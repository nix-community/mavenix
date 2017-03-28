{ stdenv, lib, maven, runCommand, writeText, fetchurl, makeWrapper
, requireFile
}:

let
  settings' = writeText "settings.xml" ''
    <settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                          http://maven.apache.org/xsd/settings-1.0.0.xsd">
    </settings>
  '';

  #pathToString = path: suffix: toString (path + ("/" + suffix));
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

  mapmap = fs: map (v: map (f: f v) fs);

  # XXX: Maybe use `fetchMaven` instead?
  urlToScript = (dep: let
    inherit (dep) path url sha1;

    authenticated = false;

    fetch = (if authenticated then requireFile else fetchurl) {
      inherit url sha1;
    };
  # XXX: What does this do? move to bash function in mkRepo
  in ''
    dir="$out/$(dirname ${path})"
    dest="$dir/${baseNameOf path}"
    mkdir -p "$dir"
    ln -sfv "${fetch}" "$dest"
    linkSnapshot "$dest"
  '');

  drvToScript = drv: ''
    echo >&2 BUILDING FROM DERIVATION
    props="${drv}/share/java/*.properties"
    for prop in $props; do getMavenPathFromProperties $prop; done
  '';

  transDeps = drvs: builtins.concatLists (
    map
      (drv: (readJSONFile "${drv}/share/java/maven-info.json").deps)
      (builtins.attrValues drvs)
  );

  mkRepo = drvs: deps: runCommand "mk-repo" {} ''
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

    ${lib.concatStrings (map urlToScript (deps ++ (transDeps drvs)))}
    ${lib.concatStrings (map drvToScript (builtins.attrValues drvs))}
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
in {
  buildMaven =
  { src
  , infoFile
  , drvs        ? {}
  , settings    ? settings'
  , buildInputs ? []
  , derivationExtra ? {}
  }: let
    info = readJSONFile infoFile;

    repo = mkRepo drvs info.deps;

    mvn-offline = runCommand "mvn-offline" { buildInputs = [ makeWrapper ]; } ''
      makeWrapper ${maven}/bin/mvn $out/bin/mvn-offline \
        --add-flags "--offline" \
        --add-flags "--settings ${settings}" \
        --add-flags "-Dmaven.repo.local=${repo}"
    '';
  in stdenv.mkDerivation ({
    name = builtins.trace "The name of this project is ${info.name}" info.name;
    src = filterSrc src;

    buildInputs = [ mvn-offline ] ++ buildInputs;

    phases = "unpackPhase buildPhase installPhase";

    buildPhase = ''
      runHook preBuild

      mvn-offline -version
      mvn-offline -nsu package

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      dir="$out/share/java"
      mkdir -p $dir

      cp ${infoFile} $dir/maven-info.json

      ${lib.concatStrings (builtins.concatLists (
        mapmap
          [ cp-artifact cp-pom mk-properties mk-maven-metadata ]
          info.submodules
      ))}

      runHook postInstall
    '';
  } // derivationExtra);

  inherit mkRepo;
}
