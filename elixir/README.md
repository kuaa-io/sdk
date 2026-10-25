# KUAA SDK para Elixir

SDK oficial da API do KUAA para Elixir 1.18+, sem dependências: só `:httpc`, `:crypto` e o módulo `JSON`. É gerado a partir do contrato da API (`openapi.json`, na raiz de [kuaa-io/sdk](https://github.com/kuaa-io/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```elixir
# mix.exs
{:kuaa_io_sdk, "~> 0.2.0"}
```

```elixir
client = Kuaa.new(System.fetch_env!("KUAA_API_KEY")) # kuaa_<prefixo>_<segredo> ou kuaa_test_<prefixo>_<segredo>

{:ok, kase} =
  Kuaa.Cases.create(
    client,
    %{external_reference: "pedido-0001", kind: "KYC", parties: [%{kind: "PERSON", primary: true, cpf: "123.456.789-09"}]},
    idempotency_key: "pedido-0001"
  )

{:ok, _run} = Kuaa.Cases.start(client, kase.id, idempotency_key: "pedido-0001-start")

client
|> Kuaa.Cases.list_stream(status: "in_review")
|> Enum.each(&IO.puts("#{&1.id} #{&1.status}"))

Kuaa.last_response().livemode # false no sandbox (cabeçalho Kuaa-Livemode)
```

A chave decide a organização e o ambiente: `kuaa_test_…` só funciona no sandbox, e a chave sem `test` só em produção. `Kuaa.last_response/0` traz, por processo, o `status`, o `livemode`, o `environment`, o `idempotent_replayed` e o `request_id` da última resposta.

## Recursos

| Módulo | Funções |
|---|---|
| `Kuaa.Billing` | `balance`, `statement`, `statement_stream` |
| `Kuaa.CaseCaptureSessions` | `create`, `list`, `revoke` |
| `Kuaa.CaseChipChallenges` | `create` |
| `Kuaa.CaseChipReads` | `create` |
| `Kuaa.CaseDocuments` | `list` |
| `Kuaa.CaseMedia` | `create` |
| `Kuaa.CaseOwnership` | `create`, `get` |
| `Kuaa.CaseParties` | `create` |
| `Kuaa.CaseTags` | `create`, `delete`, `list` |
| `Kuaa.Cases` | `create`, `decision`, `dossier`, `get`, `list`, `list_stream`, `start`, `submit`, `update` |
| `Kuaa.Health` | `get` |
| `Kuaa.Lookups` | `business`, `get`, `person` |
| `Kuaa.Parties` | `get`, `list`, `list_stream` |
| `Kuaa.Webhooks` | `create`, `delete`, `list` |
| `Kuaa.Workflows` | `list` |

Cada função recebe o cliente primeiro e devolve `{:ok, valor}` ou `{:error, %Kuaa.Error{}}`. Os objetos respondidos são structs com os nomes da API (`kase.external_reference`). O corpo de uma escrita é a struct de parâmetros do método (`%Kuaa.CaseRequest{…}`), uma keyword list ou um mapa com chaves atom; um campo opcional não informado fica fora do JSON. As listas paginadas respondem um `%Kuaa.Page{items, next_cursor, has_more}`, e as funções `_stream` devolvem um `Stream` preguiçoso que percorre todas as páginas pelo cursor e levanta `Kuaa.Error` numa recusa. O envio de imagens (`Kuaa.CaseMedia.create`) vai como `multipart/form-data`, com cada arquivo num `%Kuaa.FilePart{}` (ou `Kuaa.FilePart.from_path/2`).

As escritas aceitam `idempotency_key:`, e todas aceitam `api_key:` para usar outra chave numa chamada. `Kuaa.new/2` aceita `base_url:`, `timeout:` (30 segundos, em milissegundos) e `transport:`.

## Consultas de CPF e CNPJ

Uma consulta lê o cadastro de um CPF ou de um CNPJ fora de qualquer case: o que a Receita Federal guarda (pelo bureau Direct Data), cruzado com as listas do KUAA. A resposta traz `status` (`regular`, `irregular` ou `inconclusive`, a conclusão do KUAA sob `rule_version`; `failed` numa consulta lida cujo processamento não terminou), `reasons`, os dados (`person` ou `company`), `provenance` (de onde veio cada campo e quando), `screening`, `sources` e `cost` (com os créditos cobrados em `credits`). Acima do limite diário de consultas, ela responde `inconclusive` com `daily_limit_reached`, sem consultar o bureau; consultas demais num minuto, pela chave ou pela organização, recebem um 429 (`rate_limited`) com `Retry-After`. `purpose` é obrigatório e fica registrado com a sua base legal na LGPD. Com uma chave `kuaa_test_…`, o sandbox responde dados sintéticos pelos valores mágicos (o CPF `000.000.001-91` e o CNPJ `SA.NDB.OX0/0001-25` respondem `regular`) e nunca consulta o bureau.

```elixir
{:ok, lookup} =
  Kuaa.Lookups.person(client, %{cpf: "000.000.001-91", purpose: "onboarding"}, idempotency_key: "consulta-0001")

IO.inspect({lookup.status, lookup.reasons})

{:ok, _company} =
  Kuaa.Lookups.business(client, %{cnpj: "SA.NDB.OX0/0001-25", purpose: "onboarding"}, idempotency_key: "consulta-0002")

{:ok, _again} = Kuaa.Lookups.get(client, lookup.id)
```

## Erros

Uma recusa da API é um `{:error, %Kuaa.Error{}}`, com `status`, `code` (`validation_failed`, `not_found`, `conflict`, `payment_required`…), `message`, `fields` (as mensagens de cada campo), `retry_after` em segundos (num 429 ou 503) e `request_id`.

## Webhooks

```elixir
{:ok, event} = Kuaa.verify_webhook(System.fetch_env!("KUAA_WEBHOOK_SECRET"), conn.req_headers, raw_body)
IO.puts("#{event.type} #{event.data.case_id}")
```

Cada entrega leva `X-Arandu-Delivery-Id`, `X-Arandu-Timestamp` e `X-Arandu-Signature: sha256=hex(HMAC-SHA256(segredo, timestamp + "." + delivery_id + "." + corpo))`. Durante uma rotação vem uma linha de assinatura por segredo ativo, e basta uma conferir. Um timestamp a mais de 5 minutos do relógio é recusado com `{:error, %Kuaa.WebhookVerificationError{}}`. Passe o corpo cru, antes de interpretar; o evento é um envelope CloudEvents 1.0 e deve ser deduplicado pelo `id`, porque a entrega é pelo menos uma vez.

Versão do SDK: 0.2.0 · contrato da API: 1.0.0
