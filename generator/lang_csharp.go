package generator

import (
	"sort"
	"strings"
	"text/template"
)

// csKeywords are names a C# parameter cannot take without an @.
var csKeywords = map[string]bool{
	"abstract": true, "as": true, "base": true, "bool": true, "break": true, "byte": true, "case": true,
	"catch": true, "char": true, "checked": true, "class": true, "const": true, "continue": true,
	"decimal": true, "default": true, "delegate": true, "do": true, "double": true, "else": true,
	"enum": true, "event": true, "explicit": true, "extern": true, "false": true, "finally": true,
	"fixed": true, "float": true, "for": true, "foreach": true, "goto": true, "if": true, "implicit": true,
	"in": true, "int": true, "interface": true, "internal": true, "is": true, "lock": true, "long": true,
	"namespace": true, "new": true, "null": true, "object": true, "operator": true, "out": true,
	"override": true, "params": true, "private": true, "protected": true, "public": true,
	"readonly": true, "ref": true, "return": true, "sbyte": true, "sealed": true, "short": true,
	"sizeof": true, "stackalloc": true, "static": true, "string": true, "struct": true, "switch": true,
	"this": true, "throw": true, "true": true, "try": true, "typeof": true, "uint": true, "ulong": true,
	"unchecked": true, "unsafe": true, "ushort": true, "using": true, "virtual": true, "void": true,
	"volatile": true, "while": true,
}

func init() {
	register(Language{Name: "csharp", Funcs: template.FuncMap{
		"csName": idiomPascal,
		// csProp is a field's property name; a property cannot take its
		// class's name.
		"csProp": func(model, wire string) string {
			name := idiomPascal(wire)
			if name == model {
				return name + "Value"
			}
			return name
		},
		"csParam": func(wire string) string {
			name := idiomCamel(wire)
			if csKeywords[name] {
				return "@" + name
			}
			return name
		},
		"csType":     csType,
		"csRequired": func(f *Field, input bool) bool { return f.Required && (input || !f.Nullable) },
		// csConst names an enumerated value's constant; a member cannot take
		// its class's name.
		"csConst": func(model, field, value string) string {
			name := idiomPascal(field) + csConstPart(value)
			if name == model {
				return name + "Value"
			}
			return name
		},
		"csDoc":        csDoc,
		"csText":       csText,
		"csTypes":      csTypes,
		"csInfo":       csInfo,
		"csQueryType":  csQueryType,
		"csQueryValue": csQueryValue,
		"csPart":       csPart,
	}})
}

// csConstPart writes one_time as OneTime and BRL as BRL.
func csConstPart(value string) string {
	var b strings.Builder
	upper := true
	for _, r := range value {
		switch {
		case r >= 'a' && r <= 'z':
			if upper {
				r -= 'a' - 'A'
			}
			b.WriteRune(r)
			upper = false
		case r >= 'A' && r <= 'Z' || r >= '0' && r <= '9':
			b.WriteRune(r)
			upper = false
		default:
			upper = true
		}
	}
	out := b.String()
	if out == "" || out[0] >= '0' && out[0] <= '9' {
		out = "_" + out
	}
	return out
}

// csType is a field's C# type: nullable when the API may leave it out or
// send null, or a request may leave it out.
func csType(f *Field, input bool) string {
	base := csRef(f.Type)
	if f.Required && (input || !f.Nullable) {
		return base
	}
	return base + "?"
}

func csRef(t *TypeRef) string {
	switch t.Kind {
	case "string":
		return "string"
	case "integer":
		return "long"
	case "number":
		return "double"
	case "boolean":
		return "bool"
	case "model":
		return t.Model
	case "array":
		return "IReadOnlyList<" + csRef(t.Items) + ">"
	case "map":
		return "IReadOnlyDictionary<string, " + csRef(t.Items) + ">"
	case "file":
		return "FilePart"
	}
	return "JsonElement"
}

// csText escapes a description for an XML doc comment.
func csText(text string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(strings.TrimSpace(text))
}

// csDoc writes a description as an XML doc summary.
func csDoc(indent, text string) string {
	text = csText(text)
	return indent + "/// <summary>" + strings.ReplaceAll(text, "\n", "\n"+indent+"/// ") + "</summary>\n"
}

// csTypes are the types the SDK reads and writes as JSON, once each, for
// the source-generated JSON context: what the services answer (a list's
// items as a list), the bodies they send, and the webhook event.
func csTypes(ir *IR) []string {
	seen := map[string]bool{"WebhookEvent": true}
	for _, service := range ir.Services {
		for _, method := range service.Methods {
			if method.Paginated {
				seen["IReadOnlyList<"+method.Item+">"] = true
			} else {
				seen[method.Response] = true
			}
			if method.Body != nil && !method.Multipart {
				seen[method.Body.Name] = true
			}
		}
	}
	out := make([]string, 0, len(seen))
	for name := range seen {
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}

// csInfo is the name of a type's JsonTypeInfo on the context.
func csInfo(name string) string {
	if strings.HasPrefix(name, "IReadOnlyList<") {
		return strings.TrimSuffix(strings.TrimPrefix(name, "IReadOnlyList<"), ">") + "List"
	}
	return name
}

// csQueryType is a query parameter's C# type.
func csQueryType(t *TypeRef) string {
	switch t.Kind {
	case "integer":
		return "long?"
	case "number":
		return "double?"
	case "boolean":
		return "bool?"
	case "array":
		return "IReadOnlyList<string>?"
	}
	return "string?"
}

// csQueryValue writes a query parameter's value as the text sent.
func csQueryValue(p *Param) string {
	name := idiomPascal(p.Name)
	switch p.Type.Kind {
	case "integer", "number":
		return name + "?.ToString(CultureInfo.InvariantCulture)"
	case "boolean":
		return name + " is null ? null : " + name + ".Value ? \"true\" : \"false\""
	}
	return name
}

// csPart writes a multipart value as the text or the file sent.
func csPart(t *TypeRef, expr string) string {
	switch t.Kind {
	case "integer", "number":
		return expr + ".ToString(CultureInfo.InvariantCulture)"
	case "boolean":
		return "(" + expr + " ? \"true\" : \"false\")"
	}
	return expr
}
