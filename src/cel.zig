const std = @import("std");

// ---------------------------------------------------------------------------
// Submodule namespaces — access internals via cel.parse.ast, cel.eval.partial, etc.
// ---------------------------------------------------------------------------

pub const parse = @import("parse.zig");
pub const checker = @import("checker.zig");
pub const compiler = @import("compiler.zig");
pub const env = @import("env.zig");
pub const eval = @import("eval.zig");
pub const library = @import("library.zig");
pub const types = @import("types.zig");
pub const util = @import("util.zig");

// ---------------------------------------------------------------------------
// Top-level convenience aliases
// ---------------------------------------------------------------------------

pub const Env = env.Env;
pub const EnvOption = env.EnvOption;
pub const Library = env.Library;
pub const TypeProvider = env.TypeProvider;
pub const Activation = eval.Activation;
pub const Program = compiler.Program;
pub const Value = types.Value;
pub const value = env.value;
pub const Type = types.Type;
pub const TypeRef = types.TypeRef;
pub const EvalOptions = eval.EvalOptions;
pub const EvalScratch = eval.EvalScratch;
pub const EvalState = eval.EvalState;
pub const TrackedResult = eval.TrackedResult;
pub const CostEstimate = eval.cost.CostEstimate;
pub const ValidationResult = checker.validate.ValidationResult;
pub const Decorator = eval.Decorator;
pub const NodeCounter = eval.NodeCounter;
pub const TraceCollector = eval.TraceCollector;

// Extension libraries
pub const strings = library.stdlib_ext.string_library;
pub const math = library.stdlib_ext.math_library;
pub const protos = library.stdlib_ext.proto_library;
pub const lists = library.list_ext.list_library;
pub const sets = library.set_ext.set_library;
pub const regex = library.cel_regex.regex_library;
pub const json = library.json_ext.json_library;
pub const maps = library.maps_ext.maps_library;
pub const format = library.format_ext.format_library;
pub const hash = library.hash_ext.hash_library;
pub const network = library.network_ext.library;
pub const semver = library.semver_ext.semver_library;
pub const urls = library.url_ext.urls_library;
pub const jsonpatch = library.jsonpatch_ext.jsonpatch_library;
pub const comprehensions = library.comprehensions_ext.two_var_comprehensions_library;

// ---------------------------------------------------------------------------
// EnvOption constructors
// ---------------------------------------------------------------------------

pub fn variable(name: []const u8, typ: Type) EnvOption {
    return .{ .variable = .{ .name = name, .type = typ } };
}

pub fn constant(name: []const u8, typ: Type, val: Value) EnvOption {
    return .{ .constant = .{ .name = name, .type = typ, .value = val } };
}

pub fn withLibrary(lib: Library) EnvOption {
    return .{ .library = lib };
}

pub fn container(scope: []const u8) EnvOption {
    return .{ .container = scope };
}

// ---------------------------------------------------------------------------
// CEL type constants (mirrors cel-go's cel.StringType, cel.IntType, etc.)
// ---------------------------------------------------------------------------

pub const StringType: Type = .string;
pub const IntType: Type = .int;
pub const UintType: Type = .uint;
pub const DoubleType: Type = .double;
pub const BoolType: Type = .boolean;
pub const BytesType: Type = .bytes;
pub const NullType: Type = .null_type;
pub const DynType: Type = .dyn;
pub const TimestampType: Type = .timestamp;
pub const DurationType: Type = .duration;

pub fn ListType(comptime elem: Type) Type {
    return Type.listOf(elem);
}

pub fn MapType(comptime key: Type, comptime val: Type) Type {
    return Type.mapOf(key, val);
}

pub fn OptionalType(comptime inner: Type) Type {
    return Type.optionalOf(inner);
}

pub fn ObjectType(comptime name: []const u8) Type {
    return .{ .message = name };
}

// Re-export type composite constructors (lowercase aliases)
pub const listOf = Type.listOf;
pub const mapOf = Type.mapOf;
pub const optionalOf = Type.optionalOf;

// ---------------------------------------------------------------------------
// Type definition helpers
// ---------------------------------------------------------------------------

pub const ObjectField = types.ObjectField;

pub fn field(name: []const u8, typ: Type) ObjectField {
    return .{ .name = name, .type = typ };
}

pub fn message(name: []const u8, fields: []const ObjectField) EnvOption {
    return .{ .object = .{ .name = name, .fields = fields } };
}

pub fn customTypes(provider: *types.TypeProvider) EnvOption {
    return .{ .custom_types = provider };
}

// ---------------------------------------------------------------------------
// Core API (free functions - delegate to methods on Env/Program)
// ---------------------------------------------------------------------------

pub fn parseExpr(
    allocator: std.mem.Allocator,
    source: []const u8,
) parse.parser.Error!parse.ast.Ast {
    return parse.parser.parse(allocator, source);
}

pub fn compile(
    allocator: std.mem.Allocator,
    environment: *Env,
    source: []const u8,
) checker.Error!Program {
    return compiler.compile.compile(allocator, environment, source);
}

pub fn compileOptimized(
    allocator: std.mem.Allocator,
    environment: *Env,
    source: []const u8,
) (checker.Error || error{OptimizationFailed})!Program {
    var program = try compile(allocator, environment, source);
    errdefer program.deinit();
    compiler.optimize.optimize(allocator, &program, environment, &.{
        compiler.optimize.constantFolding,
        compiler.optimize.precompileArguments,
    }) catch return error.OptimizationFailed;
    return program;
}

pub fn unparseProgram(allocator: std.mem.Allocator, program: *const Program) std.mem.Allocator.Error![]u8 {
    return parse.unparse.unparse(allocator, &program.ast);
}

pub fn compileParsed(
    analysis_allocator: std.mem.Allocator,
    environment: *Env,
    tree: parse.ast.Ast,
) checker.Error!Program {
    return compiler.compile.compileParsed(analysis_allocator, environment, tree);
}

pub fn compileUnchecked(
    allocator: std.mem.Allocator,
    environment: *Env,
    source: []const u8,
) parse.parser.Error!Program {
    return compiler.compile.compileUnchecked(allocator, environment, source);
}

pub fn compileParsedUnchecked(
    analysis_allocator: std.mem.Allocator,
    environment: *Env,
    tree: parse.ast.Ast,
) parse.parser.Error!Program {
    return compiler.compile.compileParsedUnchecked(analysis_allocator, environment, tree);
}

pub fn prepareEnvironment(environment: *Env) compiler.compile.PrepareError!void {
    return compiler.compile.prepareEnvironment(environment);
}

pub fn evaluate(
    allocator: std.mem.Allocator,
    program: *const Program,
    activation: *const Activation,
    options: EvalOptions,
) env.EvalError!Value {
    return program.evaluate(allocator, activation, options);
}

pub fn evaluateWithScratch(
    scratch: *EvalScratch,
    program: *const Program,
    activation: *const Activation,
) env.EvalError!Value {
    return eval.eval.evalWithScratch(scratch, program, activation);
}

pub fn evaluateBorrowedWithScratch(
    scratch: *EvalScratch,
    program: *const Program,
    activation: *const Activation,
) env.EvalError!Value {
    return eval.eval.evalBorrowedWithScratch(scratch, program, activation);
}

pub fn evaluateTracked(
    allocator: std.mem.Allocator,
    program: *const Program,
    activation: *const Activation,
) env.EvalError!eval.TrackedResult {
    return eval.eval.evalTracked(allocator, program, activation);
}

pub fn evaluateTrackedWithScratch(
    scratch: *EvalScratch,
    program: *const Program,
    activation: *const Activation,
) env.EvalError!eval.TrackedResult {
    return eval.eval.evalTrackedWithScratch(scratch, program, activation);
}

pub fn estimateCost(program: *const Program) CostEstimate {
    return eval.cost.estimateCost(program);
}

pub fn validateProgram(allocator: std.mem.Allocator, program: *const Program) !ValidationResult {
    return checker.validate.validateDefault(allocator, program);
}

// ---------------------------------------------------------------------------
// Compile diagnostics
// ---------------------------------------------------------------------------

pub const Diagnostic = struct {
    error_code: checker.Error,
    source: []const u8,
    message: []const u8,
    offset: u32,
    line: u32,
    column: u32,
    allocator: ?std.mem.Allocator,

    pub fn deinit(self: *Diagnostic) void {
        if (self.allocator) |a| a.free(self.message);
    }

    pub fn format(self: *const Diagnostic, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}:{d}: {s}", .{
            self.line,
            self.column,
            self.message,
        }) catch self.message;
    }
};

pub const CompileResult = union(enum) {
    ok: Program,
    err: Diagnostic,

    pub fn deinit(self: *CompileResult) void {
        switch (self.*) {
            .ok => |*p| p.deinit(),
            .err => |*d| d.deinit(),
        }
    }

    pub fn unwrap(self: CompileResult) checker.Error!Program {
        return switch (self) {
            .ok => |p| p,
            .err => |d| d.error_code,
        };
    }
};

pub fn compileWithDiagnostic(
    allocator: std.mem.Allocator,
    environment: *Env,
    source: []const u8,
) CompileResult {
    return .{ .ok = compiler.compile.compile(allocator, environment, source) catch |err| {
        const error_name = @errorName(err);
        const msg = allocator.dupe(u8, error_name) catch error_name;
        const has_alloc = if (msg.ptr != error_name.ptr) true else false;
        return .{ .err = .{
            .error_code = err,
            .source = source,
            .message = msg,
            .offset = 0,
            .line = 1,
            .column = 1,
            .allocator = if (has_alloc) allocator else null,
        } };
    } };
}

// ---------------------------------------------------------------------------
// Source caching (stores source text for later recompilation)
// ---------------------------------------------------------------------------

pub fn cacheSource(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "CEL0");
    const source_len: u32 = @intCast(source.len);
    try buf.appendSlice(allocator, std.mem.asBytes(&source_len));
    try buf.appendSlice(allocator, source);
    return buf.toOwnedSlice(allocator);
}

pub fn restoreFromSource(
    allocator: std.mem.Allocator,
    environment: *Env,
    data: []const u8,
) error{ InvalidData, OutOfMemory }!Program {
    if (data.len < 8) return error.InvalidData;
    if (!std.mem.eql(u8, data[0..4], "CEL0")) return error.InvalidData;
    const source_len = std.mem.readInt(u32, data[4..8], .little);
    if (source_len > data.len -| 8) return error.InvalidData;
    const source = data[8..][0..source_len];
    return compiler.compile.compile(allocator, environment, source) catch error.InvalidData;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    _ = parse;
    _ = checker;
    _ = compiler;
    _ = env;
    _ = eval;
    _ = library;
    _ = util;
}

test "Type resolves builtins correctly" {
    var provider = try env.types.TypeProvider.init(std.testing.allocator);
    defer provider.deinit();

    const cases = [_]struct { typ: Type, expected: TypeRef }{
        .{ .typ = StringType, .expected = provider.builtins.string_type },
        .{ .typ = IntType, .expected = provider.builtins.int_type },
        .{ .typ = UintType, .expected = provider.builtins.uint_type },
        .{ .typ = DoubleType, .expected = provider.builtins.double_type },
        .{ .typ = BoolType, .expected = provider.builtins.bool_type },
        .{ .typ = BytesType, .expected = provider.builtins.bytes_type },
        .{ .typ = NullType, .expected = provider.builtins.null_type },
        .{ .typ = DynType, .expected = provider.builtins.dyn_type },
        .{ .typ = TimestampType, .expected = provider.builtins.timestamp_type },
        .{ .typ = DurationType, .expected = provider.builtins.duration_type },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, try case.typ.resolve(&provider));
    }
}

test "Type resolves composites correctly" {
    var provider = try env.types.TypeProvider.init(std.testing.allocator);
    defer provider.deinit();

    const list_str = try ListType(StringType).resolve(&provider);
    const expected_list = try provider.listOf(provider.builtins.string_type);
    try std.testing.expectEqual(expected_list, list_str);

    const map_str_int = try MapType(StringType, IntType).resolve(&provider);
    const expected_map = try provider.mapOf(provider.builtins.string_type, provider.builtins.int_type);
    try std.testing.expectEqual(expected_map, map_str_int);

    const opt_bool = try OptionalType(BoolType).resolve(&provider);
    const expected_opt = try provider.optionalOf(provider.builtins.bool_type);
    try std.testing.expectEqual(expected_opt, opt_bool);

    const nested = try ListType(MapType(StringType, ListType(IntType))).resolve(&provider);
    const inner_list = try provider.listOf(provider.builtins.int_type);
    const inner_map = try provider.mapOf(provider.builtins.string_type, inner_list);
    const expected_nested = try provider.listOf(inner_map);
    try std.testing.expectEqual(expected_nested, nested);
}

test "Env.init with options" {
    var environment = try Env.init(std.testing.allocator, &.{
        variable("name", StringType),
        variable("age", IntType),
        variable("items", ListType(StringType)),
    });
    defer environment.deinit();

    try std.testing.expect(environment.lookupVar("name") != null);
    try std.testing.expect(environment.lookupVar("age") != null);
    try std.testing.expect(environment.lookupVar("items") != null);
    try std.testing.expect(environment.lookupVar("missing") == null);
}

test "message registers object with fields" {
    var environment = try Env.init(std.testing.allocator, &.{
        message("Point", &.{
            field("x", IntType),
            field("y", IntType),
        }),
        variable("p", ObjectType("Point")),
    });
    defer environment.deinit();

    // Type-checks field access on the defined type
    var program = try environment.compile("p.x + p.y");
    defer program.deinit();

    try std.testing.expect(environment.lookupVar("p") != null);
}

test "customTypes with external TypeProvider" {
    var provider = try std.testing.allocator.create(env.types.TypeProvider);
    provider.* = try env.types.TypeProvider.init(std.testing.allocator);
    defer {
        provider.deinit();
        std.testing.allocator.destroy(provider);
    }

    _ = try provider.defineMessage("Widget", &.{
        .{ .name = "name", .type = StringType },
        .{ .name = "count", .type = IntType },
    });

    var environment = try Env.init(std.testing.allocator, &.{
        customTypes(provider),
        variable("w", ObjectType("Widget")),
    });
    defer environment.deinit();

    var program = try environment.compile("w.name");
    defer program.deinit();

    try std.testing.expect(environment.lookupVar("w") != null);
}

test "Env.compile and Program.evaluate with struct context" {
    var environment = try Env.init(std.testing.allocator, &.{
        variable("name", StringType),
        variable("age", IntType),
        variable("active", BoolType),
        variable("score", DoubleType),
    });
    defer environment.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        .{ .expr = "name == 'Alice'", .expected = true },
        .{ .expr = "name == 'Bob'", .expected = false },
        .{ .expr = "age > 18", .expected = true },
        .{ .expr = "age < 10", .expected = false },
        .{ .expr = "active", .expected = true },
        .{ .expr = "!active", .expected = false },
        .{ .expr = "score > 3.0", .expected = true },
        .{ .expr = "score < 1.0", .expected = false },
        .{ .expr = "name == 'Alice' && age > 18 && active", .expected = true },
        .{ .expr = "name == 'Bob' || age > 100", .expected = false },
    };
    for (cases) |case| {
        var program = try environment.compile(case.expr);
        defer program.deinit();
        var result = try program.evaluate(std.testing.allocator, .{
            .name = "Alice",
            .age = @as(i64, 25),
            .active = true,
            .score = @as(f64, 3.14),
        }, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.bool);
    }
}

test "Program.evaluate with int expressions" {
    var environment = try Env.init(std.testing.allocator, &.{
        variable("x", IntType),
        variable("y", IntType),
    });
    defer environment.deinit();

    const cases = [_]struct { expr: []const u8, expected: i64 }{
        .{ .expr = "x + y", .expected = 42 },
        .{ .expr = "x - y", .expected = -22 },
        .{ .expr = "x * y", .expected = 320 },
        .{ .expr = "x + y + 8", .expected = 50 },
        .{ .expr = "x", .expected = 10 },
    };
    for (cases) |case| {
        var program = try environment.compile(case.expr);
        defer program.deinit();
        var result = try program.evaluate(std.testing.allocator, .{
            .x = @as(i64, 10),
            .y = @as(i64, 32),
        }, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.int);
    }
}

test "Program.evaluate with optional null" {
    var environment = try Env.init(std.testing.allocator, &.{
        variable("x", NullType),
    });
    defer environment.deinit();

    var program = try environment.compile("x == null");
    defer program.deinit();
    var result = try program.evaluate(std.testing.allocator, .{
        .x = @as(?i64, null),
    }, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(true, result.bool);
}

test "Program.evaluate with Activation" {
    var environment = try Env.init(std.testing.allocator, &.{});
    defer environment.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var p1 = try compile(std.testing.allocator, &environment, "true");
    defer p1.deinit();
    var r1 = try p1.evaluate(std.testing.allocator, &activation, .{});
    defer r1.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?bool, true), r1.toBool());
    try std.testing.expectEqual(@as(?i64, null), r1.toInt());

    var p2 = try compile(std.testing.allocator, &environment, "42");
    defer p2.deinit();
    var r2 = try p2.evaluate(std.testing.allocator, &activation, .{});
    defer r2.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?i64, 42), r2.toInt());

    var p3 = try compile(std.testing.allocator, &environment, "'hello'");
    defer p3.deinit();
    var r3 = try p3.evaluate(std.testing.allocator, &activation, .{});
    defer r3.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", r3.toString().?);

    var p4 = try compile(std.testing.allocator, &environment, "null");
    defer p4.deinit();
    var r4 = try p4.evaluate(std.testing.allocator, &activation, .{});
    defer r4.deinit(std.testing.allocator);
    try std.testing.expect(r4.isNull());
}

test "compileWithDiagnostic success and failure" {
    var environment = try Env.init(std.testing.allocator, &.{});
    defer environment.deinit();

    var ok = compileWithDiagnostic(std.testing.allocator, &environment, "1 + 2");
    defer ok.deinit();
    try std.testing.expect(ok == .ok);

    const error_cases = [_][]const u8{ "missing_var", "1 + 'x'", "(" };
    for (error_cases) |expr| {
        var result = compileWithDiagnostic(std.testing.allocator, &environment, expr);
        defer result.deinit();
        try std.testing.expect(result == .err);
    }
}

test "source cache roundtrip" {
    var environment = try Env.init(std.testing.allocator, &.{
        variable("x", IntType),
    });
    defer environment.deinit();

    const source = "x + 1";
    var program = try environment.compile(source);
    defer program.deinit();

    const data = try cacheSource(std.testing.allocator, source);
    defer std.testing.allocator.free(data);

    var restored = try restoreFromSource(std.testing.allocator, &environment, data);
    defer restored.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.put("x", .{ .int = 10 });

    var r1 = try program.evaluate(std.testing.allocator, &activation, .{});
    defer r1.deinit(std.testing.allocator);
    var r2 = try restored.evaluate(std.testing.allocator, &activation, .{});
    defer r2.deinit(std.testing.allocator);
    try std.testing.expectEqual(r1.toInt().?, r2.toInt().?);
}

test "budget enforcement" {
    var environment = try Env.init(std.testing.allocator, &.{
        variable("x", IntType),
    });
    defer environment.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.put("x", .{ .int = 10 });

    const cases = [_]struct { expr: []const u8, budget: u64, succeeds: bool }{
        .{ .expr = "1", .budget = 1, .succeeds = true },
        .{ .expr = "1", .budget = 0, .succeeds = false },
        .{ .expr = "1 + 2", .budget = 3, .succeeds = true },
        .{ .expr = "1 + 2", .budget = 1, .succeeds = false },
    };
    for (cases) |case| {
        var program = try environment.compile(case.expr);
        defer program.deinit();
        const result = program.evaluate(std.testing.allocator, &activation, .{ .budget = case.budget });
        if (case.succeeds) {
            var v = try result;
            defer v.deinit(std.testing.allocator);
        } else {
            try std.testing.expectError(error.CostBudgetExceeded, result);
        }
    }
}

test "restoreFromSource rejects invalid data" {
    var environment = try Env.init(std.testing.allocator, &.{});
    defer environment.deinit();

    const cases = [_][]const u8{ "", "CEL", "CEL0", "XXXX\x00\x00\x00\x00", "CEL0\xff\xff\xff\xff" };
    for (cases) |data| {
        try std.testing.expectError(error.InvalidData, restoreFromSource(std.testing.allocator, &environment, data));
    }
}

test "unparse preserves evaluation across grouping-sensitive expressions" {
    // String equality on the unparsed text proves the AST shape survives,
    // but what actually matters is that the unparsed expression evaluates
    // to the same value as the original. Subtraction, division, conditional
    // grouping, and string-concat-vs-conditional cases are all sensitive to
    // parenthesization in ways that would silently break with a buggy
    // unparser.
    var environment = try Env.init(std.testing.allocator, &.{
        variable("a", IntType),
        variable("b", IntType),
        variable("c", IntType),
        variable("x", BoolType),
        variable("y", StringType),
        variable("z", StringType),
    });
    defer environment.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.put("a", .{ .int = 1 });
    try activation.put("b", .{ .int = 2 });
    try activation.put("c", .{ .int = 3 });
    try activation.put("x", .{ .bool = true });
    try activation.putString("y", "Y");
    try activation.putString("z", "Z");

    const Expected = union(enum) { int: i64, string: []const u8 };
    const cases = [_]struct { expr: []const u8, expected: Expected }{
        // Subtraction is not associative — left-assoc is the default.
        .{ .expr = "a - b - c", .expected = .{ .int = -4 } },
        .{ .expr = "(a - b) - c", .expected = .{ .int = -4 } },
        .{ .expr = "a - (b - c)", .expected = .{ .int = 2 } },
        // Division precedence vs addition.
        .{ .expr = "a + b * c", .expected = .{ .int = 7 } },
        .{ .expr = "(a + b) * c", .expected = .{ .int = 9 } },
        // String concat with embedded conditional. The conditional must
        // re-parenthesize on round-trip or it would be reinterpreted as
        // the outermost operator and change the result type.
        .{ .expr = "\"a\" + (x ? y : z) + \"c\"", .expected = .{ .string = "aYc" } },
        // Right-associative conditional in else position.
        .{ .expr = "x ? \"first\" : x ? \"second\" : \"third\"", .expected = .{ .string = "first" } },
    };

    for (cases) |case| {
        // First evaluate the original expression.
        var prog1 = try environment.compile(case.expr);
        defer prog1.deinit();
        var v1 = try prog1.evaluate(std.testing.allocator, &activation, .{});
        defer v1.deinit(std.testing.allocator);

        // Unparse, re-compile, and evaluate again.
        const text = try unparseProgram(std.testing.allocator, &prog1);
        defer std.testing.allocator.free(text);
        var prog2 = try environment.compile(text);
        defer prog2.deinit();
        var v2 = try prog2.evaluate(std.testing.allocator, &activation, .{});
        defer v2.deinit(std.testing.allocator);

        // Both must agree with each other and with the expected value.
        switch (case.expected) {
            .int => |want| {
                try std.testing.expectEqual(want, v1.int);
                try std.testing.expectEqual(want, v2.int);
            },
            .string => |want| {
                try std.testing.expectEqualStrings(want, v1.string);
                try std.testing.expectEqualStrings(want, v2.string);
            },
        }
    }
}
