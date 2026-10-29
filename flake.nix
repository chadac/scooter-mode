{
  description = "Scooter from Emacs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      packages = forAll (pkgs: rec {
        # The local helper: `scooter acp` (an ACP agent for agent-shell).
        scooter = pkgs.buildGoModule {
          pname = "scooter";
          version = "0.1.0";
          src = ./.;
          subPackages = [ "cmd/scooter" ];
          vendorHash = null;
          meta.mainProgram = "scooter";
        };
        default = scooter;
      });

      checks = forAll (pkgs: { scooter = self.packages.${pkgs.system}.scooter; });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell { packages = [ pkgs.emacs-nox pkgs.go pkgs.golangci-lint pkgs.just ]; };
      });
    };
}
