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

**Do not create, edit or delete files outside this repository without being
asked to, in that turn.** Reading them is fine and often necessary; changing
them is not. This holds however small or obviously-helpful the change looks,
and it holds for a file that does not exist yet as much as for one that does.

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
- **Mutating this machine's state counts too.** `/etc`, systemd units, the
  client's own config files — anything outside this working tree. Running a
  command that writes as a side effect (`nxcli connection add` edits
  `profile.json`) is a change, even though no editor was opened. If diagnosis
  genuinely needs one, say so first, keep it reversible, and put it back.
- **Say what you touched.** If something outside this tree did change, name it
  explicitly in the summary rather than leaving it to be discovered.

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
