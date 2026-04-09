package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"

	expr "cel.dev/expr"
	testpb "cel.dev/expr/conformance/test"
	"google.golang.org/protobuf/encoding/prototext"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/dynamicpb"
)

type suiteJSON struct {
	Name        string     `json:"name"`
	Description string     `json:"description"`
	Tests       []testJSON `json:"tests"`
}

type testJSON struct {
	Section       string        `json:"section"`
	Name          string        `json:"name"`
	Description   string        `json:"description,omitempty"`
	Expr          string        `json:"expr"`
	DisableMacros bool          `json:"disable_macros,omitempty"`
	DisableCheck  bool          `json:"disable_check,omitempty"`
	CheckOnly     bool          `json:"check_only,omitempty"`
	Container     string        `json:"container,omitempty"`
	Locale        string        `json:"locale,omitempty"`
	Declarations  []declJSON    `json:"declarations,omitempty"`
	Bindings      []bindingJSON `json:"bindings,omitempty"`
	Expected      expectedJSON  `json:"expected"`
}

type declJSON struct {
	Kind      string         `json:"kind"`
	Name      string         `json:"name"`
	Type      string         `json:"type,omitempty"`
	Overloads []overloadJSON `json:"overloads,omitempty"`
}

type overloadJSON struct {
	ID            string   `json:"id"`
	Params        []string `json:"params,omitempty"`
	Result        string   `json:"result,omitempty"`
	ReceiverStyle bool     `json:"receiver_style,omitempty"`
}

type bindingJSON struct {
	Name string        `json:"name"`
	Expr exprValueJSON `json:"expr"`
}

type expectedJSON struct {
	Kind          string     `json:"kind"`
	Value         *valueJSON `json:"value,omitempty"`
	DeducedType   string     `json:"deduced_type,omitempty"`
	ErrorMessages []string   `json:"error_messages,omitempty"`
	UnknownExprs  []int64    `json:"unknown_exprs,omitempty"`
}

type exprValueJSON struct {
	Kind          string     `json:"kind"`
	Value         *valueJSON `json:"value,omitempty"`
	ErrorMessages []string   `json:"error_messages,omitempty"`
	UnknownExprs  []int64    `json:"unknown_exprs,omitempty"`
}

type valueJSON struct {
	Kind          string         `json:"kind"`
	Bool          *bool          `json:"bool,omitempty"`
	Int           string         `json:"int,omitempty"`
	Uint          string         `json:"uint,omitempty"`
	Double        string         `json:"double,omitempty"`
	String        string         `json:"string,omitempty"`
	Base64        string         `json:"base64,omitempty"`
	TypeName      string         `json:"type_name,omitempty"`
	EnumType      string         `json:"enum_type,omitempty"`
	EnumValue     *int32         `json:"enum_value,omitempty"`
	ObjectTypeURL string         `json:"object_type_url,omitempty"`
	ObjectBase64  string         `json:"object_base64,omitempty"`
	List          []valueJSON    `json:"list,omitempty"`
	Map           []mapEntryJSON `json:"map,omitempty"`
}

type mapEntryJSON struct {
	Key   valueJSON `json:"key"`
	Value valueJSON `json:"value"`
}

type descriptorSetJSON struct {
	Messages   []messageDescriptorJSON   `json:"messages"`
	Extensions []extensionDescriptorJSON `json:"extensions"`
	Enums      []enumValueJSON           `json:"enums"`
}

type messageDescriptorJSON struct {
	Name   string                `json:"name"`
	Kind   string                `json:"kind"`
	Fields []fieldDescriptorJSON `json:"fields,omitempty"`
}

type fieldDescriptorJSON struct {
	Name        string            `json:"name"`
	Number      int32             `json:"number"`
	Type        string            `json:"type"`
	HasPresence bool              `json:"has_presence,omitempty"`
	Default     *valueJSON        `json:"default,omitempty"`
	Encoding    fieldEncodingJSON `json:"encoding"`
}

type extensionDescriptorJSON struct {
	Extendee string              `json:"extendee"`
	Field    fieldDescriptorJSON `json:"field"`
}

type fieldEncodingJSON struct {
	Kind         string `json:"kind"`
	Scalar       string `json:"scalar,omitempty"`
	Message      string `json:"message,omitempty"`
	Packed       bool   `json:"packed,omitempty"`
	MapKeyScalar string `json:"map_key_scalar,omitempty"`
	MapValueKind string `json:"map_value_kind,omitempty"`
	MapValueType string `json:"map_value_type,omitempty"`
}

type enumValueJSON struct {
	Name  string `json:"name"`
	Value int32  `json:"value"`
}

func main() {
	var input string
	var output string
	var descriptorsOutput string
	flag.StringVar(&input, "input", "", "input textproto path")
	flag.StringVar(&output, "output", "", "output json path")
	flag.StringVar(&descriptorsOutput, "descriptors-output", "", "output descriptor summary json path")
	flag.Parse()

	protoRoot := filepath.Join("..", "..", ".cache", "cel-spec", "proto")

	if descriptorsOutput != "" {
		if err := writeDescriptorSummary(protoRoot, descriptorsOutput); err != nil {
			fail(err)
		}
	}

	if input == "" && output == "" {
		if descriptorsOutput != "" {
			return
		}
		fail(errors.New("either --input/--output or --descriptors-output is required"))
	}
	if input == "" || output == "" {
		fail(errors.New("both --input and --output are required"))
	}

	if err := writeSuiteJSON(protoRoot, input, output); err != nil {
		fail(err)
	}
}

func writeSuiteJSON(protoRoot, input, output string) error {
	data, err := os.ReadFile(input)
	if err != nil {
		return err
	}

	resolver, err := loadConformanceResolver(protoRoot)
	if err != nil {
		return err
	}

	var file testpb.SimpleTestFile
	if err := (prototext.UnmarshalOptions{
		Resolver: resolver,
	}).Unmarshal(data, &file); err != nil {
		return err
	}

	out := suiteJSON{
		Name:        file.GetName(),
		Description: file.GetDescription(),
	}
	for _, section := range file.GetSection() {
		for _, testCase := range section.GetTest() {
			normalized, err := normalizeTest(section.GetName(), testCase)
			if err != nil {
				return fmt.Errorf("%s/%s: %w", section.GetName(), testCase.GetName(), err)
			}
			out.Tests = append(out.Tests, normalized)
		}
	}

	return writeJSON(output, out)
}

func writeDescriptorSummary(protoRoot, output string) error {
	files, err := loadConformanceFiles(protoRoot)
	if err != nil {
		return err
	}

	out := descriptorSetJSON{}
	files.RangeFiles(func(fd protoreflect.FileDescriptor) bool {
		collectMessages(&out, fd.Messages())
		collectExtensions(&out, fd.Extensions())
		collectEnums(&out, fd.Enums())
		return true
	})

	sort.Slice(out.Messages, func(i, j int) bool { return out.Messages[i].Name < out.Messages[j].Name })
	sort.Slice(out.Extensions, func(i, j int) bool {
		if out.Extensions[i].Extendee == out.Extensions[j].Extendee {
			return out.Extensions[i].Field.Number < out.Extensions[j].Field.Number
		}
		return out.Extensions[i].Extendee < out.Extensions[j].Extendee
	})
	sort.Slice(out.Enums, func(i, j int) bool { return out.Enums[i].Name < out.Enums[j].Name })
	for i := range out.Messages {
		sort.Slice(out.Messages[i].Fields, func(a, b int) bool {
			return out.Messages[i].Fields[a].Number < out.Messages[i].Fields[b].Number
		})
	}

	return writeJSON(output, out)
}

func normalizeTest(section string, testCase *testpb.SimpleTest) (testJSON, error) {
	out := testJSON{
		Section:       section,
		Name:          testCase.GetName(),
		Description:   testCase.GetDescription(),
		Expr:          testCase.GetExpr(),
		DisableMacros: testCase.GetDisableMacros(),
		DisableCheck:  testCase.GetDisableCheck(),
		CheckOnly:     testCase.GetCheckOnly(),
		Container:     testCase.GetContainer(),
		Locale:        testCase.GetLocale(),
	}

	for _, decl := range testCase.GetTypeEnv() {
		normalized, err := normalizeDecl(decl)
		if err != nil {
			return testJSON{}, err
		}
		out.Declarations = append(out.Declarations, normalized)
	}

	for name, exprValue := range testCase.GetBindings() {
		normalized, err := normalizeExprValue(exprValue)
		if err != nil {
			return testJSON{}, fmt.Errorf("binding %q: %w", name, err)
		}
		out.Bindings = append(out.Bindings, bindingJSON{
			Name: name,
			Expr: normalized,
		})
	}

	switch matcher := testCase.GetResultMatcher().(type) {
	case *testpb.SimpleTest_Value:
		value, err := normalizeValue(matcher.Value)
		if err != nil {
			return testJSON{}, err
		}
		out.Expected = expectedJSON{
			Kind:  "value",
			Value: &value,
		}
	case *testpb.SimpleTest_TypedResult:
		ty, err := normalizeType(matcher.TypedResult.GetDeducedType())
		if err != nil {
			return testJSON{}, err
		}
		var value *valueJSON
		if matcher.TypedResult.GetResult() != nil {
			normalized, err := normalizeValue(matcher.TypedResult.GetResult())
			if err != nil {
				return testJSON{}, err
			}
			value = &normalized
		}
		out.Expected = expectedJSON{
			Kind:        "typed_result",
			Value:       value,
			DeducedType: ty,
		}
	case *testpb.SimpleTest_EvalError:
		out.Expected = expectedJSON{
			Kind:          "eval_error",
			ErrorMessages: normalizeErrors(matcher.EvalError),
		}
	case *testpb.SimpleTest_AnyEvalErrors:
		out.Expected = expectedJSON{
			Kind:          "any_eval_errors",
			ErrorMessages: normalizeErrorMatcher(matcher.AnyEvalErrors),
		}
	case *testpb.SimpleTest_Unknown:
		out.Expected = expectedJSON{
			Kind:         "unknown",
			UnknownExprs: matcher.Unknown.GetExprs(),
		}
	case *testpb.SimpleTest_AnyUnknowns:
		out.Expected = expectedJSON{
			Kind:         "any_unknowns",
			UnknownExprs: normalizeUnknownMatcher(matcher.AnyUnknowns),
		}
	case nil:
		expectedTrue := true
		out.Expected = expectedJSON{
			Kind: "value",
			Value: &valueJSON{
				Kind: "bool",
				Bool: &expectedTrue,
			},
		}
	default:
		return testJSON{}, fmt.Errorf("unsupported result matcher %T", matcher)
	}
	return out, nil
}

func normalizeDecl(decl *expr.Decl) (declJSON, error) {
	switch d := decl.GetDeclKind().(type) {
	case *expr.Decl_Ident:
		ty, err := normalizeType(d.Ident.GetType())
		if err != nil {
			return declJSON{}, fmt.Errorf("decl %q: %w", decl.GetName(), err)
		}
		return declJSON{
			Kind: "ident",
			Name: decl.GetName(),
			Type: ty,
		}, nil
	case *expr.Decl_Function:
		out := declJSON{
			Kind: "function",
			Name: decl.GetName(),
		}
		for _, overload := range d.Function.GetOverloads() {
			var params []string
			for _, param := range overload.GetParams() {
				ty, err := normalizeType(param)
				if err != nil {
					return declJSON{}, fmt.Errorf("function %q overload %q param: %w", decl.GetName(), overload.GetOverloadId(), err)
				}
				params = append(params, ty)
			}
			result, err := normalizeType(overload.GetResultType())
			if err != nil {
				return declJSON{}, fmt.Errorf("function %q overload %q result: %w", decl.GetName(), overload.GetOverloadId(), err)
			}
			out.Overloads = append(out.Overloads, overloadJSON{
				ID:            overload.GetOverloadId(),
				Params:        params,
				Result:        result,
				ReceiverStyle: overload.GetIsInstanceFunction(),
			})
		}
		return out, nil
	default:
		return declJSON{}, fmt.Errorf("unsupported declaration kind %T", d)
	}
}

func normalizeExprValue(exprValue *expr.ExprValue) (exprValueJSON, error) {
	switch kind := exprValue.GetKind().(type) {
	case *expr.ExprValue_Value:
		value, err := normalizeValue(kind.Value)
		if err != nil {
			return exprValueJSON{}, err
		}
		return exprValueJSON{
			Kind:  "value",
			Value: &value,
		}, nil
	case *expr.ExprValue_Error:
		return exprValueJSON{
			Kind:          "error",
			ErrorMessages: normalizeErrors(kind.Error),
		}, nil
	case *expr.ExprValue_Unknown:
		return exprValueJSON{
			Kind:         "unknown",
			UnknownExprs: kind.Unknown.GetExprs(),
		}, nil
	default:
		return exprValueJSON{}, fmt.Errorf("unsupported expr value kind %T", kind)
	}
}

func normalizeValue(v *expr.Value) (valueJSON, error) {
	switch kind := v.GetKind().(type) {
	case *expr.Value_NullValue:
		return valueJSON{Kind: "null"}, nil
	case *expr.Value_BoolValue:
		return valueJSON{Kind: "bool", Bool: &kind.BoolValue}, nil
	case *expr.Value_Int64Value:
		return valueJSON{Kind: "int", Int: strconv.FormatInt(kind.Int64Value, 10)}, nil
	case *expr.Value_Uint64Value:
		return valueJSON{Kind: "uint", Uint: strconv.FormatUint(kind.Uint64Value, 10)}, nil
	case *expr.Value_DoubleValue:
		return valueJSON{Kind: "double", Double: strconv.FormatFloat(kind.DoubleValue, 'g', -1, 64)}, nil
	case *expr.Value_StringValue:
		return valueJSON{Kind: "string", String: kind.StringValue}, nil
	case *expr.Value_BytesValue:
		return valueJSON{Kind: "bytes", Base64: base64.StdEncoding.EncodeToString(kind.BytesValue)}, nil
	case *expr.Value_EnumValue:
		enumValue := kind.EnumValue.GetValue()
		return valueJSON{
			Kind:      "enum",
			EnumType:  kind.EnumValue.GetType(),
			EnumValue: &enumValue,
		}, nil
	case *expr.Value_ObjectValue:
		return valueJSON{
			Kind:          "object",
			ObjectTypeURL: kind.ObjectValue.GetTypeUrl(),
			ObjectBase64:  base64.StdEncoding.EncodeToString(kind.ObjectValue.GetValue()),
		}, nil
	case *expr.Value_MapValue:
		out := valueJSON{Kind: "map"}
		for _, entry := range kind.MapValue.GetEntries() {
			key, err := normalizeValue(entry.GetKey())
			if err != nil {
				return valueJSON{}, err
			}
			val, err := normalizeValue(entry.GetValue())
			if err != nil {
				return valueJSON{}, err
			}
			out.Map = append(out.Map, mapEntryJSON{
				Key:   key,
				Value: val,
			})
		}
		return out, nil
	case *expr.Value_ListValue:
		out := valueJSON{Kind: "list"}
		for _, entry := range kind.ListValue.GetValues() {
			value, err := normalizeValue(entry)
			if err != nil {
				return valueJSON{}, err
			}
			out.List = append(out.List, value)
		}
		return out, nil
	case *expr.Value_TypeValue:
		return valueJSON{Kind: "type", TypeName: kind.TypeValue}, nil
	default:
		return valueJSON{}, fmt.Errorf("unsupported value kind %T", kind)
	}
}

func normalizeType(ty *expr.Type) (string, error) {
	switch kind := ty.GetTypeKind().(type) {
	case *expr.Type_Dyn:
		return "dyn", nil
	case *expr.Type_Null:
		return "null", nil
	case *expr.Type_Primitive:
		return primitiveTypeName(kind.Primitive)
	case *expr.Type_Wrapper:
		name, err := primitiveTypeName(kind.Wrapper)
		if err != nil {
			return "", err
		}
		return "wrapper(" + name + ")", nil
	case *expr.Type_WellKnown:
		switch kind.WellKnown {
		case expr.Type_ANY:
			return "message(google.protobuf.Any)", nil
		case expr.Type_TIMESTAMP:
			return "message(google.protobuf.Timestamp)", nil
		case expr.Type_DURATION:
			return "message(google.protobuf.Duration)", nil
		default:
			return "", fmt.Errorf("unsupported well-known type %v", kind.WellKnown)
		}
	case *expr.Type_ListType_:
		elem, err := normalizeType(kind.ListType.GetElemType())
		if err != nil {
			return "", err
		}
		return "list(" + elem + ")", nil
	case *expr.Type_MapType_:
		key, err := normalizeType(kind.MapType.GetKeyType())
		if err != nil {
			return "", err
		}
		value, err := normalizeType(kind.MapType.GetValueType())
		if err != nil {
			return "", err
		}
		return "map(" + key + ", " + value + ")", nil
	case *expr.Type_MessageType:
		return "message(" + kind.MessageType + ")", nil
	case *expr.Type_TypeParam:
		return "type_param(" + kind.TypeParam + ")", nil
	case *expr.Type_Type:
		if kind.Type == nil {
			return "type", nil
		}
		nested, err := normalizeType(kind.Type)
		if err != nil {
			return "", err
		}
		return "type(" + nested + ")", nil
	case *expr.Type_Error:
		return "error", nil
	case *expr.Type_AbstractType_:
		name := kind.AbstractType.GetName()
		params := kind.AbstractType.GetParameterTypes()
		if len(params) == 0 {
			return "abstract(" + name + ")", nil
		}
		out := "abstract(" + name + "<"
		for i, param := range params {
			if i > 0 {
				out += ", "
			}
			normalized, err := normalizeType(param)
			if err != nil {
				return "", err
			}
			out += normalized
		}
		out += ">)"
		return out, nil
	case *expr.Type_Function:
		result, err := normalizeType(kind.Function.GetResultType())
		if err != nil {
			return "", err
		}
		out := "function(" + result
		for _, arg := range kind.Function.GetArgTypes() {
			normalized, err := normalizeType(arg)
			if err != nil {
				return "", err
			}
			out += ", " + normalized
		}
		out += ")"
		return out, nil
	default:
		return "", fmt.Errorf("unsupported type kind %T", kind)
	}
}

func primitiveTypeName(primitive expr.Type_PrimitiveType) (string, error) {
	switch primitive {
	case expr.Type_BOOL:
		return "bool", nil
	case expr.Type_INT64:
		return "int", nil
	case expr.Type_UINT64:
		return "uint", nil
	case expr.Type_DOUBLE:
		return "double", nil
	case expr.Type_STRING:
		return "string", nil
	case expr.Type_BYTES:
		return "bytes", nil
	default:
		return "", fmt.Errorf("unsupported primitive type %v", primitive)
	}
}

func normalizeErrors(set *expr.ErrorSet) []string {
	if set == nil {
		return nil
	}
	out := make([]string, 0, len(set.GetErrors()))
	for _, status := range set.GetErrors() {
		out = append(out, status.GetMessage())
	}
	return out
}

func normalizeErrorMatcher(matcher *testpb.ErrorSetMatcher) []string {
	if matcher == nil {
		return nil
	}
	var out []string
	for _, set := range matcher.GetErrors() {
		out = append(out, normalizeErrors(set)...)
	}
	return out
}

func normalizeUnknownMatcher(matcher *testpb.UnknownSetMatcher) []int64 {
	if matcher == nil {
		return nil
	}
	var out []int64
	for _, unknown := range matcher.GetUnknowns() {
		out = append(out, unknown.GetExprs()...)
	}
	return out
}

func writeJSON(path string, data any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	fileHandle, err := os.Create(path)
	if err != nil {
		return err
	}
	defer fileHandle.Close()

	encoder := json.NewEncoder(fileHandle)
	encoder.SetIndent("", "  ")
	return encoder.Encode(data)
}

func loadConformanceFiles(protoRoot string) (*protoregistry.Files, error) {
	descriptorPath := filepath.Join("..", "..", ".cache", "conformance", "conformance-descriptors.pb")
	if err := ensureDescriptorSet(protoRoot, descriptorPath); err != nil {
		return nil, err
	}

	data, err := os.ReadFile(descriptorPath)
	if err != nil {
		return nil, err
	}

	var set descriptorpb.FileDescriptorSet
	if err := proto.Unmarshal(data, &set); err != nil {
		return nil, err
	}
	return protodesc.NewFiles(&set)
}

func collectMessages(out *descriptorSetJSON, messages protoreflect.MessageDescriptors) {
	for i := 0; i < messages.Len(); i++ {
		md := messages.Get(i)
		fullName := string(md.FullName())
		if includeMessage(fullName) {
			message := messageDescriptorJSON{
				Name: fullName,
				Kind: messageKind(fullName),
			}
			fields := md.Fields()
			for j := 0; j < fields.Len(); j++ {
				fd := fields.Get(j)
				if fd.Kind() == protoreflect.GroupKind {
					continue
				}
				field, err := descriptorField(fd)
				if err != nil {
					fail(fmt.Errorf("descriptor field %s.%s: %w", fullName, fd.Name(), err))
				}
				message.Fields = append(message.Fields, field)
			}
			out.Messages = append(out.Messages, message)
		}
		collectMessages(out, md.Messages())
		collectExtensions(out, md.Extensions())
		collectEnums(out, md.Enums())
	}
}

func collectExtensions(out *descriptorSetJSON, exts protoreflect.ExtensionDescriptors) {
	for i := 0; i < exts.Len(); i++ {
		xd := exts.Get(i)
		field, err := descriptorField(xd)
		if err != nil {
			fail(fmt.Errorf("descriptor extension %s: %w", xd.FullName(), err))
		}
		field.Name = string(xd.FullName())
		out.Extensions = append(out.Extensions, extensionDescriptorJSON{
			Extendee: string(xd.ContainingMessage().FullName()),
			Field:    field,
		})
	}
}

func collectEnums(out *descriptorSetJSON, enums protoreflect.EnumDescriptors) {
	for i := 0; i < enums.Len(); i++ {
		ed := enums.Get(i)
		fullName := string(ed.FullName())
		if includeEnum(fullName) {
			values := ed.Values()
			for j := 0; j < values.Len(); j++ {
				ev := values.Get(j)
				out.Enums = append(out.Enums, enumValueJSON{
					Name:  fmt.Sprintf("%s.%s", fullName, ev.Name()),
					Value: int32(ev.Number()),
				})
			}
		}
	}
}

func includeMessage(name string) bool {
	switch {
	case name == "google.protobuf.Timestamp",
		name == "google.protobuf.Duration",
		name == "google.protobuf.Any",
		name == "google.protobuf.Struct",
		name == "google.protobuf.Value",
		name == "google.protobuf.ListValue",
		name == "google.protobuf.BoolValue",
		name == "google.protobuf.BytesValue",
		name == "google.protobuf.DoubleValue",
		name == "google.protobuf.FloatValue",
		name == "google.protobuf.Int32Value",
		name == "google.protobuf.Int64Value",
		name == "google.protobuf.StringValue",
		name == "google.protobuf.UInt32Value",
		name == "google.protobuf.UInt64Value":
		return false
	default:
		return true
	}
}

func includeEnum(name string) bool {
	return name != "google.protobuf.NullValue"
}

func messageKind(name string) string {
	switch name {
	case "google.protobuf.Timestamp":
		return "timestamp"
	case "google.protobuf.Duration":
		return "duration"
	case "google.protobuf.Any":
		return "any"
	case "google.protobuf.Struct":
		return "struct_value"
	case "google.protobuf.Value":
		return "value"
	case "google.protobuf.ListValue":
		return "list_value"
	case "google.protobuf.BoolValue":
		return "bool_wrapper"
	case "google.protobuf.BytesValue":
		return "bytes_wrapper"
	case "google.protobuf.DoubleValue":
		return "double_wrapper"
	case "google.protobuf.FloatValue":
		return "float_wrapper"
	case "google.protobuf.Int32Value":
		return "int32_wrapper"
	case "google.protobuf.Int64Value":
		return "int64_wrapper"
	case "google.protobuf.StringValue":
		return "string_wrapper"
	case "google.protobuf.UInt32Value":
		return "uint32_wrapper"
	case "google.protobuf.UInt64Value":
		return "uint64_wrapper"
	default:
		return "plain"
	}
}

func descriptorField(fd protoreflect.FieldDescriptor) (fieldDescriptorJSON, error) {
	out := fieldDescriptorJSON{
		Name:        string(fd.Name()),
		Number:      int32(fd.Number()),
		HasPresence: fd.HasPresence(),
		Default:     descriptorDefaultValue(fd),
	}

	if fd.IsMap() {
		out.Type = normalizedMapType(fd)
		entry := fd.Message()
		keyField := entry.Fields().ByNumber(1)
		valueField := entry.Fields().ByNumber(2)
		valueKind, valueType, err := fieldTypeEncoding(valueField)
		if err != nil {
			return fieldDescriptorJSON{}, err
		}
		out.Encoding = fieldEncodingJSON{
			Kind:         "map",
			MapKeyScalar: scalarKindName(keyField.Kind()),
			MapValueKind: valueKind,
			MapValueType: valueType,
		}
		return out, nil
	}

	if fd.Cardinality() == protoreflect.Repeated {
		out.Type = "list(" + celFieldType(fd) + ")"
		kind, typeName, err := fieldTypeEncoding(fd)
		if err != nil {
			return fieldDescriptorJSON{}, err
		}
		out.Encoding = fieldEncodingJSON{
			Kind:    "repeated",
			Packed:  fd.IsPacked(),
			Scalar:  kindIfScalar(kind, typeName),
			Message: typeIfMessage(kind, typeName),
		}
		return out, nil
	}

	out.Type = celFieldType(fd)
	kind, typeName, err := fieldTypeEncoding(fd)
	if err != nil {
		return fieldDescriptorJSON{}, err
	}
	out.Encoding = fieldEncodingJSON{
		Kind:    "singular",
		Scalar:  kindIfScalar(kind, typeName),
		Message: typeIfMessage(kind, typeName),
	}
	return out, nil
}

func normalizedMapType(fd protoreflect.FieldDescriptor) string {
	entry := fd.Message()
	keyField := entry.Fields().ByNumber(1)
	valueField := entry.Fields().ByNumber(2)
	return "map(" + celFieldType(keyField) + ", " + celFieldType(valueField) + ")"
}

func celFieldType(fd protoreflect.FieldDescriptor) string {
	switch fd.Kind() {
	case protoreflect.BoolKind:
		return "bool"
	case protoreflect.Int32Kind, protoreflect.Sint32Kind, protoreflect.Sfixed32Kind,
		protoreflect.Int64Kind, protoreflect.Sint64Kind, protoreflect.Sfixed64Kind:
		return "int"
	case protoreflect.Uint32Kind, protoreflect.Fixed32Kind,
		protoreflect.Uint64Kind, protoreflect.Fixed64Kind:
		return "uint"
	case protoreflect.FloatKind, protoreflect.DoubleKind:
		return "double"
	case protoreflect.StringKind:
		return "string"
	case protoreflect.BytesKind:
		return "bytes"
	case protoreflect.EnumKind:
		return "enum(" + string(fd.Enum().FullName()) + ")"
	case protoreflect.MessageKind:
		name := string(fd.Message().FullName())
		switch messageKind(name) {
		case "any", "value":
			return "dyn"
		case "struct_value":
			return "map(string, dyn)"
		case "list_value":
			return "list(dyn)"
		case "bool_wrapper":
			return "bool"
		case "bytes_wrapper":
			return "bytes"
		case "double_wrapper", "float_wrapper":
			return "double"
		case "int32_wrapper", "int64_wrapper":
			return "int"
		case "string_wrapper":
			return "string"
		case "uint32_wrapper", "uint64_wrapper":
			return "uint"
		default:
			return "message(" + name + ")"
		}
	default:
		return "dyn"
	}
}

func fieldTypeEncoding(fd protoreflect.FieldDescriptor) (kind string, typeName string, err error) {
	switch fd.Kind() {
	case protoreflect.BoolKind:
		return "scalar", "bool", nil
	case protoreflect.Int32Kind:
		return "scalar", "int32", nil
	case protoreflect.Int64Kind:
		return "scalar", "int64", nil
	case protoreflect.Sint32Kind:
		return "scalar", "sint32", nil
	case protoreflect.Sint64Kind:
		return "scalar", "sint64", nil
	case protoreflect.Uint32Kind:
		return "scalar", "uint32", nil
	case protoreflect.Uint64Kind:
		return "scalar", "uint64", nil
	case protoreflect.Fixed32Kind:
		return "scalar", "fixed32", nil
	case protoreflect.Fixed64Kind:
		return "scalar", "fixed64", nil
	case protoreflect.Sfixed32Kind:
		return "scalar", "sfixed32", nil
	case protoreflect.Sfixed64Kind:
		return "scalar", "sfixed64", nil
	case protoreflect.FloatKind:
		return "scalar", "float", nil
	case protoreflect.DoubleKind:
		return "scalar", "double", nil
	case protoreflect.StringKind:
		return "scalar", "string", nil
	case protoreflect.BytesKind:
		return "scalar", "bytes", nil
	case protoreflect.EnumKind:
		return "scalar", "enum_value", nil
	case protoreflect.MessageKind:
		return "message", string(fd.Message().FullName()), nil
	default:
		return "", "", fmt.Errorf("unsupported field kind %v", fd.Kind())
	}
}

func scalarKindName(kind protoreflect.Kind) string {
	switch kind {
	case protoreflect.BoolKind:
		return "bool"
	case protoreflect.Int32Kind:
		return "int32"
	case protoreflect.Int64Kind:
		return "int64"
	case protoreflect.Sint32Kind:
		return "sint32"
	case protoreflect.Sint64Kind:
		return "sint64"
	case protoreflect.Uint32Kind:
		return "uint32"
	case protoreflect.Uint64Kind:
		return "uint64"
	case protoreflect.Fixed32Kind:
		return "fixed32"
	case protoreflect.Fixed64Kind:
		return "fixed64"
	case protoreflect.Sfixed32Kind:
		return "sfixed32"
	case protoreflect.Sfixed64Kind:
		return "sfixed64"
	case protoreflect.FloatKind:
		return "float"
	case protoreflect.DoubleKind:
		return "double"
	case protoreflect.StringKind:
		return "string"
	case protoreflect.BytesKind:
		return "bytes"
	case protoreflect.EnumKind:
		return "enum_value"
	default:
		return ""
	}
}

func kindIfScalar(kind, typeName string) string {
	if kind == "scalar" {
		return typeName
	}
	return ""
}

func typeIfMessage(kind, typeName string) string {
	if kind == "message" {
		return typeName
	}
	return ""
}

func descriptorDefaultValue(fd protoreflect.FieldDescriptor) *valueJSON {
	if !fd.HasDefault() {
		return nil
	}
	v := fd.Default()
	switch fd.Kind() {
	case protoreflect.BoolKind:
		b := v.Bool()
		return &valueJSON{Kind: "bool", Bool: &b}
	case protoreflect.Int32Kind, protoreflect.Int64Kind,
		protoreflect.Sint32Kind, protoreflect.Sint64Kind,
		protoreflect.Sfixed32Kind, protoreflect.Sfixed64Kind:
		return &valueJSON{Kind: "int", Int: strconv.FormatInt(v.Int(), 10)}
	case protoreflect.Uint32Kind, protoreflect.Uint64Kind,
		protoreflect.Fixed32Kind, protoreflect.Fixed64Kind:
		return &valueJSON{Kind: "uint", Uint: strconv.FormatUint(v.Uint(), 10)}
	case protoreflect.FloatKind, protoreflect.DoubleKind:
		return &valueJSON{Kind: "double", Double: strconv.FormatFloat(v.Float(), 'g', -1, 64)}
	case protoreflect.StringKind:
		return &valueJSON{Kind: "string", String: v.String()}
	case protoreflect.BytesKind:
		return &valueJSON{Kind: "bytes", Base64: base64.StdEncoding.EncodeToString(v.Bytes())}
	case protoreflect.EnumKind:
		num := int32(v.Enum())
		return &valueJSON{
			Kind:      "enum",
			EnumType:  string(fd.Enum().FullName()),
			EnumValue: &num,
		}
	default:
		return nil
	}
}

func loadConformanceResolver(protoRoot string) (*protoregistry.Types, error) {
	files, err := loadConformanceFiles(protoRoot)
	if err != nil {
		return nil, err
	}

	types := &protoregistry.Types{}
	files.RangeFiles(func(fd protoreflect.FileDescriptor) bool {
		registerMessages(types, fd.Messages())
		registerExtensions(types, fd.Extensions())
		return true
	})
	return types, nil
}

func ensureDescriptorSet(protoRoot, descriptorPath string) error {
	protoRootAbs, err := filepath.Abs(protoRoot)
	if err != nil {
		return err
	}
	descriptorPathAbs, err := filepath.Abs(descriptorPath)
	if err != nil {
		return err
	}
	protoInfo, err := os.Stat(protoRootAbs)
	if err != nil {
		return err
	}
	if !protoInfo.IsDir() {
		return fmt.Errorf("proto root is not a directory: %s", protoRootAbs)
	}
	if err := os.MkdirAll(filepath.Dir(descriptorPathAbs), 0o755); err != nil {
		return err
	}

	var protoFiles []string
	err = filepath.WalkDir(protoRootAbs, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() || filepath.Ext(path) != ".proto" {
			return nil
		}
		rel, err := filepath.Rel(protoRootAbs, path)
		if err != nil {
			return err
		}
		protoFiles = append(protoFiles, rel)
		return nil
	})
	if err != nil {
		return err
	}

	args := []string{
		"--include_imports",
		"--descriptor_set_out=" + descriptorPathAbs,
		"-I",
		protoRootAbs,
	}
	args = append(args, protoFiles...)
	cmd := exec.Command("protoc", args...)
	cmd.Dir = protoRootAbs
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("protoc failed: %w: %s", err, output)
	}
	return nil
}

func registerMessages(reg *protoregistry.Types, messages protoreflect.MessageDescriptors) {
	for i := 0; i < messages.Len(); i++ {
		md := messages.Get(i)
		_ = reg.RegisterMessage(dynamicpb.NewMessageType(md))
		registerMessages(reg, md.Messages())
		registerExtensions(reg, md.Extensions())
	}
}

func registerExtensions(reg *protoregistry.Types, exts protoreflect.ExtensionDescriptors) {
	for i := 0; i < exts.Len(); i++ {
		_ = reg.RegisterExtension(dynamicpb.NewExtensionType(exts.Get(i)))
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
