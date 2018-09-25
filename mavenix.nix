{ stdenv, lib, runCommand, fetchurl, makeWrapper, maven, writeText
, requireFile, yq
}:

let
  inherit (builtins) attrNames attrValues pathExists toPath;
  inherit (lib) concatLists concatStrings importJSON strings;
  maven' = maven;
  settings' = writeText "settings.xml" ''
    <settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                          http://maven.apache.org/xsd/settings-1.0.0.xsd">
    </settings>
  '';

  mapmap = fs: ls: concatLists (map (v: map (f: f v) fs) ls);

  urlToScript = (remotes: dep: let
    inherit (dep) path sha1;
    authenticated = if dep?authenticated then dep.authenticated else false;

    fetch = (if authenticated then requireFile else fetchurl) {
      inherit sha1;
      urls = map (r: "${r}/${path}") (attrValues remotes);
    };
  in ''
    mkdir -p "$(dirname ${path})"
    ln -sfv "${fetch}" "${path}"
  '');

  metadataToScript = (remote: meta: let
    inherit (meta) path content;
    name = "maven-metadata-${remote}.xml";
  in ''
    mkdir -p "${path}"
    ( cd "${path}"
      ln -sfv "${writeText "maven-metadata.xml" content}" "${name}"
      linkSnapshot < "${name}" )
  '');

  drvToScript = drv: ''
    echo >&2 BUILDING FROM DERIVATION
    props="${drv}/share/java/*.properties"
    for prop in $props; do getMavenPathFromProperties $prop; done
  '';

  transDeps = drvs: concatLists (map
    (drv: (importJSON "${drv}/share/java/mavenix-info.json").deps)
    drvs
  );

  transMetas = drvs: concatLists (map
    (drv: (importJSON "${drv}/share/java/mavenix-info.json").metas)
    drvs
  );

  getRemotes = { src, maven, settings ? settings' }:
    importJSON (stdenv.mkDerivation {
      inherit src;
      name = "remotes.json";
      phases = [ "unpackPhase" "installPhase" ];
      installPhase = ''
        parse() {
          local sep=""
          echo "{"
          while test "$1"; do
            echo "$sep\"$1\":\"$2\""
            sep=","
            shift 2
          done
          echo "}"
        }
        parse $(
          ${maven}/bin/mvn 2>&- -B -nsu --offline --settings "${settings}" \
            dependency:list-repositories \
          | sed -n 's/.* \(id\|url\)://p' | tr -d '\n'
        ) > $out
      '';
    });

  mkRepo = { remotes ? {}, drvs ? [], deps ? [], metas ? [] }: runCommand "mk-repo" {} ''
    set -e

    getMavenPath() {
      local version="$(sed -n 's|^version=||p' "$1")"
      local groupId="$(sed -n 's|^groupId=||p' "$1")"
      local artifactId="$(sed -n 's|^artifactId=||p' "$1")"
      echo "$(sed 's|\.|/|g' <<<"$groupId")/$artifactId/$version/$artifactId-$version"
    }

    linkSnapshot() {
      ${yq}/bin/xq -r '
        .metadata as $o
          | [.metadata.versioning.snapshotVersions.snapshotVersion] | flatten | .[]
          | ((if .classifier? then ("-" + .classifier) else "" end) + "." + .extension) as $e
          | $o.artifactId + "-" + .value + $e + " " + $o.artifactId + "-" + $o.version + $e
      ' | xargs -L1 ln -sfv
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

    mkdir -p "$out"
    (cd $out
      ${concatStrings (map (urlToScript remotes) (deps ++ (transDeps drvs)))}
      ${concatStrings (mapmap
        (map metadataToScript (attrNames remotes)) (metas ++ (transMetas drvs)))}
      ${concatStrings (map drvToScript drvs)}
    )
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
in config'@{
  src
, infoFile
, deps        ? []
, drvs        ? []
, settings    ? settings'
, maven       ? maven'
, buildInputs ? []
, remotes     ? getRemotes { inherit src maven settings; }
, doCheck     ? true
, debug       ? false
, ...
}: let
  config = config' // {
    buildInputs = buildInputs ++ [ maven ];
  };
  info = importJSON infoFile;
  repo = mkRepo {
    inherit (info) deps metas;
    inherit drvs remotes;
  };
  emptyRepo = mkRepo { inherit drvs remotes; };
in {
  inherit emptyRepo repo remotes deps infoFile maven settings config;
  build = lib.makeOverridable stdenv.mkDerivation ({
    inherit src;
    name = info.name;

    checkPhase = ''
      runHook preCheck

      mvn --offline -B --settings ${settings} -Dmaven.repo.local=${repo} -nsu test

      runHook postCheck
    '';

    buildPhase = ''
      runHook preBuild

      mvn --offline -B -version -Dmaven.repo.local=${repo}
      mvn --offline -B --settings ${settings} -Dmaven.repo.local=${repo} -nsu package -DskipTests=true -Dmaven.test.skip=true

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
  } // (config // {
    deps = null;
    drvs = null;
    remotes = null;
  }));
}
