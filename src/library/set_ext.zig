const std = @import("std");
const cel_env = @import("../env/env.zig");
const types = @import("../env/types.zig");
const value = @import("../env/value.zig");

pub const set_library = cel_env.Library{
    .name = "cel.lib.ext.sets",
    .install = installSetLibrary,
};

fn installSetLibrary(environment: *cel_env.Env) !void {
    _ = try environment.addDynamicFunction("sets.contains", false, matchTwoLists, evalSetsContains);
    _ = try environment.addDynamicFunction("sets.equivalent", false, matchTwoLists, evalSetsEquivalent);
    _ = try environment.addDynamicFunction("sets.intersects", false, matchTwoLists, evalSetsIntersects);
}

fn matchTwoLists(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 2) return null;
    if (!isListLike(environment, params[0])) return null;
    if (!isListLike(environment, params[1])) return null;
    return environment.types.builtins.bool_type;
}

fn isListLike(environment: *const cel_env.Env, actual: types.TypeRef) bool {
    return switch (environment.types.spec(actual)) {
        .list, .dyn => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// sets.contains(list, subset) — all elements of subset are in list
// ---------------------------------------------------------------------------

fn evalSetsContains(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 2 or args[0] != .list or args[1] != .list) return value.RuntimeError.TypeMismatch;
    const haystack = args[0].list.items;
    const needles = args[1].list.items;

    for (needles) |needle| {
        var found = false;
        for (haystack) |hay| {
            if (needle.eql(hay)) {
                found = true;
                break;
            }
        }
        if (!found) return .{ .bool = false };
    }
    return .{ .bool = true };
}

// ---------------------------------------------------------------------------
// sets.equivalent(a, b) — same elements regardless of order/duplicates
// ---------------------------------------------------------------------------

fn evalSetsEquivalent(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 2 or args[0] != .list or args[1] != .list) return value.RuntimeError.TypeMismatch;
    const a = args[0].list.items;
    const b = args[1].list.items;

    // Every element of a must be in b.
    for (a) |item_a| {
        var found = false;
        for (b) |item_b| {
            if (item_a.eql(item_b)) {
                found = true;
                break;
            }
        }
        if (!found) return .{ .bool = false };
    }
    // Every element of b must be in a.
    for (b) |item_b| {
        var found = false;
        for (a) |item_a| {
            if (item_b.eql(item_a)) {
                found = true;
                break;
            }
        }
        if (!found) return .{ .bool = false };
    }
    return .{ .bool = true };
}

// ---------------------------------------------------------------------------
// sets.intersects(a, b) — any common element
// ---------------------------------------------------------------------------

fn evalSetsIntersects(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 2 or args[0] != .list or args[1] != .list) return value.RuntimeError.TypeMismatch;
    const a = args[0].list.items;
    const b = args[1].list.items;

    for (a) |item_a| {
        for (b) |item_b| {
            if (item_a.eql(item_b)) return .{ .bool = true };
        }
    }
    return .{ .bool = false };
}

// ===========================================================================
// Tests
// ===========================================================================

const compile_mod = @import("../compiler/compile.zig");
const eval_impl = @import("../eval/eval.zig");
const Activation = @import("../eval/activation.zig").Activation;

test "sets.contains" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(set_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        .{ .expr = "sets.contains([1,2,3], [1,2])", .expected = true },
        .{ .expr = "sets.contains([1,2,3], [1,2,3])", .expected = true },
        .{ .expr = "sets.contains([1,2,3], [])", .expected = true },
        .{ .expr = "sets.contains([], [])", .expected = true },
        .{ .expr = "sets.contains([1,2,3], [4])", .expected = false },
        .{ .expr = "sets.contains([1,2,3], [1,4])", .expected = false },
        .{ .expr = "sets.contains([], [1])", .expected = false },
        .{ .expr = "sets.contains([1,2,2,3], [2])", .expected = true },
        .{ .expr = "sets.contains([1,2,3], [3,2,1])", .expected = true },
        .{ .expr = "sets.contains([1], [1,1,1])", .expected = true },
    };
    for (cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.bool);
    }
}

test "sets.equivalent" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(set_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        .{ .expr = "sets.equivalent([1,2], [2,1])", .expected = true },
        .{ .expr = "sets.equivalent([1,2,3], [3,2,1])", .expected = true },
        .{ .expr = "sets.equivalent([], [])", .expected = true },
        .{ .expr = "sets.equivalent([1], [1])", .expected = true },
        .{ .expr = "sets.equivalent([1,1,2], [1,2,2])", .expected = true },
        .{ .expr = "sets.equivalent([1,2], [1,2,3])", .expected = false },
        .{ .expr = "sets.equivalent([1,2,3], [1,2])", .expected = false },
        .{ .expr = "sets.equivalent([1], [2])", .expected = false },
        .{ .expr = "sets.equivalent([], [1])", .expected = false },
        .{ .expr = "sets.equivalent([1], [])", .expected = false },
    };
    for (cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.bool);
    }
}

test "sets.intersects" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(set_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        .{ .expr = "sets.intersects([1,2], [2,3])", .expected = true },
        .{ .expr = "sets.intersects([1,2,3], [3,4,5])", .expected = true },
        .{ .expr = "sets.intersects([1], [1])", .expected = true },
        .{ .expr = "sets.intersects([1,2], [3,4])", .expected = false },
        .{ .expr = "sets.intersects([], [])", .expected = false },
        .{ .expr = "sets.intersects([1,2], [])", .expected = false },
        .{ .expr = "sets.intersects([], [1,2])", .expected = false },
        .{ .expr = "sets.intersects([1,1,1], [1])", .expected = true },
        .{ .expr = "sets.intersects([1,2,3], [4,5,6])", .expected = false },
        .{ .expr = "sets.intersects([1,2,3], [3])", .expected = true },
    };
    for (cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.bool);
    }
}

test "sets.* honor CEL == semantics for cross-type, NaN, and maps" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(set_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        // Cross-type numeric: 1u == 1 in CEL, so contains/equivalent must agree.
        .{ .expr = "sets.contains([1u], [1])", .expected = true },
        .{ .expr = "sets.contains([1], [1u])", .expected = true },
        .{ .expr = "sets.equivalent([1u, 2], [1, 2u])", .expected = true },
        .{ .expr = "sets.intersects([1.0], [1])", .expected = true },
        // NaN is never equal to itself in CEL, so no NaN element can be matched.
        .{ .expr = "sets.contains([double('NaN')], [double('NaN')])", .expected = false },
        .{ .expr = "sets.intersects([double('NaN')], [double('NaN')])", .expected = false },
        // Map equality is order-independent in CEL `==`.
        .{ .expr = "sets.contains([{'a': 1, 'b': 2}], [{'b': 2, 'a': 1}])", .expected = true },
        .{ .expr = "sets.equivalent([{'a': 1, 'b': 2}], [{'b': 2, 'a': 1}])", .expected = true },
    };
    for (cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.bool);
    }
}
