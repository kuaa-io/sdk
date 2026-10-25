# KUAA SDK para PHP

SDK oficial da API do KUAA para PHP 8.1+, só com as extensões `curl` e `json`. É gerado a partir do contrato da API (`openapi.json`, na raiz de [kuaa-io/sdk](https://github.com/kuaa-io/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
composer require kuaa-io/sdk
```

```php
$kuaa = new Kuaa\Kuaa(getenv('KUAA_API_KEY')); // kuaa_<prefixo>_<segredo> ou kuaa_test_<prefixo>_<segredo>

$case = $kuaa->cases->create([
    'external_reference' => 'pedido-0001',
    'kind' => 'KYC',
    'parties' => [['kind' => 'PERSON', 'primary' => true, 'cpf' => '123.456.789-09']],
], idempotencyKey: 'pedido-0001');
$kuaa->cases->start($case->id, idempotencyKey: 'pedido-0001-start');

foreach ($kuaa->cases->listIter(['status' => 'in_review']) as $summary) {
    echo $summary->id, ' ', $summary->status, PHP_EOL;
}

var_dump($kuaa->lastResponse?->livemode); // false no sandbox (cabeçalho Kuaa-Livemode)
```

A chave decide a organização e o ambiente: `kuaa_test_…` só funciona no sandbox, e a chave sem `test` só em produção. `$kuaa->lastResponse` traz o `status`, o `livemode`, o `environment`, o `idempotentReplayed` e o `requestId` da última resposta.

## Recursos

| Serviço | Métodos |
|---|---|
| `$kuaa->billing` | `balance`, `statement`, `statementIter` |
| `$kuaa->caseCaptureSessions` | `create`, `list`, `revoke` |
| `$kuaa->caseChipChallenges` | `create` |
| `$kuaa->caseChipReads` | `create` |
| `$kuaa->caseDocuments` | `list` |
| `$kuaa->caseMedia` | `create` |
| `$kuaa->caseOwnership` | `create`, `get` |
| `$kuaa->caseParties` | `create` |
| `$kuaa->caseTags` | `create`, `delete`, `list` |
| `$kuaa->cases` | `create`, `decision`, `dossier`, `get`, `list`, `listIter`, `start`, `submit`, `update` |
| `$kuaa->health` | `get` |
| `$kuaa->lookups` | `business`, `get`, `person` |
| `$kuaa->parties` | `get`, `list`, `listIter` |
| `$kuaa->webhooks` | `create`, `delete`, `list` |
| `$kuaa->workflows` | `list` |

Os objetos respondidos são classes com propriedades `readonly` em camelCase (`$case->externalReference`); o case é `Kuaa\Models\CaseModel`, porque `case` é palavra reservada do PHP. Os corpos das escritas são arrays com os nomes da API (`['external_reference' => …]`), descritos para o PHPStan. As listas paginadas respondem uma `Kuaa\Page` (`items`, `nextCursor`, `hasMore`), e o `…Iter` percorre todas as páginas pelo cursor. O envio de imagens (`$kuaa->caseMedia->create`) vai como `multipart/form-data`, com cada arquivo num `Kuaa\File` (ou `Kuaa\File::fromPath`).

## Consultas de CPF e CNPJ

Uma consulta lê o cadastro de um CPF ou de um CNPJ fora de qualquer case: o que a Receita Federal guarda (pelo bureau Direct Data), cruzado com as listas do KUAA. A resposta traz `status` (`regular`, `irregular` ou `inconclusive`, a conclusão do KUAA sob `rule_version`), `reasons`, os dados (`person` ou `company`), `provenance` (de onde veio cada campo e quando), `screening`, `sources` e `cost`. `purpose` é obrigatório e fica registrado com a sua base legal na LGPD. Com uma chave `kuaa_test_…`, o sandbox responde dados sintéticos pelos valores mágicos (o CPF `000.000.001-91` e o CNPJ `SA.NDB.OX0/0001-25` respondem `regular`) e nunca consulta o bureau.

```php
$lookup = $kuaa->lookups->person(['cpf' => '000.000.001-91', 'purpose' => 'onboarding'], idempotencyKey: 'consulta-0001');
echo $lookup->status, ' ', implode(',', $lookup->reasons), PHP_EOL;
echo $lookup->provenance->situacaoCadastral?->source, PHP_EOL;

$company = $kuaa->lookups->business(['cnpj' => 'SA.NDB.OX0/0001-25', 'purpose' => 'onboarding'], idempotencyKey: 'consulta-0002');
$again = $kuaa->lookups->get($lookup->id);
```

## Erros

Uma recusa da API lança `Kuaa\KuaaException`, com `status`, `errorCode` (`validation_failed`, `not_found`, `conflict`, `payment_required`…), `fields` (as mensagens de cada campo), `retryAfter` em segundos (num 429 ou 503) e `requestId`.

## Webhooks

```php
$event = Kuaa\Webhook::verify(getenv('KUAA_WEBHOOK_SECRET'), getallheaders(), file_get_contents('php://input'));
echo $event->type, ' ', $event->data->caseId;
```

Cada entrega leva `X-Arandu-Delivery-Id`, `X-Arandu-Timestamp` e `X-Arandu-Signature: sha256=hex(HMAC-SHA256(segredo, timestamp + "." + delivery_id + "." + corpo))`. Durante uma rotação vem uma linha de assinatura por segredo ativo, e basta uma conferir. Um timestamp a mais de 5 minutos do relógio é recusado com `Kuaa\WebhookVerificationException`. Passe o corpo cru, antes de interpretar; o evento é um envelope CloudEvents 1.0 e deve ser deduplicado pelo `id`, porque a entrega é pelo menos uma vez.

Versão do SDK: 0.1.0 · contrato da API: 1.0.0
