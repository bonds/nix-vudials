{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.vudials;
in {
  options.services.vudials = {
    enable = mkEnableOption "VU Dials";

    port = mkOption {
      type = types.port;
      default = 5340;
      description = "Port on which VU Server listens.";
    };

    device = mkOption {
      type = types.str;
      default = "/dev/cu.usbserial-DQ0164KM";
      description = "Serial device path for the VU1 hub.";
    };

    runtimedir = mkOption {
      type = types.str;
      default = "/tmp/vuserver/run";
      description = "Runtime directory for www files and PID.";
    };

    statedir = mkOption {
      type = types.str;
      default = "/tmp/vuserver/state";
      description = "State directory for database and key file.";
    };

    logsdir = mkOption {
      type = types.str;
      default = "/tmp/vuserver/logs";
      description = "Log directory.";
    };

    cpudial = mkOption {
      type = types.str;
      default = "";
      description = "UID of the dial that will display CPU load.";
    };

    gpudial = mkOption {
      type = types.str;
      default = "";
      description = "UID of the dial that will display GPU load.";
    };

    memdial = mkOption {
      type = types.str;
      default = "";
      description = "UID of the dial that will display memory load.";
    };

    dskdial = mkOption {
      type = types.str;
      default = "";
      description = "UID of the dial that will display disk usage on root partition.";
    };

    key = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "API key for vuclient to authenticate with vuserver. If null, reads from statedir/key at runtime.";
    };

    user = mkOption {
      type = types.str;
      default = "vudials";
      description = "User account under which VU Dials runs.";
    };

    group = mkOption {
      type = types.str;
      default = "vudials";
      description = "Group under which VU Dials runs.";
    };
  };

  config = mkIf cfg.enable (
    let
      isDarwin = config.nixpkgs.hostPlatform.isDarwin;
    in
      {
        environment.systemPackages = [pkgs.vuserver];
      }
      // lib.optionalAttrs isDarwin {
        system.activationScripts.vudials.text = ''
          _vuhash="${pkgs.vuserver} ${pkgs.vuclient}"
          if [ -f "${cfg.statedir}/.vu-hash" ] && [ "$(cat "${cfg.statedir}/.vu-hash")" != "$_vuhash" ]; then
            launchctl kickstart -k gui/501/org.nixos.vuserver 2>/dev/null || true
            launchctl kickstart -k gui/501/org.nixos.vuclient 2>/dev/null || true
          fi
          mkdir -p ${cfg.statedir}
          echo -n "$_vuhash" > "${cfg.statedir}/.vu-hash"
        '';

        launchd.user.agents = {
          vuserver = {
            command = "${pkgs.vuserver}/bin/vuserver";
            serviceConfig = {
              KeepAlive = true;
              RunAtLoad = true;
              StandardOutPath = "${cfg.logsdir}/stdout.log";
              StandardErrorPath = "${cfg.logsdir}/stderr.log";
              EnvironmentVariables = {
                STATEDIR = cfg.statedir;
                LOGSDIR = cfg.logsdir;
                RUNTIMEDIR = cfg.runtimedir;
                PORT = toString cfg.port;
                DEVICE = cfg.device;
              };
            };
          };

          vuclient = {
            command = "${pkgs.vuclient}/bin/vuclient";
            serviceConfig = {
              KeepAlive = true;
              RunAtLoad = true;
              StandardOutPath = "/tmp/vuclient.out.log";
              StandardErrorPath = "/tmp/vuclient.err.log";
              EnvironmentVariables =
                {
                  CPUDIAL = cfg.cpudial;
                  GPUDIAL = cfg.gpudial;
                  MEMDIAL = cfg.memdial;
                  DSKDIAL = cfg.dskdial;
                  VU_KEY_FILE = "${cfg.statedir}/key";
                }
                // lib.optionalAttrs (cfg.key != null) {
                  VU_API_KEY = cfg.key;
                };
            };
          };
        };
      }
      // lib.optionalAttrs (!isDarwin) {
        users.users.${cfg.user} = {
          isSystemUser = true;
          group = cfg.group;
          description = "VU Server user";
        };

        users.groups.${cfg.group} = {};

        services.udev.extraRules = ''
          ACTION=="add", SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6015", ATTRS{serial}=="DQ0164KM", SYMLINK+="vuserver-$attr{serial}", TAG+="systemd", ENV{SYSTEMD_WANTS}="vuserver@$attr{serial}.service", MODE="0666"
          ACTION=="remove", SUBSYSTEM=="tty", ENV{ID_VENDOR_ID}=="0403", ENV{ID_MODEL_ID}=="6015", ENV{ID_SERIAL_SHORT}=="DQ0164KM", RUN+="${pkgs.systemd}/bin/systemctl stop vuserver@$env{ID_SERIAL_SHORT}.service"
        '';

        systemd.services."vuserver@" = {
          description = "VU Server for %I. Provides API, admin web page, and pushed updates to USB dials";
          partOf = ["vuserver.target"];

          serviceConfig = {
            ExecStart = "${pkgs.vuserver}/bin/vuserver";
            User = cfg.user;
            Group = cfg.group;
            Restart = "on-failure";
            WorkingDirectory = "${pkgs.vuserver}/lib";
            RuntimeDirectory = "vuserver";
            LogsDirectory = "vuserver";
            StateDirectory = "vuserver";
            TimeoutStopSec = "1s";
            Environment = [
              "STATEDIR=%S/vuserver"
              "LOGSDIR=%L/vuserver"
              "RUNTIMEDIR=%t/vuserver"
              "DEVICE=/dev/vuserver-%I"
              "PORT=${toString cfg.port}"
            ];
          };
        };

        systemd.targets.vuserver = {};

        systemd.services.vuclient = {
          enable = true;
          description = "Monitor computer and push info to VU server.";
          wantedBy = ["multi-user.target"];
          wants = ["vuserver.target"];
          after = ["vuserver.target"];
          serviceConfig = {
            ExecStart = "${pkgs.vuclient}/bin/vuclient";
            TimeoutStopSec = "5s";
            Restart = "on-failure";
            Environment = [
              "CPUDIAL=${cfg.cpudial}"
              "GPUDIAL=${cfg.gpudial}"
              "MEMDIAL=${cfg.memdial}"
              "DSKDIAL=${cfg.dskdial}"
            ];
          };
        };

        powerManagement.powerDownCommands = mkAfter ''
          systemctl stop vuclient.service
          sleep 1
        '';

        powerManagement.powerUpCommands = mkAfter ''
          systemctl start vuclient.service
        '';
      }
  );
}
