package generator

import (
	"encoding/json"
	"testing"
)

// The contract kuaa.io serves reads into services and models: every /v1
// operation the API key reaches, the cursor lists paginated over the model
// they list, the inline objects named once each, and the envelopes unwrapped.
func TestTheContractReadsIntoTheIR(t *testing.T) {
	ir, err := Load("../openapi.json", "0.1.0")
	if err != nil {
		t.Fatal(err)
	}
	services := map[string]map[string]*Method{}
	count := 0
	for _, service := range ir.Services {
		services[service.Name] = map[string]*Method{}
		for _, method := range service.Methods {
			services[service.Name][method.Name] = method
			count++
		}
	}
	if count != 27 {
		t.Errorf("%d operations, the contract has 27", count)
	}
	list := services["cases"]["list"]
	if list == nil || !list.Paginated || list.Item != "CaseSummary" || list.ItemField != "cases" || list.Path != "/v1/cases" {
		t.Fatalf("cases.list = %+v", list)
	}
	for _, param := range list.Query {
		if param.Name == "cursor" || param.Name == "limit" {
			t.Fatalf("cases.list keeps %s among its filters", param.Name)
		}
	}
	if statement := services["billing"]["statement"]; !statement.Paginated || statement.Item != "StatementEntry" {
		t.Fatalf("billing.statement = %+v", statement)
	}
	create := services["cases"]["create"]
	if create == nil || create.Body == nil || create.Body.Name != "CaseRequest" || !create.Write || create.Response != "Case" {
		t.Fatalf("cases.create = %+v", create)
	}
	if start := services["cases"]["start"]; start.Body != nil || !start.Write || start.Response != "Run" {
		t.Fatalf("cases.start = %+v", start)
	}
	media := services["case_media"]["create"]
	if media == nil || !media.Multipart || media.Body.Name != "CaptureForm" || !media.Body.Multipart {
		t.Fatalf("case_media.create = %+v", media)
	}
	if revoke := services["case_capture_sessions"]["revoke"]; len(revoke.PathParams) != 2 || revoke.PathParams[1] != "session" {
		t.Fatalf("case_capture_sessions.revoke = %+v", revoke)
	}
	if untag := services["case_tags"]["delete"]; len(untag.Query) != 1 || untag.Query[0].Type.Kind != "array" || untag.Write {
		t.Fatalf("case_tags.delete = %+v", untag)
	}
	if decision := services["cases"]["decision"]; decision.Response != "CaseDecision" {
		t.Fatalf("cases.decision answers %s", decision.Response)
	}
	models := map[string]*Model{}
	for _, model := range ir.Models {
		if models[model.Name] != nil {
			t.Fatalf("model %s twice", model.Name)
		}
		models[model.Name] = model
	}
	for _, name := range []string{"Case", "Party", "Relationship", "Run", "Dossier", "Decision", "Document", "Webhook",
		"WebhookEvent", "WebhookEventData", "Workflow", "WorkflowVersion", "BeneficialOwner", "StatementEntry", "Balance"} {
		if models[name] == nil {
			t.Fatalf("model %s missing", name)
		}
	}
	for name := range models {
		if name == "Problem" || len(name) > 8 && name[len(name)-8:] == "Response" {
			t.Fatalf("%s became a model", name)
		}
	}
	// The decision the case answers and the one the dossier lists are the
	// same shape, written out twice in the contract: one model.
	for _, field := range models["CaseDecision"].Fields {
		if field.Wire == "decision" && (field.Type.Model != "Decision" || !field.Nullable) {
			t.Fatalf("CaseDecision.decision = %+v", field.Type)
		}
	}
	if Pascal("capture_sessions") != "CaptureSessions" || Camel("capture_sessions") != "captureSessions" || Pascal("case_id") != "CaseID" ||
		Camel("url") != "url" || Camel("return_url") != "returnURL" || singular("parties") != "party" || singular("cases") != "case" {
		t.Fatal("naming")
	}
}

// The webhook vectors are the same bytes on every run, and each valid one
// carries the signature Sign writes.
func TestTheWebhookVectorsAreStable(t *testing.T) {
	first, err := WebhookVectors()
	if err != nil {
		t.Fatal(err)
	}
	second, _ := WebhookVectors()
	if string(first) != string(second) {
		t.Fatal("the vectors change between runs")
	}
	var vectors Vectors
	if err := json.Unmarshal(first, &vectors); err != nil {
		t.Fatal(err)
	}
	valid := 0
	for _, v := range vectors.Vectors {
		if v.Valid {
			valid++
			if v.Event == nil {
				t.Errorf("%s verifies but says no event", v.Name)
			}
		}
	}
	if valid == 0 || valid == len(vectors.Vectors) {
		t.Fatalf("%d of %d vectors verify", valid, len(vectors.Vectors))
	}
	// Computed apart, with Python's hmac: HMAC-SHA256("secret", "1.d.{}").
	if got := Sign("secret", "1", "d", []byte("{}")); got != "sha256=f80f036d2cba9f751d598385972fbb41a3301950e4aaa2b96d9ed3b444c183da" {
		t.Fatalf("Sign = %s", got)
	}
}
