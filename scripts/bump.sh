#!/usr/bin/env bash

set -euo pipefail
# shellcheck disable=SC2154
trap 's=$?; echo >&2 ": Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR
set -x

cd "$(dirname "$0")"/..

if [[ $# -eq 0 ]]; then
	echo "must provide version number"
	exit 1
fi
version="${1#v}"

pattern='"zap\.sh .*"'
replacement='"zap.sh '"$version"'"'
sed s/"$pattern"/"$replacement"/ bin/zap > bin/zap.new
mv bin/zap.new bin/zap
chmod +x bin/zap
git add bin/zap

scripts/generate-manpage.sh
git add man/man1/zap.1

scripts/generate-readme-usage
git add README.org

git commit -m "release: v$version"
git tag -s "v$version" -em "v$version"
git push origin main "v$version"
gh release create "v$version" --notes-from-tag

umask 022
chmod a+r "$(brew edit --print-path zap.sh)"
brew bump --tap ajaikn/homebrew-tap --no-fork --open-pr zap.sh
