{
  description = "Scooter from Emacs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default";
  };

  outputs = inputs@{ flake-parts, systems, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;

      perSystem = { pkgs, self', ... }: {
        # The local helper: `scooter acp` (an ACP agent for agent-shell).
        packages.scooter = pkgs.buildGoModule {
          pname = "scooter";
          version = "0.1.0";
          src = ./.;
          subPackages = [ "cmd/scooter" ];
          vendorHash = null;
          meta.mainProgram = "scooter";
        };
        packages.default = self'.packages.scooter;

        checks.scooter = self'.packages.scooter;

        devShells.default = pkgs.mkShell {
          # Cask runs a bare Emacs so MELPA, not nixpkgs, supplies the deps.
          CASK_EMACS = "${pkgs.emacs-nox}/bin/emacs";
          packages = [
            (pkgs.emacs-nox.pkgs.withPackages (e: [ e.magit-section e.transient e.agent-shell e.evil e.projectile ]))
            pkgs.emacs-nox.pkgs.cask
            pkgs.go
            pkgs.golangci-lint
            pkgs.just
            pkgs.curl
          ];
        };
      };
    };
}
