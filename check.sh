#!/bin/sh
# The gates every change passes: the generator and its tests, the SDKs being
# exactly what the generator writes, and each language's own tests and type
# checks. CHECK_DRIFT=1 (CI) also fails when a regenerated SDK differs from
# what is committed. MYPY and PHPSTAN name those tools when they are not on
# the PATH; when neither is found, that one type check is skipped with a
# message, never silently (CI installs both). Swift needs Apple's toolchain
# (CryptoKit, Network): it runs only on macOS, and SKIP_SWIFT=1 leaves it to
# the macOS CI job.
set -eu
cd "$(dirname "$0")"
export GOWORK=off

sdks="go typescript python php ruby java csharp elixir dart rust swift"

echo "== generator"
unformatted=$("$(go env GOROOT)/bin/gofmt" -l generator cmd go)
if [ -n "$unformatted" ]; then
	echo "not gofmt'd:"
	echo "$unformatted"
	exit 1
fi
go vet ./...
go test -count=1 ./...
go run ./cmd/sdkgen
# shellcheck disable=SC2086
if [ "${CHECK_DRIFT:-}" = 1 ] && [ -n "$(git status --porcelain -- openapi.json testdata $sdks Package.swift)" ]; then
	echo "the SDKs differ from what the generator writes: run go run ./cmd/sdkgen and commit"
	git status --porcelain -- openapi.json testdata $sdks Package.swift
	exit 1
fi

# tool NAME OVERRIDE answers the command to run, or nothing when it is absent.
tool() {
	candidate=${2:-$1}
	if command -v "$candidate" >/dev/null 2>&1; then
		echo "$candidate"
	fi
}

echo "== go"
(cd go && go vet ./... && go test -count=1 ./...)

echo "== typescript"
(cd typescript && npm install --no-audit --no-fund --silent && npx tsc -p tsconfig.json --noEmit && node --test 'test/*.test.ts')

echo "== python"
(cd python && PYTHONPATH=src python3 -m unittest discover -s tests)
mypy=$(tool mypy "${MYPY:-}")
if [ -n "$mypy" ]; then
	(cd python && "$mypy" --strict --python-version 3.11 src/kuaa)
else
	echo "SKIPPED: mypy --strict (mypy is not installed; set MYPY or install it; CI runs it)"
fi

echo "== php"
(cd php && php tests/run.php)
phpstan=$(tool phpstan "${PHPSTAN:-}")
if [ -n "$phpstan" ]; then
	(cd php && "$phpstan" analyse --no-progress --level 8 src)
else
	echo "SKIPPED: PHPStan level 8 (phpstan is not installed; set PHPSTAN or install it; CI runs it)"
fi

echo "== ruby"
(cd ruby && ruby -w -Ilib -Itest test/kuaa_test.rb)

echo "== java"
(cd java && mvn -q -B verify)

echo "== csharp"
(cd csharp && dotnet test --nologo)

echo "== elixir"
(cd elixir && mix compile --warnings-as-errors && mix test --warnings-as-errors)

echo "== dart"
(cd dart && dart pub get && dart format --output=none --set-exit-if-changed . && dart analyze --fatal-infos && dart test)

echo "== rust"
(cd rust && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test)

if [ "${SKIP_SWIFT:-}" != 1 ]; then
	echo "== swift"
	swift=swift
	if command -v xcrun >/dev/null; then
		swift="xcrun swift"
	fi
	(cd swift && $swift test) && $swift build
fi
echo "== all gates passed"
