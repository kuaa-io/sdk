package generator

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Every language writes its SDK, a file a model or a service written once
// for each, the webhook vectors among its tests, and nothing it did not write
// is left behind.
func TestEveryLanguageWritesItsSDK(t *testing.T) {
	ir, err := Load("../openapi.json", "0.1.0")
	if err != nil {
		t.Fatal(err)
	}
	expected := map[string][]string{
		"go":         {"go.mod", "client.go", "services.go", "models.go", "testdata/webhook-vectors.json"},
		"typescript": {"package.json", "src/client.ts", "src/services.ts", "test/kuaa.test.ts", "test/webhook-vectors.json"},
		"python":     {"pyproject.toml", "src/kuaa/__init__.py", "src/kuaa/py.typed", "tests/test_kuaa.py", "tests/webhook-vectors.json"},
		"php":        {"composer.json", "src/Kuaa.php", "src/Models/CaseModel.php", "src/Services/CasesService.php", "tests/webhook-vectors.json"},
		"ruby":       {"kuaa.gemspec", "lib/kuaa.rb", "lib/kuaa/services.rb", "test/kuaa_test.rb", "test/webhook-vectors.json"},
		"elixir":     {"mix.exs", "lib/kuaa.ex", "lib/kuaa/services.ex", "test/kuaa_test.exs", "test/webhook-vectors.json"},
	}
	if len(expected) != len(Languages) {
		t.Fatalf("languages %d, checked %d", len(Languages), len(expected))
	}
	for language, files := range expected {
		out := t.TempDir()
		stale := filepath.Join(out, "stale.txt")
		if err := os.WriteFile(stale, nil, 0o644); err != nil {
			t.Fatal(err)
		}
		if err := Generate(ir, language, out); err != nil {
			t.Fatalf("%s: %v", language, err)
		}
		for _, file := range files {
			if _, err := os.Stat(filepath.Join(out, file)); err != nil {
				t.Errorf("%s did not write %s", language, file)
			}
		}
		if _, err := os.Stat(stale); err == nil {
			t.Errorf("%s left a file it does not write", language)
		}
		_ = filepath.WalkDir(out, func(path string, entry os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if (strings.Contains(path, "__") || strings.HasSuffix(path, ".tmpl")) && !strings.Contains(path, "__init__") {
				t.Errorf("%s wrote %s", language, path)
			}
			if strings.HasSuffix(path, "webhook-vectors.json") {
				raw, _ := os.ReadFile(path)
				if string(raw) != ir.WebhookVectors {
					t.Errorf("%s wrote other vectors", language)
				}
			}
			if !entry.IsDir() && !strings.HasSuffix(path, ".json") {
				raw, _ := os.ReadFile(path)
				for _, word := range []string{"Peráta", "perata", "Perata", "prk_"} {
					if strings.Contains(string(raw), word) {
						t.Errorf("%s: %s still says %s", language, path, word)
					}
				}
			}
			return nil
		})
	}
}
