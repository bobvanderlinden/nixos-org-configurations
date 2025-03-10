{ resources, config, lib, pkgs, ... }:
let
  inherit (lib) filterAttrs flip mapAttrsToList;

  macs = filterAttrs (_: v: (v.macosGuest or {}).enable or false) resources.machines;
in {
  imports =  [
    ../modules/rfc39.nix
    ../modules/prometheus
    ./eris/packet-spot-market-prices.nix
    ./eris/github-project-monitor.nix
    ./eris/alertmanager-matrix-forwarder.nix
    ./eris/channel-monitor.nix
  ];
  deployment.targetEnv = "hetzner";
  deployment.hetzner.mainIPv4 = "138.201.32.77";


  networking.extraHosts = ''
    10.254.1.1 bastion
    10.254.1.3 ceres

    10.254.1.9 haumea

    10.254.3.1 webserver

    '' + (toString (flip mapAttrsToList macs (machine: v: ''
    ${v.deployment.targetHost} ${machine}
    '')));

  networking.firewall.allowedTCPPorts = [
    443 80 # nginx
    9090 # prometheus's web UI
    9200 # hydra-queue-runner rexporter
  ];

  networking.firewall.interfaces.wg0.allowedTCPPorts = [
    9093 # alertmanager
  ];

  services.nginx = {
    enable = true;
    virtualHosts."monitoring.nixos.org" = {
      enableACME = true;
      forceSSL = true;
      locations."/".return = "302 https://status.nixos.org";
      locations."/prometheus/".proxyPass = "http://${config.services.prometheus.listenAddress}:${toString config.services.prometheus.port}";
      locations."/grafana/".proxyPass = "http://${config.services.grafana.addr}:${toString config.services.grafana.port}/";
    };
  };

  services.prometheus = {
    enable = true;
    extraFlags = [
      "--storage.tsdb.retention=${toString (150 * 24)}h"
      "--web.external-url=https://monitoring.nixos.org/prometheus/"
    ];

    exporters.blackbox = {
      enable = true;
      listenAddress = "127.0.0.1";
      configFile = pkgs.writeText "probes.yml" (builtins.toJSON {
        modules.https_success = {
          prober = "http";
          tcp.tls = true;
          http.headers.User-Agent = "blackbox-exporter";
        };
      });
    };

    alertmanagers = [
      {
        scheme = "http";
        static_configs = [
          {
            targets = [ "localhost:${toString config.services.prometheus.alertmanager.port}" ];
          }
        ];
      }
    ];

    alertmanager = {
      enable = true;
      webExternalUrl = "http://10.254.1.4:9093/";
      configuration = {
        global = {};
        route = {
          receiver = "ignore";
          group_wait = "30s";
          group_interval = "5m";
          repeat_interval = "4h";
          group_by = [ "alertname" ];

          routes = [
            {
              receiver = "go-neb";
              group_wait = "30s";
              match.severity = "warning";
            }
          ];
        };
        receivers = [
          {
            # with no *_config, this will drop all alerts directed to it
            name = "ignore";
          }
          {
            name = "go-neb";
            webhook_configs = [
              {
                url = "${config.services.go-neb.baseUrl}:4050/services/hooks/YWxlcnRtYW5hZ2VyX3NlcnZpY2U";
                send_resolved = true;
              }
            ];
          }
        ];
      };
    };

    rules = [ (builtins.toJSON {
      groups = [
        {
          name = "hydra";
          rules = [
            {
              alert = "BuildsStuckOverTwoDays";
              expr = ''hydra_machine_build_duration_bucket{le="+Inf"} - ignoring(le) hydra_machine_build_duration_bucket{le="172800"} > 0'';
              for = "30m";
              labels.severity = "warning";
              annotations.summary = "{{ $labels.machine }} has {{ $value }} over-age jobs.";
              annotations.grafana = "https://monitoring.nixos.org/grafana/d/j0hJAY1Wk/in-progress-build-duration-heatmap";
            }

            {
              alert = "BuilderTypeMissing";
              expr = ''
                hydra_machine_type_runnable > 0 and hydra_machine_type_running == 0 and (hydra_machine_type_last_active_total < time() - (2*86400))
              '';
              labels.severity = "warning";
              annotations.summary = "Runnable jobs for {{ $labels.machineType }}, but no runners to execute.";
              annotations.grafana = "https://monitoring.nixos.org/grafana/d/MJw9PcAiz/hydra-jobs?orgId=1&from=now-7d&to=now&refresh=5m&var-machine=All&viewPanel=2";
            }
          ];
        }

        {
          name = "system";
          rules = let
            diskSelector = ''mountpoint=~"(/|/scratch)"'';
            relevantLabels = "device,fstype,instance,mountpoint";
          in
          [
            {
              alert = "PartitionLowInodes";
              expr = ''
                avg (node_filesystem_files_free{${diskSelector}} <= 10000) by (${relevantLabels})
              '';
              for = "30m";
              labels.severity = "warning";
              annotations.summary = "{{ $labels.device }} mounted to {{ $labels.mountpoint }} ({{ $labels.fstype }}) on {{ $labels.instance }} has {{ $value }} inodes free.";
              annotations.grafana = "https://monitoring.nixos.org/grafana/d/5LANB9pZk/per-instance-metrics?orgId=1&refresh=30s&var-instance={{ $labels.instance }}";
            }

            {
              alert = "PartitionLowDiskSpace";
              expr = ''
                (avg (round(node_filesystem_avail_bytes{${diskSelector}} * 10^(-9) <= 10)) by (${relevantLabels}))
                or
                (avg (((node_filesystem_avail_bytes{${diskSelector}} / node_filesystem_size_bytes) * 100) <= 10) by (${relevantLabels}))
              '';
              for = "30m";
              labels.severity = "warning";
              annotations.summary = "{{ $labels.device }} mounted to {{ $labels.mountpoint }} ({{ $labels.fstype }}) on {{ $labels.instance }} has {{ $value }} GB free.";
              annotations.grafana = "https://monitoring.nixos.org/grafana/d/5LANB9pZk/per-instance-metrics?orgId=1&refresh=30s&var-instance={{ $labels.instance }}";
            }
          ];
        }

        {
          name = "scheduled-jobs";
          rules = [
            {
              alert = "RFC39MaintainerSync";
              expr = ''node_systemd_unit_state{name=~"^rfc39-sync.service$", state="failed"} == 1'';
              for = "30m";
              labels.severity = "warning";
              annotations.grafana = "https://monitoring.nixos.org/grafana/d/fBW4tL1Wz/scheduled-task-state-channels-website?orgId=1&refresh=10s";
            }
            {
              alert = "ChannelUpdateStuck";
              expr = ''max_over_time(node_systemd_unit_state{name=~"^update-nix.*.service$",state=~"failed"}[5m]) == 1'';
              for = "30m";
              labels.severity = "warning";
              annotations.summary = "{{ $labels.name }} on {{ $labels.instance }}";
              annotations.grafana = "https://monitoring.nixos.org/grafana/d/fBW4tL1Wz/scheduled-task-state-channels-website?orgId=1&refresh=10s";
            }
          ];
        }

        {
          name = "blackbox";
          rules = [
            {
              alert = "CertificateExpiry";
              expr = "probe_ssl_earliest_cert_expiry - time() < 86400 * 14";
              for = "10m";
              labels.severity = "warning";
              annotations.summary = "Certificate for {{ $labels.instance }} is expiring soon.";
            }
          ];
        }
      ];
    }) ];

    globalConfig.scrape_interval = "15s";
    scrapeConfigs = [
      {
        job_name = "node";
        static_configs = [
          {
            targets = flip mapAttrsToList resources.machines (machine: v: "${v.networking.hostName}:9100");
            labels.role = "unknown";
          }
          {
            targets = [
              "haumea:9100"
            ];
            labels.role = "database";
          }
          {
            targets = [
              "webserver:9100"
            ];
            labels.role = "webserver";
          }
          {
            targets = [
              "bastion:9100"
            ];
            labels.role = "bastion";
          }
          {
            targets = flip mapAttrsToList macs (machine: v: "${machine}:9101");
            labels.mac = "guest";
            labels.role = "builder";
          }
          {
            targets = flip mapAttrsToList macs (machine: v: "${machine}:9100");
            labels.mac = "host";
            labels.role = "builder";
          }
        ];
      }
      {
        job_name = "nixos";
        static_configs = [
          {
            targets = flip mapAttrsToList resources.machines (machine: v: "${v.networking.hostName}:9300");
          }
          {
            targets = [
              "webserver:9300"
            ];
            labels.role = "webserver";
          }
          {
            targets = [
              "bastion:9300"
            ];
            labels.role = "bastion";
          }
        ];
      }
      {
        job_name = "packet_nodes";
        file_sd_configs = [
          {
            files = [ "/var/lib/packet-sd/packet-sd.json" ];
            refresh_interval = "30s";
          }
        ];
        relabel_configs = [
          {
            source_labels = [ "__meta_packet_public_ipv4" ];
            target_label = "__address__";
            replacement = "\${1}:9100";
            action = "replace";
          }
          {
            source_labels = [ "__meta_packet_facility" ];
            target_label = "facility";
          }
          {
            source_labels = [ "__meta_packet_facility" ];
            target_label = "packet_facility";
          }
          {
            source_labels = [ "__meta_packet_plan" ];
            target_label = "plan";
          }
          {
            source_labels = [ "__meta_packet_plan" ];
            target_label = "packet_plan";
          }
          { # todo: change from _id to _uuid
            source_labels = [ "__meta_packet_switch_id" ];
            target_label = "packet_switch_id";
          }
          {
            source_labels = [ "__meta_packet_device_id" ];
            target_label = "packet_device_id";
          }
          {
            source_labels = [ "__meta_packet_state" ];
            target_label = "packet_device_state";
          }
          {
            source_labels = [ "__meta_packet_short_id" ];
            target_label = "instance";
            replacement = "\${1}.packethost.net";
            action = "replace";
          }
          {
            source_labels = [ "__meta_packet_tags" ];
            target_label = "role";
            regex = ".*hydra.*";
            replacement = "builder";
            action = "replace";
          }
          {
            source_labels = [ "__meta_packet_tags" ];
            regex = ".*prometheus-scraping-disabled.*";
            action = "drop";
          }
        ];
      }
      {
        job_name = "haumea-postgresql";
        metrics_path = "/metrics";
        static_configs = [
          {
            targets = [
              "haumea:9187"
            ];
          }
        ];
      }
      {
        job_name = "fastly";
        metrics_path = "/metrics";
        static_configs = [
          {
            targets = [
              "127.0.0.1:9118"
            ];
          }
        ];
      }
      {
        job_name = "rfc39";
        metrics_path = "/";
        static_configs = [
          {
            targets = [
              "127.0.0.1:9190"
            ];
          }
        ];
      }
      {
        job_name = "hydra-reexport";
        metrics_path = "/";
        static_configs = [
          {
            targets = [
              "monitoring.nixos.org:9200"
            ];
          }
        ];
      }
      {
        job_name = "hydra";
        metrics_path = "/prometheus";
        scheme = "https";
        static_configs = [
          {
            targets = [
              "hydra.nixos.org:443"
            ];
          }
        ];
      }
      {
        job_name = "hydra_notify";
        metrics_path = "/metrics";
        scheme = "http";
        static_configs = [
          {
            targets = [
              "hydra.nixos.org:9199"
            ];
          }
        ];
      }

      {
        job_name = "hydra-webserver";
        metrics_path = "/metrics";
        scheme = "https";
        static_configs = [
          {
            targets = [
              "hydra.nixos.org:443"
            ];
          }
        ];
      }


      {
        job_name = "prometheus-packet-sd";
        metrics_path = "/metrics";
        static_configs = [
          {
            targets = [
              "127.0.0.1:9465"
            ];
          }
        ];
      }

      {
        job_name = "prometheus-packet-spot-price-exporter";
        metrics_path = "/metrics";
        static_configs = [
          {
            targets = [
              "127.0.0.1:9400"
            ];
          }
        ];
      }

      {
        job_name = "prometheus-github-exporter";
        metrics_path = "/";
        static_configs = [
          {
            targets = [
              "127.0.0.1:9401"
            ];
          }
        ];
      }

      {
        job_name = "r13y";
        scheme = "https";
        metrics_path = "/metrics";
        static_configs = [
          {
            targets = [
              "r13y.com"
            ];
          }
        ];
      }

      {
        job_name = "channel-updates";
        metrics_path = "/";
        static_configs = [
          {
            targets = [
              "127.0.0.1:9402"
            ];
          }
        ];
      }
    ]
    ++ (let
      mkProbe = module: targets: {
        job_name = "blackbox-${module}";
        metrics_path = "/probe";
        params = {
          module = [ module ];
        };
        static_configs = [{ inherit targets; }];
        relabel_configs = [ {
          source_labels = [ "__address__" ];
          target_label = "__param_target";
        } {
          source_labels = [ "__param_target" ];
          target_label = "instance";
        } {
          target_label = "__address__";
          replacement = "localhost:9115";
        } ];
      }; in [
        (mkProbe "https_success" [
          "https://cache.nixos.org"
          "https://channels.nixos.org"
          "https://common-styles.nixos.org"
          "https://conf.nixos.org"
          "https://discourse.nixos.org"
          "https://hydra.nixos.org"
          "https://mobile.nixos.org"
          "https://monitoring.nixos.org"
          "https://nixos.org"
          "https://planet.nixos.org"
          "https://releases.nixos.org"
          "https://status.nixos.org"
          "https://survey.nixos.org"
          "https://tarballs.nixos.org"
          "https://weekly.nixos.org"
          "https://www.nixos.org"
        ])
      ]
    )
    ++ lib.mapAttrsToList (name: value: {
        job_name = "channel-job-${name}";
        scheme = "https";
        scrape_interval = "5m";
        metrics_path = "/job/${value.job}/prometheus";
        static_configs = [ {
          labels = {
            current = if value.status != "unmaintained" then "1" else "0";
            channel = name;
          };
          targets = [ "hydra.nixos.org:443" ];
        } ];
      }) (import ../channels.nix).channels;
  };

  services.grafana = {
    enable = true;
    auth.anonymous.enable = true;
    users.allowSignUp = true;
    addr = "0.0.0.0";
    domain = "monitoring.nixos.org";
    rootUrl = "https://monitoring.nixos.org/grafana/";
  };

  systemd.services.prometheus-hydra-exporter = {
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "60s";
      PrivateTmp =  true;
      WorkingDirectory = "/tmp";
      ExecStart = let
          python = pkgs.python3.withPackages (p: [
             p.requests p.prometheus_client
          ]);
        in ''
          ${python}/bin/python ${./prometheus/hydra-queue-runner-reexporter.py}
      '';
    };
  };

  deployment.keys."packet-sd-env" = {
    keyFile = /home/deploy/src/nixos-org-configurations/prometheus-packet-service-discovery;
    user = "packet-sd";
  };

  users.users.packet-sd = {
    description = "Prometheus Packet Service Discovery";
    isSystemUser = true;
    group = "packet-sd";
  };
  users.groups.packet-sd = {};

  systemd.tmpfiles.rules = [
    "d /var/lib/packet-sd 0755 packet-sd - -"
    "f /var/lib/packet-sd/packet-sd.json 0644 packet-sd - -"
  ];

  systemd.services.prometheus-packet-sd = let
    sd = pkgs.callPackage ./prometheus/packet-sd.nix {};
  in {
    wantedBy = [ "multi-user.target" "prometheus.service" ];
    after = [ "network.target" ];

    serviceConfig = {
      User = "packet-sd";
      Group = "keys";
      ExecStart = "${sd}/bin/prometheus-packet-sd --output.file=/var/lib/packet-sd/packet-sd.json";
      EnvironmentFile = "/run/keys/packet-sd-env";
      Restart = "always";
      RestartSec = "60s";
    };
  };

  deployment.keys."fastly-read-only-api-token" = {
    keyFile = /home/deploy/src/nixos-org-configurations/fastly-read-only-api-token;
  };

  systemd.services.prometheus-fastly-exporter = let
    fastly = pkgs.callPackage ./prometheus/fastly.nix {};
  in {
    wantedBy = [ "multi-user.target" "prometheus.service" ];
    after = [ "network.target" ];

    script = ''
      export FASTLY_API_TOKEN=$(cat /run/keys/fastly-read-only-api-token)
      ${fastly}/bin/fastly-exporter \
        -endpoint http://127.0.0.1:9118/metrics
    '';

    serviceConfig = {
      Group = "keys";
      Restart = "always";
      RestartSec = "60s";
    };
  };
}
