# nix build .#checks.x86_64-linux.zitadel-pg18 -L
{ pkgs, overlay, hardenedModule }:

pkgs.testers.runNixOSTest {
  name = "zitadel-pg18";

  node.pkgsReadOnly = false;

  nodes.machine = { config, lib, pkgs, ... }: {
    imports = [ hardenedModule ];

    virtualisation.memorySize = 4096;
    virtualisation.diskSize   = 8192;

    nixpkgs.overlays = [ overlay ];

    environment.etc."zitadel-test/masterkey".text = "0123456789abcdef0123456789abcdef";
    environment.etc."zitadel-test/db.yaml".text = ''
      Database:
        postgres:
          User:
            Username: zitadel
            Password: testpassword
            SSL:
              Mode: disable
          Admin:
            Username: zitadel
            Password: testpassword
            ExistingDatabase: zitadel
            SSL:
              Mode: disable
    '';

    services.postgresql = {
      enable  = true;
      package = pkgs.postgresql_18;
      ensureDatabases = [ "zitadel" ];
      ensureUsers = [{
        name = "zitadel";
        ensureDBOwnership = true;
        ensureClauses = { createdb = true; createrole = true; };
      }];
    };

    systemd.services.zitadel-db-init = {
      description = "Prepare Zitadel's PostgreSQL role";
      after      = [ "postgresql-setup.service" ];
      requires   = [ "postgresql-setup.service" ];
      before     = [ "zitadel.service" ];
      requiredBy = [ "zitadel.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        RemainAfterExit = true;
      };
      # SQL on stdin, not -c: psql only interpolates :'pw' in the lexed stream.
      script = ''
        ${config.services.postgresql.package}/bin/psql -v ON_ERROR_STOP=1 --no-psqlrc \
          -v pw="testpassword" <<'SQL'
        ALTER ROLE zitadel WITH PASSWORD :'pw';
        SQL
      '';
    };

    services.zitadel = {
      enable       = true;
      openFirewall = false;
      tlsMode      = "external";
      masterKeyFile      = "/etc/zitadel-test/masterkey";
      extraSettingsPaths = [ "/etc/zitadel-test/db.yaml" ];
      settings = {
        Port           = 8090;
        ExternalDomain = "auth.example.com";
        ExternalPort   = 443;
        ExternalSecure = true;

        Database.postgres = {
          Host     = "127.0.0.1";
          Port     = 5432;
          Database = "zitadel";
          MaxOpenConns    = 15;
          MaxIdleConns    = 10;
          MaxConnLifetime = "1h";
          MaxConnIdleTime = "5m";
        };
      };
    };

    system.stateVersion = "25.11";
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("postgresql.service")
    machine.wait_for_unit("zitadel-db-init.service")

    machine.wait_for_unit("zitadel.service", timeout=300)
    machine.wait_for_open_port(8090, timeout=300)

    machine.wait_until_succeeds(
        "curl -sSf http://127.0.0.1:8090/debug/healthz", timeout=300
    )

    discovery = machine.succeed(
        "curl -sSf -H 'Host: auth.example.com' "
        "http://127.0.0.1:8090/.well-known/openid-configuration"
    )
    assert "auth.example.com" in discovery, discovery

    # The console's own OIDC client has no registered redirect_uri, so hitting
    # /oauth/v2/authorize directly can't be used to test v1/v2; read the
    # feature flag straight from Zitadel's own projection instead.
    login_v2_feature = machine.succeed(
        "sudo -u postgres psql -tAd zitadel -c "
        "\"select coalesce(value::text, 'ABSENT') from projections.instance_features5 "
        "where key='login_v2'\""
    ).strip()
    assert login_v2_feature != "ABSENT", (
        "no login_v2 row in instance_features5: "
        "DefaultInstance.Features.LoginV2.Required was not applied"
    )
    assert login_v2_feature == "{}", (
        f"login v2 is required on the new instance: {login_v2_feature}"
    )

    tables = machine.succeed(
        "sudo -u postgres psql -tAd zitadel -c "
        "\"select count(*) from information_schema.tables where table_schema='projections'\""
    )
    assert int(tables.strip()) > 0, f"no projection table: {tables}"

    machine.fail(
        "journalctl -u zitadel.service | grep -q 'cannot be unlogged'"
    )

    persistence = machine.succeed(
        "sudo -u postgres psql -tAd zitadel -c "
        "\"select c.relname||'='||c.relpersistence::text from pg_class c "
        "join pg_namespace n on n.oid=c.relnamespace "
        "where n.nspname='cache' and c.relkind in ('r','p') order by c.relname\""
    )
    print(f"cache schema persistence:\n{persistence}")
    assert "objects=p" in persistence, persistence
    assert "string_keys=p" in persistence, persistence

    parts = machine.succeed(
        "sudo -u postgres psql -tAd zitadel -c "
        "\"select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace "
        "where n.nspname='cache' and c.relname like 'objects\\_%' \""
    )
    assert int(parts.strip()) >= 1, f"no cache partition created: {parts}"
  '';
}
