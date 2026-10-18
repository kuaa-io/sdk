package kuaa

import (
	"fmt"
	"time"
)

// Error is a request the API refused. Code is the API's, the one to branch
// on: unauthenticated, forbidden, not_found, conflict,
// idempotency_key_reused, validation_failed, payment_required,
// malformed_json, body_too_large, rate_limited… Fields says, for
// validation_failed, what is wrong with each field. RetryAfter is how long
// the API asked to wait, on a 429 or a 503. RequestID names the request to
// KUAA's support.
type Error struct {
	StatusCode int
	Code       string
	Message    string
	Fields     map[string][]string
	RetryAfter time.Duration
	RequestID  string
}

func (e *Error) Error() string {
	if e.Message != "" {
		return fmt.Sprintf("kuaa: %d %s: %s", e.StatusCode, e.Code, e.Message)
	}
	return fmt.Sprintf("kuaa: %d %s", e.StatusCode, e.Code)
}
