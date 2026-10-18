// Command sdkgen writes KUAA's SDKs from the public API's contract.
//
//	go run ./cmd/sdkgen                                  # every language
//	go run ./cmd/sdkgen -language go                     # one
//	go run ./cmd/sdkgen -sync http://127.0.0.1:8080/docs/openapi.json
//	go run ./cmd/sdkgen -sync ../openapi.json            # a file
//
// -sync copies the contract kuaa.io serves at /docs/openapi.json (with
// API_DOCS_ENABLED=true) into openapi.json first, so the contract the SDKs
// were written from is kept beside them. Every run also writes
// testdata/webhook-vectors.json, the webhook test vectors each SDK's tests
// read from their own copy.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/kuaa-io/sdk/generator"
)

func main() {
	spec := flag.String("spec", "openapi.json", "the public API's contract")
	sync := flag.String("sync", "", "a contract, a file or an http(s) URL, to copy into -spec before generating")
	language := flag.String("language", "", "one language; every language when empty")
	out := flag.String("out", ".", "the directory that holds VERSION and <language>/")
	flag.Parse()
	if *sync != "" {
		raw, err := read(*sync)
		if err == nil && !json.Valid(raw) {
			err = fmt.Errorf("%s is not JSON", *sync)
		}
		if err == nil {
			err = os.WriteFile(*spec, raw, 0o644)
		}
		if err != nil {
			fail("sdkgen: sync the contract:", err)
		}
	}
	version, err := os.ReadFile(filepath.Join(*out, "VERSION"))
	if err != nil {
		fail("sdkgen: read the SDK version:", err)
	}
	ir, err := generator.Load(*spec, strings.TrimSpace(string(version)))
	if err != nil {
		fail(err)
	}
	vectors := filepath.Join(*out, "testdata", "webhook-vectors.json")
	if err := os.MkdirAll(filepath.Dir(vectors), 0o755); err == nil {
		err = os.WriteFile(vectors, []byte(ir.WebhookVectors), 0o644)
	}
	if err != nil {
		fail("sdkgen: write the webhook vectors:", err)
	}
	languages := []string{*language}
	if *language == "" {
		languages = languages[:0]
		for name := range generator.Languages {
			languages = append(languages, name)
		}
		sort.Strings(languages)
	}
	for _, name := range languages {
		if err := generator.Generate(ir, name, filepath.Join(*out, name)); err != nil {
			fail(err)
		}
		fmt.Println("sdkgen: wrote", filepath.Join(*out, name))
	}
}

// read is a file, or what an http(s) URL answers.
func read(source string) ([]byte, error) {
	if !strings.HasPrefix(source, "http://") && !strings.HasPrefix(source, "https://") {
		return os.ReadFile(source)
	}
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Get(source)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s answered %s", source, resp.Status)
	}
	return io.ReadAll(resp.Body)
}

func fail(args ...any) {
	fmt.Fprintln(os.Stderr, args...)
	os.Exit(1)
}
