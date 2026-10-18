package generator

import (
	"go/format"
	"strings"
	"text/template"
)

// goKeywords are names a Go parameter cannot take.
var goKeywords = map[string]bool{"type": true, "func": true, "range": true, "map": true, "default": true, "interface": true, "select": true, "package": true}

func init() {
	register(Language{Name: "go", Funcs: template.FuncMap{
		"goType": goType,
		"goParam": func(name string) string {
			camel := Camel(name)
			if goKeywords[camel] {
				return camel + "ID"
			}
			return camel
		},
		"goTag": func(f *Field, input bool) string {
			if !f.Required {
				return f.Wire + ",omitempty"
			}
			return f.Wire
		},
		"goComment": goComment,
		"goPointer": func(t *TypeRef, f *Field, input bool) bool { return strings.HasPrefix(goType(t, f, input), "*") },
		"goQueryType": func(t *TypeRef) string {
			switch t.Kind {
			case "integer":
				return "int"
			case "number":
				return "float64"
			case "boolean":
				return "*bool"
			case "array":
				return "[]string"
			}
			return "string"
		},
		"goQuerySet": goQuerySet,
		"goPart":     goPart,
	}})
}

// goType is a field's Go type: a pointer when the API may answer null or
// leave the field out, or when a request may.
func goType(t *TypeRef, f *Field, input bool) string {
	base := goBase(t)
	if f == nil {
		return base
	}
	pointer := f.Nullable || !f.Required
	if pointer && t.Kind != "array" && t.Kind != "map" {
		return "*" + base
	}
	return base
}

func goBase(t *TypeRef) string {
	switch t.Kind {
	case "string":
		return "string"
	case "integer":
		return "int64"
	case "number":
		return "float64"
	case "boolean":
		return "bool"
	case "model":
		return t.Model
	case "file":
		return "File"
	case "array":
		return "[]" + goBase(t.Items)
	case "map":
		return "map[string]" + goBase(t.Items)
	}
	return "any"
}

// goQuerySet writes one query parameter into q, when it is set.
func goQuerySet(p *Param) string {
	field, name := "p."+Pascal(p.Name), `"`+p.Name+`"`
	switch p.Type.Kind {
	case "integer":
		return "\tif " + field + " != 0 {\n\t\tq.Set(" + name + ", strconv.Itoa(" + field + "))\n\t}"
	case "number":
		return "\tif " + field + " != 0 {\n\t\tq.Set(" + name + ", strconv.FormatFloat(" + field + ", 'f', -1, 64))\n\t}"
	case "boolean":
		return "\tif " + field + " != nil {\n\t\tq.Set(" + name + ", strconv.FormatBool(*" + field + "))\n\t}"
	case "array":
		return "\tfor _, each := range " + field + " {\n\t\tq.Add(" + name + ", each)\n\t}"
	}
	return "\tif " + field + " != \"\" {\n\t\tq.Set(" + name + ", " + field + ")\n\t}"
}

// goPart is the multipart part of one value.
func goPart(wire string, t *TypeRef, value string) string {
	name := `"` + wire + `"`
	switch t.Kind {
	case "file":
		return "filePart(" + name + ", " + value + ")"
	case "integer":
		return "textPart(" + name + ", strconv.FormatInt(" + value + ", 10))"
	case "number":
		return "textPart(" + name + ", strconv.FormatFloat(" + value + ", 'f', -1, 64))"
	case "boolean":
		return "textPart(" + name + ", strconv.FormatBool(" + value + "))"
	}
	return "textPart(" + name + ", " + value + ")"
}

// goComment writes a description as a Go comment, or nothing.
func goComment(prefix, text string) string {
	text = strings.TrimSpace(text)
	if text == "" {
		return ""
	}
	return prefix + "// " + strings.ReplaceAll(text, "\n", "\n"+prefix+"// ") + "\n"
}

// FormatGo gofmt's a generated Go file.
func FormatGo(source []byte) ([]byte, error) { return format.Source(source) }
