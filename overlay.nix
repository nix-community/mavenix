self: super:
let
  mavenix = import ./. {};
in {
  inherit mavenix;
  mavenix-cli = mavenix.cli;
}
