{ pkgs ? (import <nixpkgs> {})
, maven ? pkgs.maven
}:

pkgs.callPackage (import ./mavenix.nix) { inherit maven; }
