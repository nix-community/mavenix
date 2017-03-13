declare -A repos

set_repos() {
  while test "$1";do
    repos["$1="]="$2"
    shift 2
  done
}

mkdir -p "${TMP_REPO}"

echo >&2 "GETTING PROJECT INFO"
cp -r "${TMP_REPO}" "${TMP_REPO}__"

#DEBUG
#which mvn >&2
#cat `which mvn` >&2
export PATH=${maven}/bin:$PATH

proj="$(mvn -q -nsu --non-recursive \
  --settings $settings -Dmaven.repo.local=${TMP_REPO}__ \
  org.codehaus.mojo:exec-maven-plugin:1.3.1:exec \
  -Dexec.executable="echo" -Dexec.args='${project.groupId} ${project.artifactId} ${project.version}')"
groupId="$(cut -d' ' -f1 <<<"$proj")"
artifactId="$(cut -d' ' -f2 <<<"$proj")"
version="$(cut -d' ' -f3 <<<"$proj")"
rm -fr "${TMP_REPO}__"

echo >&2 "RUNING MAVEN INSTALL" >&2
mvn >&2 -nsu install --settings $settings -Dmaven.repo.local=${TMP_REPO} || echo -n

echo >&2 "RESOLVING MAVEN DEPENDENCIES"
# Maven 3.3.9
mvn >&2 -nsu dependency:go-offline --settings $settings -Dmaven.repo.local=${TMP_REPO}
# Maven 3.0.5
#mvn >&2 -nsu org.apache.maven.plugins:maven-dependency-plugin:2.6:go-offline --settings $settings -Dmaven.repo.local=${TMP_REPO}

echo >&2 "RESOLVING MAVEN REPOSITORIES"
# Maven 3.3.9
set_repos $(mvn -o -nsu \
  dependency:list-repositories --settings $settings -Dmaven.repo.local=${TMP_REPO} 2>&- \
  | grep -Eo '(id: |url: ).*$' | sed 's|[^ ]*||')
# Maven 3.0.5
#set_repos $(mvn -o -nsu \
#   org.apache.maven.plugins:maven-dependency-plugin:2.6:list-repositories \
#   --settings $settings -Dmaven.repo.local=${TMP_REPO} 2>&1 \
#  | grep -Eo '(id: |url: ).*$' | sed 's|[^ ]*||')

echo >&2 "CREATING OUTPUT"
( cd $TMP_REPO

metafiles="$(find . -type f -name "maven-metadata-*.xml"  | sed 's|^\./||' | sort)"
remotes="$(find . -type f -name "*.repositories" | sed 's|^\./||' | sort)"

echo -n "{
  \"name\": \"$artifactId-$version\",
  \"groupId\": \"$groupId\",
  \"artifactId\": \"$artifactId\",
  \"version\": \"$version\",
  \"deps\": ["
# XXX: is this needed?
#for file in $metafiles; do
#  repo=$(basename $file | sed 's/^maven-metadata-//;s/\.xml$/=/')
#  test "${repos[$repo]}" || continue
#  echo -n "$sep
#    {
#      \"path\": \"$file\",
#      \"url\": \"${repos[$repo]}/$(dirname $file)/maven-metadata.xml\",
#      \"sha1\": \"$(cat $file.sha1)\"
#    }"
#  sep=,
#done
for remote in $remotes; do
  dir="$(dirname "$remote")"
  #test $(find "$dir" -type f -name "*.jar" | wc -l) -gt 1 && continue
  files="$(find "$dir" -type f ! -name "*.repositories" ! -name "*.sha1" \
    | grep -v '^#' "$remote" | sed "s|^|$dir/|")"
  for file_ in $files; do
    file=$(echo $file_ | cut -d '>' -f1)
    # Maven 3.0.5 for 3.3.9 use $file instead of $file_real
    file_real=$(echo $(echo $file | sed 's/-SNAPSHOT\./-[0-9]*\./'))
    repo=$(echo $file_ | cut -d '>' -f2)
    test "${repos[$repo]}" || continue
    echo -n "$sep
    {
      \"path\": \"$file_real\",
      \"url\": \"${repos[$repo]}/$file_real\",
      \"sha1\": \"$(cut -d\  -f1 $file_real.sha1)\"
    }"
    sep=,
  done
done
echo ']
}'

)
