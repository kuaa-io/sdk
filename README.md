# SDKs do KUAA

Os SDKs oficiais da API do KUAA (verificação de identidade, KYC, KYB e idade para o Brasil), num monorepo no padrão do SDK da Peráta: um contrato, um gerador e um pacote por linguagem.

| Linguagem | Pasta | Pacote |
|---|---|---|
| Go | [`go/`](go) | `github.com/kuaa-io/sdk/go` |
| TypeScript / JavaScript | [`typescript/`](typescript) | `@kuaa-io/sdk` (npm) |
| Python | [`python/`](python) | `kuaa-io-sdk` (PyPI), `import kuaa` |
| PHP | [`php/`](php) | `kuaa-io/sdk` (Packagist) |
| Ruby | [`ruby/`](ruby) | `kuaa-io-sdk` (RubyGems), `require "kuaa"` |
| Java (e Kotlin) | [`java/`](java) | `io.kuaa:sdk` (Maven Central), pacote `io.kuaa.sdk` |
| C# / .NET | [`csharp/`](csharp) | `KuaaIo.Sdk` (NuGet) |
| Elixir | [`elixir/`](elixir) | `kuaa_io_sdk` (Hex), módulo `Kuaa` |
| Dart / Flutter | [`dart/`](dart) | `kuaa_io_sdk` (pub.dev) |
| Rust | [`rust/`](rust) | `kuaa-io-sdk` (crates.io), crate `kuaa_io_sdk` |
| Swift (iOS, macOS) | [`swift/`](swift) | Swift Package Manager: `https://github.com/kuaa-io/sdk`, produto `KuaaSDK` |

Todos fazem o mesmo, com a mesma versão (`VERSION`):
- a chave da API como `Bearer` (`kuaa_<prefixo>_<segredo>` em produção, `kuaa_test_<prefixo>_<segredo>` no sandbox), que define a organização e o ambiente; a última resposta traz o `Kuaa-Livemode`;
- todos os recursos de `/v1`: cases (abrir, listar, ler, alterar, iniciar, enviar, decisão, dossiê), partes, sociedade e beneficiários finais, documentos, links de captura, envio de imagens (`multipart/form-data`), tags, endpoints de webhook, workflows, perfis de parte e créditos (saldo e extrato);
- listas paginadas por cursor, com iterador que percorre todas as páginas;
- `Idempotency-Key` nas escritas;
- erros tipados, com as mensagens de cada campo, o `Retry-After` e o `X-Request-ID`;
- verificação dos webhooks no esquema do KUAA (`X-Arandu-Delivery-Id`, `X-Arandu-Timestamp`, `X-Arandu-Signature: sha256=…`, uma linha por segredo na rotação, tolerância de 5 minutos) e leitura tipada do envelope CloudEvents 1.0.

Só usam a biblioteca padrão da linguagem, com duas exceções onde ela não tem HTTP, JSON ou HMAC: Dart (`http` e `crypto`, do próprio time do Dart) e Rust (`serde`, `ureq`, `hmac`, `sha2`).

## Como é feito

```
openapi.json      o contrato da API pública, servido pelo kuaa.io em /docs/openapi.json
generator/        OpenAPI → IR neutra → um emissor por linguagem (templates)
cmd/sdkgen        o comando que gera
testdata/         os vetores de teste dos webhooks, gerados em Go e copiados para os testes de cada SDK
<linguagem>/      saída do gerador, uma pasta por linguagem: nunca editada à mão
Package.swift     o manifesto do Swift na raiz, que o SwiftPM exige
```

```sh
go run ./cmd/sdkgen -sync http://127.0.0.1:8080/docs/openapi.json   # contrato novo (kuaa.io com API_DOCS_ENABLED=true)
go run ./cmd/sdkgen                                                  # regenerar
./check.sh                                                           # todos os gates
```

Licença MIT.
