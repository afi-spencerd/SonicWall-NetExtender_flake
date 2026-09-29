# AGENTS.md

Guidance and preferences for AI agents (and humans) working in this repository.

## Project

A Nix flake that packages **SonicWall NetExtender** (the Linux VPN client) and
provides a NixOS module to run it. NetExtender ships as a proprietary,
pre-compiled `x86_64-linux` tarball, so the package patches the vendored ELF
binaries for NixOS rather than building from source.

Upstream artifact (pinned in `nix/package.nix`):
<https://software.sonicwall.com/NetExtender/NetExtender-linux-amd64-10.3.6-39.tar.gz>

## Scope: this repository only

**Do not create, edit or delete files in another repository without being asked
to, in that turn.** Reading them is fine and often necessary; changing them is
not. This holds however small or obviously-helpful the change looks, and it
holds for a file that does not exist yet as much as for one that does.

The line is durability, not location. A commit in a neighbouring repo outlives
the session and is invisible in this one's diff. A scratch file or a throwaway
config entry you put back is neither.

The pull is real, because the interesting parts of this project live on the
other side of the flake boundary. Diagnosing anything means reading the
consuming NixOS configuration, `/etc/SonicWall/NetExtender/Config/`, systemd
units, `/var/log/SonicWall/`. Once you are already reading a consumer's module
it feels natural to fix it there too — and the person reviewing a change to
*this* repo will not see that happen.

So:

- **Reference freely.** Quote another repo, name the exact file and line, write
  out the diff you would apply, hand it over for someone else to paste. A
  precise description of a change elsewhere is worth as much as making it, and
  it stays visible.
- **Ask first, every time.** Prior permission to touch a neighbouring repo does
  not carry into the next request, or the next turn.
- **Machine state is a different question, and mostly fine.** Recon needs it:
  adding a throwaway `nxcli` profile to learn a schema, writing a scratch file,
  restarting a unit, connecting the VPN to capture what it does. Do it without
  asking, on two conditions — the change must be reversible, and you must
  actually reverse it. Take a copy first and diff against it afterwards rather
  than assuming the revert worked; `nxcli connection del` restoring the
  `default` flag on the surviving profile was worth checking, not trusting.
  Anything that outlives a reboot *and* that you cannot put back does not
  belong in this category.
- **Note that a command can be a change.** `nxcli connection add` edits
  `profile.json` with no editor involved. Judge by what a command writes, not
  by whether it looked like an edit.
- **Say what you touched.** If anything outside this tree changed — including
  something reverted — name it in the summary rather than leaving it to be
  discovered.

## Tooling preferences

- **Flake framework:** [`flake-parts`](https://github.com/hercules-ci/flake-parts)
  (`github:hercules-ci/flake-parts`). Note: the canonical owner is
  `hercules-ci` (with an `i`), not `hercules-cl`.
- **nixpkgs:** `github:nixos/nixpkgs/nixos-unstable`.
- **Dev environment:** all development dependencies live in the flake's
  `devShells.default`. Do not rely on tools being present on the host — add them
  to the dev shell instead. Enter it with `nix develop`.
- **Formatter:** `nixfmt` (RFC 166 style, `nixfmt-rfc-style` in nixpkgs), wired
  as the flake `formatter` through `pkgs.nixfmt-tree` (a treefmt wrapper) so
  that a bare `nix fmt` formats the whole tree. Run it before committing;
  `nix fmt -- --ci` checks instead of writing and exits non-zero when
  something is unformatted.

## Version control

- The repository is tracked with **[Jujutsu](https://jj-vcs.github.io/jj/)
  (`jj`) using the Git backend**. Prefer `jj` commands over raw `git`.
- **Conventional Commits** are required for every commit description. Use types
  such as `feat`, `fix`, `docs`, `chore`, `refactor`, `build`, `ci`, `test`, and
  optional scopes like `feat(pkg):` or `feat(module):`.
- Keep commits small and logically scoped; each should describe one coherent
  change.

## Layout

- `flake.nix` — flake-parts entry point: packages, dev shell, formatter,
  NixOS module, and overlay.
- `nix/package.nix` — the `netextender` derivation (fetch + patch vendored
  binaries).
- `nix/module.nix` — the `services.netextender` NixOS module.
- `README.md` — user-facing installation and usage docs.

## Conventions & gotchas

- The vendored binaries hardcode `/usr/local/netextender/...` for `wg`,
  `wg-quick`, and `locales`. The NixOS module recreates that path with a
  tmpfiles symlink into the store — keep this behavior when refactoring.
- Never enable NetExtender's bundled `autoUpgrader`; it would try to write into
  the (read-only) Nix store. Upgrades happen by bumping the version + hash in
  `nix/package.nix`.
- The upstream tarball bundles WireGuard (`wg`, `wg-quick`, `wireguard-go`); the
  package keeps and patches those rather than substituting nixpkgs' copies, to
  match what NEService expects.
