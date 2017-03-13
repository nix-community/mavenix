{
  stdenv, maven, runCommand, writeText, writeScript, writeScriptBin, fetchurl,
  makeWrapper, lib, requireFile, unzip
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
      p2s = pathToString src;
      isResult = lib.hasPrefix (p2s "result") p;
      check = (!isResult) &&
        (! builtins.elem p (map p2s [ "target" ".git" ]));
    in check
  ) src;

  #maven-old = maven.overrideDerivation (_: rec {
  #  version = "3.0.5";
  #  name = "apache-maven-${version}";
  #  src = fetchurl {
  #    url = "mirror://apache/maven/maven-3/${version}/binaries/${name}-bin.tar.gz";
  #    sha256 = "1nbx6pmdgzv51p4nd4d3h8mm1rka8vyiwm0x1j924hi5x5mpd3fr";
  #  };
  #});
in

{ src
, drvs        ? []
, settings    ? settings_
, opts        ? ""
, buildInputs ? []
}: let
  drvToScript = drv: ''
    echo >&2 BUILDING FROM DERIVATION

    jars="$(find ${drv}/share/java -type f -path "${drv}/share/java/*.jar" ! -name "*-sources.jar")"

    getMavenPathFromProp "${drv}/share/java"
    for jar in $jars; do getMavenPathFromJar $jar; done
    #chmod -R +w $TMP_REPO
  '';

  # TODO: maybe use:
  mvn-online = runCommand "mvn" { buildInputs = [ makeWrapper ]; } ''
    makeWrapper ${maven}/bin/mvn $out/bin/mvn \
      --add-flags "--settings ${settings}" \
      --add-flags "-nsu"
  '';

  mvnix = writeScriptBin "mvnix" (''
      set -e

      TMP_REPO="$PWD/.m2_repository"
      mkdir -p "$TMP_REPO"
      #chmod -R +w "$TMP_REPO"
      MAVEN_OPTS="${opts}"

      cleanup() {
        rm -rf "$TMP_REPO"
      }

      trap "trap - TERM; cleanup; kill -- $$" EXIT INT TERM

      cleanup

      export PATH=${mvn-online}/bin:$PATH
      (
    ''
    + (builtins.readFile ./drvbuilder.sh)
    + ''
      ${lib.concatStrings (map drvToScript drvs)}
      test -d "$TMP_REPO" && chmod -R +w "$TMP_REPO" || echo >&2 Failed to set chmod on temp repo dir.
      ) >&2
    ''
    + (builtins.readFile ./mkinfo.sh)
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
      };

    urlToScript = (dep: let
      inherit (dep) path url sha1;

      authenticated = false;

      fetch = (if authenticated then requireFile else fetchurl) {
        inherit url sha1;
      };
    in ''
      dir="$out/$(dirname ${path})"
      dest="$dir/${baseNameOf path}"
      mkdir -p "$dir"
      ln -sv "${fetch}" "$dest"
      linkSnapshot "$dest"
    '');

    script = writeText "build-maven-repository.sh" (
    (builtins.readFile ./drvbuilder.sh) + ''
      ${lib.concatStrings
        ((map urlToScript info.deps) ++ (map drvToScript drvs))}
    '');

    repo = runCommand "maven-repository" {
      buildInputs = [ unzip ] ++ buildInputs;
    } ''
      mkdir -p "$out"
      TMP_REPO="$out" MAVEN_OPTS="${opts}" bash ${script}
    '';

    mvn-offline = runCommand "mvn" { buildInputs = [ makeWrapper ]; } ''
      makeWrapper ${maven}/bin/mvn $out/bin/mvn \
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

    #shellHook = ''
    #  mkdir -p .m2
    #  ln -fs "${settings}" "$PWD/.m2/settings.xml"
    #  ln -fs "${repo}" "$PWD/.m2/repository"
    #  export MAVEN_OPTS+=" -Duser.home=$PWD"' ${opts}'
    #'';
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

      find . -type f \
        -regex ".*/target/[^/]*\.\(jar\|war\)$" ! -name "*-sources.jar" \
        -exec cp -v {} $dir \;

      cp -v pom.xml $dir/pom.xml

      echo '# Generated with MaveNix
      groupId=${info.groupId}
      artifactId=${info.artifactId}
      version=${info.version}
      ' > $dir/pom.properties

      runHook postInstall
    '';
  }
)
