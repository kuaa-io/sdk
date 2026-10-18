package kuaa

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// The headers KUAA signs every webhook delivery with.
const (
	WebhookHeaderDeliveryID = "X-Arandu-Delivery-Id"
	WebhookHeaderTimestamp  = "X-Arandu-Timestamp"
	WebhookHeaderSignature  = "X-Arandu-Signature"
)

// WebhookTolerance is how far from now a delivery's timestamp may be, either
// way.
const WebhookTolerance = 5 * time.Minute

// maxWebhookSignatures is how many signatures a delivery may carry: one per
// secret still signing, the current one and at most five previous ones.
const maxWebhookSignatures = 6

// ErrWebhookSignature is a delivery KUAA did not sign with the secret, or
// signed too long ago.
var ErrWebhookSignature = errors.New("kuaa: webhook signature does not verify")

// VerifyWebhook checks a delivery KUAA sent and answers its event, a
// CloudEvents 1.0 envelope. The signature is
// sha256=hex(HMAC-SHA256(secret, timestamp + "." + delivery_id + "." + body)),
// keyed with the endpoint's secret exactly as it was shown; during a rotation
// the X-Arandu-Signature header comes once per secret, and any one matching
// is enough. A timestamp more than five minutes from now is refused. Read the
// body raw and verify before parsing it; deduplicate on the event's ID, since
// delivery is at least once.
func VerifyWebhook(secret string, header http.Header, body []byte) (*WebhookEvent, error) {
	return verifyWebhookAt(secret, header, body, time.Now())
}

func verifyWebhookAt(secret string, header http.Header, body []byte, now time.Time) (*WebhookEvent, error) {
	if secret == "" {
		return nil, errors.New("kuaa: the webhook secret is empty")
	}
	values := func(name string) []string {
		var out []string
		for key, lines := range header {
			if strings.EqualFold(key, name) {
				out = append(out, lines...)
			}
		}
		return out
	}
	first := func(name string) string {
		if lines := values(name); len(lines) > 0 {
			return strings.TrimSpace(lines[0])
		}
		return ""
	}
	delivery, stamp := first(WebhookHeaderDeliveryID), first(WebhookHeaderTimestamp)
	if delivery == "" || stamp == "" || strings.Trim(stamp, "0123456789") != "" {
		return nil, ErrWebhookSignature
	}
	seconds, err := strconv.ParseInt(stamp, 10, 64)
	if err != nil {
		return nil, ErrWebhookSignature
	}
	if delta := now.Sub(time.Unix(seconds, 0)); delta > WebhookTolerance || delta < -WebhookTolerance {
		return nil, ErrWebhookSignature
	}
	signature := strings.Join(values(WebhookHeaderSignature), ",")
	if strings.TrimSpace(signature) == "" {
		return nil, ErrWebhookSignature
	}
	entries := strings.Split(signature, ",")
	if len(entries) > maxWebhookSignatures {
		return nil, ErrWebhookSignature
	}
	given := make([][]byte, 0, len(entries))
	for _, entry := range entries {
		entry = strings.TrimSpace(entry)
		digest, ok := strings.CutPrefix(entry, "sha256=")
		decoded, err := hex.DecodeString(digest)
		if !ok || err != nil || len(decoded) != sha256.Size {
			return nil, ErrWebhookSignature
		}
		given = append(given, decoded)
	}
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(stamp + "." + delivery + "."))
	mac.Write(body)
	expected := mac.Sum(nil)
	matched := false
	for _, each := range given {
		if hmac.Equal(each, expected) {
			matched = true
		}
	}
	if !matched {
		return nil, ErrWebhookSignature
	}
	var event WebhookEvent
	if err := json.Unmarshal(body, &event); err != nil {
		return nil, err
	}
	return &event, nil
}
