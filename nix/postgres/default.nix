# Based on https://github.com/cachix/devenv/blob/main/src/modules/services/postgres.nix
{ name, config, pkgs, lib, ... }:
with lib.types; let
  inherit (lib) types;
in
{
  options = {
    enable = lib.mkEnableOption name;

    package = lib.mkOption {
      type = types.package;
      description = "Which package of postgresql to use";
      default = pkgs.postgresql;
      defaultText = lib.literalExpression "pkgs.postgresql";
      apply = postgresPkg:
        if config.extensions != null then
          if builtins.hasAttr "withPackages" postgresPkg
          then postgresPkg.withPackages config.extensions
          else
            builtins.throw ''
              Cannot add extensions to the PostgreSQL package.
              `services.postgres.package` is missing the `withPackages` attribute. Did you already add extensions to the package?
            ''
        else postgresPkg;

    };

    extensions = lib.mkOption {
      type = with types; nullOr (functionTo (listOf package));
      default = null;
      example = lib.literalExpression ''
        extensions: [
          extensions.pg_cron
          extensions.postgis
          extensions.timescaledb
        ];
      '';
      description = ''
        Additional PostgreSQL extensions to install.

        The available extensions are:

        ${lib.concatLines (builtins.map (x: "- " + x) (builtins.attrNames pkgs.postgresql.pkgs))}
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "./data/${name}";
      description = "The DB data directory";
    };

    socketDir = lib.mkOption {
      type = lib.types.str;
      default = config.dataDir;
      description = "The DB socket directory";
    };

    hbaConf =
      let
        hbaConfSubmodule = lib.types.submodule {
          options = {
            type = lib.mkOption { type = lib.types.str; };
            database = lib.mkOption { type = lib.types.str; };
            user = lib.mkOption { type = lib.types.str; };
            address = lib.mkOption { type = lib.types.str; };
            method = lib.mkOption { type = lib.types.str; };
          };
        };
      in
      lib.mkOption {
        type = lib.types.listOf hbaConfSubmodule;
        default = [ ];
        description = ''
          A list of objects that represent the entries in the pg_hba.conf file.

          Each object has sub-options for type, database, user, address, and method.

          See the official PostgreSQL documentation for more information:
          https://www.postgresql.org/docs/current/auth-pg-hba-conf.html
        '';
        example = [
          { type = "local"; database = "all"; user = "postgres"; address = ""; method = "md5"; }
          { type = "host"; database = "all"; user = "all"; address = "0.0.0.0/0"; method = "md5"; }
        ];
      };
    hbaConfFile =
      let
        # Default pg_hba.conf entries
        defaultHbaConf = [
          { type = "local"; database = "all"; user = "all"; address = ""; method = "trust"; }
          { type = "host"; database = "all"; user = "all"; address = "127.0.0.1/32"; method = "trust"; }
          { type = "host"; database = "all"; user = "all"; address = "::1/128"; method = "trust"; }
          { type = "local"; database = "replication"; user = "all"; address = ""; method = "trust"; }
          { type = "host"; database = "replication"; user = "all"; address = "127.0.0.1/32"; method = "trust"; }
          { type = "host"; database = "replication"; user = "all"; address = "::1/128"; method = "trust"; }
        ];

        # Merge the default pg_hba.conf entries with the user-defined entries
        hbaConf = defaultHbaConf ++ config.hbaConf;

        # Convert the pgHbaConf array to a string
        hbaConfString = ''
          # Generated by Nix
          ${"# TYPE\tDATABASE\tUSER\tADDRESS\tMETHOD\n"}
          ${lib.concatMapStrings (cnf: "  ${cnf.type}\t${cnf.database}\t${cnf.user}\t${cnf.address}\t${cnf.method}\n") hbaConf}
        '';
      in
      lib.mkOption {
        type = lib.types.package;
        internal = true;
        readOnly = true;
        description = "The `pg_hba.conf` file.";
        default = pkgs.writeText "pg_hba.conf" hbaConfString;
      };

    listen_addresses = lib.mkOption {
      type = lib.types.str;
      description = "Listen address";
      default = "";
      example = "127.0.0.1";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5432;
      description = ''
        The TCP port to accept connections.
      '';
    };

    superuser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of superuser.
        null defaults to $USER
      '';
    };

    createDatabase = lib.mkOption {
      type = types.bool;
      default = true;
      description = ''
        Create a database named like current user on startup. Only applies when initialDatabases is an empty list.
      '';
    };

    initdbArgs = lib.mkOption {
      type = types.listOf types.lines;
      default = [ "--locale=C" "--encoding=UTF8" ];
      example = [ "--data-checksums" "--allow-group-access" ];
      description = ''
        Additional arguments passed to `initdb` during data dir
        initialisation.
      '';
    };

    defaultSettings =
      lib.mkOption {
        type = with lib.types; attrsOf (oneOf [ bool float int str ]);
        internal = true;
        readOnly = true;
        description = ''
          Default configuration for `postgresql.conf`. `settings` can override these values.
        '';
        default = {
          listen_addresses = config.listen_addresses;
          port = config.port;
          unix_socket_directories = config.socketDir;
          hba_file = "${config.hbaConfFile}";
        };
      };

    settings =
      lib.mkOption {
        type = with lib.types; attrsOf (oneOf [ bool float int str ]);
        default = { };
        description = ''
          PostgreSQL configuration. Refer to
          <https://www.postgresql.org/docs/11/config-setting.html#CONFIG-SETTING-CONFIGURATION-FILE>
          for an overview of `postgresql.conf`.

          String values will automatically be enclosed in single quotes. Single quotes will be
          escaped with two single quotes as described by the upstream documentation linked above.
        '';
        default = {
          listen_addresses = config.listen_addresses;
          port = config.port;
          unix_socket_directories = lib.mkDefault config.socketDir;
          hba_file = "${config.hbaConfFile}";
        };
        example = lib.literalExpression ''
          {
            log_connections = true;
            log_statement = "all";
            logging_collector = true
            log_disconnections = true
            log_destination = lib.mkForce "syslog";
          }
        '';
      };

    initialDatabases = lib.mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = lib.mkOption {
            type = types.str;
            description = ''
              The name of the database to create.
            '';
          };
          schemas = lib.mkOption {
            type = types.nullOr (types.listOf types.path);
            default = null;
            description = ''
              The initial list of schemas for the database; if null (the default),
              an empty database is created.
            '';
          };
        };
      });
      default = [ ];
      description = ''
        List of database names and their initial schemas that should be used to create databases on the first startup
        of Postgres. The schema attribute is optional: If not specified, an empty database is created.
      '';
      example = lib.literalExpression ''
        [
          {
            name = "foodatabase";
            schemas = [ ./fooschemas ./bar.sql ];
          }
          { name = "bardatabase"; }
        ]
      '';
    };

    depends_on = lib.mkOption {
      description = "Extra process dependency relationships for `${name}-init` process.";
      type = types.nullOr (types.attrsOf (types.submodule {
        options = {
          condition = lib.mkOption {
            type = types.enum [
              "process_completed"
              "process_completed_successfully"
              "process_healthy"
              "process_started"
            ];
            example = "process_healthy";
          };
        };
      }));
      default = null;
    };

    initialScript = lib.mkOption {
      type = types.submodule ({ config, ... }: {
        options = {
          before = lib.mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              SQL commands to run before the database initialization.
            '';
            example = lib.literalExpression ''
              CREATE USER postgres SUPERUSER;
              CREATE USER bar;
            '';
          };
          after = lib.mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              SQL commands to run after the database initialization.
            '';
            example = lib.literalExpression ''
              CREATE TABLE users (
                id SERIAL PRIMARY KEY,
                name VARCHAR(50) NOT NULL,
                email VARCHAR(50) NOT NULL UNIQUE
              );
            '';
          };
        };
      });
      default = { before = null; after = null; };
      description = ''
        Initial SQL commands to run during database initialization. This can be multiple
        SQL expressions separated by a semi-colon.
      '';
    };
    outputs.settings = lib.mkOption {
      type = types.deferredModule;
      internal = true;
      readOnly = true;
      default =
        {
          processes = {
            # DB initialization
            "${name}-init" =
              let
                setupScript = import ./setup-script.nix { inherit config pkgs lib; };
              in
              {
                command = setupScript;
                depends_on = config.depends_on;
                namespace = name;
              };

            # DB process
            ${name} =
              let
                startScript = pkgs.writeShellApplication {
                  name = "start-postgres";
                  runtimeInputs = [ config.package pkgs.coreutils ];
                  text = ''
                    set -euo pipefail

                    set -x
                    echo "MAIN PROCESS"

                    PGDATA=$(readlink -f "${config.dataDir}")
                    PGSOCKETDIR=$(readlink -f "${config.socketDir}")
                    export PGDATA
                    postgres -k "$PGSOCKETDIR"
                  '';
                };
                pg_isreadyArgs = [
                  "-h $(readlink -f \"${config.socketDir}\")"
                  "-p ${toString config.port}"
                  "-d template1"
                ] ++ (lib.optional (config.superuser != null) "-U ${config.superuser}");
              in
              {
                command = startScript;
                # SIGINT (= 2) for faster shutdown: https://www.postgresql.org/docs/current/server-shutdown.html
                shutdown.signal = 2;
                readiness_probe = {
                  exec.command = "${config.package}/bin/pg_isready ${lib.concatStringsSep " " pg_isreadyArgs}";
                  initial_delay_seconds = 2;
                  period_seconds = 10;
                  timeout_seconds = 4;
                  success_threshold = 1;
                  failure_threshold = 5;
                };
                namespace = name;
                depends_on."${name}-init".condition = "process_completed_successfully";
                # https://github.com/F1bonacc1/process-compose#-auto-restart-if-not-healthy
                availability.restart = "on_failure";
              };
          };
        };
    };
  };
}
