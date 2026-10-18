# KUAA SDK para Java

SDK oficial da API do KUAA para Java 11+ (e Kotlin), sem dependências: só `java.net.http` e um leitor de JSON próprio. É gerado a partir do contrato da API (`openapi.json`, na raiz de [kuaa-io/sdk](https://github.com/kuaa-io/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```xml
<dependency>
    <groupId>io.kuaa</groupId>
    <artifactId>kuaa-java</artifactId>
    <version>0.1.0</version>
</dependency>
```

```java
import io.kuaa.*;

Kuaa kuaa = new Kuaa(System.getenv("KUAA_API_KEY")); // kuaa_<prefixo>_<segredo> ou kuaa_test_<prefixo>_<segredo>

Case kase = kuaa.cases().create(
        CaseRequest.builder()
                .externalReference("pedido-0001")
                .kind(CaseRequest.KIND_KYC)
                .parties(List.of(CaseRequestParty.builder().kind("PERSON").primary(true).cpf("123.456.789-09").build()))
                .build(),
        RequestOptions.builder().idempotencyKey("pedido-0001").build());
kuaa.cases().start(kase.getId(), RequestOptions.builder().idempotencyKey("pedido-0001-start").build());

for (CaseSummary summary : kuaa.cases().listIter(CasesService.ListParams.builder().status("in_review").build())) {
    System.out.println(summary.getId() + " " + summary.getStatus());
}

System.out.println(kuaa.getLastResponse().getLivemode()); // false no sandbox (cabeçalho Kuaa-Livemode)
```

A chave decide a organização e o ambiente: `kuaa_test_…` só funciona no sandbox, e a chave sem `test` só em produção. `kuaa.getLastResponse()` traz o status, o `Kuaa-Livemode`, o `Kuaa-Environment`, o `Idempotent-Replayed` e o `X-Request-ID` da última resposta.

## Recursos

| Serviço | Métodos |
|---|---|
| `kuaa.billing()` | `balance`, `statement`, `statementIter` |
| `kuaa.caseCaptureSessions()` | `create`, `list`, `revoke` |
| `kuaa.caseDocuments()` | `list` |
| `kuaa.caseMedia()` | `create` |
| `kuaa.caseOwnership()` | `create`, `get` |
| `kuaa.caseParties()` | `create` |
| `kuaa.caseTags()` | `create`, `delete`, `list` |
| `kuaa.cases()` | `create`, `decision`, `dossier`, `get`, `list`, `listIter`, `start`, `submit`, `update` |
| `kuaa.parties()` | `get`, `list`, `listIter` |
| `kuaa.webhooks()` | `create`, `delete`, `list` |
| `kuaa.workflows()` | `list` |

Os objetos respondidos são classes imutáveis com getters (`kase.getExternalReference()`), e os valores enumerados são constantes (`Case.STATUS_APPROVED`). Os corpos das escritas são construídos com `builder()`, e um campo opcional não informado fica fora do JSON. As listas paginadas respondem uma `Page<T>` (`getItems`, `getNextCursor`, `hasMore`), e o `…Iter` devolve um `Iterable` que percorre todas as páginas pelo cursor. O envio de imagens (`kuaa.caseMedia().create`) vai como `multipart/form-data`, com cada arquivo num `FilePart` (ou `FilePart.fromPath`). O cliente pode ser compartilhado entre threads.

## Erros

Uma recusa da API lança `KuaaException`, com `getStatus()`, `getCode()` (`validation_failed`, `not_found`, `conflict`, `payment_required`…), `getApiMessage()`, `getFields()` (as mensagens de cada campo), `getRetryAfter()` em segundos (num 429 ou 503) e `getRequestId()`.

## Webhooks

```java
WebhookEvent event = WebhookSignature.verify(System.getenv("KUAA_WEBHOOK_SECRET"), headers, rawBody);
System.out.println(event.getType() + " " + event.getData().getCaseId());
```

Cada entrega leva `X-Arandu-Delivery-Id`, `X-Arandu-Timestamp` e `X-Arandu-Signature: sha256=hex(HMAC-SHA256(segredo, timestamp + "." + delivery_id + "." + corpo))`. Durante uma rotação vem uma linha de assinatura por segredo ativo, e basta uma conferir. Um timestamp a mais de 5 minutos do relógio é recusado com `WebhookVerificationException`. Passe o corpo cru (`byte[]`) e os cabeçalhos como `Map<String, List<String>>`, antes de interpretar; o evento é um envelope CloudEvents 1.0 e deve ser deduplicado pelo `getId()`, porque a entrega é pelo menos uma vez.

Versão do SDK: 0.1.0 · contrato da API: 1.0.0
