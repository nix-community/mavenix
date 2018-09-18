{ stdenv, lib, runCommand, writeText, fetchurl, makeWrapper, maven
, requireFile
}:

let
  inherit (builtins) attrNames attrValues;
  inherit (lib) concatLists concatStrings;
  maven' = maven;
  settings' = writeText "settings.xml" ''
    <settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                          http://maven.apache.org/xsd/settings-1.0.0.xsd">
    </settings>
  '';

  filterSrc = src: builtins.filterSource (path: type:
    let
      p = toString path;
      #p2s = pathToString src;
      isResult = type == "symlink" && lib.hasPrefix "result" (builtins.baseNameOf p);
      isIgnore = type == "directory" && builtins.elem (builtins.baseNameOf p) [ "target" ".git" ];
      check = ! (isResult || isIgnore);
    in check
  ) src;

  readJSONFile = file: builtins.fromJSON (builtins.readFile file);

  mapmap = fs: ls: concatLists (map (v: map (f: f v) fs) ls);

  # XXX: Maybe use `fetchMaven` instead?
  urlToScript = (remotes: dep: let
    inherit (dep) path sha1;
    authenticated = false;

    fetch = (if authenticated then requireFile else fetchurl) {
      inherit sha1;
      urls = map (r: "${r}/${path}") (attrValues remotes);
    };
  # XXX: What does this do? move to bash function in mkRepo
  in ''
    dir="$out/$(dirname ${path})"
    dest="$dir/${baseNameOf path}"
    mkdir -p "$dir"
    ln -sfv "${fetch}" "$dest"
    linkSnapshot "$dest"
  '');

  metadataToScript = (remote: meta: let
    inherit (meta) path content;
    name = "maven-metadata-${remote}.xml";
  in ''
    dir="$out/${path}"
    dest="$dir/${name}"
    mkdir -p "$dir"
    ln -sfv "${writeText name content}" "$dest"
    linkSnapshot "$dest"
  '');

  drvToScript = drv: ''
    echo >&2 BUILDING FROM DERIVATION
    props="${drv}/share/java/*.properties"
    for prop in $props; do getMavenPathFromProperties $prop; done
  '';

  transDeps = drvs: concatLists (map
    (drv: (readJSONFile "${drv}/share/java/mavenix-info.json").deps)
    (attrValues drvs)
  );

  transMetas = drvs: concatLists (map
    (drv: (readJSONFile "${drv}/share/java/mavenix-info.json").metas)
    (attrValues drvs)
  );

  getRemotes = { src, maven, settings ? settings' }:
    import (stdenv.mkDerivation {
      inherit src;
      name = "remotes.nix";
      phases = [ "unpackPhase" "installPhase" ];
      installPhase = ''
        ( echo "{"
          while read id url; do
            echo "  \"$id\" = \"$url\";"
          done <<<"$(
            ${maven}/bin/mvn 2>&- -nsu -o --settings "${settings}" \
              dependency:list-repositories \
            | grep -Eo '(id: |url: ).*$' | sed 's|[^ ]*||' | tr -d '\n'
          )"
          echo "}"
        ) > $out
      '';
    });

  mkRepo = { remotes ? {}, drvs ? {}, deps ? [], metas ? [] }: runCommand "mk-repo" {} ''
    set -e
    mkdir -p "$out"
    TMP_REPO="$out"

    getMavenPath() {
      local version="$(sed -n 's|^version=||p' "$1")"
      local groupId="$(sed -n 's|^groupId=||p' "$1")"
      local artifactId="$(sed -n 's|^artifactId=||p' "$1")"
      echo "$TMP_REPO/$(sed 's|\.|/|g' <<<"$groupId")/$artifactId/$version/$artifactId-$version"
    }

    linkSnapshot() {
      local file="$(basename $1)"
      local ext="''${file##*.}"
      local dir="$(dirname $1)"
      local version="$(basename $dir)"
      local name="$(basename `dirname $dir`)"
      local dest="$dir/$name-$version.$ext"
      test -f "$dest" || ln -sv "$1" "$dest"
    }

    getMavenPathFromProperties() {
      local path="$(getMavenPath "$1")"
      local bpath="$(dirname $path)"
      local basefilename="''${1%%.properties}"

      if test "$bpath"; then
        mkdir -p "$bpath"
        for fn in $basefilename-* $basefilename.{pom,jar}; do
          test ! -f $fn || ln -sfv "$fn" "$bpath"
        done
        ln -sfv "$basefilename.metadata.xml" "$bpath/maven-metadata-local.xml"
      fi
    }

    ${concatStrings (map (urlToScript remotes) (deps ++ (transDeps drvs)))}
    ${concatStrings (mapmap
      (map metadataToScript (attrNames remotes)) (metas ++ (transMetas drvs)))}
    ${concatStrings (map drvToScript (attrValues drvs))}
  '';

  cp-artifact = submod: ''
    find . -type f \
      -regex "${submod.path}/target/[^/]*\.\(jar\|war\)$" ! -name "*-sources.jar" \
      -exec cp -v {} $dir \;
  '';

  cp-pom = submod: ''
    cp -v ${submod.path}/pom.xml $dir/${submod.name}.pom
  '';

  mk-properties = submod: ''
    echo 'groupId=${submod.groupId}
    artifactId=${submod.artifactId}
    version=${submod.version}
    ' > $dir/${submod.name}.properties
  '';

  mk-maven-metadata = submod: ''
    echo '<metadata>
      <groupId>${submod.groupId}</groupId>
      <artifactId>${submod.artifactId}</artifactId>
      <version>${submod.version}</version>
    </metadata>
    ' > $dir/${submod.name}.metadata.xml
  '';

  mvn-offline = { repo, maven, settings }:
    runCommand "mvn-offline" { buildInputs = [ makeWrapper ]; } ''
      makeWrapper ${maven}/bin/mvn $out/bin/mvn \
        --add-flags "--offline" \
        --add-flags "--settings ${settings}" \
        --add-flags "-Dmaven.repo.local=${repo}"
    '';
in config@{
  src
, infoFile
, drvs        ? {}
, settings    ? settings'
, maven       ? maven'
, buildInputs ? []
, ...
}: let
  info = readJSONFile infoFile;
  remotes = getRemotes { inherit src maven settings; };
  repo = mkRepo {
    inherit (info) deps metas;
    inherit drvs remotes;
  };
  emptyRepo = mkRepo { inherit drvs remotes; };
  mvn-offline' = mvn-offline { inherit repo maven settings; };
in {
  inherit emptyRepo repo remotes infoFile drvs maven settings config;
  build = stdenv.mkDerivation ({
    inherit src;
    name = info.name;

    phases = "unpackPhase buildPhase installPhase";

    buildPhase = ''
      runHook preBuild

      mvn -version
      mvn -nsu package

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      dir="$out/share/java"
      mkdir -p $dir

      cp ${infoFile} $dir/mavenix-info.json

      ${concatStrings (mapmap
        [ cp-artifact cp-pom mk-properties mk-maven-metadata ]
        info.submodules
      )}

      runHook postInstall
    '';
  } // (config // { buildInputs = buildInputs ++ [ mvn-offline' ]; }));
}
