# SonicWall NetExtender for NixOS

A Nix flake that packages the [SonicWall
NetExtender](https://www.sonicwall.com/) Linux SSL-VPN client (version
`10.3.6-39`) and provides a NixOS module to run its background service.

NetExtender is distributed by SonicWall only as a proprietary, pre-compiled
`x86_64-linux` tarball. This flake fetches that tarball, patches the vendored
ELF binaries for NixOS (`autoPatchelfHook`), and wires up the `NEService`
daemon that the `netExtender` CLI and GUI talk to over `localhost:51330`.

> **Unfree package.** NetExtender is proprietary. You must allow the unfree
> `sonicwall-netextender` package — e.g. `nixpkgs.config.allowUnfree = true` or
> an `allowUnfreePredicate`.

## What you get

| Output | Description |
| --- | --- |
| `packages.netextender` (also `.default`) | The patched client: `netExtender`/`nxcli` (CLI), `NEService` (daemon), bundled WireGuard tools, and the optional WebKit GUI. |
| `nixosModules.default` / `.netextender` | The `services.netextender` module that runs `NEService`. |
| `overlays.default` | Adds `sonicwall-netextender` to nixpkgs. |
| `devShells.default` | Tooling for hacking on this flake. |

## Usage

### 1. Add the flake as an input

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    sonicwall-netextender.url = "github:youruser/sonicwall-ne"; # this repo
  };

  outputs = { nixpkgs, sonicwall-netextender, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        sonicwall-netextender.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

### 2. Enable it in your NixOS configuration

```nix
{
  nixpkgs.config.allowUnfree = true; # NetExtender is proprietary

  services.netextender.enable = true;

  # On a systemd-resolved host, use resolved's resolvconf shim for VPN DNS:
  # services.netextender.resolvconfPackage = config.systemd.package;

  # ...or keep the VPN's nameservers to the domains that need them; see
  # "NetExtender has no split DNS" under Known issues.
  # services.netextender.splitDns = { enable = true; domains = [ "example.com" ]; };
}
```

`nixos-rebuild switch` then:

- installs the client into the system profile (`netExtender`, `nxcli`, and the
  `SonicWall NetExtender` desktop entry),
- runs the `NEService` systemd unit,
- recreates the `/usr/local/netextender` path the binaries expect.

### 3. Connect

`NEService` performs the privileged work; the CLI is an unprivileged client.

```console
$ netExtender connect --help    # exact flags (service must be running)
$ netExtender connect <server> ...
$ netExtender status
$ netExtender disconnect
```

`netExtender` and `nxcli` are the same tool. NetExtender supports the `SSLVPN`
and `DTLSVPN` protocols. The GUI is launched from your desktop menu (or
`NetExtender`).

## Configuration options

| Option | Default | Description |
| --- | --- | --- |
| `services.netextender.enable` | `false` | Enable the `NEService` daemon. |
| `services.netextender.package` | `pkgs.callPackage ./nix/package.nix {}` | The NetExtender package to run. |
| `services.netextender.resolvconfPackage` | `pkgs.openresolv` | Provider of `resolvconf`, used by the bundled `wg-quick` for VPN DNS. Set to `config.systemd.package` when using systemd-resolved. |
| `services.netextender.createBinBash` | `true` | Create `/bin/bash` (referenced by `NEService`). |
| `services.netextender.interface` | `"snwl_ssltunnel"` | The tun interface NEService creates for the SSL-VPN tunnel. The helper units bind to its `.device` unit. |
| `services.netextender.warnRouteCollisions` | `true` | Log a warning when a pushed route shadows a network this host is already on. Diagnostic only. |
| `services.netextender.connections` | `{ }` | Declarative connection profiles, keyed by the name `nxcli connect <name>` takes. Authoritative — see below. |
| `services.netextender.defaultConnection` | `null` | Which declared connection a bare `nxcli connect` uses. Required when more than one is declared. |
| `services.netextender.splitDns.enable` | `false` | Route only selected domains to the VPN's nameservers, via systemd-resolved. Requires `services.resolved.enable`. |
| `services.netextender.splitDns.domains` | `[ ]` | The domains to resolve over the tunnel (e.g. your AD domain). Required when `splitDns.enable` is set. |

To build a lean, GUI-less client (no GTK/WebKit in the closure):

```nix
services.netextender.package =
  pkgs.callPackage ./nix/package.nix { withGui = false; };
```

## Declaring connections

Profiles normally come from `nxcli connection add`, which writes them into
`/etc/SonicWall/NetExtender/Config/profile.json`. `services.netextender.connections`
writes that file instead:

```nix
{
  services.netextender = {
    connections = {
      work = {
        server = "vpn.example.com";
        port = 4433;
        username = "admin";
        domain = "example.com";
        protocol = "auto";        # or "sslvpn", "dtlsvpn", "wireguard"
      };
    };

    defaultConnection = "work";   # optional with exactly one connection
  };
}
```

`nxcli connect work` then works on a freshly built machine with no interactive
setup step.

`server` may carry its own `:port`, which wins over `port`. The four `protocol`
values are what the client stores on disk; `nxcli` spells the same four `Auto`,
`TLS`, `DTLS` and `WireGuard` on its command line.

### What this deliberately does not cover

| `nxcli` flag | why there is no option for it |
| --- | --- |
| `--always-trust` | A flag on the invocation, not a property of a profile. Nothing in the client's on-disk config records it. |
| `--force` | Only tells `nxcli connection add` to save a profile it could not validate against the appliance. Writing the file directly always "forces". |
| `-p` / password | The client takes it at connect time and never stores it. Use SAML, or pass it to `nxcli connect -p`. |

`domainType` (`saml`, and so on) is discoverable rather than declarable: the
client works it out at first logon, and the module preserves what it found
across rebuilds. There is an option to pin it if discovery ever goes wrong.

### Authoritative, and why it is written rather than symlinked

**Declared profiles are the whole set.** A profile added by hand with
`nxcli connection add` is removed on the next rebuild. Whatever was in the file
before this module first touched it is preserved once, at
`profile.json.before-nixos`. Leaving `connections` at `{ }` disables profile
management entirely.

The file cannot be an `environment.etc` symlink into the store, because the
client writes to it — on connect it records the appliance's resolved address
and the domain type it discovered. So a oneshot unit renders it into place
before `NEService` starts, and changing it restarts the daemon, which only
reads the file at startup.

Those two discovered fields are preserved across rebuilds rather than reset,
but only while `server` still matches — a resolved address left over from a
different appliance is worse than none.

Driving `nxcli connection add` would have been the obvious alternative, and it
does not work for this: it contacts the appliance to validate and prompts
interactively when it cannot reach one, its `--force` path silently discards
`-d domain`, `connection edit` has no `--force` at all, both need the daemon
already running, and both renumber ids and move the `default` flag as a side
effect.

## Trying it without a module

```console
$ nix build github:youruser/sonicwall-ne#netextender
$ ./result/bin/netExtender status   # needs NEService running as root
```

## Development

```console
$ nix develop        # patchelf, file, binutils, curl, gnutar, nixfmt, jj, ...
$ nix flake check    # builds the package + evaluates the module
$ nix fmt            # format with nixfmt (RFC 166)
```

### Updating to a new NetExtender release

1. Bump `version` in [`nix/package.nix`](nix/package.nix).
2. Update `src.hash`:
   ```console
   $ nix-prefetch-url --type sha256 \
       https://software.sonicwall.com/NetExtender/NetExtender-linux-amd64-<version>.tar.gz
   # convert to SRI:
   $ nix hash to-sri --type sha256 <hash>
   ```
3. If upstream changes its WebKit ABI (`libwebkit2gtk-4.1` → newer), adjust the
   GUI `buildInputs` in the package accordingly.
4. `nix flake check`.

## Known issues

### SAML logon stalls on the appliance's "session status" page

**Symptom.** The browser opens, you complete the IdP login, and you land on
`https://<appliance>:4433/SonicWall-SSLVPN/sad` — but the client never
connects. `/var/log/SonicWall/NetExtender/neservice.log` shows it stuck in
`StateNeedSamlInfo`, polling once per second and never reaching
`StateLogonSuccess`.

**Workaround.** Reload that page (<kbd>Ctrl</kbd>+<kbd>R</kbd>). The logon
completes within a second.

**Why.** The SAML result is handed back server-side, not through the browser:
`NEService` polls `/__api__/v1/logon/<id>/status` until the appliance reports
the logon finished, and the appliance finalizes it when it serves the `sad`
URL. On affected SonicOS firmware the first request doesn't finalize the
logon, but a second one does — hence the reload. The page itself is only a
"you're connected, close this tab" screen (its JS makes no API calls at all),
so nothing local consumes it, and no MIME type or URL scheme is involved.
There is nothing for this package to register; the fix belongs in the
appliance's firmware.

Two related symptoms are *not* this bug: if the browser offers to download the
`sad` page instead of rendering it, the appliance is labelling that response
with a content type the browser won't display; and saving the page by hand
(<kbd>Ctrl</kbd>+<kbd>S</kbd>) also completes the logon, because the appliance
sends `Cache-Control: no-store` and the save re-requests the URL. The reload is
the same trick without the stray file.

**Automating the reload.** If the keystroke gets old, a userscript manager
(e.g. Violentmonkey) can do it — substitute your own appliance host:

```js
// ==UserScript==
// @name     NetExtender SAML: nudge the session-status page
// @include  /^https:\/\/vpn\.example\.com:4433\/SonicWall-SSLVPN\/sad/
// @run-at   document-end
// @grant    none
// ==/UserScript==
if (!sessionStorage.getItem('ne-sad-reloaded')) {
  sessionStorage.setItem('ne-sad-reloaded', '1');
  location.reload();
}
```

The `sessionStorage` flag is what prevents a reload loop: it is scoped to that
tab and origin, so the reloaded page sees it and stops, while the next logon
starts in a fresh tab. `@include` with a regex rather than `@match`, because
match patterns cannot express the `:4433` port.

### NetExtender has no split DNS, and takes over all of it

**Symptom.** While the tunnel is up every lookup on the host goes to the
appliance's nameservers, and unqualified names on your *local* network stop
resolving. Depending on what else writes `/etc/resolv.conf`, your search domain
may disappear too, so short corporate names break as well.

**Why.** NetExtender applies VPN DNS by piping a `resolv.conf` into
`resolvconf -a <iface>`. That is the whole mechanism — there is no per-domain
routing anywhere in the client, and `resolvectl` appears nowhere in the
binaries. openresolv then merges the VPN's nameservers into the single
system-wide `/etc/resolv.conf`, displacing the ones your local link supplied.
The appliance makes it worse by pushing an empty `domainSuffixes`, so nothing
supplies a search domain to replace what the merge drops.

(When no `resolvconf` is on `PATH` the client instead bind-mounts its
`resolv.conf` over `/etc/resolv.conf` — but it does so inside its own mount
namespace, so that path has no effect on the host at all. This is why DNS
appears to do nothing on a NixOS host that has not put a `resolvconf`
implementation on the service's `PATH`.)

**Workaround.** `services.netextender.splitDns` hands DNS to systemd-resolved
instead:

```nix
{
  services.resolved.enable = true;
  networking.networkmanager.dns = "systemd-resolved";

  services.netextender.splitDns = {
    enable = true;
    domains = [ "example.com" ];
  };
}
```

A oneshot unit bound to `sys-subsystem-net-devices-snwl_ssltunnel.device` reads
the negotiated servers out of `nxcli status -f` and registers them against the
tunnel link as *routing-only* domains, with `default-route` off — so
`example.com` resolves over the VPN and everything else stays on the local
resolver. Add reverse zones (`12.168.192.in-addr.arpa`) to `domains` if you want
PTR lookups to follow.

Enabling this also points `resolvconfPackage` at a stub that discards the
client's own call, so NEService and the helper cannot both write DNS. Set
`resolvconfPackage` explicitly if you need the bundled `wg-quick` to keep a real
`resolvconf`.

**This arrangement fails closed.** Because the client's own DNS call is
discarded, a failure in the helper — the `nxcli status -f` poll timing out,
resolved not being up, `script` unable to get a pty — leaves the tunnel
connected with *no* corporate DNS at all rather than with the wrong DNS. That is
the right direction to fail in, but the symptom is "VPN connected, nothing
corporate resolves", which on its own points nowhere:

```console
$ journalctl -u netextender-split-dns
```

`splitDns` is about *resolution*, not *routing* — it does nothing about which
destinations go down the tunnel. See "The appliance's routes can shadow the
network you are on" below, which is a separate problem and, on a roaming
client, a larger one.

### The appliance's routes can shadow the network you are on

**Symptom.** While the tunnel is up, hosts on your local network get slow or
stop answering — your own router, a NAS, a printer — while internet access
carries on working normally. Nothing in any log mentions it.

**Why.** The appliance decides which subnets to push and this module does not
filter them. If one of them is the range your Wi-Fi is already using, both
routes exist at once and the tunnel's wins, because NEService sets no metric on
its routes (so, `0`) while NetworkManager's link routes sit at `600`:

```
10.57.50.0/24 via 192.168.2.63 dev snwl_ssltunnel        ← metric 0, wins
10.57.50.0/24 dev wlo1 proto kernel ... metric 600
```

It is not a close call, and it applies to the gateway's own address too.

**What actually breaks** (measured on a colliding network, 2026-09-28):

| | |
| --- | --- |
| Internet traffic | **unaffected.** The default route pins its device, so the gateway is reached by neighbour lookup on the real link rather than a recursive lookup that would fall into the tunnel. |
| The tunnel itself | **unaffected.** The client installs a `/32` host route to the appliance via the local gateway. |
| Hosts on the shadowed range | redirected into the tunnel. What happens next depends on whether the VPN also serves that range. |

That last row is the whole story. Two cases:

- **The collided range is one the VPN serves** (you are in the office, on a
  corporate subnet). Traffic still arrives, the long way round. Measured: the
  gateway one hop away went from **1.7 ms to 44 ms** — slower than reaching
  `8.8.8.8`. Nothing fails, so nothing gets reported, and this is the case you
  will never diagnose.
- **The collided range is a foreign network that happens to match** — a hotel
  or home LAN on `192.168.2.0/24`, where the appliance pushes `192.168.2.0/24`
  because that is its VPN pool. Those packets go to the corporate subnet and
  never reach the machine down the hall. This is the case that looks like *"the
  VPN broke my Wi-Fi"*.

Ranges most likely to collide in the wild: `192.168.2.0/24` and
`192.168.3.0/24` (stock consumer-router LANs), `10.10.10.0/24` (small-business
gear), `172.16.30.0/24` (hypervisor defaults). Note that the VPN pool's own
subnet is always pushed, so whatever your appliance hands out addresses from is
permanently on the list.

**What this module does about it.** Warns, and nothing else.
`services.netextender.warnRouteCollisions` (on by default) runs a check when
the tunnel appears and logs which pushed routes shadow a network this host is
already attached to, plus whether the default gateway is one of them:

```console
$ journalctl -u netextender-route-collisions
```

It changes no routes. Filtering them would mean this module overriding the
appliance's policy, which is not its call to make — and the real fix is on the
appliance, which most people running a VPN client do not administer. If you
need a route gone, delete it by hand or take it up with whoever runs the
SonicWall.

## Notes & caveats

- **`x86_64-linux` only** — SonicWall does not ship other Linux architectures.
- **Do not run the bundled `autoUpgrader`.** It would try to write into the
  read-only Nix store. Upgrade by bumping the version + hash instead.
- The upstream tarball bundles its own WireGuard (`wg`, `wg-quick`,
  `wireguard-go`); this package patches and keeps those, because `NEService`
  resolves them by absolute path.
- `NEService` runs as root (it configures networking and WireGuard interfaces).

See [`AGENTS.md`](AGENTS.md) for repository conventions.
