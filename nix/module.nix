{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.netextender;
in
{
  options.services.netextender = {
    enable = lib.mkEnableOption "the SonicWall NetExtender VPN service (NEService)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = ''
        The NetExtender package to use. Note that NetExtender is proprietary, so
        your configuration must allow the unfree `sonicwall-netextender`
        package (e.g. `nixpkgs.config.allowUnfree = true`).
      '';
    };

    resolvconfPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openresolv;
      defaultText = lib.literalExpression "pkgs.openresolv";
      description = ''
        Package providing the `resolvconf` command used by the bundled
        `wg-quick` to apply VPN-pushed DNS settings. On a system using
        systemd-resolved, set this to `config.systemd.package` (its `resolvconf`
        shim forwards to resolved) instead of openresolv.
      '';
    };

    createBinBash = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Create a `/bin/bash` symlink. NEService references `/bin/bash`, which
        does not exist on NixOS by default. Disable if you provide `/bin/bash`
        by other means or hit a conflict.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # The vendored binaries hardcode /usr/local/netextender for wg, wg-quick and
    # the locale files; recreate that path as a symlink into the store. Also
    # provide the writable state dir wg-quick expects and, optionally, /bin/bash.
    systemd.tmpfiles.rules = [
      "L+ /usr/local/netextender - - - - ${cfg.package}/share/netextender"
      "d /etc/wireguard 0700 root root -"
    ]
    ++ lib.optional cfg.createBinBash "L+ /bin/bash - - - - ${lib.getExe pkgs.bash}";

    systemd.services.NEService = {
      description = "SonicWall NetExtender Service";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      # wg-quick (invoked by NEService) shells out to these at runtime, as does
      # NEService itself for the SSL-VPN (PPP) transport: it builds firewall
      # rules with `iptables` and applies VPN DNS by bind-mounting
      # /etc/resolv.conf inside a mount namespace (`unshare`, `mount`,
      # `umount` -- all from util-linux). Without these the tunnel still comes
      # up, but silently loses firewall rules and DNS.
      path = [
        cfg.package
        cfg.resolvconfPackage
        pkgs.iproute2
        pkgs.iptables
        pkgs.util-linux # unshare, mount, umount
        pkgs.procps # sysctl
        pkgs.gnugrep
        pkgs.gnused
        pkgs.gawk
        pkgs.coreutils
        pkgs.bash
      ];

      serviceConfig = {
        Type = "simple";
        ExecStartPre = "-${pkgs.coreutils}/bin/rm -f /run/NEService.pid";
        ExecStart = "${cfg.package}/share/netextender/NEService";
        PIDFile = "/run/NEService.pid";
        Restart = "on-failure";
        RestartSec = 3;
        # NEService reconfigures networking and manages WireGuard interfaces, so
        # it runs as root. KillMode=process mirrors the upstream unit.
        KillMode = "process";
      };
    };

    # wg-quick uses the kernel WireGuard module when present and transparently
    # falls back to the bundled wireguard-go otherwise; enable the module so the
    # faster in-kernel path is available.
    boot.extraModulePackages = lib.mkDefault [ ];
    boot.kernelModules = lib.mkDefault [ "wireguard" ];
  };
}
