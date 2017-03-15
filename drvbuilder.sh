getMavenPath() {
  local version="$(sed -n 's|^version=||p' "$1")"
  local groupId="$(sed -n 's|^groupId=||p' "$1")"
  local artifactId="$(sed -n 's|^artifactId=||p' "$1")"
  echo "$TMP_REPO/$(sed 's|\.|/|g' <<<"$groupId")/$artifactId/$version/$artifactId-$version"
}

linkSnapshot() {
  local file="$(basename $1)"
  local ext="${file##*.}"
  local dir="$(dirname $1)"
  local version="$(basename $dir)"
  local name="$(basename `dirname $dir`)"
  local dest="$dir/$name-$version.$ext"
  test -f "$dest" || ln -v "$1" "$dest"
}

getMavenPathFromProperties() {
  local path="$(getMavenPath "$1")"
  local bpath="$(dirname $path)"
  local basefilename="${1%%.properties}"

  if test "$bpath"; then
    mkdir -p "$bpath"
    for fn in $basefilename-* $basefilename.{pom,jar}; do
      test ! -f $fn || ln -fv "$fn" "$bpath"
    done
    ln -fv "$basefilename.metadata.xml" "$bpath/maven-metadata-local.xml"
  fi
}
