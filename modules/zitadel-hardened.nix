{ config, lib, ... }:

lib.mkIf config.services.zitadel.enable {

  services.zitadel.settings = {
    ServicePing.Enabled = false;

    # This package excludes apps/login, so without this, every interactive login 404s.
    DefaultInstance.Features.LoginV2.Required = false;
  };

  systemd.services.zitadel.serviceConfig = {
    NoNewPrivileges         = true;
    PrivateTmp              = true;
    PrivateDevices          = true;
    ProtectSystem           = "strict";
    ProtectHome             = true;
    ProtectKernelTunables   = true;
    ProtectKernelModules    = true;
    ProtectControlGroups    = true;
    ProtectHostname         = true;
    ProtectClock            = true;
    # AF_NETLINK is required: Zitadel's sonyflake ID generator enumerates network interfaces.
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
    RestrictNamespaces      = true;
    RestrictSUIDSGID        = true;
    RestrictRealtime        = true;
    LockPersonality         = true;
    RemoveIPC               = true;
    # No capabilities needed; a consumer setting Port <1024 will need CAP_NET_BIND_SERVICE here.
    CapabilityBoundingSet   = "";
    SystemCallArchitectures = "native";
    SystemCallFilter        = [ "@system-service" ];
    # Relax this first if the Go binary faults with a memory-mapping error.
    MemoryDenyWriteExecute  = true;
  };
}
