{
  pkgs ? (import (fetchTarball "https://github.com/NixOS/nixpkgs-channels/tarball/c75de8bc12cc7e713206199e5ca30b224e295041";) {}),
  mavenixLib ? import ./mavenix.nix { inherit pkgs; },
}: with pkgs;

let
  inherit (mavenixLib) name version;
  homepage = "https://github.com/nix-community/mavenix";
  download = "${homepage}/tarball/v${version}";
  gen-header = "# This file has been generated by ${name}.";

  default-tmpl = writeText "default-tmpl.nix" ''
    ${gen-header} Configure the build here!
    let
      mavenix-src = %%env%%;
    in {
      # pkgs is pinned to 19.09 in mavenix-src,
      # replace/invoke with <nixpkgs> or /path/to/your/nixpkgs_checkout
      pkgs ? (import mavenix-src {}).pkgs,
      mavenix ? import mavenix-src { inherit pkgs; },
      src ? %%src%%,
      doCheck ? false,
    }: mavenix.buildMaven {
      inherit src doCheck;
      infoFile = ./mavenix.lock;

      # Add build dependencies
      #
      #buildInputs = with pkgs; [ git makeWrapper ];

      # Set build environment variables
      #
      #MAVEN_OPTS = "-Dfile.encoding=UTF-8";

      # Attributes are passed to the underlying `stdenv.mkDerivation`, so build
      #   hooks can be set here also.
      #
      #postInstall = '''
      #  makeWrapper ''${pkgs.jre8_headless}/bin/java $out/bin/my-bin \
      #    --add-flags "-jar $out/share/java/my-proj.jar"
      #''';

      # Add extra maven dependencies which might not have been picked up
      #   automatically
      #
      #deps = [
      #  { path = "org/group-id/artifactId/version/file.jar"; sha1 = "0123456789abcdef"; }
      #  { path = "org/group-id/artifactId/version/file.pom"; sha1 = "123456789abcdef0"; }
      #];

      # Add dependencies on other mavenix derivations
      #
      #drvs = [ (import ../other/mavenix/derivation {}) ];

      # Override which maven package to build with
      #
      #maven = maven.overrideAttrs (_: { jdk = pkgs.oraclejdk10; });

      # Override remote repository URLs and settings.xml
      #
      #remotes = { central = "https://repo.maven.apache.org/maven2"; };
      #settings = ./settings.xml;
    }
  '';
in mavenixLib // {
  cli = stdenv.mkDerivation {
    inherit name;
    src = lib.cleanSource ./.;

    buildInputs = [ makeWrapper ];

    phases = [ "unpackPhase" "installPhase" "fixupPhase" ];
    installPhase = ''
      mkdir -p $out/bin
      cp mvnix-init mvnix-update $out/bin
      wrapProgram $out/bin/mvnix-init \
        --set CONFIG_TEMPLATE  ${default-tmpl} \
        --set MAVENIX_SCRIPT   ${./mavenix.nix} \
        --set MAVENIX_DOWNLOAD ${download} \
        --set MAVENIX_VERSION ${version} \
        --prefix PATH : ${lib.makeBinPath [ nix coreutils yq ]}
      wrapProgram $out/bin/mvnix-update \
        --set MAVENIX_VERSION ${version} \
        --prefix PATH : ${lib.makeBinPath [ nix coreutils jq yq mktemp ]}
    '';

    meta = with lib; {
      inherit homepage;
      description = "Mavenix: deterministic builds for Maven using Nix?";
      license = licenses.unlicense;
      maintainers = [ { email = "me@icetan.org"; github = "icetan"; name = "Christopher Fredén"; } ];
    };
  };
}
