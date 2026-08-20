{
  description = "SonicWall NetExtender VPN client packaged for NixOS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      flake.overlays.default = final: _prev: {
        sonicwall-netextender = final.callPackage ./nix/package.nix { };
      };

      perSystem =
        {
          system,
          pkgs,
          config,
          ...
        }:
        {
          # NetExtender is proprietary; evaluate nixpkgs with unfree allowed.
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };

          formatter = pkgs.nixfmt;

          packages.netextender = pkgs.callPackage ./nix/package.nix { };
          packages.default = config.packages.netextender;

          devShells.default = pkgs.mkShell {
            name = "sonicwall-netextender-dev";
            packages = with pkgs; [
              # VCS + commit hygiene
              jujutsu

              # Nix formatting / hashing helpers
              nixfmt
              nix-prefetch

              # Inspecting and patching the vendored ELF binaries
              patchelf
              file
              binutils # readelf, objdump
              curl
              gnutar
            ];
          };
        };
    };
}
