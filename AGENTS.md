# Working in this repository

KUAA's official SDKs, one package per language, generated from the public
API's contract. The pattern is Peráta's SDK monorepo (`perata-sh/sdk`), and
the decision that lets this repository hold code in languages other than Go
is ADR-0008 in the KUAA vault
(`10-adr/ADR-0008-sdk-monorepo-is-the-go-only-exception.md`). Read this before
changing anything.

## What is generated and what is written

- `go/`, `typescript/`, `python/`, `php/`, `ruby/`, `java/`, `csharp/`,
  `elixir/`, `dart/`, `rust/` and `swift/` are **output**. The generator
  empties each one and writes it again, so an edit there is lost on the next
  run. Change the template instead.
- `generator/templates/<language>/` is where every SDK's hand-written part
  lives: client, errors, pagination, multipart, webhooks, tests, README. A
  `.tmpl` file is rendered with the IR; any other file is copied. `_dot_` in a
  name becomes `.`; `__model__`, `__input__` and `__service__` write the file
  once per answered model, per request body or per service.
- `generator/` (Go) reads `openapi.json` into a language-neutral IR
  (`ir.go`) and renders it (`emit.go`, `lang_<language>.go`). KUAA's contract
  writes its objects inline: the IR gives each shape one model, named after
  the property that holds it, with the `overrides` table in `ir.go` for the
  few the rule names poorly. The operations come from kuaa.io's route names
  (`api.cases.tags.store` is `case_tags.create`).
- `openapi.json` is the document kuaa.io serves at `/docs/openapi.json`
  (`API_DOCS_ENABLED=true`). Never edit it here: change the API in kuaa.io
  (`routes/openapi.go`), boot it, and run
  `go run ./cmd/sdkgen -sync http://127.0.0.1:<port>/docs/openapi.json`.
- `testdata/webhook-vectors.json` and its copy in every SDK's tests are
  written by `generator/vectors.go`, deterministically. They were checked
  against hesape/webhook's own Arandu validator, the code kuaa.io signs with.

## Names

| Language | Folder | Package |
|---|---|---|
| Go | `go/` | module `github.com/kuaa-io/sdk/go`, package `kuaa` |
| TypeScript | `typescript/` | npm `@kuaa-io/sdk` |
| Python | `python/` | PyPI `kuaa-io-sdk`, import `kuaa` |
| PHP | `php/` | Composer `kuaa-io/sdk`, namespace `Kuaa`, split to `kuaa-io/sdk-php` |
| Ruby | `ruby/` | RubyGems `kuaa-io-sdk`, require `kuaa` |
| Java | `java/` | Maven `io.kuaa:sdk`, package `io.kuaa.sdk` |
| C# | `csharp/` | NuGet `KuaaIo.Sdk`, namespace `KuaaIo.Sdk` |
| Elixir | `elixir/` | Hex `kuaa_io_sdk`, module `Kuaa` |
| Dart | `dart/` | pub.dev `kuaa_io_sdk` |
| Rust | `rust/` | crates.io `kuaa-io-sdk`, crate `kuaa_io_sdk` |
| Swift | `swift/` | SwiftPM repository `kuaa-io/sdk`, product `KuaaSDK`, module `Kuaa` |

Every name follows `kuaa-io/sdk`, adapted only where a registry forbids the
slash (decision of Paulo R. Lima, 18/10/2026).

## The gates

`./check.sh` runs all of them; nothing is finished until it exits zero.
- generator: gofmt, vet, test, regenerate;
- go: vet and test;
- typescript: `tsc --noEmit` and `node --test`;
- python: unittest and `mypy --strict` on 3.11;
- php: `tests/run.php` and PHPStan level 8;
- ruby: minitest under `ruby -w`;
- java: `mvn verify` (`-Xlint:all -Werror`);
- csharp: `dotnet test`, warnings as errors;
- elixir: compile and test with `--warnings-as-errors`;
- dart: `dart format`, `dart analyze --fatal-infos`, `dart test`;
- rust: `cargo fmt --check`, clippy `-D warnings`, `cargo test`;
- swift: `swift test` in `swift/` and `swift build` at the root (macOS only:
  CryptoKit and Network; CI runs it in its own macOS job).

`MYPY` and `PHPSTAN` name those tools when they are not on the PATH. When one
is not found, `check.sh` prints `SKIPPED:` and goes on; CI installs both, so a
skip is never the last word. Record a skip when you report a run.

`Package.swift` at the root is hand-written, because SwiftPM resolves a
package from the repository root; keep it in step with `swift/Package.swift`.

CI also fails when the committed SDKs differ from what the generator writes.

Use `$(go env GOROOT)/bin/gofmt`: a Homebrew gofmt on the PATH may be a newer
release that formats differently from CI.

## Rules

- Every SDK does the same thing, under the same version (`VERSION`). A feature
  goes into every language, with the same test in each, or into none. Each
  SDK's tests cover: the key and the unwrapped data with the last answer's
  `Kuaa-Livemode`, a write with its body and `Idempotency-Key`, the cursor
  walk, a typed refusal with field problems and `Retry-After`, the capture
  upload as multipart/form-data, a repeated query parameter, and every
  webhook vector.
- No third-party runtime dependency where the language's standard library can
  do HTTP, JSON and HMAC. The two exceptions are Peráta's, deliberate: Dart
  uses `http` and `crypto` from dart.dev, and Rust uses serde, serde_json,
  ureq, hmac and sha2. Do not add others.
- Each SDK keeps its language's idiom for walking every page: Go `ListIter`,
  TypeScript async iterators, Python and Ruby `list_iter`, PHP generators,
  Java `Iterable`, C# `IAsyncEnumerable`, Elixir `list_stream`, Dart and Swift
  streams, Rust `Iterator`.
- Webhook verification is KUAA's scheme, exactly what kuaa.io signs
  (`60-contracts/CT-webhooks.md`, hesape/webhook's Arandu dialect):
  `X-Arandu-Delivery-Id`, `X-Arandu-Timestamp` and
  `X-Arandu-Signature: sha256=hex(HMAC-SHA256(secret, timestamp + "." +
  delivery_id + "." + body))`, one line per secret during a rotation, at most
  six, five minutes of tolerance. Change both together or neither, and
  regenerate the vectors.
- Engines produce evidence; KUAA decides. An SDK never turns an answer into an
  approval of its own.
- Code, comments and commits are in English; the READMEs are in Brazilian
  Portuguese. Commits are authored by the global identity,
  `Paulo R. Lima <paulorlima@hyz.is>`, without `--author` and without any AI
  attribution (no trailer, footer, vendor name or robot emoji). Agent
  instructions live only in this file: no `CLAUDE.md`.

## Release

One version for every language. Pushing, tagging and publishing need the
owner's authorization.
1. Bump `VERSION`, run `go run ./cmd/sdkgen` and `./check.sh`, and commit
   `sdk: release X.Y.Z` on develop; fast-forward main.
2. Tag `vX.Y.Z` and `go/vX.Y.Z` on that commit and push both. The `v` tag runs
   `.github/workflows/release.yml`, which publishes npm and PyPI by trusted
   publishing (OIDC, no stored token); the `go/` tag is the Go module's
   version, and the `v` tag is the Swift package's.
3. `scripts/split-php.sh vX.Y.Z` pushes `php/` to `kuaa-io/sdk-php`, the
   repository Packagist reads, which needs the package at its root.
4. RubyGems, crates.io, Hex, pub.dev, Maven Central and NuGet are published by
   hand until each registry's trusted publisher is configured for this
   repository; no registry secret is stored here.
