const std = @import("std");
const ast = @import("../parse/ast.zig");
const checker = @import("../checker/check.zig");
const env = @import("../env/env.zig");
const parser = @import("../parse/parser.zig");
const prepare = @import("prepare.zig");
const program = @import("program.zig");
const types = @import("../env/types.zig");

pub const Error = checker.Error;
pub const Program = program.Program;
pub const PrepareError = prepare.PrepareError;

pub fn compile(
    allocator: std.mem.Allocator,
    environment: *env.Env,
    source: []const u8,
) Error!Program {
    return checker.compile(allocator, environment, source);
}

pub fn compileUnchecked(
    allocator: std.mem.Allocator,
    environment: *env.Env,
    source: []const u8,
) parser.Error!Program {
    return checker.compileUnchecked(allocator, environment, source);
}

pub fn compileParsed(
    analysis_allocator: std.mem.Allocator,
    environment: *env.Env,
    tree: ast.Ast,
) Error!Program {
    return checker.compileParsed(analysis_allocator, environment, tree);
}

pub fn compileParsedUnchecked(
    analysis_allocator: std.mem.Allocator,
    environment: *env.Env,
    tree: ast.Ast,
) parser.Error!Program {
    return checker.compileParsedUnchecked(analysis_allocator, environment, tree);
}

pub fn prepareEnvironment(environment: *env.Env) PrepareError!void {
    return prepare.prepareEnvironment(environment);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "compile simple expressions" {
    const allocator = std.testing.allocator;
    var environment = try env.Env.initDefault(allocator);
    defer environment.deinit();

    const cases = [_][]const u8{
        "1 + 2",
        "true",
        "\"hello\"",
        "1 == 1",
        "true && false",
    };

    for (cases) |source| {
        var prog = try compile(allocator, &environment, source);
        defer prog.deinit();
    }
}

test "compile with type-checked result types" {
    const allocator = std.testing.allocator;
    var environment = try env.Env.initDefault(allocator);
    defer environment.deinit();

    const cases = [_]struct { source: []const u8, expected_type: types.TypeRef }{
        .{ .source = "1 + 2", .expected_type = environment.types.builtins.int_type },
        .{ .source = "true", .expected_type = environment.types.builtins.bool_type },
        .{ .source = "\"hello\"", .expected_type = environment.types.builtins.string_type },
        .{ .source = "1.5", .expected_type = environment.types.builtins.double_type },
        .{ .source = "null", .expected_type = environment.types.builtins.null_type },
    };

    for (cases) |c| {
        var prog = try compile(allocator, &environment, c.source);
        defer prog.deinit();
        try std.testing.expectEqual(c.expected_type, prog.result_type);
    }
}

test "compile rejects undefined identifier" {
    const allocator = std.testing.allocator;
    var environment = try env.Env.initDefault(allocator);
    defer environment.deinit();

    const result = compile(allocator, &environment, "undefined_var");
    try std.testing.expectError(error.UndefinedIdentifier, result);
}

test "compile rejects invalid binary operand types" {
    const allocator = std.testing.allocator;
    var environment = try env.Env.initDefault(allocator);
    defer environment.deinit();

    const result = compile(allocator, &environment, "1 + \"hello\"");
    try std.testing.expectError(error.InvalidBinaryOperand, result);
}

test "compile with declared variable succeeds" {
    const allocator = std.testing.allocator;
    var environment = try env.Env.initDefault(allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.int_type);

    var prog = try compile(allocator, &environment, "x + 1");
    defer prog.deinit();
    try std.testing.expectEqual(environment.types.builtins.int_type, prog.result_type);
}

test "compile list and map literals" {
    const allocator = std.testing.allocator;
    var environment = try env.Env.initDefault(allocator);
    defer environment.deinit();

    const cases = [_][]const u8{
        "[1, 2, 3]",
        "{\"a\": 1, \"b\": 2}",
    };

    for (cases) |source| {
        var prog = try compile(allocator, &environment, source);
        defer prog.deinit();
    }
}

test "compile ternary conditional" {
    const allocator = std.testing.allocator;
    var environment = try env.Env.initDefault(allocator);
    defer environment.deinit();

    var prog = try compile(allocator, &environment, "true ? 1 : 2");
    defer prog.deinit();
    try std.testing.expectEqual(environment.types.builtins.int_type, prog.result_type);
}

test "compile parse error on malformed input" {
    const allocator = std.testing.allocator;
    var environment = try env.Env.initDefault(allocator);
    defer environment.deinit();

    const bad_cases = [_][]const u8{
        "",
        "1 +",
        "(((",
    };

    for (bad_cases) |source| {
        const result = compile(allocator, &environment, source);
        try std.testing.expect(if (result) |_| false else |_| true);
        if (result) |_| {} else |_| {}
    }
}
