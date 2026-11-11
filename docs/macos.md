# macOS / nix-darwin

**Status: not supported, and no supported way to add it has been found yet.**
This page records where we looked, so the search does not have to be repeated
from scratch. It is a snapshot from **2026-11-11**. Re-check the sources below
before relying on any of it.

## Why the flake is `x86_64-linux` only

Neither half of the flake carries over to darwin:

- **The package is Linux machine code.** `nix/package.nix` fetches
  `NetExtender-linux-amd64-*.tar.gz` and patches its prebuilt x86_64 Linux ELF
  binaries for NixOS. macOS cannot run those binaries, and there is no source to
  rebuild. Adding a darwin system to `systems` would only move the failure.
- **The module is NixOS-only.** `nix/module.nix` is built on systemd units,
  systemd-resolved, tmpfiles (the `/usr/local/netextender` symlink) and loading
  the `wireguard` kernel module. nix-darwin has none of these.

So darwin support would mean packaging a *different* SonicWall client, the
macOS one, if it can be had in a form Nix can install. Even then, a macOS VPN
client normally ships a Network Extension or system extension. macOS only
activates one of those from a properly signed app bundle in `/Applications`,
after the user approves it in System Settings. nix-darwin's store-backed
`/Applications/Nix Apps` copies tend not to meet that bar. That part is
inferred, not tested.

A Mac can still *build* `packages.netextender` through a remote builder or
`linux-builder`, but the result only runs on Linux.

## Where we looked for a macOS client

### Checked by hand (a person, in a browser)

| Source | Finding |
| --- | --- |
| Our appliance's Virtual Office portal | Offers NetExtender installers for **Linux and Windows only**. Nothing for macOS on our firmware. |
| SonicWall technical documentation and release notes | Searched for `NetExtender macOS`, `macOS`, `mac` and `pkg`. Nothing mentions a native macOS NetExtender package. |
| MySonicWall Download Center | Says **Mobile Connect will be replaced by NetExtender on macOS**. It gives no date and does not say whether that will be a downloadable `.pkg` or another App Store app. |
| Mac App Store | **SonicWall Mobile Connect** is the macOS client, and it is distributed only through the App Store. That needs an Apple Account (iCloud). We don't want to create one for the office, and we don't want staff using their personal one. |
| Homebrew (formulae.brew.sh search for `sonicwall`) | No SonicWall casks. The results were unrelated. |

### Checked once from this repo's tooling (2026-11-11, one request each)

| Request | Finding |
| --- | --- |
| `https://formulae.brew.sh/api/cask.json` (7,823 casks) | No cask whose token, name, description, homepage or URL matches `sonicwall`, `netextender` or `mobile connect`. The only relevant hit is the third-party **`vpn-tracker-365`** (equinux), described as supporting "SonicWALL/AnyConnect/Fortinet SSL". |
| `https://itunes.apple.com/search?term=sonicwall&entity=macSoftware` | **SonicWall Mobile Connect 5.0.15** (seller SonicWall Inc., app id `822514576`), minimum macOS 12.4, current version released 2026-05-14. No other SonicWall macOS app is listed. |
| `https://www.sonicwall.com/products/remote-access/vpn-clients` | **Not checked.** The site sits behind an Incapsula bot wall, which returned a challenge page instead of content. We did not retry, because this repo avoids repeated automated requests against SonicWall's hosts. Look at it in a browser. |

## What that leaves

None of these is something this flake can package. Each is listed so the
decision can be made with the options in view:

- **Wait for NetExtender on macOS.** SonicWall says it is coming. When it
  appears, the questions that decide whether it belongs in this flake are: is
  it a downloadable `.pkg`/`.dmg` (not App Store only)? Does our appliance's
  Virtual Office offer it? Does it use a system extension (see above)?
- **App Store without a personal Apple Account.** Apple Business Manager can
  buy App Store apps in volume and assign them *to devices* through an MDM.
  Device-assigned apps install with no Apple Account signed in on the Mac. This
  is general Apple behaviour; we have not tried it with Mobile Connect. It only
  makes sense if the office already runs, or wants, an MDM.
- **A third-party client.** VPN Tracker 365 claims SonicWall SSL-VPN support and
  has a Homebrew cask, which nix-darwin's `homebrew.casks` can install. It is a
  commercial subscription product, and we have not checked whether it works
  with our appliance's protocol (SSL-VPN vs. WireGuard) or SAML logon.

## When to revisit

- A SonicWall firmware update on the appliance. Check whether Virtual Office
  now lists a macOS download.
- SonicWall release notes announcing NetExtender for macOS.
- A `sonicwall` or `netextender` cask appearing in Homebrew.
