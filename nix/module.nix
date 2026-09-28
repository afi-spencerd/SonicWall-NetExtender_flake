{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.netextender;

  deviceUnit = "sys-subsystem-net-devices-${cfg.splitDns.interface}.device";

  resolvectl = lib.getExe' config.systemd.package "resolvectl";

  # NetExtender applies VPN DNS by piping a resolv.conf into
  # `resolvconf -a <iface>`, which is all-or-nothing: openresolv merges the
  # appliance's nameservers into /etc/resolv.conf for every lookup on the host,
  # and drops whatever `domain`/`search` line another source contributed. The
  # appliance pushes no suffix of its own (`domainSuffixes` comes back empty),
  # so unqualified corporate names stop resolving at the same time.
  #
  # With splitDns on we want resolved to own the link, so hand NEService a
  # `resolvconf` that does nothing rather than let it race us for
  # /etc/resolv.conf. Stubbing rather than removing matters: the binary falls
  # back to bind-mounting /etc/resolv.conf inside its own (private, and
  # therefore inert) mount namespace when no `resolvconf` is on PATH, and there
  # is no reason to disturb a code path that already has no effect.
  noopResolvconf = pkgs.writeShellScriptBin "resolvconf" ''
    # services.netextender.splitDns is enabled: DNS for the tunnel belongs to
    # netextender-split-dns.service, which applies it through resolved.
    exit 0
  '';

  routingDomains = lib.escapeShellArgs (map (d: "~${d}") cfg.splitDns.domains);

  splitDnsScript = pkgs.writeShellScript "netextender-split-dns" ''
    set -euo pipefail

    iface=${lib.escapeShellArg cfg.splitDns.interface}

    # nxcli puts its terminal into raw mode unconditionally -- even for
    # `status --format`, and even when stdout is a pipe or a regular file --
    # and prints nothing at all when that fails. `script` lends it a pty so the
    # JSON actually comes out.
    read_status() {
      ${lib.getExe' pkgs.util-linux "script"} -qec \
        ${lib.escapeShellArg "${lib.getExe' cfg.package "nxcli"} status -f"} /dev/null \
        2>/dev/null | tr -d '\r'
    }

    # The .device unit activates the moment the tun appears, which is a beat
    # before NEService finishes IPCP and can report the negotiated servers.
    servers=
    for _ in $(seq 1 40); do
      servers=$(read_status | ${lib.getExe pkgs.jq} -r '.nameServers // empty' 2>/dev/null || true)
      [ -n "$servers" ] && break
      sleep 0.5
    done

    if [ -z "$servers" ]; then
      echo "netextender-split-dns: no nameservers reported for $iface after 20s" >&2
      exit 1
    fi

    # `servers` is a comma-separated list; leave it unquoted so it splits.
    ${resolvectl} dns "$iface" ''${servers//,/ }
    ${resolvectl} domain "$iface" ${routingDomains}

    # The point of the exercise: without this the link answers everything else
    # too, which is the full-tunnel DNS we are trying to get away from.
    ${resolvectl} default-route "$iface" false
  '';
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
      default = if cfg.splitDns.enable then noopResolvconf else pkgs.openresolv;
      defaultText = lib.literalExpression ''
        if config.services.netextender.splitDns.enable then
          a no-op `resolvconf` stub
        else
          pkgs.openresolv
      '';
      description = ''
        Package providing the `resolvconf` command that NEService pipes the
        VPN-pushed DNS settings into (and that the bundled `wg-quick` uses).

        On a systemd-resolved host, set this to `config.systemd.package` (its
        `resolvconf` shim forwards to resolved) instead of openresolv. When
        {option}`services.netextender.splitDns.enable` is set this defaults to a
        stub that discards the call, because the tunnel's DNS is then applied by
        `netextender-split-dns.service` and the two must not both write it.
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

    splitDns = {
      enable = lib.mkEnableOption ''
        split DNS for the NetExtender tunnel through systemd-resolved.

        NetExtender itself has no notion of split DNS: it hands the appliance's
        nameservers to `resolvconf` and they become the resolvers for every
        lookup on the host. This instead registers them with resolved as the
        tunnel link's servers, restricted to
        {option}`services.netextender.splitDns.domains`, so the rest of your
        traffic keeps using the local network's resolver
      '';

      domains = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "example.com"
          "12.168.192.in-addr.arpa"
        ];
        description = ''
          Domains routed to the VPN's nameservers, registered with resolved as
          routing-only domains (`~domain`). Everything outside this list is left
          to whatever resolver the host would otherwise use.

          The appliance pushes no suffix of its own, so this list is the only
          thing that sends queries over the tunnel. Include reverse zones for
          the pushed subnets if you want PTR lookups to go over it too.
        '';
      };

      interface = lib.mkOption {
        type = lib.types.str;
        default = "snwl_ssltunnel";
        description = ''
          Name of the tun interface NEService creates for the SSL-VPN tunnel.
          The helper unit is bound to this interface's systemd `.device` unit.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    assertions = [
      {
        assertion = cfg.splitDns.enable -> config.services.resolved.enable;
        message = ''
          services.netextender.splitDns.enable requires services.resolved.enable:
          split DNS is applied with `resolvectl`, and only resolved can route
          individual domains to a particular link.
        '';
      }
      {
        assertion = cfg.splitDns.enable -> cfg.splitDns.domains != [ ];
        message = ''
          services.netextender.splitDns.domains is empty, so no query would ever
          use the tunnel's nameservers. List the domains that should resolve
          over the VPN (e.g. your AD domain).
        '';
      }
    ];

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

    # Triggered by the tunnel interface rather than by NEService, because the
    # daemon runs continuously and the tunnel comes and goes underneath it.
    systemd.services.netextender-split-dns = lib.mkIf cfg.splitDns.enable {
      description = "Split DNS for the SonicWall NetExtender tunnel";
      bindsTo = [ deviceUnit ];
      after = [
        deviceUnit
        "NEService.service"
        "systemd-resolved.service"
      ];
      wantedBy = [ deviceUnit ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = splitDnsScript;
        # Best-effort: when the tunnel drops, the link and its settings go with
        # it, so a failure here is not interesting.
        ExecStop = "-${resolvectl} revert ${cfg.splitDns.interface}";
      };
    };

    # wg-quick uses the kernel WireGuard module when present and transparently
    # falls back to the bundled wireguard-go otherwise; enable the module so the
    # faster in-kernel path is available.
    boot.extraModulePackages = lib.mkDefault [ ];
    boot.kernelModules = lib.mkDefault [ "wireguard" ];
  };
}
