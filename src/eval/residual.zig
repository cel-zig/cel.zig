const std = @import("std");
const ast = @import("../parse/ast.zig");
const unparse_mod = @import("../parse/unparse.zig");
const compiler_program = @import("../compiler/program.zig");
const checker = @import("../checker/check.zig");
const env = @import("../env/env.zig");
const eval = @import("eval.zig");
const value = @import("../env/value.zig");

pub const PartialEvaluation = struct {
    value: value.Value,
    residual: []u8,
    state: eval.EvalState,

    pub fn deinit(self: *PartialEvaluation) void {
        const allocator = self.state.allocator;
        self.value.deinit(allocator);
        allocator.free(self.residual);
        self.state.deinit();
    }
};

pub fn residualize(
    allocator: std.mem.Allocator,
    program: *const compiler_program.Program,
    state: *const eval.EvalState,
) ![]u8 {
    var ctx = ResidualCtx{
        .state = state,
    };
    var writer = unparse_mod.Writer{
        .allocator = allocator,
        .tree = &program.ast,
        .override = overrideNode,
        .override_ctx = @ptrCast(&ctx),
    };
    try writer.writeNode(program.ast.root.?, 0, .none);
    return writer.buffer.toOwnedSlice(allocator);
}

pub fn partialEvaluate(
    allocator: std.mem.Allocator,
    program: *const compiler_program.Program,
    activation: *const eval.Activation,
) env.EvalError!PartialEvaluation {
    var tracked = try eval.evalTracked(allocator, program, activation);
    errdefer tracked.deinit();

    return .{
        .value = tracked.value,
        .residual = try residualize(allocator, program, &tracked.state),
        .state = tracked.state,
    };
}

const ResidualCtx = struct {
    state: *const eval.EvalState,
};

fn overrideNode(ctx_ptr: *anyopaque, writer: *unparse_mod.Writer, index: ast.Index) std.mem.Allocator.Error!bool {
    const ctx: *ResidualCtx = @ptrCast(@alignCast(ctx_ptr));

    // If we have a known value for this node, emit it as a literal.
    if (ctx.state.get(index)) |known| {
        if (try writer.appendValueLiteral(known.*)) return true;
    }

    // Try simplification rewrites.
    const node = writer.tree.node(index);
    switch (node.data) {
        .binary => |binary| switch (binary.op) {
            .logical_or => {
                if (knownBool(ctx.state, binary.left)) |known| {
                    if (known) {
                        try writer.buffer.appendSlice(writer.allocator, "true");
                        return true;
                    }
                    try writer.writeNode(binary.right, 0, .none);
                    return true;
                }
                if (knownBool(ctx.state, binary.right)) |known| {
                    if (known) {
                        try writer.buffer.appendSlice(writer.allocator, "true");
                        return true;
                    }
                    try writer.writeNode(binary.left, 0, .none);
                    return true;
                }
            },
            .logical_and => {
                if (knownBool(ctx.state, binary.left)) |known| {
                    if (!known) {
                        try writer.buffer.appendSlice(writer.allocator, "false");
                        return true;
                    }
                    try writer.writeNode(binary.right, 0, .none);
                    return true;
                }
                if (knownBool(ctx.state, binary.right)) |known| {
                    if (!known) {
                        try writer.buffer.appendSlice(writer.allocator, "false");
                        return true;
                    }
                    try writer.writeNode(binary.left, 0, .none);
                    return true;
                }
            },
            .in_set => if (knownEmptyList(ctx.state, binary.right)) {
                try writer.buffer.appendSlice(writer.allocator, "false");
                return true;
            },
            else => {},
        },
        .conditional => |conditional| {
            if (knownBool(ctx.state, conditional.condition)) |known| {
                try writer.writeNode(if (known) conditional.then_expr else conditional.else_expr, 0, .none);
                return true;
            }
        },
        else => {},
    }
    return false;
}

fn knownBool(state: *const eval.EvalState, index: ast.Index) ?bool {
    const known = state.get(index) orelse return null;
    return switch (known.*) {
        .bool => |v| v,
        else => null,
    };
}

fn knownEmptyList(state: *const eval.EvalState, index: ast.Index) bool {
    const known = state.get(index) orelse return false;
    return switch (known.*) {
        .list => |items| items.items.len == 0,
        else => false,
    };
}

test "residualize produces correct residual expressions" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.int_type);
    try environment.addVarTyped("y", environment.types.builtins.bool_type);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        .{ .expr = "x", .unknowns = &.{"x"}, .expected_residual = "x" },
        .{ .expr = "true && x == 1", .unknowns = &.{"x"}, .expected_residual = "x == 1" },
        .{ .expr = "[1 + 1, x]", .unknowns = &.{"x"}, .expected_residual = "[2, x]" },
        .{ .expr = "false || x == 0", .unknowns = &.{"x"}, .expected_residual = "x == 0" },
        .{ .expr = "true || x == 0", .unknowns = &.{"x"}, .expected_residual = "true" },
        .{ .expr = "false && x == 0", .unknowns = &.{"x"}, .expected_residual = "false" },
        .{ .expr = "x > 0 && y", .unknowns = &.{ "x", "y" }, .expected_residual = "x > 0 && y" },
        .{ .expr = "true && x > 0 && true", .unknowns = &.{"x"}, .expected_residual = "x > 0" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| {
            try activation.addUnknownVariable(u);
        }

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "partialEvaluate returns result state and residual" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.int_type);

    var program = try checker.compile(std.testing.allocator, &environment, "(1 < 2) ? x : 9");
    defer program.deinit();

    var activation = eval.Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.addUnknownVariable("x");

    var partial_eval = try partialEvaluate(std.testing.allocator, &program, &activation);
    defer partial_eval.deinit();

    try std.testing.expect(partial_eval.value == .unknown);
    try std.testing.expectEqualStrings("x", partial_eval.residual);
}
test "partialEvaluate with fully known expression returns value" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var program = try checker.compile(std.testing.allocator, &environment, "1 + 2 == 3");
    defer program.deinit();

    var activation = eval.Activation.init(std.testing.allocator);
    defer activation.deinit();

    var partial_eval = try partialEvaluate(std.testing.allocator, &program, &activation);
    defer partial_eval.deinit();

    try std.testing.expect(partial_eval.value == .bool);
    try std.testing.expectEqual(true, partial_eval.value.bool);
    try std.testing.expectEqualStrings("true", partial_eval.residual);
}

test "residualize logical AND pruning" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.bool_type);
    try environment.addVarTyped("y", environment.types.builtins.bool_type);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        // true && x => x
        .{ .expr = "true && x", .unknowns = &.{"x"}, .expected_residual = "x" },
        // false && x => false
        .{ .expr = "false && x", .unknowns = &.{"x"}, .expected_residual = "false" },
        // x && true => x
        .{ .expr = "x && true", .unknowns = &.{"x"}, .expected_residual = "x" },
        // x && false => false
        .{ .expr = "x && false", .unknowns = &.{"x"}, .expected_residual = "false" },
        // both unknown => preserved
        .{ .expr = "x && y", .unknowns = &.{ "x", "y" }, .expected_residual = "x && y" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize logical OR pruning" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.bool_type);
    try environment.addVarTyped("y", environment.types.builtins.bool_type);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        // true || x => true
        .{ .expr = "true || x", .unknowns = &.{"x"}, .expected_residual = "true" },
        // false || x => x
        .{ .expr = "false || x", .unknowns = &.{"x"}, .expected_residual = "x" },
        // x || true => true
        .{ .expr = "x || true", .unknowns = &.{"x"}, .expected_residual = "true" },
        // x || false => x
        .{ .expr = "x || false", .unknowns = &.{"x"}, .expected_residual = "x" },
        // both unknown => preserved
        .{ .expr = "x || y", .unknowns = &.{ "x", "y" }, .expected_residual = "x || y" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize chained logical with mixed known/unknown" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.int_type);
    try environment.addVarTyped("y", environment.types.builtins.bool_type);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        // true && x > 0 && true => x > 0
        .{ .expr = "true && x > 0 && true", .unknowns = &.{"x"}, .expected_residual = "x > 0" },
        // false && x > 0 && true => false
        .{ .expr = "false && x > 0 && true", .unknowns = &.{"x"}, .expected_residual = "false" },
        // true || x > 0 || false => true
        .{ .expr = "true || y || false", .unknowns = &.{"y"}, .expected_residual = "true" },
        // false || y || false => y
        .{ .expr = "false || y || false", .unknowns = &.{"y"}, .expected_residual = "y" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize fully known expressions fold to literals" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const cases = [_]struct {
        expr: []const u8,
        expected_residual: []const u8,
    }{
        .{ .expr = "1 + 2", .expected_residual = "3" },
        .{ .expr = "10 - 3", .expected_residual = "7" },
        .{ .expr = "2 * 3", .expected_residual = "6" },
        .{ .expr = "true && false", .expected_residual = "false" },
        .{ .expr = "true || false", .expected_residual = "true" },
        .{ .expr = "!true", .expected_residual = "false" },
        .{ .expr = "1 == 1", .expected_residual = "true" },
        .{ .expr = "1 != 2", .expected_residual = "true" },
        .{ .expr = "3 > 2", .expected_residual = "true" },
        .{ .expr = "2 < 3", .expected_residual = "true" },
        .{ .expr = "'hello' + ' ' + 'world'", .expected_residual = "\"hello world\"" },
        .{ .expr = "[1, 2, 3]", .expected_residual = "[1, 2, 3]" },
        .{ .expr = "{'a': 1}", .expected_residual = "{\"a\": 1}" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize arithmetic with unknowns preserved" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.int_type);
    try environment.addVarTyped("y", environment.types.builtins.int_type);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        .{ .expr = "x + 1", .unknowns = &.{"x"}, .expected_residual = "x + 1" },
        .{ .expr = "x - 1", .unknowns = &.{"x"}, .expected_residual = "x - 1" },
        .{ .expr = "x * 2", .unknowns = &.{"x"}, .expected_residual = "x * 2" },
        .{ .expr = "x / 2", .unknowns = &.{"x"}, .expected_residual = "x / 2" },
        .{ .expr = "x % 3", .unknowns = &.{"x"}, .expected_residual = "x % 3" },
        .{ .expr = "x + y", .unknowns = &.{ "x", "y" }, .expected_residual = "x + y" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize comparisons with unknowns" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.int_type);
    try environment.addVarTyped("y", environment.types.builtins.int_type);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        .{ .expr = "x > 5", .unknowns = &.{"x"}, .expected_residual = "x > 5" },
        .{ .expr = "x < 5", .unknowns = &.{"x"}, .expected_residual = "x < 5" },
        .{ .expr = "x >= 5", .unknowns = &.{"x"}, .expected_residual = "x >= 5" },
        .{ .expr = "x <= 5", .unknowns = &.{"x"}, .expected_residual = "x <= 5" },
        .{ .expr = "x == 5", .unknowns = &.{"x"}, .expected_residual = "x == 5" },
        .{ .expr = "x != 5", .unknowns = &.{"x"}, .expected_residual = "x != 5" },
        .{ .expr = "x == y", .unknowns = &.{ "x", "y" }, .expected_residual = "x == y" },
        .{ .expr = "x > y", .unknowns = &.{ "x", "y" }, .expected_residual = "x > y" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize ternary/conditional with unknowns" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.bool_type);
    try environment.addVarTyped("a", environment.types.builtins.int_type);
    try environment.addVarTyped("b", environment.types.builtins.int_type);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        // known true condition => then branch
        .{ .expr = "true ? a : b", .unknowns = &.{ "a", "b" }, .expected_residual = "a" },
        // known false condition => else branch
        .{ .expr = "false ? a : b", .unknowns = &.{ "a", "b" }, .expected_residual = "b" },
        // unknown condition, both branches unknown => full ternary
        .{ .expr = "x ? a : b", .unknowns = &.{ "x", "a", "b" }, .expected_residual = "x ? a : b" },
        // unknown condition, known branches => ternary with literals
        .{ .expr = "x ? 1 : 2", .unknowns = &.{"x"}, .expected_residual = "x ? 1 : 2" },
        // computed known condition => folds
        .{ .expr = "(1 < 2) ? a : b", .unknowns = &.{ "a", "b" }, .expected_residual = "a" },
        .{ .expr = "(1 > 2) ? a : b", .unknowns = &.{ "a", "b" }, .expected_residual = "b" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize select on unknown (dyn type)" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.dyn_type);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        .{ .expr = "x.field", .unknowns = &.{"x"}, .expected_residual = "x.field" },
        .{ .expr = "x.a.b", .unknowns = &.{"x"}, .expected_residual = "x.a.b" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize function calls with unknown args" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("s", environment.types.builtins.string_type);
    const list_int = try environment.types.listOf(environment.types.builtins.int_type);
    try environment.addVarTyped("lst", list_int);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        // size() as receiver call on unknown string
        .{ .expr = "s.size()", .unknowns = &.{"s"}, .expected_residual = "s.size()" },
        // size() on unknown list
        .{ .expr = "lst.size()", .unknowns = &.{"lst"}, .expected_residual = "lst.size()" },
        // contains() with unknown receiver
        .{ .expr = "s.contains('x')", .unknowns = &.{"s"}, .expected_residual = "s.contains(\"x\")" },
        // startsWith() with unknown receiver
        .{ .expr = "s.startsWith('pre')", .unknowns = &.{"s"}, .expected_residual = "s.startsWith(\"pre\")" },
        // size() on known string => folds to literal
        .{ .expr = "size('hello')", .unknowns = &.{}, .expected_residual = "5" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize nested logical with multiple unknowns" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.bool_type);
    try environment.addVarTyped("y", environment.types.builtins.bool_type);
    try environment.addVarTyped("z", environment.types.builtins.bool_type);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        // (x || y) && z, all unknown
        .{ .expr = "(x || y) && z", .unknowns = &.{ "x", "y", "z" }, .expected_residual = "(x || y) && z" },
        // (x && y) || z, all unknown
        .{ .expr = "(x && y) || z", .unknowns = &.{ "x", "y", "z" }, .expected_residual = "x && y || z" },
        // x || (y && z), all unknown
        .{ .expr = "x || (y && z)", .unknowns = &.{ "x", "y", "z" }, .expected_residual = "x || y && z" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize unary operators with unknowns" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.bool_type);
    try environment.addVarTyped("n", environment.types.builtins.int_type);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        .{ .expr = "!x", .unknowns = &.{"x"}, .expected_residual = "!x" },
        .{ .expr = "-n", .unknowns = &.{"n"}, .expected_residual = "-n" },
        // known values fold
        .{ .expr = "!true", .unknowns = &.{}, .expected_residual = "false" },
        .{ .expr = "-5", .unknowns = &.{}, .expected_residual = "-5" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize list and map with unknown elements" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.int_type);
    try environment.addVarTyped("y", environment.types.builtins.int_type);
    try environment.addVarTyped("s", environment.types.builtins.string_type);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        // list with mixed known/unknown
        .{ .expr = "[1, x, 3]", .unknowns = &.{"x"}, .expected_residual = "[1, x, 3]" },
        // list all unknown
        .{ .expr = "[x, y]", .unknowns = &.{ "x", "y" }, .expected_residual = "[x, y]" },
        // known subexpression in list folds
        .{ .expr = "[1 + 1, x]", .unknowns = &.{"x"}, .expected_residual = "[2, x]" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize index access on unknown" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const list_int = try environment.types.listOf(environment.types.builtins.int_type);
    try environment.addVarTyped("lst", list_int);
    const map_type = try environment.types.mapOf(
        environment.types.builtins.string_type,
        environment.types.builtins.int_type,
    );
    try environment.addVarTyped("m", map_type);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        .{ .expr = "lst[0]", .unknowns = &.{"lst"}, .expected_residual = "lst[0]" },
        .{ .expr = "m['key']", .unknowns = &.{"m"}, .expected_residual = "m[\"key\"]" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize string literals and escaping" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("s", environment.types.builtins.string_type);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        // known string literal
        .{ .expr = "'hello'", .unknowns = &.{}, .expected_residual = "\"hello\"" },
        // string concat with unknown
        .{ .expr = "s + 'world'", .unknowns = &.{"s"}, .expected_residual = "s + \"world\"" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize precedence and parentheses" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("a", environment.types.builtins.int_type);
    try environment.addVarTyped("b", environment.types.builtins.int_type);
    try environment.addVarTyped("c", environment.types.builtins.int_type);
    try environment.addVarTyped("x", environment.types.builtins.bool_type);
    try environment.addVarTyped("y", environment.types.builtins.bool_type);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        // multiplication has higher precedence than addition => no parens needed
        .{ .expr = "a + b * c", .unknowns = &.{ "a", "b", "c" }, .expected_residual = "a + b * c" },
        // explicit grouping preserved when needed
        .{ .expr = "(a + b) * c", .unknowns = &.{ "a", "b", "c" }, .expected_residual = "(a + b) * c" },
        // OR has lower precedence than AND => parens on OR when inside AND
        .{ .expr = "(x || y) && x", .unknowns = &.{ "x", "y" }, .expected_residual = "(x || y) && x" },
        // AND inside OR doesn't need parens
        .{ .expr = "x && y || x", .unknowns = &.{ "x", "y" }, .expected_residual = "x && y || x" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize with known variable values" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.int_type);
    try environment.addVarTyped("y", environment.types.builtins.int_type);
    try environment.addVarTyped("z", environment.types.builtins.int_type);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        known_vars: []const struct { name: []const u8, val: value.Value },
        expected_residual: []const u8,
    }{
        // x known=5, y unknown => 5 + y
        .{
            .expr = "x + y",
            .unknowns = &.{"y"},
            .known_vars = &.{.{ .name = "x", .val = .{ .int = 5 } }},
            .expected_residual = "5 + y",
        },
        // all known => literal
        .{
            .expr = "x + y",
            .unknowns = &.{},
            .known_vars = &.{
                .{ .name = "x", .val = .{ .int = 3 } },
                .{ .name = "y", .val = .{ .int = 7 } },
            },
            .expected_residual = "10",
        },
        // known variable in comparison
        .{
            .expr = "x > y",
            .unknowns = &.{"y"},
            .known_vars = &.{.{ .name = "x", .val = .{ .int = 10 } }},
            .expected_residual = "10 > y",
        },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);
        for (case.known_vars) |kv| try activation.put(kv.name, kv.val);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize double and uint literals" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.double_type);
    try environment.addVarTyped("u", environment.types.builtins.uint_type);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        // known double
        .{ .expr = "1.5 + 2.5", .unknowns = &.{}, .expected_residual = "4.0" },
        // unknown double in arithmetic
        .{ .expr = "x + 1.0", .unknowns = &.{"x"}, .expected_residual = "x + 1.0" },
        // known uint
        .{ .expr = "1u + 2u", .unknowns = &.{}, .expected_residual = "3u" },
        // unknown uint
        .{ .expr = "u + 1u", .unknowns = &.{"u"}, .expected_residual = "u + 1u" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize null literal" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.dyn_type);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        .{ .expr = "null", .unknowns = &.{}, .expected_residual = "null" },
        .{ .expr = "x == null", .unknowns = &.{"x"}, .expected_residual = "x == null" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize in operator with unknowns" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.int_type);
    const list_int = try environment.types.listOf(environment.types.builtins.int_type);
    try environment.addVarTyped("lst", list_int);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        // unknown element, known list
        .{ .expr = "x in [1, 2, 3]", .unknowns = &.{"x"}, .expected_residual = "x in [1, 2, 3]" },
        // unknown list
        .{ .expr = "1 in lst", .unknowns = &.{"lst"}, .expected_residual = "1 in lst" },
        // both unknown
        .{ .expr = "x in lst", .unknowns = &.{ "x", "lst" }, .expected_residual = "x in lst" },
        // known element in empty list => false (writeSimplified handles this)
        .{ .expr = "1 in []", .unknowns = &.{}, .expected_residual = "false" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "residualize complex mixed expressions" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.int_type);
    try environment.addVarTyped("y", environment.types.builtins.int_type);
    try environment.addVarTyped("b", environment.types.builtins.bool_type);
    try environment.addVarTyped("s", environment.types.builtins.string_type);

    const cases = [_]struct {
        expr: []const u8,
        unknowns: []const []const u8,
        expected_residual: []const u8,
    }{
        // comparison in logical with partial known
        .{ .expr = "true && x > 0 && y < 10", .unknowns = &.{ "x", "y" }, .expected_residual = "x > 0 && y < 10" },
        // nested arithmetic inside comparison
        .{ .expr = "x + 1 > y - 2", .unknowns = &.{ "x", "y" }, .expected_residual = "x + 1 > y - 2" },
        // conditional with logical condition
        .{ .expr = "b ? x + 1 : y * 2", .unknowns = &.{ "b", "x", "y" }, .expected_residual = "b ? x + 1 : y * 2" },
        // string size in comparison
        .{ .expr = "s.size() > 0", .unknowns = &.{"s"}, .expected_residual = "s.size() > 0" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        for (case.unknowns) |u| try activation.addUnknownVariable(u);

        var tracked = try eval.evalTracked(std.testing.allocator, &program, &activation);
        defer tracked.deinit();

        const residual_str = try residualize(std.testing.allocator, &program, &tracked.state);
        defer std.testing.allocator.free(residual_str);

        try std.testing.expectEqualStrings(case.expected_residual, residual_str);
    }
}

test "partialEvaluate unknown vs known result state" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.int_type);
    try environment.addVarTyped("y", environment.types.builtins.int_type);

    // Case 1: partially unknown => value is unknown
    {
        var program = try checker.compile(std.testing.allocator, &environment, "x + 1");
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        try activation.addUnknownVariable("x");

        var partial_eval = try partialEvaluate(std.testing.allocator, &program, &activation);
        defer partial_eval.deinit();

        try std.testing.expect(partial_eval.value == .unknown);
        try std.testing.expectEqualStrings("x + 1", partial_eval.residual);
    }

    // Case 2: all known => concrete value
    {
        var program = try checker.compile(std.testing.allocator, &environment, "x + y");
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        try activation.put("x", .{ .int = 3 });
        try activation.put("y", .{ .int = 7 });

        var partial_eval = try partialEvaluate(std.testing.allocator, &program, &activation);
        defer partial_eval.deinit();

        try std.testing.expect(partial_eval.value == .int);
        try std.testing.expectEqual(@as(i64, 10), partial_eval.value.int);
        try std.testing.expectEqualStrings("10", partial_eval.residual);
    }

    // Case 3: logical short-circuit with known false
    {
        var program = try checker.compile(std.testing.allocator, &environment, "false && x > 0");
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        try activation.addUnknownVariable("x");

        var partial_eval = try partialEvaluate(std.testing.allocator, &program, &activation);
        defer partial_eval.deinit();

        try std.testing.expect(partial_eval.value == .bool);
        try std.testing.expectEqual(false, partial_eval.value.bool);
        try std.testing.expectEqualStrings("false", partial_eval.residual);
    }

    // Case 4: logical short-circuit with known true in OR
    {
        var program = try checker.compile(std.testing.allocator, &environment, "true || x > 0");
        defer program.deinit();

        var activation = eval.Activation.init(std.testing.allocator);
        defer activation.deinit();
        try activation.addUnknownVariable("x");

        var partial_eval = try partialEvaluate(std.testing.allocator, &program, &activation);
        defer partial_eval.deinit();

        try std.testing.expect(partial_eval.value == .bool);
        try std.testing.expectEqual(true, partial_eval.value.bool);
        try std.testing.expectEqualStrings("true", partial_eval.residual);
    }
}
