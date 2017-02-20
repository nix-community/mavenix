{ pkgs ? (import <nixpkgs> {}) }:

pkgs.callPackage (import ./mavenix.nix) {}
