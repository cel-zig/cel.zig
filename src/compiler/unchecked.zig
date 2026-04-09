const std = @import("std");
const ast = @import("../parse/ast.zig");
const env = @import("../env/env.zig");
const parser = @import("../parse/parser.zig");
const compile_mod = @import("compile.zig");
const program = @import("program.zig");

pub const Program = program.Program;

pub fn compile(
    allocator: std.mem.Allocator,
    environment: *env.Env,
    source: []const u8,
) parser.Error!Program {
    return compile_mod.compileUnchecked(allocator, environment, source);
}

pub fn compileParsed(
    analysis_allocator: std.mem.Allocator,
    environment: *env.Env,
    tree: ast.Ast,
) parser.Error!Program {
    return compile_mod.compileParsedUnchecked(analysis_allocator, environment, tree);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const types = @import("../env/types.zig");

test "unchecked compile returns expected types for expressions" {
    const allocator = std.testing.allocator;
    var environment = try env.Env.initDefault(allocator);
    defer environment.deinit();

    const b = environment.types.builtins;
    const list_dyn = try environment.types.listOf(b.dyn_type);
    const map_dyn_dyn = try environment.types.mapOf(b.dyn_type, b.dyn_type);

    // Unchecked mode returns concrete types for literals and dyn for compound ops.
    const cases = [_]struct { expr: []const u8, expected: types.TypeRef }{
        .{ .expr = "1", .expected = b.int_type },
        .{ .expr = "1u", .expected = b.uint_type },
        .{ .expr = "1.5", .expected = b.double_type },
        .{ .expr = "\"hello\"", .expected = b.string_type },
        .{ .expr = "true", .expected = b.bool_type },
        .{ .expr = "null", .expected = b.null_type },
        .{ .expr = "1 + 2", .expected = b.dyn_type },
        .{ .expr = "1.5 * 3.0", .expected = b.dyn_type },
        .{ .expr = "[1, 2, 3]", .expected = list_dyn },
        .{ .expr = "{\"a\": 1}", .expected = map_dyn_dyn },
    };

    for (cases) |c| {
        var prog = try compile(allocator, &environment, c.expr);
        defer prog.deinit();
        try std.testing.expectEqual(c.expected, prog.result_type);
    }
}

test "unchecked compile does not reject undefined identifiers" {
    const allocator = std.testing.allocator;
    var environment = try env.Env.initDefault(allocator);
    defer environment.deinit();

    // In checked mode this would fail with UndefinedIdentifier.
    // Unchecked mode should accept it.
    var prog = try compile(allocator, &environment, "undefined_var");
    defer prog.deinit();
    try std.testing.expectEqual(environment.types.builtins.dyn_type, prog.result_type);
}

test "unchecked compile does not reject type mismatches" {
    const allocator = std.testing.allocator;
    var environment = try env.Env.initDefault(allocator);
    defer environment.deinit();

    const cases = [_][]const u8{
        "1 + \"hello\"",
        "true + 1",
    };

    for (cases) |expr| {
        var prog = try compile(allocator, &environment, expr);
        defer prog.deinit();
        try std.testing.expectEqual(environment.types.builtins.dyn_type, prog.result_type);
    }
}

test "unchecked compile still rejects parse errors" {
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

test "unchecked compile recognizes macros" {
    const allocator = std.testing.allocator;
    var environment = try env.Env.initDefault(allocator);
    defer environment.deinit();

    // has() is a well-known macro in CEL; unchecked returns bool_type for it.
    var prog = try compile(allocator, &environment, "has(x.y)");
    defer prog.deinit();
    try std.testing.expectEqual(environment.types.builtins.bool_type, prog.result_type);

    // Verify it recorded a macro call resolution.
    var found_macro = false;
    for (prog.call_resolution.items) |res| {
        switch (res) {
            .macro => |m| {
                if (m == .has) {
                    found_macro = true;
                    break;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(found_macro);
}
