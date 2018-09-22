echo >&2 "RUNING MAVEN INSTALL" >&2
mvn_ >&2 package -Dmaven.test.skip.exec=true -Dmaven.repo.local=${TMP_REPO}

echo >&2 "GETTING PROJECT INFO"
pom="$(mvn_out help:effective-pom | grep -v '^\[\|^Effective \|^$' | xq -c .)"
projects="$(jq -c '.projects.project // [.project]' <<<"$pom")"
pq() { jq -rc "$1" <<<"$projects"; }
export -f pq

groupId="$(pq .[0].groupId)"
artifactId="$(pq .[0].artifactId)"
version="$(pq .[0].version)"

modules="$(pq '[.[] | {name: (.artifactId + "-" + .version), groupId, artifactId, version, path: (.build.directory | sub("^'$PWD'/"; "./") | sub("/target"; ""))}]')"

echo >&2 "RESOLVING MAVEN DEPENDENCIES"
# Maven 3.3.9
mvn_ >&2 dependency:go-offline -Dmaven.test.skip.exec=true -Dmaven.repo.local=${TMP_REPO}
# Maven 3.0.5
#mvn >&2 org.apache.maven.plugins:maven-dependency-plugin:2.6:go-offline -Dmaven.repo.local=${TMP_REPO}

echo >&2 "CREATING OUTPUT"
(
echo -n "{
  \"name\": \"$artifactId-$version\",
  \"groupId\": \"$groupId\",
  \"artifactId\": \"$artifactId\",
  \"version\": \"$version\",
  \"submodules\": $modules,
  \"deps\": ["
( cd $TMP_REPO
remotes="$(find . -type f -name "*.repositories" | sed 's|^\./||' | sort)"
sep=""
for remote in $remotes; do
  dir="$(dirname "$remote")"
  files="$(find "$dir" -type f ! -name "*.repositories" ! -name "*.sha1" \
    | grep -v '^#' "$remote" | sed "s|^|$dir/|")"
  for file_ in $files; do
    file=$(echo $file_ | cut -d '>' -f1)
    # Maven 3.0.5 for 3.3.9 use $file instead of $file_real
    file_real=$(echo $(echo $file | sed 's/-SNAPSHOT\./-[0-9]*\./'))
    repo=$(echo $file_ | cut -d '>' -f2 | sed 's/=$//')
    test "$repo" || continue
    echo -n "$sep
    {\"path\":\"$file_real\",\"sha1\":\"$(grep -Eo '[0-9a-zA-Z]{40}' < $file_real.sha1)\"}"
    sep=","
  done
done

echo -n "
  ],
  \"metas\": ["
# XXX: is this needed? Yes, for transitive deps
metafiles="$(find . -type f -name "maven-metadata-*.xml"  | sed 's|^\./||' | sort)"
sep=""
for file in $metafiles; do
  repo=$(basename $file | sed 's/^maven-metadata-//;s/\.xml$//')
  [[ "$repo" && "$repo" != "local"  ]] || continue
  echo -n "$sep{
      \"path\": \"$(dirname $file)\",
      \"content\": \"$(sed ':a;N;$!ba;s/\n/\\n/g;s/\"/\\\"/g' $file)\"
    }"
  sep=", "
done
)
echo -n "
  ]
}
"
) > "$output"
