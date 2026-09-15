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

To build a lean, GUI-less client (no GTK/WebKit in the closure):

```nix
services.netextender.package =
  pkgs.callPackage ./nix/package.nix { withGui = false; };
```

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

## Notes & caveats

- **`x86_64-linux` only** — SonicWall does not ship other Linux architectures.
- **Do not run the bundled `autoUpgrader`.** It would try to write into the
  read-only Nix store. Upgrade by bumping the version + hash instead.
- The upstream tarball bundles its own WireGuard (`wg`, `wg-quick`,
  `wireguard-go`); this package patches and keeps those, because `NEService`
  resolves them by absolute path.
- `NEService` runs as root (it configures networking and WireGuard interfaces).

See [`AGENTS.md`](AGENTS.md) for repository conventions.
