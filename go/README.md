# KUAA SDK para Go

SDK oficial da API do KUAA para Go 1.23+, só com a biblioteca padrão. É gerado a partir do contrato da API (`openapi.json`, na raiz de [kuaa-io/sdk](https://github.com/kuaa-io/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
go get github.com/kuaa-io/sdk/go
```

```go
import kuaa "github.com/kuaa-io/sdk/go"

client := kuaa.New(os.Getenv("KUAA_API_KEY")) // kuaa_<prefixo>_<segredo> ou kuaa_test_<prefixo>_<segredo>

c, err := client.Cases.Create(ctx, kuaa.CaseRequest{
	ExternalReference: "pedido-0001",
	Kind:              "KYC",
	Parties:           []kuaa.CaseRequestParty{{Kind: "PERSON", Primary: kuaa.Ptr(true), Cpf: kuaa.Ptr("123.456.789-09")}},
}, kuaa.WithIdempotencyKey("pedido-0001"))

run, err := client.Cases.Start(ctx, c.ID, kuaa.WithIdempotencyKey("pedido-0001-start"))

for summary, err := range client.Cases.ListIter(ctx, &kuaa.CasesListParams{Status: "in_review"}) {
	if err != nil {
		return err
	}
	fmt.Println(summary.ID, summary.Status)
}

// Ambiente da chave, como a API respondeu (cabeçalho Kuaa-Livemode).
if last := client.LastResponse(); last != nil && last.Livemode != nil && !*last.Livemode {
	fmt.Println("sandbox")
}
```

A chave decide a organização e o ambiente: `kuaa_test_…` só funciona no sandbox, e a chave sem `test` só em produção. `client.LastResponse()` traz o status, o `Kuaa-Livemode`, o `Kuaa-Environment`, o `Idempotent-Replayed` e o `X-Request-ID` da última resposta.

## Recursos

| Serviço | Métodos |
|---|---|
| `client.Billing` | `Balance`, `Statement`, `StatementIter` |
| `client.CaseCaptureSessions` | `Create`, `List`, `Revoke` |
| `client.CaseChipChallenges` | `Create` |
| `client.CaseChipReads` | `Create` |
| `client.CaseDocuments` | `List` |
| `client.CaseMedia` | `Create` |
| `client.CaseOwnership` | `Create`, `Get` |
| `client.CaseParties` | `Create` |
| `client.CaseTags` | `Create`, `Delete`, `List` |
| `client.Cases` | `Create`, `Decision`, `Dossier`, `Get`, `List`, `ListIter`, `Start`, `Submit`, `Update` |
| `client.Health` | `Get` |
| `client.Lookups` | `Business`, `Get`, `Person` |
| `client.Parties` | `Get`, `List`, `ListIter` |
| `client.Webhooks` | `Create`, `Delete`, `List` |
| `client.Workflows` | `List` |

As listas paginadas respondem uma `*kuaa.Page[T]` (`Items`, `NextCursor`, `HasMore`); o método `…Iter` percorre todas as páginas pelo cursor. As escritas aceitam `kuaa.WithIdempotencyKey`, e toda chamada aceita `kuaa.WithAPIKey` para usar outra chave. O envio de imagens (`client.CaseMedia.Create`) vai como `multipart/form-data`, com cada arquivo num `kuaa.File`.

## Consultas de CPF e CNPJ

Uma consulta lê o cadastro de um CPF ou de um CNPJ fora de qualquer case: o que a Receita Federal guarda (pelo bureau Direct Data), cruzado com as listas do KUAA. A resposta traz `status` (`regular`, `irregular` ou `inconclusive`, a conclusão do KUAA sob `rule_version`), `reasons`, os dados (`person` ou `company`), `provenance` (de onde veio cada campo e quando), `screening`, `sources` e `cost`. `purpose` é obrigatório e fica registrado com a sua base legal na LGPD. Com uma chave `kuaa_test_…`, o sandbox responde dados sintéticos pelos valores mágicos (o CPF `000.000.001-91` e o CNPJ `SA.NDB.OX0/0001-25` respondem `regular`) e nunca consulta o bureau.

```go
lookup, err := client.Lookups.Person(ctx, kuaa.PersonLookupRequest{
	Cpf:     "000.000.001-91",
	Purpose: "onboarding",
}, kuaa.WithIdempotencyKey("consulta-0001"))
if err != nil {
	return err
}
fmt.Println(lookup.Status, lookup.Reasons)
if origin := lookup.Provenance.SituacaoCadastral; origin != nil {
	fmt.Println(origin.Source, origin.RetrievedAt)
}

company, err := client.Lookups.Business(ctx, kuaa.BusinessLookupRequest{Cnpj: "SA.NDB.OX0/0001-25", Purpose: "onboarding"},
	kuaa.WithIdempotencyKey("consulta-0002"))
again, err := client.Lookups.Get(ctx, lookup.ID)
```

## Erros

Uma recusa da API é um `*kuaa.Error` com `StatusCode`, `Code` (`validation_failed`, `not_found`, `conflict`, `payment_required`…), `Message`, `Fields` (as mensagens de cada campo), `RetryAfter` (num 429 ou 503) e `RequestID`.

## Webhooks

```go
event, err := kuaa.VerifyWebhook(os.Getenv("KUAA_WEBHOOK_SECRET"), r.Header, body)
if err != nil {
	http.Error(w, "assinatura inválida", http.StatusBadRequest)
	return
}
fmt.Println(event.Type, event.Data.CaseID, event.Data.Livemode)
```

Cada entrega leva `X-Arandu-Delivery-Id`, `X-Arandu-Timestamp` e `X-Arandu-Signature: sha256=hex(HMAC-SHA256(segredo, timestamp + "." + delivery_id + "." + corpo))`. Durante uma rotação vem uma linha de assinatura por segredo ativo, e basta uma conferir. Um timestamp a mais de 5 minutos do relógio é recusado. Leia o corpo cru e verifique antes de interpretar; o evento é um envelope CloudEvents 1.0 (`kuaa.WebhookEvent`) e deve ser deduplicado pelo `ID`, porque a entrega é pelo menos uma vez.

Versão do SDK: 0.1.0 · contrato da API: 1.0.0
