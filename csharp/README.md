# KUAA SDK para .NET

SDK oficial da API do KUAA para C# e .NET 8+ (LTS), sem dependências: `HttpClient`, `System.Text.Json` com serialização gerada em compilação (compatível com trimming e Native AOT) e `HMACSHA256`. É gerado a partir do contrato da API (`openapi.json`, na raiz de [kuaa-io/sdk](https://github.com/kuaa-io/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
dotnet add package KuaaIo.Sdk
```

```csharp
using KuaaIo.Sdk;

var kuaa = new KuaaClient(Environment.GetEnvironmentVariable("KUAA_API_KEY")!); // kuaa_<prefixo>_<segredo> ou kuaa_test_<prefixo>_<segredo>

var kase = await kuaa.Cases.CreateAsync(
    new CaseRequest
    {
        ExternalReference = "pedido-0001",
        Kind = CaseRequest.KindKYC,
        Parties = [new CaseRequestParty { Kind = "PERSON", Primary = true, Cpf = "123.456.789-09" }],
    },
    new RequestOptions { IdempotencyKey = "pedido-0001" });
await kuaa.Cases.StartAsync(kase.Id, new RequestOptions { IdempotencyKey = "pedido-0001-start" });

await foreach (var summary in kuaa.Cases.ListIterAsync(new CasesListParams { Status = "in_review" }))
{
    Console.WriteLine($"{summary.Id} {summary.Status}");
}

Console.WriteLine(kuaa.LastResponse?.Livemode); // False no sandbox (cabeçalho Kuaa-Livemode)
```

A chave decide a organização e o ambiente: `kuaa_test_…` só funciona no sandbox, e a chave sem `test` só em produção. `kuaa.LastResponse` traz o `Status`, o `Livemode`, o `Environment`, o `IdempotentReplayed` e o `RequestId` da última resposta. `new KuaaClient(apiKey, new KuaaClientOptions { BaseUrl = …, Timeout = …, HttpClient = … })` troca o endereço, o tempo de espera (30 s por padrão) ou o HTTP. O cliente pode ser compartilhado entre threads.

## Recursos

| Serviço | Métodos |
|---|---|
| `kuaa.Billing` | `BalanceAsync`, `StatementAsync`, `StatementIterAsync` |
| `kuaa.CaseCaptureSessions` | `CreateAsync`, `ListAsync`, `RevokeAsync` |
| `kuaa.CaseChipChallenges` | `CreateAsync` |
| `kuaa.CaseChipReads` | `CreateAsync` |
| `kuaa.CaseDocuments` | `ListAsync` |
| `kuaa.CaseMedia` | `CreateAsync` |
| `kuaa.CaseOwnership` | `CreateAsync`, `GetAsync` |
| `kuaa.CaseParties` | `CreateAsync` |
| `kuaa.CaseTags` | `CreateAsync`, `DeleteAsync`, `ListAsync` |
| `kuaa.Cases` | `CreateAsync`, `DecisionAsync`, `DossierAsync`, `GetAsync`, `ListAsync`, `ListIterAsync`, `StartAsync`, `SubmitAsync`, `UpdateAsync` |
| `kuaa.Health` | `GetAsync` |
| `kuaa.Lookups` | `BusinessAsync`, `GetAsync`, `PersonAsync` |
| `kuaa.Parties` | `GetAsync`, `ListAsync`, `ListIterAsync` |
| `kuaa.Webhooks` | `CreateAsync`, `DeleteAsync`, `ListAsync` |
| `kuaa.Workflows` | `ListAsync` |

Os objetos respondidos são `record`s imutáveis em PascalCase (`kase.ExternalReference`), com os valores enumerados como constantes (`Case.StatusApproved`). O corpo de cada escrita é um `record` com membros `required` (`CaseRequest`); um campo opcional nulo fica fora da requisição. As listas aceitam `…ListParams` (`Limit`, `Cursor` e os filtros), respondem uma `Page<T>` (`Items`, `NextCursor`, `HasMore`), e o `…IterAsync` devolve um `IAsyncEnumerable` que percorre todas as páginas pelo cursor. O envio de imagens (`kuaa.CaseMedia.CreateAsync`) vai como `multipart/form-data`, com cada arquivo num `FilePart` (ou `FilePart.FromPath`). Todo método aceita, por último, `RequestOptions` (`IdempotencyKey` nas escritas, `ApiKey` para usar outra chave numa chamada) e um `CancellationToken`.

## Consultas de CPF e CNPJ

Uma consulta lê o cadastro de um CPF ou de um CNPJ fora de qualquer case: o que a Receita Federal guarda (pelo bureau Direct Data), cruzado com as listas do KUAA. A resposta traz `status` (`regular`, `irregular` ou `inconclusive`, a conclusão do KUAA sob `rule_version`), `reasons`, os dados (`person` ou `company`), `provenance` (de onde veio cada campo e quando), `screening`, `sources` e `cost`. `purpose` é obrigatório e fica registrado com a sua base legal na LGPD. Com uma chave `kuaa_test_…`, o sandbox responde dados sintéticos pelos valores mágicos (o CPF `000.000.001-91` e o CNPJ `SA.NDB.OX0/0001-25` respondem `regular`) e nunca consulta o bureau.

```csharp
var lookup = await kuaa.Lookups.PersonAsync(
    new PersonLookupRequest { Cpf = "000.000.001-91", Purpose = PersonLookupRequest.PurposeOnboarding },
    new RequestOptions { IdempotencyKey = "consulta-0001" });
Console.WriteLine($"{lookup.Status} {string.Join(",", lookup.Reasons)} {lookup.Provenance.SituacaoCadastral?.Source}");

var company = await kuaa.Lookups.BusinessAsync(
    new BusinessLookupRequest { Cnpj = "SA.NDB.OX0/0001-25", Purpose = BusinessLookupRequest.PurposeOnboarding },
    new RequestOptions { IdempotencyKey = "consulta-0002" });
var again = await kuaa.Lookups.GetAsync(lookup.Id);
```

## Erros

Uma recusa da API lança `KuaaException`, com `Status`, `Code` (`validation_failed`, `not_found`, `conflict`, `payment_required`…), `ApiMessage`, `Fields` (as mensagens de cada campo), `RetryAfter` em segundos (num 429 ou 503) e `RequestId`. Uma falha de rede lança `HttpRequestException`; o tempo esgotado, `TimeoutException`.

## Webhooks

```csharp
using var reader = new StreamReader(Request.Body);
var body = await reader.ReadToEndAsync();
var webhook = WebhookSignature.Verify(Environment.GetEnvironmentVariable("KUAA_WEBHOOK_SECRET")!, Request.Headers, body);
Console.WriteLine($"{webhook.Type} {webhook.Data.CaseId}");
```

Cada entrega leva `X-Arandu-Delivery-Id`, `X-Arandu-Timestamp` e `X-Arandu-Signature: sha256=hex(HMAC-SHA256(segredo, timestamp + "." + delivery_id + "." + corpo))`. Durante uma rotação vem uma linha de assinatura por segredo ativo, e basta uma conferir. Um timestamp a mais de 5 minutos do relógio é recusado com `WebhookVerificationException`. Passe o corpo cru, antes de interpretar; os cabeçalhos podem ser os do ASP.NET, de um `HttpHeaders` ou um dicionário. O evento é um envelope CloudEvents 1.0 e deve ser deduplicado pelo `Id`, porque a entrega é pelo menos uma vez.

Versão do SDK: 0.1.0 · contrato da API: 1.0.0
