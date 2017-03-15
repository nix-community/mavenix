{
  stdenv, maven, runCommand, writeText, writeScript, writeScriptBin, fetchurl,
  makeWrapper, lib, requireFile, unzip, mktemp
}:

let
  #first = op: list: let head = builtins.head list; in
  #  if op head then head else first op (builtins.tail list);

  settings_ = writeText "settings.xml" ''
    <settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                          http://maven.apache.org/xsd/settings-1.0.0.xsd">
    </settings>
  '';

  # TODO: move to build-tools as common functions.
  pathToString = path: suffix: toString (path + ("/" + suffix));
  filterSrc = src: builtins.filterSource (path: type:
    let
      p = toString path;
      #p2s = pathToString src;
      isResult = type == "symlink" && lib.hasPrefix "result" (builtins.baseNameOf p);
      isIgnore = type == "directory" && builtins.elem (builtins.baseNameOf p) [ "target" ".git" ];
      check = ! (isResult || isIgnore);
    in check
  ) src;

  jsonFile = file: builtins.fromJSON (builtins.readFile file);

  mapmap = fs: map (v: map (f: f v) fs);
  #flatmapmap = builtins.concatLists mapmap

  #maven-old = maven.overrideDerivation (_: rec {
  #  version = "3.0.5";
  #  name = "apache-maven-${version}";
  #  src = fetchurl {
  #    url = "mirror://apache/maven/maven-3/${version}/binaries/${name}-bin.tar.gz";
  #    sha256 = "1nbx6pmdgzv51p4nd4d3h8mm1rka8vyiwm0x1j924hi5x5mpd3fr";
  #  };
  #});

  urlToScript = (dep: let
    inherit (dep) path url sha1;

    authenticated = false;

    fetch = (if authenticated then requireFile else fetchurl) {
      inherit url sha1;
    };
  # XXX: What does this do?
  in ''
    dir="$out/$(dirname ${path})"
    dest="$dir/${baseNameOf path}"
    mkdir -p "$dir"
    ln -fv "${fetch}" "$dest"
    linkSnapshot "$dest"
  '');

  drvToScript = drv: ''
    echo >&2 BUILDING FROM DERIVATION

    props="${drv}/share/java/*.properties"
    for prop in $props; do getMavenPathFromProperties $prop; done
  '';

  transDeps = drvs: builtins.concatLists (
    map (drv: (jsonFile "${drv}/share/java/info.json").deps) drvs
  );
in

{ src
, drvs        ? []
, settings    ? settings_
, opts        ? ""
, buildInputs ? []
}: let

  mkRepo = drvs: deps: runCommand "mk-repo" {
    buildInputs = [ unzip ] ++ buildInputs;
  } ''
    set -e
    mkdir -p "$out"
    TMP_REPO="$out"

    ${builtins.readFile ./drvbuilder.sh}

    ${lib.concatStrings (map urlToScript (deps ++ (transDeps drvs)))}
    ${lib.concatStrings (map drvToScript drvs)}
  '';

  initRepo = mkRepo drvs [];

  mvn-online = runCommand "mvn" { buildInputs = [ makeWrapper ]; } ''
    makeWrapper ${maven}/bin/mvn $out/bin/mvn \
      --add-flags "--settings ${settings}" \
      --add-flags "-nsu"
  '';

  mvnix = writeScriptBin "mvnix" (''
      set -e
      MAVEN_OPTS="$MAVEN_OPTS ${opts}"

      export PATH=${mvn-online}/bin:$PATH
      export PATH=${mktemp}/bin:$PATH

      TMP_REPO="$(mktemp -d --tmpdir mavenix-m2-repo.XXXXXX)"

      cleanup() {
        rm -rf "$TMP_REPO" || echo -n
      }
      trap "trap - TERM; cleanup; kill -- $$" EXIT INT TERM

      cp -rf ${initRepo}/* $TMP_REPO || echo -n
      chmod -R +w "$TMP_REPO" || echo >&2 Failed to set chmod on temp repo dir.
    '' + (builtins.readFile ./mkinfo.sh)
  );
in (infoFile:
 let
    info = if builtins.pathExists infoFile
      then builtins.fromJSON (builtins.readFile infoFile)
      else {
        name = "undefined";
        deps = [];
        artifactId = "undefined";
        groupId = "undefined";
        version = "undefined";
        submodules = [];
      };

    repo = mkRepo drvs info.deps;

    cp-artifact = submod: ''
      find . -type f \
        -regex "${submod.path}/target/[^/]*\.\(jar\|war\)$" ! -name "*-sources.jar" \
        -exec cp -v {} $dir \;
    '';

    cp-pom = submod: ''
      cp -v ${submod.path}/pom.xml $dir/${submod.name}.pom
    '';

    mk-properties = submod: ''
      echo '# Generated with MaveNix
      groupId=${submod.groupId}
      artifactId=${submod.artifactId}
      version=${submod.version}
      ' > $dir/${submod.name}.properties
    '';

    mk-maven-metadata = submod: ''
      echo '<!-- Generated with MaveNix -->
      <groupId>${submod.groupId}</groupId>
        <artifactId>${submod.artifactId}</artifactId>
        <versioning>
          <versions>
            <version>${submod.version}</version>
          </versions>
        </versioning>
      </metadata>
      ' > $dir/${submod.name}.metadata.xml
    '';

    mvn-offline = runCommand "mvn-offline" { buildInputs = [ makeWrapper ]; } ''
      makeWrapper ${maven}/bin/mvn $out/bin/mvn-offline \
        --add-flags "--offline" \
        --add-flags "--settings ${settings}" \
        --add-flags "-Dmaven.repo.local=${repo}"
    '';

  in stdenv.mkDerivation {
    name = builtins.trace "The name of this project is ${info.name}" info.name;
    src = filterSrc src;

    MAVEN_OPTS = opts;
    LC_ALL = "en_US.UTF-8";

    buildInputs = [ mvn-offline mvnix ] ++ buildInputs;

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

      cp ${if builtins.pathExists infoFile then infoFile else ""} $dir/info.json

      ${lib.concatStrings (builtins.concatLists (
        mapmap [ cp-artifact cp-pom mk-properties mk-maven-metadata ] info.submodules
      ))}

      runHook postInstall
    '';
  }
)
