unzipFile() {
  unzip -p "$1" "$(unzip -l "$1" | grep -E "$2" | tr -s ' ' | cut -d ' ' -f5)"
}

getMavenPath() {
  local version="$(sed -n 's|^version=||p' "$1")"
  local groupId="$(sed -n 's|^groupId=||p' "$1")"
  local artifactId="$(sed -n 's|^artifactId=||p' "$1")"
  echo "$TMP_REPO/$(sed 's|\.|/|g' <<<"$groupId")/$artifactId/$version/$artifactId-$version"
}

getMavenPathFromJar() {
  unzipFile "$1" "/pom.properties$" > _pom.properties
  local path="$(getMavenPath _pom.properties)"
  rm _pom.properties

  if test "$path"; then
    local dir="$(dirname $path)"
    rm -rf "$dir"
    mkdir -p "$dir"
    unzipFile "$1" "/pom.xml$" > "$path.pom"
    # Hardlink here, otherwise Maven will complain (permissions).
    ln -fv "$1" "$path.jar"
  fi
}

getMavenPathFromProp() {
  local path="$(getMavenPath "$1/pom.properties")"

  if test "$path"; then
    mkdir -p "$(dirname $path)"
    ln -fv "$1/pom.xml" "$path.pom"
  fi
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
