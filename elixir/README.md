# KUAA SDK para Elixir

SDK oficial da API do KUAA para Elixir 1.18+, sem dependências: só `:httpc`, `:crypto` e o módulo `JSON`. É gerado a partir do contrato da API (`openapi.json`, na raiz de [kuaa-io/sdk](https://github.com/kuaa-io/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```elixir
# mix.exs
{:kuaa, "~> 0.1.0"}
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
| `Kuaa.CaseDocuments` | `list` |
| `Kuaa.CaseMedia` | `create` |
| `Kuaa.CaseOwnership` | `create`, `get` |
| `Kuaa.CaseParties` | `create` |
| `Kuaa.CaseTags` | `create`, `delete`, `list` |
| `Kuaa.Cases` | `create`, `decision`, `dossier`, `get`, `list`, `list_stream`, `start`, `submit`, `update` |
| `Kuaa.Parties` | `get`, `list`, `list_stream` |
| `Kuaa.Webhooks` | `create`, `delete`, `list` |
| `Kuaa.Workflows` | `list` |

Cada função recebe o cliente primeiro e devolve `{:ok, valor}` ou `{:error, %Kuaa.Error{}}`. Os objetos respondidos são structs com os nomes da API (`kase.external_reference`). O corpo de uma escrita é a struct de parâmetros do método (`%Kuaa.CaseRequest{…}`), uma keyword list ou um mapa com chaves atom; um campo opcional não informado fica fora do JSON. As listas paginadas respondem um `%Kuaa.Page{items, next_cursor, has_more}`, e as funções `_stream` devolvem um `Stream` preguiçoso que percorre todas as páginas pelo cursor e levanta `Kuaa.Error` numa recusa. O envio de imagens (`Kuaa.CaseMedia.create`) vai como `multipart/form-data`, com cada arquivo num `%Kuaa.FilePart{}` (ou `Kuaa.FilePart.from_path/2`).

As escritas aceitam `idempotency_key:`, e todas aceitam `api_key:` para usar outra chave numa chamada. `Kuaa.new/2` aceita `base_url:`, `timeout:` (30 segundos, em milissegundos) e `transport:`.

## Erros

Uma recusa da API é um `{:error, %Kuaa.Error{}}`, com `status`, `code` (`validation_failed`, `not_found`, `conflict`, `payment_required`…), `message`, `fields` (as mensagens de cada campo), `retry_after` em segundos (num 429 ou 503) e `request_id`.

## Webhooks

```elixir
{:ok, event} = Kuaa.verify_webhook(System.fetch_env!("KUAA_WEBHOOK_SECRET"), conn.req_headers, raw_body)
IO.puts("#{event.type} #{event.data.case_id}")
```

Cada entrega leva `X-Arandu-Delivery-Id`, `X-Arandu-Timestamp` e `X-Arandu-Signature: sha256=hex(HMAC-SHA256(segredo, timestamp + "." + delivery_id + "." + corpo))`. Durante uma rotação vem uma linha de assinatura por segredo ativo, e basta uma conferir. Um timestamp a mais de 5 minutos do relógio é recusado com `{:error, %Kuaa.WebhookVerificationError{}}`. Passe o corpo cru, antes de interpretar; o evento é um envelope CloudEvents 1.0 e deve ser deduplicado pelo `id`, porque a entrega é pelo menos uma vez.

Versão do SDK: 0.1.0 · contrato da API: 1.0.0
