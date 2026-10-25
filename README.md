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
- todos os recursos de `/v1`: cases (abrir, listar, ler, alterar, iniciar, enviar, decisão, dossiê), partes, sociedade e beneficiários finais, documentos, links de captura, envio de imagens (`multipart/form-data`), tags, endpoints de webhook, workflows, perfis de parte, leitura do chip do documento, disponibilidade dos engines, créditos (saldo e extrato) e consultas de CPF e CNPJ fora de um case (`lookups`);
- listas paginadas por cursor, com iterador que percorre todas as páginas;
- `Idempotency-Key` nas escritas;
- erros tipados, com as mensagens de cada campo, o `Retry-After` e o `X-Request-ID`;
- verificação dos webhooks no esquema do KUAA (`X-Arandu-Delivery-Id`, `X-Arandu-Timestamp`, `X-Arandu-Signature: sha256=…`, uma linha por segredo na rotação, tolerância de 5 minutos) e leitura tipada do envelope CloudEvents 1.0.

Só usam a biblioteca padrão da linguagem, com duas exceções onde ela não tem HTTP, JSON ou HMAC: Dart (`http` e `crypto`, do próprio time do Dart) e Rust (`serde`, `ureq`, `hmac`, `sha2`).

## Consultas de CPF e CNPJ

`lookups.person` e `lookups.business` consultam o cadastro de um CPF ou de um CNPJ sem abrir um case, e `lookups.get` lê uma consulta de novo. A resposta traz a conclusão do KUAA em `status` (`regular`, `irregular` ou `inconclusive`; `failed` numa consulta que não terminou), as `reasons`, os dados, em `provenance` de onde veio cada campo e, em `cost.credits`, os créditos cobrados. `purpose` é obrigatório. No sandbox (`kuaa_test_…`), o CPF `000.000.001-91` e o CNPJ `SA.NDB.OX0/0001-25` respondem `regular` com dados sintéticos. Em TypeScript:

```ts
const lookup = await kuaa.lookups.person({ cpf: "000.000.001-91", purpose: "onboarding" }, { idempotencyKey: "consulta-0001" });
console.log(lookup.status, lookup.reasons, lookup.provenance.situacao_cadastral?.source);

const company = await kuaa.lookups.business({ cnpj: "SA.NDB.OX0/0001-25", purpose: "onboarding" }, { idempotencyKey: "consulta-0002" });
const again = await kuaa.lookups.get(lookup.id);
```

O README de cada linguagem traz o mesmo exemplo no seu idioma.

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
