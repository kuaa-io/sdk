// Package generator builds KUAA's SDKs from the public API's contract: the
// OpenAPI document kuaa.io serves at /docs/openapi.json is read into an
// intermediate representation that no language knows about -- services,
// methods, models, pagination -- and one emitter per language renders it.
// The SDKs under sdk/<language> are output and are never edited by hand;
// what is hand-written lives in this package's templates.
package generator

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
)

// DefaultBaseURL is where the SDKs send their calls when the contract names
// no server. kuaa.io serves /v1 at the root of its own origin.
const DefaultBaseURL = "https://kuaa.io"

// IR is the API as every SDK sees it.
type IR struct {
	// Version is the SDK's version, the same in every language.
	Version string
	// APIVersion is the contract's info.version.
	APIVersion string
	BaseURL    string
	Models     []*Model
	Services   []*Service
	// WebhookVectors is the JSON of the webhook test vectors every SDK's
	// tests check against (see vectors.go).
	WebhookVectors string
}

// Model is a named object: a resource the API answers, an object nested in
// one, or the body of a request.
type Model struct {
	Name        string
	Description string
	Fields      []*Field
	// Input says the model is sent, not read.
	Input bool
	// Multipart says the model is sent as multipart/form-data, not JSON.
	Multipart bool
}

// Field is one property of a model.
type Field struct {
	// Wire is the JSON name.
	Wire        string
	Description string
	Type        *TypeRef
	Required    bool
	Nullable    bool
}

// TypeRef is a field's type.
type TypeRef struct {
	// Kind is string, integer, number, boolean, model, array, map or file (a
	// multipart part's bytes).
	Kind  string
	Model string
	Items *TypeRef
	// Enum are a string's allowed values.
	Enum   []string
	Format string
}

// Service groups the methods of one resource: cases, webhooks.
type Service struct {
	Name    string
	Methods []*Method
}

// Method is one operation.
type Method struct {
	// Name is the operation's verb: list, get, create, start.
	Name        string
	OperationID string
	Summary     string
	HTTPMethod  string
	Path        string
	PathParams  []string
	// Query are the query parameters; on a paginated method, without cursor
	// and limit, which every SDK names itself.
	Query []*Param
	// Body is the request model, or nil.
	Body *Model
	// Multipart says Body travels as multipart/form-data.
	Multipart bool
	// Response is the model answered in the data envelope; on a paginated
	// method, the item.
	Response string
	// Paginated says the answer is one page of Item, walked by cursor.
	Paginated bool
	Item      string
	// ItemField is the property of data that holds a page's items.
	ItemField string
	// Write says it takes an Idempotency-Key.
	Write bool
}

// Param is a query parameter.
type Param struct {
	Name, Description string
	Type              *TypeRef
	Required          bool
}

type spec struct {
	Info struct {
		Version string `json:"version"`
	} `json:"info"`
	Servers []struct {
		URL string `json:"url"`
	} `json:"servers"`
	Paths      map[string]map[string]*operation `json:"paths"`
	Components struct {
		Schemas map[string]*schema `json:"schemas"`
	} `json:"components"`
}

type operation struct {
	OperationID string                `json:"operationId"`
	Summary     string                `json:"summary"`
	Security    []map[string][]string `json:"security"`
	Parameters  []struct {
		Name        string  `json:"name"`
		In          string  `json:"in"`
		Description string  `json:"description"`
		Required    bool    `json:"required"`
		Schema      *schema `json:"schema"`
	} `json:"parameters"`
	RequestBody *struct {
		Content map[string]struct {
			Schema *schema `json:"schema"`
		} `json:"content"`
	} `json:"requestBody"`
	Responses map[string]struct {
		Content map[string]struct {
			Schema *schema `json:"schema"`
		} `json:"content"`
	} `json:"responses"`
}

type schema struct {
	Ref         string             `json:"$ref"`
	Type        any                `json:"type"`
	Format      string             `json:"format"`
	Description string             `json:"description"`
	Enum        []string           `json:"enum"`
	Required    []string           `json:"required"`
	Properties  map[string]*schema `json:"properties"`
	Items       *schema            `json:"items"`
	// AdditionalProperties is a schema, or false for a closed object.
	AdditionalProperties json.RawMessage `json:"additionalProperties"`

	raw json.RawMessage
}

func (s *schema) UnmarshalJSON(b []byte) error {
	type plain schema
	if err := json.Unmarshal(b, (*plain)(s)); err != nil {
		return err
	}
	s.raw = append(json.RawMessage(nil), b...)
	return nil
}

// additional is the schema of a map's values, or nil.
func (s *schema) additional() *schema {
	raw := strings.TrimSpace(string(s.AdditionalProperties))
	if raw == "" || !strings.HasPrefix(raw, "{") {
		return nil
	}
	var values schema
	if json.Unmarshal(s.AdditionalProperties, &values) != nil {
		return nil
	}
	return &values
}

// kind is the schema's type without null, and whether null is allowed.
func (s *schema) kind() (string, bool) {
	switch t := s.Type.(type) {
	case string:
		return t, false
	case []any:
		kind, nullable := "", false
		for _, each := range t {
			if each == "null" {
				nullable = true
			} else {
				kind, _ = each.(string)
			}
		}
		return kind, nullable
	}
	return "", false
}

// object says the schema is an object with properties: a model.
func (s *schema) object() bool {
	kind, _ := s.kind()
	return kind == "object" && len(s.Properties) > 0
}

// signature is the schema's shape without its prose, so that one object the
// contract writes out in several places is one model.
func (s *schema) signature() string {
	var tree any
	if err := json.Unmarshal(s.raw, &tree); err != nil {
		return string(s.raw)
	}
	var strip func(any) any
	strip = func(node any) any {
		switch n := node.(type) {
		case map[string]any:
			out := map[string]any{}
			for key, value := range n {
				switch key {
				case "description", "example", "examples", "title":
					continue
				case "required":
					if list, ok := value.([]any); ok {
						names := make([]string, 0, len(list))
						for _, each := range list {
							names = append(names, fmt.Sprint(each))
						}
						sort.Strings(names)
						out[key] = names
						continue
					}
				}
				out[key] = strip(value)
			}
			return out
		case []any:
			out := make([]any, len(n))
			for i, each := range n {
				out[i] = strip(each)
			}
			return out
		}
		return node
	}
	shape := strip(tree)
	// Whether null is allowed is the property's, not the model's.
	if top, ok := shape.(map[string]any); ok {
		if types, ok := top["type"].([]any); ok {
			for _, each := range types {
				if each != "null" {
					top["type"] = each
				}
			}
		}
	}
	encoded, _ := json.Marshal(shape)
	return string(encoded)
}

// Load reads the contract at path into the IR.
func Load(path, version string) (*IR, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var doc spec
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("generator: read %s: %w", path, err)
	}
	ir, err := build(&doc, version)
	if err != nil {
		return nil, err
	}
	vectors, err := WebhookVectors()
	if err != nil {
		return nil, err
	}
	ir.WebhookVectors = string(vectors)
	return ir, nil
}

// skipped are the components the SDKs do not declare as models: the error
// body, which each SDK's hand-written runtime turns into its own error type,
// and the response envelopes, which the SDKs unwrap.
func skipped(name string) bool {
	return name == "Problem" || strings.HasSuffix(name, "Response")
}

// overrides name the objects the contract writes inline where the rule in
// namer.nested would name them poorly, by "<parent model>.<property>"; a
// response's data is "<response component>.data".
var overrides = map[string]string{
	"CaseTagsResponse.data":                "CaseTagList",
	"DecisionResponse.data":                "CaseDecision",
	"Run.workflow":                         "RunWorkflow",
	"PartyResponse.data":                   "AddedParty",
	"PartyList.parties":                    "PartySummary",
	"Statement.entries":                    "StatementEntry",
	"WorkflowList.workflows":               "Workflow",
	"Workflow.latest_version":              "WorkflowVersion",
	"Workflow.versions":                    "WorkflowVersion",
	"Dossier.workflow":                     "DossierWorkflow",
	"DossierWorkflow.steps":                "WorkflowStep",
	"OwnershipResolution.resolution":       "BeneficialOwnerResolution",
	"BeneficialOwnerResolution.candidates": "BeneficialOwner",
	"BeneficialOwnerResolution.owners":     "BeneficialOwner",
	"BeneficialOwnerResolution.exempt":     "OwnershipExemption",
	"BeneficialOwnerResolution.unresolved": "UnresolvedOwnership",
	"BeneficialOwner.paths":                "OwnershipPath",
}

// reserved are the names the overrides ask for.
func reserved() map[string]bool {
	out := map[string]bool{}
	for _, name := range overrides {
		out[name] = true
	}
	return out
}

// namer names the models: the contract's components by their own names, and
// each object it writes inline after the property that holds it. One shape
// is one model, however many times the contract repeats it.
type namer struct {
	ir      *IR
	bySig   map[string]string
	taken   map[string]bool
	pending []*job
}

// job is an inline object waiting for its name.
type job struct {
	parent, field string
	schema        *schema
	array         bool
	depth         int
	input         bool
	// target is the TypeRef to point at the model once it is named.
	target *TypeRef
}

func (n *namer) key(s *schema, input bool) string {
	return fmt.Sprint(input) + s.signature()
}

// declare adds a model named name for s, unless its shape already has one.
func (n *namer) declare(name string, s *schema, input bool, depth int) (string, error) {
	if existing, ok := n.bySig[n.key(s, input)]; ok {
		return existing, nil
	}
	n.bySig[n.key(s, input)] = name
	n.taken[name] = true
	model, err := n.modelOf(name, s, input, depth)
	if err != nil {
		return "", err
	}
	n.ir.Models = append(n.ir.Models, model)
	return name, nil
}

// generic are property names too vague to name a model by themselves.
var generic = map[string]bool{"data": true, "meta": true, "items": true, "resolution": true}

// nested names one inline object: the override, then the property's own
// name (singular for a list), then the parent's name with it.
func (n *namer) nested(j *job) (string, error) {
	if existing, ok := n.bySig[n.key(j.schema, j.input)]; ok {
		return existing, nil
	}
	noun := Pascal(j.field)
	if j.array {
		noun = Pascal(singular(j.field))
	}
	var candidates []string
	if name, ok := overrides[j.parent+"."+j.field]; ok {
		candidates = append(candidates, name)
	}
	if !j.input && !generic[j.field] {
		candidates = append(candidates, noun)
	}
	if strings.HasSuffix(j.parent, Pascal(j.field)) && j.parent != Pascal(j.field) {
		candidates = append(candidates, strings.TrimSuffix(j.parent, Pascal(j.field))+noun)
	}
	candidates = append(candidates, j.parent+noun)
	for i, name := range candidates {
		// A name an override asks for is kept for it.
		if !n.taken[name] && (i == 0 && overrides[j.parent+"."+j.field] == name || !reserved()[name]) {
			return n.declare(name, j.schema, j.input, j.depth)
		}
	}
	for i := 2; ; i++ {
		name := fmt.Sprintf("%s%s%d", j.parent, noun, i)
		if !n.taken[name] {
			return n.declare(name, j.schema, j.input, j.depth)
		}
	}
}

// drain names the pending objects level by level, lists before objects, so
// a list's items take the short name before a lone object of the same name.
func (n *namer) drain() error {
	for len(n.pending) > 0 {
		jobs := n.pending
		n.pending = nil
		sort.SliceStable(jobs, func(a, b int) bool {
			x, y := jobs[a], jobs[b]
			if x.depth != y.depth {
				return x.depth < y.depth
			}
			if x.array != y.array {
				return x.array
			}
			if x.parent != y.parent {
				return x.parent < y.parent
			}
			return x.field < y.field
		})
		depth := jobs[0].depth
		var later []*job
		for _, j := range jobs {
			if j.depth != depth {
				later = append(later, j)
				continue
			}
			name, err := n.nested(j)
			if err != nil {
				return err
			}
			j.target.Kind, j.target.Model = "model", name
		}
		n.pending = append(n.pending, later...)
	}
	return nil
}

func build(doc *spec, version string) (*IR, error) {
	ir := &IR{Version: version, APIVersion: doc.Info.Version, BaseURL: DefaultBaseURL}
	if len(doc.Servers) > 0 && doc.Servers[0].URL != "" {
		ir.BaseURL = strings.TrimRight(doc.Servers[0].URL, "/")
	}
	n := &namer{ir: ir, bySig: map[string]string{}, taken: map[string]bool{}}
	schemas := doc.Components.Schemas

	// The components the operations send are inputs; every other one is
	// something the API answers.
	inputs, multipart := map[string]bool{}, map[string]bool{}
	for _, item := range doc.Paths {
		for _, op := range item {
			if op.RequestBody == nil {
				continue
			}
			for media, content := range op.RequestBody.Content {
				if content.Schema != nil && content.Schema.Ref != "" {
					name := strings.TrimPrefix(content.Schema.Ref, "#/components/schemas/")
					inputs[name] = true
					multipart[name] = multipart[name] || media == "multipart/form-data"
				}
			}
		}
	}
	names := make([]string, 0, len(schemas))
	for name := range schemas {
		names = append(names, name)
		n.taken[name] = true
	}
	sort.Strings(names)
	for _, name := range names {
		if skipped(name) {
			continue
		}
		if _, err := n.declare(name, schemas[name], inputs[name], 0); err != nil {
			return nil, err
		}
	}
	for _, model := range ir.Models {
		model.Multipart = multipart[model.Name]
	}
	if err := n.drain(); err != nil {
		return nil, err
	}

	services := map[string]*Service{}
	paths := make([]string, 0, len(doc.Paths))
	for path := range doc.Paths {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	for _, path := range paths {
		methods := make([]string, 0, len(doc.Paths[path]))
		for method := range doc.Paths[path] {
			methods = append(methods, method)
		}
		sort.Strings(methods)
		for _, httpMethod := range methods {
			op := doc.Paths[path][httpMethod]
			if !apiKeyOperation(op) {
				continue
			}
			serviceName, methodName, err := names2(op.OperationID)
			if err != nil {
				return nil, fmt.Errorf("generator: %s %s: %w", httpMethod, path, err)
			}
			method, err := n.methodOf(op, strings.ToUpper(httpMethod), path, methodName, schemas)
			if err != nil {
				return nil, err
			}
			service := services[serviceName]
			if service == nil {
				service = &Service{Name: serviceName}
				services[serviceName] = service
			}
			service.Methods = append(service.Methods, method)
		}
	}
	if err := n.drain(); err != nil {
		return nil, err
	}
	sort.SliceStable(ir.Models, func(i, j int) bool { return ir.Models[i].Name < ir.Models[j].Name })
	for _, model := range ir.Models {
		if model.Multipart {
			continue
		}
		for _, field := range model.Fields {
			if field.Type.Kind == "file" {
				return nil, fmt.Errorf("generator: %s.%s is a file outside a multipart body", model.Name, field.Wire)
			}
		}
	}
	serviceNames := make([]string, 0, len(services))
	for name := range services {
		serviceNames = append(serviceNames, name)
	}
	sort.Strings(serviceNames)
	for _, name := range serviceNames {
		service := services[name]
		sort.Slice(service.Methods, func(i, j int) bool { return service.Methods[i].Name < service.Methods[j].Name })
		for i := 1; i < len(service.Methods); i++ {
			if service.Methods[i].Name == service.Methods[i-1].Name {
				return nil, fmt.Errorf("generator: %s has two %s methods", name, service.Methods[i].Name)
			}
		}
		ir.Services = append(ir.Services, service)
	}
	// Some languages name a service by its name alone (Elixir's Kuaa.Cases),
	// beside the models (Kuaa.Case): the two must not meet.
	for _, service := range ir.Services {
		for _, model := range ir.Models {
			if model.Name == Pascal(service.Name) {
				return nil, fmt.Errorf("generator: the model %s has the name of the %s service; name it in overrides", model.Name, service.Name)
			}
		}
	}
	return ir, nil
}

// verbs are the SDK names of the route names' resource verbs.
var verbs = map[string]string{"index": "list", "store": "create", "show": "get", "update": "update", "destroy": "delete"}

// names2 reads an operationId -- api.<resource>[.<nested>].<verb>, as kuaa.io
// names its routes -- as a service and a method. A nested resource's service
// carries its parent's singular name: api.cases.tags.store is
// case_tags.create.
func names2(operationID string) (string, string, error) {
	parts := strings.Split(strings.TrimPrefix(operationID, "api."), ".")
	if len(parts) < 2 || !strings.HasPrefix(operationID, "api.") {
		return "", "", fmt.Errorf("operationId %q is not api.<resource>.<verb>", operationID)
	}
	verb := parts[len(parts)-1]
	if mapped, ok := verbs[verb]; ok {
		verb = mapped
	}
	resource := parts[:len(parts)-1]
	service := resource[0]
	if len(resource) > 1 {
		service = singular(resource[0]) + "_" + strings.Join(resource[1:], "_")
	}
	return service, verb, nil
}

// apiKeyOperation says the operation is the SDK's: authenticated by the
// organization's API key.
func apiKeyOperation(op *operation) bool {
	for _, requirement := range op.Security {
		if _, ok := requirement["apiKey"]; ok {
			return true
		}
	}
	return false
}

func (n *namer) methodOf(op *operation, httpMethod, path, methodName string, schemas map[string]*schema) (*Method, error) {
	method := &Method{Name: methodName, OperationID: op.OperationID, Summary: strings.TrimSuffix(op.Summary, "."), HTTPMethod: httpMethod, Path: path}
	cursor, limit := false, false
	for _, param := range op.Parameters {
		switch param.In {
		case "path":
			method.PathParams = append(method.PathParams, param.Name)
		case "header":
			if strings.EqualFold(param.Name, "Idempotency-Key") {
				method.Write = true
			}
		case "query":
			cursor = cursor || param.Name == "cursor"
			limit = limit || param.Name == "limit"
			typ, _, err := n.typeOf(param.Schema, "", param.Name, false, 1)
			if err != nil {
				return nil, fmt.Errorf("generator: %s ?%s: %w", op.OperationID, param.Name, err)
			}
			if typ.Kind == "model" || typ.Kind == "map" || typ.Kind == "array" && typ.Items.Kind != "string" {
				return nil, fmt.Errorf("generator: %s ?%s is not a scalar or a list of strings", op.OperationID, param.Name)
			}
			method.Query = append(method.Query, &Param{Name: param.Name, Description: param.Description, Type: typ, Required: param.Required})
		}
	}
	statuses := make([]string, 0, len(op.Responses))
	for status := range op.Responses {
		if strings.HasPrefix(status, "2") {
			statuses = append(statuses, status)
		}
	}
	sort.Strings(statuses)
	var envelope string
	for _, status := range statuses {
		ref := strings.TrimPrefix(op.Responses[status].Content["application/json"].Schema.Ref, "#/components/schemas/")
		if envelope != "" && ref != envelope {
			return nil, fmt.Errorf("generator: %s answers %s and %s", op.OperationID, envelope, ref)
		}
		envelope = ref
	}
	wrapper := schemas[envelope]
	if wrapper == nil || wrapper.Properties["data"] == nil || !wrapper.Properties["data"].object() {
		return nil, fmt.Errorf("generator: %s answers no data object", op.OperationID)
	}
	data := wrapper.Properties["data"]
	meta := wrapper.Properties["meta"]
	if cursor && meta != nil && meta.Properties["next_cursor"] != nil {
		var arrays []string
		for name, property := range data.Properties {
			if kind, _ := property.kind(); kind == "array" {
				arrays = append(arrays, name)
			}
		}
		if len(arrays) != 1 || !limit {
			return nil, fmt.Errorf("generator: %s pages by cursor but its data has %d lists", op.OperationID, len(arrays))
		}
		items := data.Properties[arrays[0]].Items
		if !items.object() {
			return nil, fmt.Errorf("generator: %s pages %s, which are not objects", op.OperationID, arrays[0])
		}
		parent := strings.TrimSuffix(envelope, "Response")
		target := &TypeRef{}
		n.pending = append(n.pending, &job{parent: parent, field: arrays[0], schema: items, array: true, depth: 1, target: target})
		if err := n.drain(); err != nil {
			return nil, err
		}
		method.Paginated, method.Item, method.ItemField, method.Response = true, target.Model, arrays[0], target.Model
		query := method.Query[:0]
		for _, param := range method.Query {
			if param.Name != "cursor" && param.Name != "limit" {
				query = append(query, param)
			}
		}
		method.Query = query
	} else {
		name := strings.TrimSuffix(envelope, "Response")
		if override, ok := overrides[envelope+".data"]; ok {
			name = override
		}
		if existing, ok := n.bySig[n.key(data, false)]; ok {
			name = existing
		} else if n.taken[name] {
			base := name + "Result"
			name = base
			for i := 2; n.taken[name]; i++ {
				name = fmt.Sprintf("%s%d", base, i)
			}
		}
		declared, err := n.declare(name, data, false, 0)
		if err != nil {
			return nil, err
		}
		method.Response = declared
	}
	if err := n.drain(); err != nil {
		return nil, err
	}
	if op.RequestBody != nil {
		for media, content := range op.RequestBody.Content {
			if content.Schema == nil || content.Schema.Ref == "" {
				return nil, fmt.Errorf("generator: %s sends an inline body", op.OperationID)
			}
			name := strings.TrimPrefix(content.Schema.Ref, "#/components/schemas/")
			body := n.find(name)
			if body == nil {
				return nil, fmt.Errorf("generator: %s sends %s, which is not declared", op.OperationID, name)
			}
			if len(body.Fields) > 0 {
				method.Body = body
				method.Multipart = media == "multipart/form-data"
			}
		}
	}
	if method.Body != nil && len(method.Query) > 0 && !method.Paginated {
		return nil, fmt.Errorf("generator: %s takes both a body and a query, which the SDKs do not write", op.OperationID)
	}
	return method, nil
}

func (n *namer) find(name string) *Model {
	for _, model := range n.ir.Models {
		if model.Name == name {
			return model
		}
	}
	return nil
}

func (n *namer) modelOf(name string, s *schema, input bool, depth int) (*Model, error) {
	model := &Model{Name: name, Description: s.Description, Input: input}
	required := map[string]bool{}
	for _, field := range s.Required {
		required[field] = true
	}
	wires := make([]string, 0, len(s.Properties))
	for wire := range s.Properties {
		wires = append(wires, wire)
	}
	sort.Strings(wires)
	for _, wire := range wires {
		property := s.Properties[wire]
		typ, nullable, err := n.typeOf(property, name, wire, input, depth+1)
		if err != nil {
			return nil, fmt.Errorf("generator: %s.%s: %w", name, wire, err)
		}
		model.Fields = append(model.Fields, &Field{Wire: wire, Description: property.Description, Type: typ, Required: required[wire], Nullable: nullable})
	}
	return model, nil
}

// typeOf is a property's type. An inline object is queued for a name; its
// TypeRef is filled in when the namer reaches it.
func (n *namer) typeOf(s *schema, parent, field string, input bool, depth int) (*TypeRef, bool, error) {
	if s == nil {
		return nil, false, fmt.Errorf("no schema")
	}
	if s.Ref != "" {
		return &TypeRef{Kind: "model", Model: strings.TrimPrefix(s.Ref, "#/components/schemas/")}, false, nil
	}
	kind, nullable := s.kind()
	switch kind {
	case "string":
		if s.Format == "binary" {
			return &TypeRef{Kind: "file", Format: s.Format}, nullable, nil
		}
		return &TypeRef{Kind: kind, Enum: s.Enum, Format: s.Format}, nullable, nil
	case "integer", "number", "boolean":
		return &TypeRef{Kind: kind, Enum: s.Enum, Format: s.Format}, nullable, nil
	case "array":
		if s.Items != nil && s.Items.object() {
			target := &TypeRef{}
			n.pending = append(n.pending, &job{parent: parent, field: field, schema: s.Items, array: true, depth: depth, input: input, target: target})
			return &TypeRef{Kind: "array", Items: target}, nullable, nil
		}
		items, _, err := n.typeOf(s.Items, parent, field, input, depth)
		return &TypeRef{Kind: "array", Items: items}, nullable, err
	case "object":
		if s.object() {
			target := &TypeRef{}
			n.pending = append(n.pending, &job{parent: parent, field: field, schema: s, depth: depth, input: input, target: target})
			return target, nullable, nil
		}
		if values := s.additional(); values != nil {
			items, _, err := n.typeOf(values, parent, field, input, depth)
			return &TypeRef{Kind: "map", Items: items}, nullable, err
		}
	}
	return nil, false, fmt.Errorf("unsupported schema type %v", s.Type)
}

// singular writes a plural noun as one of it: cases as case, parties as
// party, entries as entry.
func singular(name string) string {
	switch {
	case strings.HasSuffix(name, "ies"):
		return strings.TrimSuffix(name, "ies") + "y"
	case strings.HasSuffix(name, "sses"), strings.HasSuffix(name, "xes"):
		return strings.TrimSuffix(name, "es")
	case strings.HasSuffix(name, "ss"):
		return name
	}
	return strings.TrimSuffix(name, "s")
}

// Pascal writes capture_sessions as CaptureSessions.
func Pascal(name string) string {
	parts := strings.FieldsFunc(name, func(r rune) bool { return r == '_' || r == '-' || r == '.' || r == ' ' })
	for i, part := range parts {
		switch strings.ToLower(part) {
		case "id", "url":
			parts[i] = strings.ToUpper(part)
		default:
			parts[i] = strings.ToUpper(part[:1]) + part[1:]
		}
	}
	return strings.Join(parts, "")
}

// Camel writes capture_sessions as captureSessions.
func Camel(name string) string {
	pascal := Pascal(name)
	for _, acronym := range []string{"URL", "ID"} {
		if strings.HasPrefix(pascal, acronym) {
			return strings.ToLower(acronym) + pascal[len(acronym):]
		}
	}
	return strings.ToLower(pascal[:1]) + pascal[1:]
}
