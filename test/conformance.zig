const std = @import("std");
const cel = @import("cel");
const appendFormat = cel.util.fmt.appendFormat;
const checker = cel.checker.check;
const env = cel.env.env;
const eval = cel.eval.eval;
const comprehensions_ext = cel.library.comprehensions_ext;
const network_ext = cel.library.network_ext;
const protobuf = cel.library.protobuf;
const schema = cel.env.schema;
const stdlib_ext = cel.library.stdlib_ext;
const types = cel.env.types;
const value = cel.env.value;

fn readFileAlloc(allocator: std.mem.Allocator, path: [:0]const u8, max_size: usize) ![]u8 {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    while (buf.items.len < max_size) {
        try buf.ensureTotalCapacity(allocator, buf.items.len + 8192);
        const avail = buf.allocatedSlice()[buf.items.len..];
        const rc = std.c.read(fd, @ptrCast(avail.ptr), avail.len);
        if (rc <= 0) break;
        buf.items.len += @intCast(rc);
    }
    return allocator.dupe(u8, buf.items);
}

const Suite = struct {
    name: []const u8,
    description: []const u8,
    tests: []const TestCase,
};

const TestCase = struct {
    section: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    expr: []const u8,
    disable_macros: bool = false,
    disable_check: bool = false,
    check_only: bool = false,
    container: ?[]const u8 = null,
    locale: ?[]const u8 = null,
    declarations: []const Decl = &.{},
    bindings: []const Binding = &.{},
    expected: Expected,
};

const Decl = struct {
    kind: []const u8,
    name: []const u8,
    type: ?[]const u8 = null,
    overloads: []const Overload = &.{},
};

const Overload = struct {
    id: []const u8,
    params: []const []const u8 = &.{},
    result: ?[]const u8 = null,
    receiver_style: bool = false,
};

const Binding = struct {
    name: []const u8,
    expr: ExprValue,
};

const Expected = struct {
    kind: []const u8,
    value: ?JsonValue = null,
    deduced_type: ?[]const u8 = null,
    error_messages: []const []const u8 = &.{},
    unknown_exprs: []const i64 = &.{},
};

const ExprValue = struct {
    kind: []const u8,
    value: ?JsonValue = null,
    error_messages: []const []const u8 = &.{},
    unknown_exprs: []const i64 = &.{},
};

const JsonValue = struct {
    kind: []const u8,
    bool: ?bool = null,
    int: ?[]const u8 = null,
    uint: ?[]const u8 = null,
    double: ?[]const u8 = null,
    string: ?[]const u8 = null,
    base64: ?[]const u8 = null,
    type_name: ?[]const u8 = null,
    enum_type: ?[]const u8 = null,
    enum_value: ?i32 = null,
    object_type_url: ?[]const u8 = null,
    object_base64: ?[]const u8 = null,
    list: []const JsonValue = &.{},
    map: []const JsonMapEntry = &.{},
};

const JsonMapEntry = struct {
    key: JsonValue,
    value: JsonValue,
};

const DescriptorSummary = struct {
    messages: []const MessageDescriptor = &.{},
    extensions: []const ExtensionDescriptor = &.{},
    enums: []const EnumValue = &.{},
};

const MessageDescriptor = struct {
    name: []const u8,
    kind: []const u8,
    fields: []const FieldDescriptor = &.{},
};

const FieldDescriptor = struct {
    name: []const u8,
    number: i32,
    type: []const u8,
    has_presence: bool = false,
    default: ?JsonValue = null,
    encoding: FieldEncodingDescriptor,
};

const FieldEncodingDescriptor = struct {
    kind: []const u8,
    scalar: ?[]const u8 = null,
    message: ?[]const u8 = null,
    @"packed": bool = false,
    map_key_scalar: ?[]const u8 = null,
    map_value_kind: ?[]const u8 = null,
    map_value_type: ?[]const u8 = null,
};

const ExtensionDescriptor = struct {
    extendee: []const u8,
    field: FieldDescriptor,
};

const EnumValue = struct {
    name: []const u8,
    value: i32,
};

const core_suites = [_][]const u8{
    "basic",
    "bindings_ext",
    "encoders_ext",
    "conversions",
    "fields",
    "fp_math",
    "integer_math",
    "lists",
    "logic",
    "macros",
    "macros2",
    "namespace",
    "plumbing",
    "string",
    "string_ext",
    "math_ext",
    "timestamps",
};

test "upstream core conformance suites" {
    for (core_suites) |suite_name| {
        try runSuiteFile(suite_name);
    }
}

test "upstream wrappers conformance suite" {
    try runSuiteFile("wrappers");
}

test "upstream dynamic conformance suite" {
    try runSuiteFile("dynamic");
}

test "upstream type deduction conformance suite" {
    try runSuiteFile("type_deduction");
}

test "upstream optionals conformance suite" {
    try runSuiteFile("optionals");
}

test "upstream comparisons conformance suite" {
    try runSuiteFile("comparisons");
}

test "upstream parse conformance suite" {
    try runSuiteFile("parse");
}

test "upstream network_ext conformance suite" {
    try runSuiteFile("network_ext");
}

test "upstream enums conformance suite" {
    try runSuiteFile("enums");
}

test "upstream block_ext conformance suite" {
    try runSuiteFile("block_ext");
}

test "upstream proto2 conformance suite" {
    try runSuiteFile("proto2");
}

test "upstream proto3 conformance suite" {
    try runSuiteFile("proto3");
}

test "upstream proto2_ext conformance suite" {
    try runSuiteFile("proto2_ext");
}

fn runSuiteFile(name: []const u8) !void {
    var path_buffer: [128]u8 = undefined;
    const path = std.fmt.bufPrintZ(path_buffer[0..], ".cache/conformance/{s}.json", .{name}) catch return error.SkipZigTest;
    const json_data = readFileAlloc(std.testing.allocator, path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(json_data);

    var parsed = try std.json.parseFromSlice(Suite, std.testing.allocator, json_data, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    var descriptor_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer descriptor_arena.deinit();
    const descriptors = try loadDescriptorSummary(descriptor_arena.allocator());

    // Build two prepared base envs: one for legacy enum mode, one for strong.
    // installDescriptorSummary bakes enum mode into field types via
    // normalizeFieldTypeForMode, so we need separate bases.
    var base_legacy = try env.Env.initDefault(std.testing.allocator);
    defer base_legacy.deinit();
    base_legacy.setEnumMode(.legacy);
    try installDescriptorSummary(&base_legacy, descriptors);
    try base_legacy.addLibrary(stdlib_ext.string_library);
    try base_legacy.addLibrary(stdlib_ext.math_library);
    try base_legacy.addLibrary(network_ext.library);
    try base_legacy.addLibrary(stdlib_ext.proto_library);
    try base_legacy.addLibrary(comprehensions_ext.two_var_comprehensions_library);

    var base_strong = try env.Env.initDefault(std.testing.allocator);
    defer base_strong.deinit();
    base_strong.setEnumMode(.strong);
    try installDescriptorSummary(&base_strong, descriptors);
    try base_strong.addLibrary(stdlib_ext.string_library);
    try base_strong.addLibrary(stdlib_ext.math_library);
    try base_strong.addLibrary(network_ext.library);
    try base_strong.addLibrary(stdlib_ext.proto_library);
    try base_strong.addLibrary(comprehensions_ext.two_var_comprehensions_library);

    var skipped: usize = 0;
    for (parsed.value.tests) |test_case| {
        const base = if (enumModeForSection(test_case.section) == .strong) &base_strong else &base_legacy;
        runSuiteCase(test_case, base) catch |err| switch (err) {
            error.SkipZigTest => skipped += 1,
            else => {
                std.debug.print("conformance suite {s} failed on {s}/{s}\n", .{ name, test_case.section, test_case.name });
                return err;
            },
        };
    }
    if (skipped != 0) {
        std.debug.print("conformance suite {s} skipped {d} cases\n", .{ name, skipped });
        return error.SkipZigTest;
    }
}

fn runSuiteCase(test_case: TestCase, base_env: *env.Env) !void {
    if (test_case.disable_macros) return error.SkipZigTest;
    if (test_case.locale) |locale| {
        if (locale.len != 0) return error.SkipZigTest;
    }

    var environment = try base_env.extend(std.testing.allocator);
    defer environment.deinit();
    environment.setEnumMode(enumModeForSection(test_case.section));
    if (test_case.container) |container| {
        if (container.len != 0) try environment.setContainer(container);
    }

    for (test_case.declarations) |decl| {
        try applyDecl(&environment, decl);
    }

    var activation = eval.Activation.init(std.testing.allocator);
    defer activation.deinit();
    for (test_case.bindings) |binding| {
        try applyBinding(&environment, &activation, binding);
    }

    if (test_case.disable_check) {
        var program = try checker.compileUnchecked(std.testing.allocator, &environment, test_case.expr);
        defer program.deinit();
        try assertExpected(test_case, &environment, &program, &activation);
        return;
    }

    var program = try cel.compile(std.testing.allocator, &environment, test_case.expr);
    defer program.deinit();
    try assertExpected(test_case, &environment, &program, &activation);
}

fn applyDecl(environment: *env.Env, decl: Decl) !void {
    if (std.mem.eql(u8, decl.kind, "ident")) {
        const ty = try parseType(environment, decl.type orelse return error.InvalidType);
        try environment.addVarTyped(decl.name, ty);
        return;
    }

    if (std.mem.eql(u8, decl.kind, "function")) {
        for (decl.overloads) |overload| {
            var params = std.ArrayListUnmanaged(types.TypeRef).empty;
            defer params.deinit(std.testing.allocator);
            try params.ensureTotalCapacity(std.testing.allocator, overload.params.len);
            for (overload.params) |param_text| {
                params.appendAssumeCapacity(try parseType(environment, param_text));
            }
            const result_ty = try parseType(environment, overload.result orelse return error.InvalidType);
            _ = try environment.addFunction(
                decl.name,
                overload.receiver_style,
                params.items,
                result_ty,
                declaredFunctionUnimplemented,
            );
        }
        return;
    }

    return error.SkipZigTest;
}

fn declaredFunctionUnimplemented(_: std.mem.Allocator, _: []const value.Value) env.EvalError!value.Value {
    return value.RuntimeError.NoMatchingOverload;
}

fn applyBinding(environment: *env.Env, activation: *eval.Activation, binding: Binding) !void {
    if (!std.mem.eql(u8, binding.expr.kind, "value")) return error.SkipZigTest;
    const val = try decodeValue(std.testing.allocator, environment, binding.expr.value orelse return error.InvalidBindingValue);
    defer {
        var temp = val;
        temp.deinit(std.testing.allocator);
    }
    try activation.put(binding.name, val);
}

fn assertExpected(
    test_case: TestCase,
    environment: *env.Env,
    program: *const checker.Program,
    activation: *const eval.Activation,
) !void {
    if (std.mem.eql(u8, test_case.expected.kind, "eval_error")) {
        var result = cel.evaluate(std.testing.allocator, program, activation, .{}) catch return;
        result.deinit(std.testing.allocator);
        std.debug.print("conformance eval_error mismatch in {s}/{s}: expression succeeded\n", .{ test_case.section, test_case.name });
        return error.TestExpectedError;
    }
    if (std.mem.eql(u8, test_case.expected.kind, "any_eval_errors")) {
        var result = cel.evaluate(std.testing.allocator, program, activation, .{}) catch return;
        result.deinit(std.testing.allocator);
        std.debug.print("conformance any_eval_errors mismatch in {s}/{s}: expression succeeded\n", .{ test_case.section, test_case.name });
        return error.TestExpectedError;
    }
    if (std.mem.eql(u8, test_case.expected.kind, "unknown") or std.mem.eql(u8, test_case.expected.kind, "any_unknowns")) {
        return error.SkipZigTest;
    }

    if (test_case.check_only) {
        if (test_case.expected.deduced_type) |expected_ty| {
            try expectTypeName(environment, program.result_type, expected_ty, test_case);
        }
        return;
    }

    var result = try cel.evaluate(std.testing.allocator, program, activation, .{});
    defer result.deinit(std.testing.allocator);

    const expected_value = test_case.expected.value orelse return error.InvalidExpectedValue;
    var expected = try decodeValue(std.testing.allocator, environment, expected_value);
    defer expected.deinit(std.testing.allocator);

    if (!conformanceValueEqual(result, expected)) {
        std.debug.print(
            "conformance value mismatch in {s}/{s}: expr `{s}`\n",
            .{ test_case.section, test_case.name, test_case.expr },
        );
        return error.TestExpectedEqual;
    }

    if (test_case.expected.deduced_type) |expected_ty| {
        try expectTypeName(environment, program.result_type, expected_ty, test_case);
    }
}

fn expectTypeName(environment: *env.Env, actual: types.TypeRef, expected_name: []const u8, test_case: TestCase) !void {
    var buffer: [256]u8 = undefined;
    const actual_name = try formatType(environment, actual, buffer[0..]);
    if (!std.mem.eql(u8, actual_name, expected_name)) {
        std.debug.print(
            "conformance type mismatch in {s}/{s}: expected {s}, got {s}\n",
            .{ test_case.section, test_case.name, expected_name, actual_name },
        );
        return error.TestExpectedEqual;
    }
}

fn decodeValue(allocator: std.mem.Allocator, environment: *env.Env, encoded: JsonValue) !value.Value {
    if (std.mem.eql(u8, encoded.kind, "null")) return .null;
    if (std.mem.eql(u8, encoded.kind, "bool")) return .{ .bool = encoded.bool orelse return error.InvalidValue };
    if (std.mem.eql(u8, encoded.kind, "int")) return .{ .int = try std.fmt.parseInt(i64, encoded.int orelse return error.InvalidValue, 10) };
    if (std.mem.eql(u8, encoded.kind, "uint")) return .{ .uint = try std.fmt.parseInt(u64, encoded.uint orelse return error.InvalidValue, 10) };
    if (std.mem.eql(u8, encoded.kind, "double")) return .{ .double = try std.fmt.parseFloat(f64, encoded.double orelse return error.InvalidValue) };
    if (std.mem.eql(u8, encoded.kind, "string")) return value.string(allocator, encoded.string orelse "");
    if (std.mem.eql(u8, encoded.kind, "bytes")) {
        const src = encoded.base64 orelse "";
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(src) catch return error.InvalidValue;
        const buffer = try allocator.alloc(u8, decoded_len);
        errdefer allocator.free(buffer);
        try std.base64.standard.Decoder.decode(buffer, src);
        const out = try value.bytesValue(allocator, buffer[0..decoded_len]);
        allocator.free(buffer);
        return out;
    }
    if (std.mem.eql(u8, encoded.kind, "type")) {
        return value.typeNameValue(allocator, encoded.type_name orelse "");
    }
    if (std.mem.eql(u8, encoded.kind, "enum")) {
        const enum_name = encoded.enum_type orelse return error.InvalidValue;
        _ = try environment.addEnum(enum_name);
        return value.enumValue(allocator, enum_name, encoded.enum_value orelse return error.InvalidValue);
    }
    if (std.mem.eql(u8, encoded.kind, "object")) {
        return decodeObjectValue(allocator, environment, encoded);
    }
    if (std.mem.eql(u8, encoded.kind, "list")) {
        var items: std.ArrayListUnmanaged(value.Value) = .empty;
        errdefer {
            for (items.items) |*entry| entry.deinit(allocator);
            items.deinit(allocator);
        }
        try items.ensureTotalCapacity(allocator, encoded.list.len);
        for (encoded.list) |entry| {
            items.appendAssumeCapacity(try decodeValue(allocator, environment, entry));
        }
        return .{ .list = items };
    }
    if (std.mem.eql(u8, encoded.kind, "map")) {
        var entries: std.ArrayListUnmanaged(value.MapEntry) = .empty;
        errdefer {
            for (entries.items) |*entry| {
                entry.key.deinit(allocator);
                entry.value.deinit(allocator);
            }
            entries.deinit(allocator);
        }
        try entries.ensureTotalCapacity(allocator, encoded.map.len);
        for (encoded.map) |entry| {
            entries.appendAssumeCapacity(.{
                .key = try decodeValue(allocator, environment, entry.key),
                .value = try decodeValue(allocator, environment, entry.value),
            });
        }
        return .{ .map = entries };
    }

    return error.SkipZigTest;
}

fn parseType(environment: *env.Env, text: []const u8) anyerror!types.TypeRef {
    if (std.mem.eql(u8, text, "dyn")) return environment.types.builtins.dyn_type;
    if (std.mem.eql(u8, text, "null")) return environment.types.builtins.null_type;
    if (std.mem.eql(u8, text, "bool")) return environment.types.builtins.bool_type;
    if (std.mem.eql(u8, text, "int")) return environment.types.builtins.int_type;
    if (std.mem.eql(u8, text, "uint")) return environment.types.builtins.uint_type;
    if (std.mem.eql(u8, text, "double")) return environment.types.builtins.double_type;
    if (std.mem.eql(u8, text, "string")) return environment.types.builtins.string_type;
    if (std.mem.eql(u8, text, "bytes")) return environment.types.builtins.bytes_type;
    if (std.mem.eql(u8, text, "type")) return environment.types.builtins.type_type;
    if (std.mem.startsWith(u8, text, "list(") and std.mem.endsWith(u8, text, ")")) {
        const inner = text[5 .. text.len - 1];
        return environment.types.listOf(try parseType(environment, inner));
    }
    if (std.mem.startsWith(u8, text, "map(") and std.mem.endsWith(u8, text, ")")) {
        const inner = text[4 .. text.len - 1];
        const comma = splitTopLevelTypeArgs(inner) orelse return error.InvalidType;
        const key = std.mem.trim(u8, inner[0..comma], " ");
        const value_text = std.mem.trim(u8, inner[comma + 1 ..], " ");
        return environment.types.mapOf(try parseType(environment, key), try parseType(environment, value_text));
    }
    if (std.mem.startsWith(u8, text, "message(") and std.mem.endsWith(u8, text, ")")) {
        const name = text[8 .. text.len - 1];
        if (std.mem.eql(u8, name, "google.protobuf.Timestamp")) return environment.types.builtins.timestamp_type;
        if (std.mem.eql(u8, name, "google.protobuf.Duration")) return environment.types.builtins.duration_type;
        return environment.types.messageOf(name);
    }
    if (std.mem.startsWith(u8, text, "enum(") and std.mem.endsWith(u8, text, ")")) {
        return environment.types.enumOf(text[5 .. text.len - 1]);
    }
    if (std.mem.startsWith(u8, text, "abstract(") and std.mem.endsWith(u8, text, ")")) {
        return parseAbstractType(environment, text[9 .. text.len - 1]);
    }
    if (std.mem.startsWith(u8, text, "type_param(") and std.mem.endsWith(u8, text, ")")) {
        return environment.types.typeParamOf(text[11 .. text.len - 1]);
    }
    if (std.mem.startsWith(u8, text, "wrapper(") and std.mem.endsWith(u8, text, ")")) {
        return environment.types.wrapperOf(try parseType(environment, text[8 .. text.len - 1]));
    }
    return error.InvalidType;
}

fn parseAbstractType(environment: *env.Env, text: []const u8) anyerror!types.TypeRef {
    const lt = std.mem.indexOfScalar(u8, text, '<') orelse return environment.types.abstractOf(text);
    if (text.len == 0 or text[text.len - 1] != '>') return error.InvalidType;
    const name = std.mem.trim(u8, text[0..lt], " ");
    const inner = text[lt + 1 .. text.len - 1];

    var params: std.ArrayListUnmanaged(types.TypeRef) = .empty;
    defer params.deinit(std.testing.allocator);

    var start: usize = 0;
    while (start <= inner.len) {
        const next = splitTopLevelGenericArgs(inner[start..]) orelse inner.len - start;
        const part = std.mem.trim(u8, inner[start .. start + next], " ");
        if (part.len == 0) return error.InvalidType;
        try params.append(std.testing.allocator, try parseType(environment, part));
        start += next;
        if (start >= inner.len) break;
        start += 1;
    }
    return environment.types.abstractOfParams(name, params.items);
}

fn decodeObjectValue(allocator: std.mem.Allocator, environment: *env.Env, encoded: JsonValue) !value.Value {
    const type_url = encoded.object_type_url orelse return error.InvalidValue;
    const base64 = encoded.object_base64 orelse "";
    const payload_len = std.base64.standard.Decoder.calcSizeForSlice(base64) catch return error.InvalidValue;
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    try std.base64.standard.Decoder.decode(payload, base64);
    const prefix = "type.googleapis.com/";
    if (!std.mem.startsWith(u8, type_url, prefix)) return error.SkipZigTest;
    return protobuf.decodeMessage(allocator, environment, type_url[prefix.len..], payload[0..payload_len]);
}

fn conformanceValueEqual(lhs: value.Value, rhs: value.Value) bool {
    const lhs_tag = std.meta.activeTag(lhs);
    const rhs_tag = std.meta.activeTag(rhs);
    if (lhs_tag != rhs_tag) return false;

    return switch (lhs) {
        .int => lhs.int == rhs.int,
        .uint => lhs.uint == rhs.uint,
        .double => blk: {
            if (std.math.isNan(lhs.double) or std.math.isNan(rhs.double)) break :blk false;
            break :blk lhs.double == rhs.double;
        },
        .bool => lhs.bool == rhs.bool,
        .string => std.mem.eql(u8, lhs.string, rhs.string),
        .bytes => std.mem.eql(u8, lhs.bytes, rhs.bytes),
        .timestamp => lhs.timestamp.seconds == rhs.timestamp.seconds and lhs.timestamp.nanos == rhs.timestamp.nanos,
        .duration => lhs.duration.seconds == rhs.duration.seconds and lhs.duration.nanos == rhs.duration.nanos,
        .enum_value => lhs.enum_value.value == rhs.enum_value.value and
            std.mem.eql(u8, lhs.enum_value.type_name, rhs.enum_value.type_name),
        .host => lhs.eql(rhs),
        .null => true,
        .unknown => lhs.unknown.eql(&rhs.unknown),
        .optional => |opt| blk: {
            if (opt.value == null) break :blk rhs.optional.value == null;
            if (rhs.optional.value == null) break :blk false;
            break :blk conformanceValueEqual(opt.value.?.*, rhs.optional.value.?.*);
        },
        .type_name => std.mem.eql(u8, lhs.type_name, rhs.type_name),
        .list => |items| blk: {
            if (items.items.len != rhs.list.items.len) break :blk false;
            for (items.items, rhs.list.items) |left_item, right_item| {
                if (!conformanceValueEqual(left_item, right_item)) break :blk false;
            }
            break :blk true;
        },
        .map => |entries| blk: {
            if (entries.items.len != rhs.map.items.len) break :blk false;
            for (entries.items) |left_entry| {
                var found = false;
                for (rhs.map.items) |right_entry| {
                    if (!conformanceValueEqual(left_entry.key, right_entry.key)) continue;
                    if (!conformanceValueEqual(left_entry.value, right_entry.value)) break :blk false;
                    found = true;
                    break;
                }
                if (!found) break :blk false;
            }
            break :blk true;
        },
        .message => |msg| blk: {
            if (!std.mem.eql(u8, msg.name, rhs.message.name)) break :blk false;
            if (msg.fields.items.len != rhs.message.fields.items.len) break :blk false;
            for (msg.fields.items) |left_field| {
                var found = false;
                for (rhs.message.fields.items) |right_field| {
                    if (!std.mem.eql(u8, left_field.name, right_field.name)) continue;
                    if (!conformanceValueEqual(left_field.value, right_field.value)) break :blk false;
                    found = true;
                    break;
                }
                if (!found) break :blk false;
            }
            break :blk true;
        },
    };
}

fn loadDescriptorSummary(allocator: std.mem.Allocator) !DescriptorSummary {
    const json_data = readFileAlloc(allocator, ".cache/conformance/descriptors.json", 8 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    return try std.json.parseFromSliceLeaky(DescriptorSummary, allocator, json_data, .{
        .ignore_unknown_fields = false,
    });
}

fn installDescriptorSummary(environment: *env.Env, summary: DescriptorSummary) !void {
    for (summary.enums) |enum_value| {
        const split = std.mem.lastIndexOfScalar(u8, enum_value.name, '.') orelse return error.InvalidValue;
        const enum_name = enum_value.name[0..split];
        const member_name = enum_value.name[split + 1 ..];
        try environment.addEnumValue(enum_name, member_name, enum_value.value);
    }
    for (summary.messages) |message_desc| {
        _ = try environment.addMessageWithKind(message_desc.name, try parseMessageKind(message_desc.kind));
        for (message_desc.fields) |field_desc| {
            try installDescriptorField(environment, message_desc.name, field_desc);
        }
    }
    for (summary.extensions) |extension_desc| {
        try installDescriptorField(environment, extension_desc.extendee, extension_desc.field);
        try environment.addConst(
            extension_desc.field.name,
            environment.types.builtins.string_type,
            try value.string(environment.allocator, extension_desc.field.name),
        );
    }
}

fn installDescriptorField(environment: *env.Env, message_name: []const u8, field_desc: FieldDescriptor) !void {
    var field_ty = try parseType(environment, field_desc.type);
    field_ty = try normalizeFieldTypeForMode(environment, field_ty);
    if (field_desc.encoding.kind.len != 0 and std.mem.eql(u8, field_desc.encoding.kind, "singular")) {
        if (field_desc.encoding.message) |message_name_ref| {
            if (environment.lookupMessage(message_name_ref)) |wrapper_desc| {
                if (schema.isWrapperKind(wrapper_desc.kind)) {
                    field_ty = try environment.types.wrapperOf(field_ty);
                }
            }
        }
    }
    var default_value = if (field_desc.default) |default_raw| try parseFieldDefault(environment.allocator, default_raw) else null;
    defer if (default_value) |*default_field| default_field.deinit(environment.allocator);
    try environment.addProtobufFieldWithOptions(
        message_name,
        field_desc.name,
        @intCast(field_desc.number),
        field_ty,
        try parseFieldEncoding(field_desc.encoding),
        if (field_desc.has_presence) .explicit else .implicit,
        default_value,
    );
}

fn parseMessageKind(text: []const u8) !schema.MessageKind {
    if (std.mem.eql(u8, text, "plain")) return .plain;
    if (std.mem.eql(u8, text, "timestamp")) return .timestamp;
    if (std.mem.eql(u8, text, "duration")) return .duration;
    if (std.mem.eql(u8, text, "any")) return .any;
    if (std.mem.eql(u8, text, "value")) return .value;
    if (std.mem.eql(u8, text, "struct_value")) return .struct_value;
    if (std.mem.eql(u8, text, "list_value")) return .list_value;
    if (std.mem.eql(u8, text, "bool_wrapper")) return .bool_wrapper;
    if (std.mem.eql(u8, text, "bytes_wrapper")) return .bytes_wrapper;
    if (std.mem.eql(u8, text, "double_wrapper")) return .double_wrapper;
    if (std.mem.eql(u8, text, "float_wrapper")) return .float_wrapper;
    if (std.mem.eql(u8, text, "int32_wrapper")) return .int32_wrapper;
    if (std.mem.eql(u8, text, "int64_wrapper")) return .int64_wrapper;
    if (std.mem.eql(u8, text, "string_wrapper")) return .string_wrapper;
    if (std.mem.eql(u8, text, "uint32_wrapper")) return .uint32_wrapper;
    if (std.mem.eql(u8, text, "uint64_wrapper")) return .uint64_wrapper;
    return error.InvalidValue;
}

fn parseFieldEncoding(encoded: FieldEncodingDescriptor) !schema.FieldEncoding {
    if (std.mem.eql(u8, encoded.kind, "singular")) {
        return .{ .singular = try parseProtoValue(encoded.scalar, encoded.message) };
    }
    if (std.mem.eql(u8, encoded.kind, "repeated")) {
        return .{ .repeated = .{
            .element = try parseProtoValue(encoded.scalar, encoded.message),
            .@"packed" = encoded.@"packed",
        } };
    }
    if (std.mem.eql(u8, encoded.kind, "map")) {
        return .{ .map = .{
            .key = try parseProtoScalar(encoded.map_key_scalar orelse return error.InvalidValue),
            .value = try parseProtoValue(
                if (encoded.map_value_kind != null and std.mem.eql(u8, encoded.map_value_kind.?, "scalar")) encoded.map_value_type else null,
                if (encoded.map_value_kind != null and std.mem.eql(u8, encoded.map_value_kind.?, "message")) encoded.map_value_type else null,
            ),
        } };
    }
    return error.InvalidValue;
}

fn parseProtoValue(scalar: ?[]const u8, message: ?[]const u8) !schema.ProtoValueType {
    if (scalar) |name| return .{ .scalar = try parseProtoScalar(name) };
    if (message) |name| return .{ .message = name };
    return error.InvalidValue;
}

fn parseProtoScalar(text: []const u8) !schema.ProtoScalarKind {
    if (std.mem.eql(u8, text, "bool")) return .bool;
    if (std.mem.eql(u8, text, "int32")) return .int32;
    if (std.mem.eql(u8, text, "int64")) return .int64;
    if (std.mem.eql(u8, text, "sint32")) return .sint32;
    if (std.mem.eql(u8, text, "sint64")) return .sint64;
    if (std.mem.eql(u8, text, "uint32")) return .uint32;
    if (std.mem.eql(u8, text, "uint64")) return .uint64;
    if (std.mem.eql(u8, text, "fixed32")) return .fixed32;
    if (std.mem.eql(u8, text, "fixed64")) return .fixed64;
    if (std.mem.eql(u8, text, "sfixed32")) return .sfixed32;
    if (std.mem.eql(u8, text, "sfixed64")) return .sfixed64;
    if (std.mem.eql(u8, text, "float")) return .float;
    if (std.mem.eql(u8, text, "double")) return .double;
    if (std.mem.eql(u8, text, "string")) return .string;
    if (std.mem.eql(u8, text, "bytes")) return .bytes;
    if (std.mem.eql(u8, text, "enum_value")) return .enum_value;
    return error.InvalidValue;
}

fn parseFieldDefault(allocator: std.mem.Allocator, encoded: JsonValue) !schema.FieldDefault {
    if (std.mem.eql(u8, encoded.kind, "bool")) return .{ .bool = encoded.bool orelse return error.InvalidValue };
    if (std.mem.eql(u8, encoded.kind, "int")) return .{ .int = try std.fmt.parseInt(i64, encoded.int orelse return error.InvalidValue, 10) };
    if (std.mem.eql(u8, encoded.kind, "uint")) return .{ .uint = try std.fmt.parseInt(u64, encoded.uint orelse return error.InvalidValue, 10) };
    if (std.mem.eql(u8, encoded.kind, "double")) return .{ .double = try std.fmt.parseFloat(f64, encoded.double orelse return error.InvalidValue) };
    if (std.mem.eql(u8, encoded.kind, "string")) return .{ .string = try allocator.dupe(u8, encoded.string orelse "") };
    if (std.mem.eql(u8, encoded.kind, "bytes")) return blk: {
        const src = encoded.base64 orelse "";
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(src) catch return error.InvalidValue;
        const buffer = try allocator.alloc(u8, decoded_len);
        errdefer allocator.free(buffer);
        try std.base64.standard.Decoder.decode(buffer, src);
        break :blk .{ .bytes = buffer[0..decoded_len] };
    };
    if (std.mem.eql(u8, encoded.kind, "enum")) return .{ .int = encoded.enum_value orelse return error.InvalidValue };
    return error.InvalidValue;
}

fn enumModeForSection(section: []const u8) env.EnumMode {
    if (std.mem.startsWith(u8, section, "strong_")) return .strong;
    return .legacy;
}

fn normalizeFieldTypeForMode(environment: *env.Env, ty: types.TypeRef) !types.TypeRef {
    if (environment.enum_mode == .strong) return ty;
    return switch (environment.types.spec(ty)) {
        .enum_type => environment.types.builtins.int_type,
        .list => |elem| environment.types.listOf(try normalizeFieldTypeForMode(environment, elem)),
        .map => |pair| environment.types.mapOf(
            try normalizeFieldTypeForMode(environment, pair.key),
            try normalizeFieldTypeForMode(environment, pair.value),
        ),
        .wrapper => |inner| environment.types.wrapperOf(try normalizeFieldTypeForMode(environment, inner)),
        .abstract => |abstract_ty| blk: {
            var params = std.ArrayListUnmanaged(types.TypeRef).empty;
            defer params.deinit(std.testing.allocator);
            try params.ensureTotalCapacity(std.testing.allocator, abstract_ty.params.len);
            for (abstract_ty.params) |param| {
                params.appendAssumeCapacity(try normalizeFieldTypeForMode(environment, param));
            }
            break :blk environment.types.abstractOfParams(abstract_ty.name, params.items);
        },
        else => ty,
    };
}

fn splitTopLevelTypeArgs(text: []const u8) ?usize {
    var paren_depth: usize = 0;
    var angle_depth: usize = 0;
    for (text, 0..) |ch, i| {
        switch (ch) {
            '(' => paren_depth += 1,
            ')' => paren_depth -= 1,
            '<' => angle_depth += 1,
            '>' => angle_depth -= 1,
            ',' => if (paren_depth == 0 and angle_depth == 0) return i,
            else => {},
        }
    }
    return null;
}

fn splitTopLevelGenericArgs(text: []const u8) ?usize {
    return splitTopLevelTypeArgs(text);
}

fn formatType(environment: *env.Env, ty: types.TypeRef, buffer: []u8) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    defer list.deinit(std.testing.allocator);
    try writeType(environment, &list, ty);
    if (list.items.len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..list.items.len], list.items);
    return buffer[0..list.items.len];
}

fn writeType(environment: *env.Env, out: *std.ArrayListUnmanaged(u8), ty: types.TypeRef) !void {
    const allocator = std.testing.allocator;
    switch (environment.types.spec(ty)) {
        .dyn => try out.appendSlice(allocator, "dyn"),
        .null_type => try out.appendSlice(allocator, "null"),
        .bool => try out.appendSlice(allocator, "bool"),
        .int => try out.appendSlice(allocator, "int"),
        .uint => try out.appendSlice(allocator, "uint"),
        .double => try out.appendSlice(allocator, "double"),
        .string => try out.appendSlice(allocator, "string"),
        .bytes => try out.appendSlice(allocator, "bytes"),
        .type_type => try out.appendSlice(allocator, "type"),
        .list => |elem| {
            try out.appendSlice(allocator, "list(");
            try writeType(environment, out, elem);
            try out.appendSlice(allocator, ")");
        },
        .map => |pair| {
            try out.appendSlice(allocator, "map(");
            try writeType(environment, out, pair.key);
            try out.appendSlice(allocator, ", ");
            try writeType(environment, out, pair.value);
            try out.appendSlice(allocator, ")");
        },
        .enum_type => |name| try appendFormat(out, allocator, "enum({s})", .{name}),
        .message => |name| try appendFormat(out, allocator, "message({s})", .{name}),
        .abstract => |abstract_ty| {
            try out.appendSlice(allocator, "abstract(");
            try out.appendSlice(allocator, abstract_ty.name);
            if (abstract_ty.params.len != 0) {
                try out.appendSlice(allocator, "<");
                for (abstract_ty.params, 0..) |param, i| {
                    if (i != 0) try out.appendSlice(allocator, ", ");
                    try writeType(environment, out, param);
                }
                try out.appendSlice(allocator, ">");
            }
            try out.appendSlice(allocator, ")");
        },
        .wrapper => |inner| {
            try out.appendSlice(allocator, "wrapper(");
            try writeType(environment, out, inner);
            try out.appendSlice(allocator, ")");
        },
        .host_scalar => |name| try out.appendSlice(allocator, name),
        .type_param => |name| try appendFormat(out, allocator, "type_param({s})", .{name}),
    }
}
