{
  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";

    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    finix-flake.url = "github:parzivale/finix-flake";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      perSystem =
        { pkgs, ... }:
        {
          checks = {
            finit = inputs.finix-flake.lib.mkTest ({ inherit pkgs; } // (import ./finit.nix pkgs));
          };
        };
    };
}
