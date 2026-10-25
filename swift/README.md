# KUAA SDK para Swift

SDK oficial da API do KUAA para Swift 6 (macOS 12+, iOS 15+, tvOS 15+, watchOS 8+, visionOS 1+), com async/await, `URLSession` e CryptoKit, sem dependências. É gerado a partir do contrato da API (`openapi.json`, na raiz de [kuaa-io/sdk](https://github.com/kuaa-io/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```swift
// Package.swift
.package(url: "https://github.com/kuaa-io/sdk", from: "0.2.0"),
// e, no target:
.product(name: "KuaaSDK", package: "sdk"),
```

```swift
import Kuaa // o módulo do produto KuaaSDK

let kuaa = KuaaClient(apiKey: ProcessInfo.processInfo.environment["KUAA_API_KEY"]!) // kuaa_<prefixo>_<segredo> ou kuaa_test_<prefixo>_<segredo>

let kase = try await kuaa.cases.create(
    CaseRequest(externalReference: "pedido-0001", kind: .kyc, parties: [CaseRequestParty(kind: .person, cpf: "123.456.789-09", primary: true)]),
    idempotencyKey: "pedido-0001"
)
_ = try await kuaa.cases.start(kase.id, idempotencyKey: "pedido-0001-start")

for try await summary in kuaa.cases.listIter(status: "in_review") {
    print(summary.id, summary.status.rawValue)
}

print(kuaa.lastResponse?.livemode as Any) // false no sandbox (cabeçalho Kuaa-Livemode)
```

A chave decide a organização e o ambiente: `kuaa_test_…` só funciona no sandbox, e a chave sem `test` só em produção. A chave dá acesso à organização inteira: use o SDK no servidor, não embutida num app. `kuaa.lastResponse` traz o `status`, o `livemode`, o `environment`, o `idempotentReplayed` e o `requestId` da última resposta.

## Recursos

| Serviço | Métodos |
|---|---|
| `kuaa.billing` | `balance`, `statement`, `statementIter` |
| `kuaa.caseCaptureSessions` | `create`, `list`, `revoke` |
| `kuaa.caseChipChallenges` | `create` |
| `kuaa.caseChipReads` | `create` |
| `kuaa.caseDocuments` | `list` |
| `kuaa.caseMedia` | `create` |
| `kuaa.caseOwnership` | `create`, `get` |
| `kuaa.caseParties` | `create` |
| `kuaa.caseTags` | `create`, `delete`, `list` |
| `kuaa.cases` | `create`, `decision`, `dossier`, `get`, `list`, `listIter`, `start`, `submit`, `update` |
| `kuaa.health` | `get` |
| `kuaa.lookups` | `business`, `get`, `person` |
| `kuaa.parties` | `get`, `list`, `listIter` |
| `kuaa.webhooks` | `create`, `delete`, `list` |
| `kuaa.workflows` | `list` |

Os objetos respondidos são structs `Codable` com propriedades em camelCase (`kase.externalReference`); os corpos das escritas são structs cujo inicializador pede primeiro os campos obrigatórios, e um campo opcional `nil` não é enviado. Os campos enumerados (`CaseStatus.approved`) guardam em `rawValue` um valor que esta versão ainda não conhece. As listas respondem uma `Page` (`items`, `nextCursor`, `hasMore`), e o `…Iter` devolve um `AsyncThrowingStream` que percorre todas as páginas pelo cursor. O envio de imagens (`kuaa.caseMedia.create`) vai como `multipart/form-data`, com cada arquivo num `FilePart`. As escritas aceitam `idempotencyKey:`, e todas aceitam `apiKey:` para usar outra chave numa chamada. `KuaaClient` aceita `baseURL`, `timeout` (30 s por padrão) e `transport`, para usar outro cliente HTTP ou testar sem rede.

## Consultas de CPF e CNPJ

Uma consulta lê o cadastro de um CPF ou de um CNPJ fora de qualquer case: o que a Receita Federal guarda (pelo bureau Direct Data), cruzado com as listas do KUAA. A resposta traz `status` (`regular`, `irregular` ou `inconclusive`, a conclusão do KUAA sob `rule_version`; `failed` numa consulta lida cujo processamento não terminou), `reasons`, os dados (`person` ou `company`), `provenance` (de onde veio cada campo e quando), `screening`, `sources` e `cost` (com os créditos cobrados em `credits`). Acima do limite diário de consultas, ela responde `inconclusive` com `daily_limit_reached`, sem consultar o bureau; consultas demais num minuto, pela chave ou pela organização, recebem um 429 (`rate_limited`) com `Retry-After`. `purpose` é obrigatório e fica registrado com a sua base legal na LGPD. Com uma chave `kuaa_test_…`, o sandbox responde dados sintéticos pelos valores mágicos (o CPF `000.000.001-91` e o CNPJ `SA.NDB.OX0/0001-25` respondem `regular`) e nunca consulta o bureau.

```swift
let lookup = try await kuaa.lookups.person(
    PersonLookupRequest(cpf: "000.000.001-91", purpose: .onboarding),
    idempotencyKey: "consulta-0001"
)
print(lookup.status.rawValue, lookup.reasons, lookup.provenance.situacaoCadastral?.source ?? "-")

let company = try await kuaa.lookups.business(
    BusinessLookupRequest(cnpj: "SA.NDB.OX0/0001-25", purpose: .onboarding),
    idempotencyKey: "consulta-0002"
)
let again = try await kuaa.lookups.get(lookup.id)
```

## Erros

Uma recusa da API lança `KuaaError`, com `status`, `code` (`validation_failed`, `not_found`, `conflict`, `payment_required`…), `message`, `fields` (as mensagens de cada campo), `retryAfter` em segundos (num 429 ou 503) e `requestId`.

## Webhooks

```swift
let event = try verifyWebhook(secret: ProcessInfo.processInfo.environment["KUAA_WEBHOOK_SECRET"]!, headers: headers, body: body)
print(event.type.rawValue, event.data.caseID)
```

Cada entrega leva `X-Arandu-Delivery-Id`, `X-Arandu-Timestamp` e `X-Arandu-Signature: sha256=hex(HMAC-SHA256(segredo, timestamp + "." + delivery_id + "." + corpo))`. Durante uma rotação vem uma linha de assinatura por segredo ativo, e basta uma conferir. Um timestamp a mais de 5 minutos do relógio lança `WebhookVerificationError.invalidSignature`. `headers` pode ser `[String: [String]]` (uma entrada por linha) ou `[String: String]`. Passe o corpo cru, antes de interpretar; o evento é um envelope CloudEvents 1.0 e deve ser deduplicado pelo `id`, porque a entrega é pelo menos uma vez. A verificação usa o CryptoKit e por isso existe nas plataformas da Apple; no Linux, o cliente compila, mas a verificação dos webhooks não está disponível.

Versão do SDK: 0.2.0 · contrato da API: 1.0.0
