package generator

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strconv"
)

// The webhook scheme kuaa.io signs with (hesape/webhook's Arandu dialect, as
// 60-contracts/CT-webhooks.md describes it): three headers, and the
// signature sha256=hex(HMAC-SHA256(secret, timestamp + "." + delivery_id +
// "." + raw_body)), keyed with the endpoint's secret exactly as it was shown.
// During a rotation the header comes once per secret still signing; a reader
// may join the lines with commas. Every SDK verifies the same way, and these
// vectors are what each one's tests check it against.
const (
	HeaderDeliveryID = "X-Arandu-Delivery-Id"
	HeaderTimestamp  = "X-Arandu-Timestamp"
	HeaderSignature  = "X-Arandu-Signature"
	// WebhookToleranceSeconds is how far from the receiver's clock a
	// timestamp may be, either way, before the delivery is refused.
	WebhookToleranceSeconds = 300
	// MaxWebhookSignatures is how many signatures a delivery may carry: the
	// current secret and the five previous ones a sender keeps.
	MaxWebhookSignatures = 6
)

// Vector is one delivery and what verifying it must answer.
type Vector struct {
	Name string `json:"name"`
	// Secret is the receiver's secret.
	Secret string `json:"secret"`
	// Now is the receiver's clock, in Unix seconds.
	Now int64 `json:"now"`
	// Headers are the request's headers, each with every line it came
	// with, under the names as given (a receiver looks them up in any case).
	Headers map[string][]string `json:"headers"`
	// Body is the raw body, as UTF-8 text.
	Body string `json:"body"`
	// Valid says the delivery verifies; when it does, Event is what the
	// parsed envelope must hold.
	Valid bool         `json:"valid"`
	Event *VectorEvent `json:"event,omitempty"`
}

// VectorEvent is the part of a parsed event a test compares.
type VectorEvent struct {
	ID          string `json:"id"`
	Type        string `json:"type"`
	Source      string `json:"source"`
	Subject     string `json:"subject"`
	CaseID      string `json:"case_id"`
	Status      string `json:"status"`
	Environment string `json:"environment"`
	Livemode    bool   `json:"livemode"`
}

// Vectors are the webhook test vectors.
type Vectors struct {
	ToleranceSeconds int      `json:"tolerance_seconds"`
	Vectors          []Vector `json:"vectors"`
}

// Sign is the value of one X-Arandu-Signature line.
func Sign(secret, timestamp, deliveryID string, body []byte) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(timestamp + "." + deliveryID + "."))
	mac.Write(body)
	return "sha256=" + hex.EncodeToString(mac.Sum(nil))
}

// WebhookVectors writes the vectors, deterministically: the same bytes on
// every run.
func WebhookVectors() ([]byte, error) {
	const (
		secret   = "whsec_kuaa_test_vector_secret_0123456789abcdef"
		previous = "whsec_kuaa_test_vector_previous_0123456789abcd"
		other    = "whsec_kuaa_test_vector_another_0123456789abcde"
		now      = int64(1_800_000_000)
		delivery = "0199f2a4-7c1e-7b10-9a51-delivery0001"
	)
	stamp := strconv.FormatInt(now, 10)
	live := `{"specversion":"1.0","type":"case.updated","source":"urn:kuaa:tenant:org_01J9ZC3ABCD","id":"evt_01J9ZC3EVT1",` +
		`"time":"2027-01-15T08:00:00Z","subject":"cases/case_01J9ZC3CASE","datacontenttype":"application/json",` +
		`"data":{"event_id":"evt_01J9ZC3EVT1","type":"case.updated","occurred_at":"2027-01-15T08:00:00Z",` +
		`"tenant_id":"org_01J9ZC3ABCD","case_id":"case_01J9ZC3CASE","status":"approved","status_market":"APPROVED",` +
		`"environment":"live","livemode":true}}`
	liveEvent := &VectorEvent{ID: "evt_01J9ZC3EVT1", Type: "case.updated", Source: "urn:kuaa:tenant:org_01J9ZC3ABCD",
		Subject: "cases/case_01J9ZC3CASE", CaseID: "case_01J9ZC3CASE", Status: "approved", Environment: "live", Livemode: true}
	// A sandbox event, with a field this SDK version does not know and text
	// outside ASCII, so the signature is over the raw UTF-8 bytes and the
	// parse ignores what it does not know.
	sandbox := `{"specversion":"1.0","type":"document.decided","source":"urn:kuaa:tenant:org_01J9ZC3SBX0",` +
		`"id":"evt_01J9ZC3EVT2","time":"2027-01-15T08:01:00Z","subject":"cases/case_01J9ZC3CAS2",` +
		`"datacontenttype":"application/json","data":{"event_id":"evt_01J9ZC3EVT2","type":"document.decided",` +
		`"occurred_at":"2027-01-15T08:01:00Z","tenant_id":"org_01J9ZC3SBX0","case_id":"case_01J9ZC3CAS2",` +
		`"status":"rerequested","decision":"rerequested","document_decision_id":"dd_01","document_id":"doc_01",` +
		`"document_type":"CNH","document_side":"front","requirement":"identity_document","environment":"sandbox",` +
		`"livemode":false,"future_field":"verificação"}}`
	sandboxEvent := &VectorEvent{ID: "evt_01J9ZC3EVT2", Type: "document.decided", Source: "urn:kuaa:tenant:org_01J9ZC3SBX0",
		Subject: "cases/case_01J9ZC3CAS2", CaseID: "case_01J9ZC3CAS2", Status: "rerequested", Environment: "sandbox", Livemode: false}

	headers := func(timestamp string, signatures ...string) map[string][]string {
		return map[string][]string{HeaderDeliveryID: {delivery}, HeaderTimestamp: {timestamp}, HeaderSignature: signatures}
	}
	at := func(seconds int64) string { return strconv.FormatInt(seconds, 10) }
	good := Sign(secret, stamp, delivery, []byte(live))
	old := Sign(previous, stamp, delivery, []byte(live))
	vectors := []Vector{
		{Name: "signed with the current secret", Secret: secret, Now: now, Headers: headers(stamp, good), Body: live, Valid: true, Event: liveEvent},
		{Name: "a rotation: one line per secret, the current one second", Secret: secret, Now: now, Headers: headers(stamp, old, good), Body: live, Valid: true, Event: liveEvent},
		{Name: "a rotation: the lines joined with a comma", Secret: secret, Now: now, Headers: headers(stamp, old+", "+good), Body: live, Valid: true, Event: liveEvent},
		{Name: "a receiver that still holds the previous secret", Secret: previous, Now: now, Headers: headers(stamp, old, good), Body: live, Valid: true, Event: liveEvent},
		{Name: "header names in lower case", Secret: secret, Now: now, Body: live, Valid: true, Event: liveEvent,
			Headers: map[string][]string{"x-arandu-delivery-id": {delivery}, "x-arandu-timestamp": {stamp}, "x-arandu-signature": {good}}},
		{Name: "a sandbox event with a field this SDK does not know", Secret: secret, Now: now, Body: sandbox, Valid: true, Event: sandboxEvent,
			Headers: headers(stamp, Sign(secret, stamp, delivery, []byte(sandbox)))},
		{Name: "signed 300 seconds ago, the edge of the tolerance", Secret: secret, Now: now + 300, Body: live, Valid: true, Event: liveEvent,
			Headers: headers(stamp, good)},
		{Name: "signed 301 seconds ago", Secret: secret, Now: now + 301, Headers: headers(stamp, good), Body: live},
		{Name: "signed 301 seconds in the future", Secret: secret, Now: now - 301, Headers: headers(stamp, good), Body: live},
		{Name: "the body changed by one byte", Secret: secret, Now: now, Headers: headers(stamp, good), Body: live + " "},
		{Name: "another delivery id", Secret: secret, Now: now, Body: live,
			Headers: map[string][]string{HeaderDeliveryID: {delivery + "x"}, HeaderTimestamp: {stamp}, HeaderSignature: {good}}},
		{Name: "a timestamp that was not the one signed", Secret: secret, Now: now, Headers: headers(at(now-1), good), Body: live},
		{Name: "signed with another secret", Secret: secret, Now: now, Headers: headers(stamp, Sign(other, stamp, delivery, []byte(live))), Body: live},
		{Name: "the signature in upper-case hex", Secret: secret, Now: now, Headers: headers(stamp, "sha256="+upper(good[len("sha256="):])), Body: live, Valid: true, Event: liveEvent},
		{Name: "the signature without its sha256= prefix", Secret: secret, Now: now, Headers: headers(stamp, good[len("sha256="):]), Body: live},
		{Name: "a malformed line beside a valid one", Secret: secret, Now: now, Headers: headers(stamp, "sha256=zz", good), Body: live},
		{Name: "more signatures than a sender writes", Secret: secret, Now: now, Body: live,
			Headers: headers(stamp, old, old, old, old, old, old, good)},
		{Name: "no signature", Secret: secret, Now: now, Body: live,
			Headers: map[string][]string{HeaderDeliveryID: {delivery}, HeaderTimestamp: {stamp}}},
		{Name: "no delivery id", Secret: secret, Now: now, Body: live,
			Headers: map[string][]string{HeaderTimestamp: {stamp}, HeaderSignature: {Sign(secret, stamp, "", []byte(live))}}},
		{Name: "a timestamp that is not a number", Secret: secret, Now: now, Body: live,
			Headers: headers("1800000000.0", Sign(secret, "1800000000.0", delivery, []byte(live)))},
	}
	var out bytes.Buffer
	encoder := json.NewEncoder(&out)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(Vectors{ToleranceSeconds: WebhookToleranceSeconds, Vectors: vectors}); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

func upper(hexText string) string {
	return string(bytes.ToUpper([]byte(hexText)))
}
