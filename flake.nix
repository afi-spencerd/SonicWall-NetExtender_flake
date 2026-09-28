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

      flake.nixosModules.netextender = ./nix/module.nix;
      flake.nixosModules.default = ./nix/module.nix;

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

          formatter = pkgs.nixfmt-tree;

          packages.netextender = pkgs.callPackage ./nix/package.nix { };
          packages.default = config.packages.netextender;

          # Cheap sanity check: fully evaluate a NixOS system that enables the
          # module, forcing the service unit + tmpfiles rules (and the package
          # reference) to resolve. Catches module regressions in `nix flake
          # check` without building a full system. The second configuration
          # exercises the split-DNS path, whose helper unit and resolvconf stub
          # only exist when it is on.
          checks.module-eval =
            let
              base = {
                nixpkgs.config.allowUnfree = true;
                boot.loader.grub.enable = false;
                fileSystems."/" = {
                  device = "/dev/sda1";
                  fsType = "ext4";
                };
                system.stateVersion = "25.05";
              };

              evalWith =
                module:
                inputs.nixpkgs.lib.nixosSystem {
                  inherit system;
                  modules = [
                    inputs.self.nixosModules.default
                    base
                    module
                  ];
                };

              plain = evalWith { services.netextender.enable = true; };

              splitDns = evalWith {
                services.netextender = {
                  enable = true;
                  splitDns = {
                    enable = true;
                    domains = [ "example.com" ];
                  };
                };
                services.resolved.enable = true;
              };

              # Reading `assertions` is what makes a failed one abort the check
              # rather than evaluate to a quietly-ignored list.
              forced = builtins.toJSON {
                plain = {
                  inherit (plain.config.systemd.services.NEService) serviceConfig path;
                  inherit (plain.config.systemd.tmpfiles) rules;
                  assertions = map (a: a.assertion) plain.config.assertions;
                };
                splitDns = {
                  inherit (splitDns.config.systemd.services.netextender-split-dns)
                    serviceConfig
                    bindsTo
                    wantedBy
                    ;
                  resolvconf = splitDns.config.services.netextender.resolvconfPackage.outPath;
                  assertions = map (a: a.assertion) splitDns.config.assertions;
                };
              };
            in
            pkgs.runCommand "netextender-module-eval" { inherit forced; } ''
              printf '%s' "$forced" > "$out"
            '';

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
