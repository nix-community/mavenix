echo >&2 "RUNING MAVEN INSTALL" >&2
mvn_ >&2 install -B -Dmaven.repo.local=${TMP_REPO}

echo >&2 "GETTING PROJECT INFO"

# XXX the maven-exec plugin will be put in the generated repo which might be
# unwanted.
proj="$(mvn_ -q --non-recursive \
  org.codehaus.mojo:exec-maven-plugin:1.3.1:exec \
  -Dexec.executable="echo" -Dexec.args='${project.groupId} ${project.artifactId} ${project.version}')"
groupId="$(cut -d' ' -f1 <<<"$proj")"
artifactId="$(cut -d' ' -f2 <<<"$proj")"
version="$(cut -d' ' -f3 <<<"$proj")"

submodules="$(mvn_ -q \
  org.codehaus.mojo:exec-maven-plugin:1.3.1:exec \
  -Dexec.executable="echo" \
  -Dexec.args='-n ,\\n
    \\s{\\n
    \\s\\s\\qname\\q: \\q${project.artifactId}-${project.version}\\q,\\n
    \\s\\s\\qgroupId\\q: \\q${project.groupId}\\q,\\n
    \\s\\s\\qartifactId\\q: \\q${project.artifactId}\\q,\\n
    \\s\\s\\qversion\\q: \\q${project.version}\\q,\\n
    \\s\\s\\qpath\\q: \\q${basedir}\\q\\n
    \\s}')"

echo >&2 "RESOLVING MAVEN DEPENDENCIES"
# Maven 3.3.9
mvn_ >&2 dependency:go-offline -B -Dmaven.repo.local=${TMP_REPO}
# Maven 3.0.5
#mvn >&2 org.apache.maven.plugins:maven-dependency-plugin:2.6:go-offline -Dmaven.repo.local=${TMP_REPO}


echo >&2 "CREATING OUTPUT"
(
echo -n "{
  \"name\": \"$artifactId-$version\",
  \"groupId\": \"$groupId\",
  \"artifactId\": \"$artifactId\",
  \"version\": \"$version\",
  \"submodules\": ["

echo -n $submodules \
  | sed 's/,//;s|\\\\q'$PWD'|".|g;s/\\\\s/  /g;s/\\\\n/\n /g;s/\\\\q/"/g'
echo -n  "
  ],
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
    echo -n "$sep{
      \"path\": \"$file_real\",
      \"sha1\": \"$(grep -Eo '[0-9a-zA-Z]{40}' < $file_real.sha1)\"
    }"
    sep=", "
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
  test "$repo" || continue
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
