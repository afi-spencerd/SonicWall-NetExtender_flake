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
| MySonicWall Download Center | Says **Mobile Connect will be replaced by NetExtender on macOS**. It gives no date and does not say whether that will be a downloadable `.pkg` or another App Store app. (The VPN clients page and the KB article, below, settle it: it is a rename of the App Store app.) |
| Mac App Store | **SonicWall Mobile Connect** is the macOS client, and it is distributed only through the App Store. That needs an Apple Account (iCloud). We don't want to create one for the office, and we don't want staff using their personal one. |
| Homebrew (formulae.brew.sh search for `sonicwall`) | No SonicWall casks. The results were unrelated. |

### Checked once from this repo's tooling (2026-11-11, one request each)

| Request | Finding |
| --- | --- |
| `https://formulae.brew.sh/api/cask.json` (7,823 casks) | No cask whose token, name, description, homepage or URL matches `sonicwall`, `netextender` or `mobile connect`. The only relevant hit is the third-party **`vpn-tracker-365`** (equinux), described as supporting "SonicWALL/AnyConnect/Fortinet SSL". |
| `https://itunes.apple.com/search?term=sonicwall&entity=macSoftware` | **SonicWall Mobile Connect 5.0.15** (seller SonicWall Inc., app id `822514576`), minimum macOS 12.4, current version released 2026-05-14. No other SonicWall macOS app is listed. |
| `https://www.sonicwall.com/products/remote-access/vpn-clients` | Blocked by an Incapsula bot wall, which returned a challenge page instead of content. Not retried, because this repo avoids repeated automated requests against SonicWall's hosts. A browser-saved copy was read instead (next section). |

### SonicWall's VPN clients page (saved from a browser, 2026-11-11)

The page lists four clients. What each one offers for macOS:

| Client | Compatible devices (per the page) | macOS |
| --- | --- | --- |
| NetExtender | TZ, NSa, NSsp and NSv firewalls | **None.** The page describes it as access "to Windows and Linux users", and the only downloads are "Get NetExtender for Windows" and "Get NetExtender for Linux". |
| Mobile Connect | TZ, NSa, NSsp and NSv firewalls; SMA 1000 | **App Store only** ("Get Mobile Connect for macOS — App Store"). |
| Connect Tunnel | **SMA 1000 Series only** | Has a direct "Get Connect Tunnel for Mac" download, but it is for SonicWall's SMA 1000 remote-access appliances, not the firewalls NetExtender talks to. |
| Global VPN Client (GVC) | TZ, NSa, NSsp and NSv firewalls (IPsec) | **None.** Windows only. |

The Mobile Connect section carries this note, which answers the open question
from the Download Center:

> Note: Mobile Connect is becoming NetExtender. This is a name change only;
> the way you use Mobile Connect on iOS, macOS, Android, and Chrome OS will be
> unaffected.

It links to knowledge-base article
<https://www.sonicwall.com/support/knowledge-base/kA1VN000002Fnth0AC> for
details (next section).

The download URLs themselves are not in the saved HTML. The version selectors
and store buttons are filled in by JavaScript.

### "Mobile Connect is becoming NetExtender" (KB article, saved as PDF, 2026-11-11)

[kA1VN000002Fnth0AC](https://www.sonicwall.com/support/knowledge-base/kA1VN000002Fnth0AC)
describes the change as renaming "the **Mobile Connect** app to
**NetExtender** across iOS, MacOS and Android". It calls it "a branding and
naming change only".

| Phase | Target start | What happens |
| --- | --- | --- |
| 1 — Informational (~6 months) | October 2026 | Notice text added to the App Store and Google Play listings. No app changes. |
| 2 — Name change (~6 months) | April 2027 | The app is renamed to NetExtender on the App Store and Google Play. The rename arrives "through the normal app Update/Upgrade flow". |
| 3 — Cleanup | October 2027 | Remaining "Mobile Connect" references are removed; the logo may change. |

Under "Impact by product", for SonicOS customers: "NetExtender is supported on
all Windows, Linux, iOS, Android, MacOS systems following the rename". The
macOS part of that means the renamed App Store app.

The article never mentions a `.pkg`, a `.dmg` or any distribution outside the
app stores. Every step it describes goes through the App Store and Google Play.

## What that leaves

None of these is something this flake can package. Each is listed so the
decision can be made with the options in view:

- **Not "NetExtender on macOS".** Per the KB article, this is the Mobile
  Connect App Store app renamed, delivered as an App Store update, with no
  change in how it installs. Waiting for it gets the same App Store dependency
  under a new name. If a downloadable `.pkg`/`.dmg` ever does appear, the
  questions that decide whether it belongs in this flake are: does our
  appliance's Virtual Office offer it, and does it use a system extension (see
  above)?
- **Not Connect Tunnel.** It is the only SonicWall client with a direct Mac
  download, but the page lists it for SMA 1000 appliances only, not for
  firewalls.
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
- The VPN clients page gaining a "Get NetExtender for macOS" download that is
  not an App Store link. Nothing announced so far points that way: the rename
  phases (April 2027, October 2027) are all App Store changes.
- A `sonicwall` or `netextender` cask appearing in Homebrew.
