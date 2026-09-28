{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.netextender;

  deviceUnit = "sys-subsystem-net-devices-${cfg.interface}.device";

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

    iface=${lib.escapeShellArg cfg.interface}

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

  # profile.json is the client's own mutable state -- NEService rewrites it on
  # connect to record the resolved address and the domain type it discovered --
  # so this cannot be an `environment.etc` symlink into the store. It is
  # rendered and copied into place instead, before the daemon starts.
  #
  # Driving `nxcli connection add` was the obvious alternative and does not
  # work: it contacts the appliance to validate, prompts interactively when it
  # cannot reach one, and its `--force` path silently discards `-d domain`.
  # `connection edit` has no `--force` at all. Both also need the daemon up,
  # and both renumber ids and move the `default` flag as a side effect.
  splitHostPort =
    s:
    let
      parts = lib.splitString ":" s;
    in
    if builtins.length parts > 1 then
      {
        host = builtins.head parts;
        port = lib.last parts;
      }
    else
      {
        host = s;
        port = null;
      };

  renderProfile =
    index: name: c:
    let
      sp = splitHostPort c.server;
      port = if sp.port != null then sp.port else toString c.port;
    in
    {
      # Ids are positional and stable for a given set of names, because the
      # attrset is already sorted; the client only uses them internally.
      id = toString (index + 1);
      default = if cfg.defaultConnection == name then "true" else "false";
      inherit name;
      server = "${sp.host}:${port}";
      # Seed value. The client replaces this with the resolved address on the
      # first connect, and the merge below keeps that result.
      host = sp.host;
      inherit port;
      inherit (c)
        username
        protocol
        domain
        clientCert
        ;
    }
    // lib.optionalAttrs (c.domainType != null) { inherit (c) domainType; };

  declaredProfiles = pkgs.writeText "netextender-profiles.json" (
    builtins.toJSON {
      profiles = lib.imap0 (i: name: renderProfile i name cfg.connections.${name}) (
        lib.attrNames cfg.connections
      );
    }
  );

  profileScript = pkgs.writeShellScript "netextender-profiles" ''
    set -euo pipefail

    dir=/etc/SonicWall/NetExtender/Config
    live=$dir/profile.json
    mkdir -p "$dir"

    # Keep one copy of whatever existed before this module took over, so the
    # first activation is not a one-way door for hand-made profiles.
    if [ -e "$live" ] && [ ! -e "$dir/profile.json.before-nixos" ]; then
      cp -a "$live" "$dir/profile.json.before-nixos"
    fi
    [ -e "$live" ] || echo '{"profiles":[]}' > "$live"

    # Declared profiles win, except for the two fields the client discovers for
    # itself -- and those are only carried over while `server` still matches,
    # since a resolved address for some other appliance is worse than none.
    ${lib.getExe pkgs.jq} -n       --slurpfile old "$live"       --slurpfile new ${declaredProfiles}       '
        ($old[0].profiles // []) as $prev
        | { profiles: [
              $new[0].profiles[]
              | . as $n
              | ($prev | map(select(.name == $n.name and .server == $n.server)) | first) as $p
              | $n
                + (if $p and ($p.host // "") != "" then { host: $p.host } else {} end)
                + (if $p and ($p.domainType // null) != null and ($n | has("domainType") | not)
                   then { domainType: $p.domainType } else {} end)
            ] }
      ' > "$live.new"

    mv "$live.new" "$live"
    chmod 0644 "$live"
  '';

  # Diagnostic only. The appliance chooses the routes and this module does not
  # filter them -- see the README -- but the failure is otherwise completely
  # silent, so at least name it in the journal.
  #
  # Both checks below defer to the kernel rather than doing prefix arithmetic in
  # shell: a collision is exactly "the same prefix is present on the tunnel and
  # on some other device", and `ip route get` answers the gateway question with
  # the same FIB lookup the stack itself would do.
  routeCollisionScript = pkgs.writeShellScript "netextender-route-collisions" ''
    # No `-e`: a check that cannot answer should not suppress the other one.
    set -uo pipefail

    iface=${lib.escapeShellArg cfg.interface}
    ip=${lib.getExe' pkgs.iproute2 "ip"}

    # Routes land a moment after the link itself does.
    for _ in $(seq 1 20); do
      [ -n "$($ip -4 route show dev "$iface" 2>/dev/null)" ] && break
      sleep 0.5
    done

    shadowed=
    while read -r prefix; do
      [ -n "$prefix" ] || continue
      others=$(
        $ip -4 route show exact "$prefix" 2>/dev/null \
          | grep -v "dev $iface" \
          | grep -oP 'dev \K[^ ]+' \
          | sort -u \
          | paste -sd' ' -
      )
      [ -n "$others" ] && shadowed="$shadowed  $prefix (this host is also on it via: $others)"$'\n'
    done <<EOF
    $($ip -4 route show dev "$iface" 2>/dev/null | grep -oP '^[0-9.]+/[0-9]+')
    EOF

    if [ -n "$shadowed" ]; then
      printf '%s\n%s' \
        "the appliance pushed routes for networks this host is already attached to:" \
        "$shadowed" >&2
      echo "traffic to those networks now goes through the VPN. The default route is" >&2
      echo "unaffected, so internet access keeps working; local hosts in those ranges are" >&2
      echo "reached the long way round, or not at all where the VPN does not serve them." >&2
    fi

    # The gateway is the case worth calling out separately: it still works,
    # because the default route pins its device and reaches it by neighbour
    # lookup rather than a recursive FIB lookup -- but everything addressed to
    # the gateway itself now detours through the appliance.
    gw=$($ip -4 route show default 2>/dev/null | grep -oP 'via \K[^ ]+' | head -1)
    if [ -n "$gw" ]; then
      gwdev=$($ip -4 route get "$gw" 2>/dev/null | grep -oP 'dev \K[^ ]+' | head -1)
      if [ "$gwdev" = "$iface" ]; then
        echo "the default gateway ($gw) is inside a pushed subnet and is now reached" >&2
        echo "through the tunnel. Routing still works; traffic to the gateway itself takes" >&2
        echo "a detour through the appliance and gets slower." >&2
      fi
    fi
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

    interface = lib.mkOption {
      type = lib.types.str;
      default = "snwl_ssltunnel";
      description = ''
        Name of the tun interface NEService creates for the SSL-VPN tunnel. The
        helper units are bound to this interface's systemd `.device` unit.
      '';
    };

    warnRouteCollisions = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Log a warning when the appliance pushes a route for a network this host
        is already attached to. Diagnostic only -- it changes no routes and
        makes no policy decision, it just gives the failure a name in the
        journal. See "The appliance's routes can shadow the network you are on"
        in the README.
      '';
    };

    connections = lib.mkOption {
      default = { };
      example = lib.literalExpression ''
        {
          work = {
            server = "vpn.example.com";
            port = 4433;
            username = "admin";
            domain = "example.com";
            protocol = "auto";
          };
        }
      '';
      description = ''
        Connection profiles to write into the client's `profile.json`, keyed by
        the name `nxcli connect <name>` takes. Equivalent to what
        `nxcli connection add` would create, but without needing the appliance
        to be reachable at activation time.

        **These are authoritative.** Any profile not declared here is removed,
        so a profile made by hand with `nxcli connection add` will disappear on
        the next rebuild. The file as it was before this module first touched it
        is kept at `/etc/SonicWall/NetExtender/Config/profile.json.before-nixos`.
        Leave this at `{ }` to not manage profiles at all.

        Note that `--force` and `--always-trust` have no equivalent here: they
        are flags to the `nxcli` invocation, not properties of a stored profile,
        and nothing in the client's on-disk config records them. Passwords have
        no equivalent either -- the client takes those at connect time.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              server = lib.mkOption {
                type = lib.types.str;
                example = "vpn.example.com";
                description = ''
                  Appliance hostname or address. May carry a `:port` suffix, in
                  which case it wins over {option}`port`. IPv4 and hostnames
                  only -- a bracketed IPv6 literal is not parsed.
                '';
              };

              port = lib.mkOption {
                type = lib.types.port;
                default = 443;
                description = ''
                  Port to reach the appliance on, unless {option}`server`
                  already carries one. 443 is the client's own default; SonicOS
                  commonly uses 4433.
                '';
              };

              username = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = ''
                  Account name to pre-fill. The password is never stored -- it
                  is given to `nxcli connect -p`, or handled by SAML.
                '';
              };

              domain = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = ''
                  Appliance login domain. Note that `nxcli connection add
                  --force` drops this field when it cannot reach the appliance;
                  writing the profile directly, as this module does, does not.
                '';
              };

              protocol = lib.mkOption {
                type = lib.types.enum [
                  "auto"
                  "sslvpn"
                  "dtlsvpn"
                  "wireguard"
                ];
                default = "auto";
                description = ''
                  Transport to negotiate. These are the values the client
                  stores; `nxcli` spells the same four `Auto`, `TLS`, `DTLS` and
                  `WireGuard` on its command line.
                '';
              };

              domainType = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "saml";
                description = ''
                  How the appliance authenticates this domain. Leave null: the
                  client discovers it on the first logon and the value is kept
                  across rebuilds. Set it only to pin a discovery that goes
                  wrong.
                '';
              };

              clientCert = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "Client certificate to present, if the appliance requires one.";
              };
            };
          }
        )
      );
    };

    defaultConnection = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "work";
      description = ''
        Which of {option}`services.netextender.connections` is marked default --
        the one a bare `nxcli connect` uses. May be left null when exactly one
        connection is declared.
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
        traffic keeps using the local network's resolver.

        Note that this fails closed: enabling it stops NEService applying DNS
        at all (see {option}`services.netextender.resolvconfPackage`), so if
        `netextender-split-dns.service` fails the tunnel comes up with no
        corporate DNS whatsoever. That is the safe direction to fail in, but
        the symptom -- connected, nothing corporate resolves -- points nowhere
        on its own, so check `journalctl -u netextender-split-dns` first
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
        assertion = cfg.defaultConnection != null -> cfg.connections ? ${toString cfg.defaultConnection};
        message = ''
          services.netextender.defaultConnection is set to
          "${toString cfg.defaultConnection}", which is not one of
          services.netextender.connections
          (${lib.concatStringsSep ", " (lib.attrNames cfg.connections)}).
        '';
      }
      {
        assertion = (lib.length (lib.attrNames cfg.connections) > 1) -> cfg.defaultConnection != null;
        message = ''
          services.netextender.connections declares more than one profile, so
          services.netextender.defaultConnection must say which of them a bare
          `nxcli connect` should use.
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

    # Ordered before the daemon: NEService reads profile.json at startup and
    # writes it back later, so seeding it underneath a running daemon would just
    # be overwritten.
    systemd.services.netextender-profiles = lib.mkIf (cfg.connections != { }) {
      description = "Write the declared NetExtender connection profiles";
      before = [ "NEService.service" ];
      requiredBy = [ "NEService.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = profileScript;
      };
    };

    systemd.services.NEService = {
      description = "SonicWall NetExtender Service";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      # A changed profile set has to reach the running daemon, which only reads
      # the file at startup.
      restartTriggers = lib.optional (cfg.connections != { }) declaredProfiles;

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
        ExecStop = "-${resolvectl} revert ${cfg.interface}";
      };
    };

    # Same trigger as the split-DNS helper: the daemon runs continuously while
    # the tunnel comes and goes underneath it, so the interface is the event.
    systemd.services.netextender-route-collisions = lib.mkIf cfg.warnRouteCollisions {
      description = "Report NetExtender routes that shadow local networks";
      bindsTo = [ deviceUnit ];
      after = [ deviceUnit ];
      wantedBy = [ deviceUnit ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = routeCollisionScript;
      };
    };

    # wg-quick uses the kernel WireGuard module when present and transparently
    # falls back to the bundled wireguard-go otherwise; enable the module so the
    # faster in-kernel path is available.
    boot.extraModulePackages = lib.mkDefault [ ];
    boot.kernelModules = lib.mkDefault [ "wireguard" ];
  };
}
