#!/bin/sh
# Publishes php/ to kuaa-io/sdk-php, the repository Packagist reads for the
# Composer package kuaa-io/sdk: it
# needs the package at the root, so php/ is split out of this history and the
# release tag is set on the split. Usage: scripts/split-php.sh v0.1.0
set -eu
cd "$(dirname "$0")/.."
tag=${1:?usage: scripts/split-php.sh vX.Y.Z}
remote=${PHP_REMOTE:-https://github.com/kuaa-io/sdk-php.git}
commit=$(git subtree split --prefix php HEAD)
git push "$remote" "$commit:refs/heads/main"
git push "$remote" "$commit:refs/tags/$tag"
