{
  description = "Mavenix";

  inputs.utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, utils }:
    utils.lib.eachSystem utils.lib.allSystems (system:
      let
        pkgs = import nixpkgs { inherit system; };
        mavenix = import ./. { inherit pkgs; };
      in rec {
        packages = utils.lib.flattenTree {
          mavenix-cli = mavenix.cli;
        };
        defaultPackage = packages.mavenix-cli;
        apps.mavenix-cli = utils.lib.mkApp { drv = packages.mavenix-cli; };
        defaultApp = apps.mavenix-cli;
      }) // {
        overlay = final: prev: {
          inherit (import ./mavenix.nix { pkgs = prev; }) buildMaven;
          mavenix-cli = (import ./. { pkgs = prev; }).cli;
        };
      };
}
