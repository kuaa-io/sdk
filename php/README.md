# KUAA SDK para PHP

SDK oficial da API do KUAA para PHP 8.1+, só com as extensões `curl` e `json`. É gerado a partir do contrato da API (`openapi.json`, na raiz de [kuaa-io/sdk](https://github.com/kuaa-io/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
composer require kuaa-io/kuaa-php
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
| `$kuaa->caseDocuments` | `list` |
| `$kuaa->caseMedia` | `create` |
| `$kuaa->caseOwnership` | `create`, `get` |
| `$kuaa->caseParties` | `create` |
| `$kuaa->caseTags` | `create`, `delete`, `list` |
| `$kuaa->cases` | `create`, `decision`, `dossier`, `get`, `list`, `listIter`, `start`, `submit`, `update` |
| `$kuaa->parties` | `get`, `list`, `listIter` |
| `$kuaa->webhooks` | `create`, `delete`, `list` |
| `$kuaa->workflows` | `list` |

Os objetos respondidos são classes com propriedades `readonly` em camelCase (`$case->externalReference`); o case é `Kuaa\Models\CaseModel`, porque `case` é palavra reservada do PHP. Os corpos das escritas são arrays com os nomes da API (`['external_reference' => …]`), descritos para o PHPStan. As listas paginadas respondem uma `Kuaa\Page` (`items`, `nextCursor`, `hasMore`), e o `…Iter` percorre todas as páginas pelo cursor. O envio de imagens (`$kuaa->caseMedia->create`) vai como `multipart/form-data`, com cada arquivo num `Kuaa\File` (ou `Kuaa\File::fromPath`).

## Erros

Uma recusa da API lança `Kuaa\KuaaException`, com `status`, `errorCode` (`validation_failed`, `not_found`, `conflict`, `payment_required`…), `fields` (as mensagens de cada campo), `retryAfter` em segundos (num 429 ou 503) e `requestId`.

## Webhooks

```php
$event = Kuaa\Webhook::verify(getenv('KUAA_WEBHOOK_SECRET'), getallheaders(), file_get_contents('php://input'));
echo $event->type, ' ', $event->data->caseId;
```

Cada entrega leva `X-Arandu-Delivery-Id`, `X-Arandu-Timestamp` e `X-Arandu-Signature: sha256=hex(HMAC-SHA256(segredo, timestamp + "." + delivery_id + "." + corpo))`. Durante uma rotação vem uma linha de assinatura por segredo ativo, e basta uma conferir. Um timestamp a mais de 5 minutos do relógio é recusado com `Kuaa\WebhookVerificationException`. Passe o corpo cru, antes de interpretar; o evento é um envelope CloudEvents 1.0 e deve ser deduplicado pelo `id`, porque a entrega é pelo menos uma vez.

Versão do SDK: 0.1.0 · contrato da API: 1.0.0
