# KUAA SDK para Python

SDK oficial da API do KUAA para Python 3.11+, sem dependências. É gerado a partir do contrato da API (`openapi.json`, na raiz de [kuaa-io/sdk](https://github.com/kuaa-io/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
pip install kuaa-io-sdk
```

```python
import os
from kuaa import Kuaa

kuaa = Kuaa(os.environ["KUAA_API_KEY"])  # kuaa_<prefixo>_<segredo> ou kuaa_test_<prefixo>_<segredo>

case = kuaa.cases.create(
    {"external_reference": "pedido-0001", "kind": "KYC", "parties": [{"kind": "PERSON", "primary": True, "cpf": "123.456.789-09"}]},
    idempotency_key="pedido-0001",
)
kuaa.cases.start(case.id, idempotency_key="pedido-0001-start")

for summary in kuaa.cases.list_iter(status="in_review"):
    print(summary.id, summary.status)

print(kuaa.last_response.livemode)  # False no sandbox (cabeçalho Kuaa-Livemode)
```

A chave decide a organização e o ambiente: `kuaa_test_…` só funciona no sandbox, e a chave sem `test` só em produção. `kuaa.last_response` traz o `status`, o `livemode`, o `environment`, o `idempotent_replayed` e o `request_id` da última resposta.

## Recursos

| Serviço | Métodos |
|---|---|
| `kuaa.billing` | `balance`, `statement`, `statement_iter` |
| `kuaa.case_capture_sessions` | `create`, `list`, `revoke` |
| `kuaa.case_chip_challenges` | `create` |
| `kuaa.case_chip_reads` | `create` |
| `kuaa.case_documents` | `list` |
| `kuaa.case_media` | `create` |
| `kuaa.case_ownership` | `create`, `get` |
| `kuaa.case_parties` | `create` |
| `kuaa.case_tags` | `create`, `delete`, `list` |
| `kuaa.cases` | `create`, `decision`, `dossier`, `get`, `list`, `list_iter`, `start`, `submit`, `update` |
| `kuaa.health` | `get` |
| `kuaa.lookups` | `business`, `get`, `person` |
| `kuaa.parties` | `get`, `list`, `list_iter` |
| `kuaa.webhooks` | `create`, `delete`, `list` |
| `kuaa.workflows` | `list` |

Os objetos respondidos são dataclasses imutáveis; os corpos das escritas são dicionários (`TypedDict`) com os nomes da API. As escritas aceitam `idempotency_key=`, e todas aceitam `api_key=` para usar outra chave numa chamada. As listas paginadas respondem uma `Page` (`items`, `next_cursor`, `has_more`), e o `…_iter` percorre todas as páginas pelo cursor. O envio de imagens (`kuaa.case_media.create`) vai como `multipart/form-data`, com cada arquivo num `KuaaFile(filename, data, content_type)`.

## Consultas de CPF e CNPJ

Uma consulta lê o cadastro de um CPF ou de um CNPJ fora de qualquer case: o que a Receita Federal guarda (pelo bureau Direct Data), cruzado com as listas do KUAA. A resposta traz `status` (`regular`, `irregular` ou `inconclusive`, a conclusão do KUAA sob `rule_version`), `reasons`, os dados (`person` ou `company`), `provenance` (de onde veio cada campo e quando), `screening`, `sources` e `cost`. `purpose` é obrigatório e fica registrado com a sua base legal na LGPD. Com uma chave `kuaa_test_…`, o sandbox responde dados sintéticos pelos valores mágicos (o CPF `000.000.001-91` e o CNPJ `SA.NDB.OX0/0001-25` respondem `regular`) e nunca consulta o bureau.

```python
lookup = kuaa.lookups.person({"cpf": "000.000.001-91", "purpose": "onboarding"}, idempotency_key="consulta-0001")
print(lookup.status, lookup.reasons)
if lookup.provenance.situacao_cadastral is not None:
    print(lookup.provenance.situacao_cadastral.source)

company = kuaa.lookups.business({"cnpj": "SA.NDB.OX0/0001-25", "purpose": "onboarding"}, idempotency_key="consulta-0002")
again = kuaa.lookups.get(lookup.id)
```

## Erros

Uma recusa da API levanta `KuaaError`, com `status`, `code` (`validation_failed`, `not_found`, `conflict`, `payment_required`…), `message`, `fields` (as mensagens de cada campo), `retry_after` em segundos (num 429 ou 503) e `request_id`.

## Webhooks

```python
from kuaa import verify_webhook

event = verify_webhook(os.environ["KUAA_WEBHOOK_SECRET"], request.headers, request.get_data())
print(event.type, event.data.case_id, event.data.livemode)
```

Cada entrega leva `X-Arandu-Delivery-Id`, `X-Arandu-Timestamp` e `X-Arandu-Signature: sha256=hex(HMAC-SHA256(segredo, timestamp + "." + delivery_id + "." + corpo))`. Durante uma rotação vem uma linha de assinatura por segredo ativo, e basta uma conferir. Um timestamp a mais de 5 minutos do relógio é recusado com `WebhookVerificationError`. Passe o corpo cru, antes de interpretar; o evento é um envelope CloudEvents 1.0 e deve ser deduplicado pelo `id`, porque a entrega é pelo menos uma vez.

Versão do SDK: 0.1.0 · contrato da API: 1.0.0
