const std = @import("std");
const ast = @import("../parse/ast.zig");
const env_mod = @import("../env/env.zig");
const eval_mod = @import("../eval/eval.zig");
const program_mod = @import("program.zig");
const value_mod = @import("../env/value.zig");
const activation_mod = @import("../eval/activation.zig");
const strings = @import("../parse/string_table.zig");

pub const Program = program_mod.Program;
pub const Env = env_mod.Env;

pub const OptimizationPass = *const fn (
    allocator: std.mem.Allocator,
    program: *Program,
    env: *const Env,
) anyerror!void;

pub fn optimize(
    allocator: std.mem.Allocator,
    program: *Program,
    env: *const Env,
    passes: []const OptimizationPass,
) !void {
    for (passes) |pass| try pass(allocator, program, env);
}

/// Returns true when a node's tag denotes a compile-time literal.
fn isLiteral(tag: ast.Tag) bool {
    return switch (tag) {
        .literal_int,
        .literal_uint,
        .literal_double,
        .literal_string,
        .literal_bytes,
        .literal_bool,
        .literal_null,
        => true,
        else => false,
    };
}

/// Convert a runtime Value into an AST Data literal node, interning strings
/// into the AST string table when needed. Returns null if the value type
/// cannot be represented as a literal AST node.
fn valueToData(
    tree: *ast.Ast,
    val: value_mod.Value,
) !?ast.Data {
    return switch (val) {
        .int => |v| .{ .literal_int = v },
        .uint => |v| .{ .literal_uint = v },
        .double => |v| .{ .literal_double = v },
        .bool => |v| .{ .literal_bool = v },
        .null => .literal_null,
        .string => |s| .{ .literal_string = try tree.strings.intern(tree.allocator, s) },
        .bytes => |b| .{ .literal_bytes = try tree.strings.intern(tree.allocator, b) },
        else => null,
    };
}

/// Constant folding optimization pass.
///
/// Walks the AST bottom-up. For each node whose operands are all literals,
/// evaluates the sub-expression at compile time using the eval engine and
/// replaces the AST node with the resulting literal.
///
/// Also handles:
/// - Logical short-circuit: `true || x` -> `true`, `false && x` -> `false`
/// - Identity elimination: `true && x` -> `x`, `false || x` -> `x`
/// - Dead branch elimination: `true ? a : b` -> `a`, `false ? a : b` -> `b`
pub fn constantFolding(
    allocator: std.mem.Allocator,
    program: *Program,
    _: *const Env,
) anyerror!void {
    const root = program.ast.root orelse return;
    _ = foldNode(allocator, program, root) catch return;
}

/// Recursively fold a single node. Returns whether the node became a literal.
fn foldNode(
    allocator: std.mem.Allocator,
    program: *Program,
    index: ast.Index,
) anyerror!bool {
    const node = program.ast.node(index);
    switch (node.data) {
        // Leaves: already literals or variables.
        .literal_int,
        .literal_uint,
        .literal_double,
        .literal_string,
        .literal_bytes,
        .literal_bool,
        .literal_null,
        => return true,

        .ident => return false,

        .unary => |u| {
            const child_is_lit = try foldNode(allocator, program, u.expr);
            if (child_is_lit) {
                return tryEvalAndReplace(allocator, program, index);
            }
            return false;
        },

        .binary => |b| {
            const left_is_lit = try foldNode(allocator, program, b.left);
            const right_is_lit = try foldNode(allocator, program, b.right);

            // Both literal: evaluate whole expression.
            if (left_is_lit and right_is_lit) {
                return tryEvalAndReplace(allocator, program, index);
            }

            // Partial folding for logical operators.
            if (b.op == .logical_and or b.op == .logical_or) {
                return tryFoldLogical(program, index, b, left_is_lit, right_is_lit);
            }

            return false;
        },

        .conditional => |c| {
            const cond_is_lit = try foldNode(allocator, program, c.condition);
            // Always try to fold the branches regardless.
            _ = try foldNode(allocator, program, c.then_expr);
            _ = try foldNode(allocator, program, c.else_expr);

            if (cond_is_lit) {
                const cond_node = program.ast.node(c.condition);
                if (cond_node.data == .literal_bool) {
                    // Dead branch elimination.
                    const kept = if (cond_node.data.literal_bool) c.then_expr else c.else_expr;
                    const kept_node = program.ast.node(kept);
                    program.ast.nodes.items[@intFromEnum(index)].data = kept_node.data;
                    return isLiteral(kept_node.tag());
                }
            }
            return false;
        },

        .call => |call| {
            // Fold arguments first.
            var all_lit = true;
            const arg_indices = program.ast.expr_ranges.items[call.args.start..][0..call.args.len];
            for (arg_indices) |arg_idx| {
                const is_lit = try foldNode(allocator, program, arg_idx);
                if (!is_lit) all_lit = false;
            }
            if (all_lit) {
                return tryEvalAndReplace(allocator, program, index);
            }
            return false;
        },

        .receiver_call => |call| {
            // Fold target and arguments.
            var all_lit = try foldNode(allocator, program, call.target);
            const arg_indices = program.ast.expr_ranges.items[call.args.start..][0..call.args.len];
            for (arg_indices) |arg_idx| {
                const is_lit = try foldNode(allocator, program, arg_idx);
                if (!is_lit) all_lit = false;
            }
            if (all_lit) {
                return tryEvalAndReplace(allocator, program, index);
            }
            return false;
        },

        .select => |sel| {
            _ = try foldNode(allocator, program, sel.target);
            return false;
        },

        .index => |acc| {
            _ = try foldNode(allocator, program, acc.target);
            _ = try foldNode(allocator, program, acc.index);
            return false;
        },

        .list => |range| {
            const items = program.ast.list_items.items[range.start..][0..range.len];
            for (items) |item| {
                _ = try foldNode(allocator, program, item.value);
            }
            return false;
        },

        .map => |range| {
            const entries = program.ast.map_entries.items[range.start..][0..range.len];
            for (entries) |entry| {
                _ = try foldNode(allocator, program, entry.key);
                _ = try foldNode(allocator, program, entry.value);
            }
            return false;
        },

        .message => |msg| {
            const fields = program.ast.field_inits.items[msg.fields.start..][0..msg.fields.len];
            for (fields) |field| {
                _ = try foldNode(allocator, program, field.value);
            }
            return false;
        },
    }
}

/// Try to evaluate a sub-expression rooted at `index` and replace the node
/// with the resulting literal. Returns true on success.
fn tryEvalAndReplace(
    allocator: std.mem.Allocator,
    program: *Program,
    index: ast.Index,
) !bool {
    // Build a mini-program that has the same AST and env but with the target
    // node as the root.
    const original_root = program.ast.root;
    program.ast.root = index;
    defer program.ast.root = original_root;

    var activation = activation_mod.Activation.init(allocator);
    defer activation.deinit();

    var result = eval_mod.eval(allocator, program, &activation) catch return false;
    defer result.deinit(allocator);

    const new_data = try valueToData(&program.ast, result);
    if (new_data) |data| {
        program.ast.nodes.items[@intFromEnum(index)].data = data;
        return true;
    }
    return false;
}

/// Handle partial folding for logical AND/OR:
/// - `true || x`  -> `true`   (short-circuit)
/// - `false && x`  -> `false`  (short-circuit)
/// - `true && x`  -> `x`      (identity elimination)
/// - `false || x`  -> `x`      (identity elimination)
/// Same rules apply symmetrically when the right side is the literal.
fn tryFoldLogical(
    program: *Program,
    index: ast.Index,
    b: ast.Binary,
    left_is_lit: bool,
    right_is_lit: bool,
) !bool {
    if (b.op == .logical_or) {
        // true || x -> true
        if (left_is_lit) {
            const left_node = program.ast.node(b.left);
            if (left_node.data == .literal_bool and left_node.data.literal_bool) {
                program.ast.nodes.items[@intFromEnum(index)].data = .{ .literal_bool = true };
                return true;
            }
        }
        // x || true -> true
        if (right_is_lit) {
            const right_node = program.ast.node(b.right);
            if (right_node.data == .literal_bool and right_node.data.literal_bool) {
                program.ast.nodes.items[@intFromEnum(index)].data = .{ .literal_bool = true };
                return true;
            }
        }
        // false || x -> x
        if (left_is_lit) {
            const left_node = program.ast.node(b.left);
            if (left_node.data == .literal_bool and !left_node.data.literal_bool) {
                const right_node = program.ast.node(b.right);
                program.ast.nodes.items[@intFromEnum(index)].data = right_node.data;
                return isLiteral(right_node.tag());
            }
        }
        // x || false -> x
        if (right_is_lit) {
            const right_node = program.ast.node(b.right);
            if (right_node.data == .literal_bool and !right_node.data.literal_bool) {
                const left_node = program.ast.node(b.left);
                program.ast.nodes.items[@intFromEnum(index)].data = left_node.data;
                return isLiteral(left_node.tag());
            }
        }
    }

    if (b.op == .logical_and) {
        // false && x -> false
        if (left_is_lit) {
            const left_node = program.ast.node(b.left);
            if (left_node.data == .literal_bool and !left_node.data.literal_bool) {
                program.ast.nodes.items[@intFromEnum(index)].data = .{ .literal_bool = false };
                return true;
            }
        }
        // x && false -> false
        if (right_is_lit) {
            const right_node = program.ast.node(b.right);
            if (right_node.data == .literal_bool and !right_node.data.literal_bool) {
                program.ast.nodes.items[@intFromEnum(index)].data = .{ .literal_bool = false };
                return true;
            }
        }
        // true && x -> x
        if (left_is_lit) {
            const left_node = program.ast.node(b.left);
            if (left_node.data == .literal_bool and left_node.data.literal_bool) {
                const right_node = program.ast.node(b.right);
                program.ast.nodes.items[@intFromEnum(index)].data = right_node.data;
                return isLiteral(right_node.tag());
            }
        }
        // x && true -> x
        if (right_is_lit) {
            const right_node = program.ast.node(b.right);
            if (right_node.data == .literal_bool and right_node.data.literal_bool) {
                const left_node = program.ast.node(b.left);
                program.ast.nodes.items[@intFromEnum(index)].data = left_node.data;
                return isLiteral(left_node.tag());
            }
        }
    }

    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const compile_mod = @import("compile.zig");

fn expectFolded(
    env_ptr: *Env,
    expr: []const u8,
    expected_int: ?i64,
    expected_bool: ?bool,
    expected_str: ?[]const u8,
    expected_uint: ?u64,
    expected_double: ?f64,
) !void {
    var prog = try compile_mod.compile(testing.allocator, env_ptr, expr);
    defer prog.deinit();

    optimize(testing.allocator, &prog, env_ptr, &.{constantFolding}) catch {};

    var activation = activation_mod.Activation.init(testing.allocator);
    defer activation.deinit();

    var result = try eval_mod.eval(testing.allocator, &prog, &activation);
    defer result.deinit(testing.allocator);

    if (expected_int) |exp| try testing.expectEqual(exp, result.int);
    if (expected_bool) |exp| try testing.expectEqual(exp, result.bool);
    if (expected_uint) |exp| try testing.expectEqual(exp, result.uint);
    if (expected_double) |exp| try testing.expectEqual(exp, result.double);
    if (expected_str) |exp| try testing.expectEqualStrings(exp, result.string);
}

test "constant folding - arithmetic" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();

    const cases = [_]struct { expr: []const u8, expected: i64 }{
        .{ .expr = "1 + 2", .expected = 3 },
        .{ .expr = "2 * 3 + 1", .expected = 7 },
        .{ .expr = "10 - 3", .expected = 7 },
        .{ .expr = "15 / 3", .expected = 5 },
        .{ .expr = "17 % 5", .expected = 2 },
        .{ .expr = "(1 + 2) * (3 + 4)", .expected = 21 },
        .{ .expr = "2 * (3 + 4) - 1", .expected = 13 },
        .{ .expr = "100 / 10 / 2", .expected = 5 },
    };
    for (cases) |case| {
        try expectFolded(&environment, case.expr, case.expected, null, null, null, null);
    }
}

test "constant folding - boolean logic" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        .{ .expr = "!true", .expected = false },
        .{ .expr = "!false", .expected = true },
        .{ .expr = "true && false", .expected = false },
        .{ .expr = "true && true", .expected = true },
        .{ .expr = "false || true", .expected = true },
        .{ .expr = "false || false", .expected = false },
        .{ .expr = "1 < 2", .expected = true },
        .{ .expr = "2 <= 2", .expected = true },
        .{ .expr = "3 > 2", .expected = true },
        .{ .expr = "2 >= 3", .expected = false },
        .{ .expr = "1 == 1", .expected = true },
        .{ .expr = "1 != 2", .expected = true },
    };
    for (cases) |case| {
        try expectFolded(&environment, case.expr, null, case.expected, null, null, null);
    }
}

test "constant folding - string concatenation" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();

    const cases = [_]struct { expr: []const u8, expected: []const u8 }{
        .{ .expr = "'hello' + ' world'", .expected = "hello world" },
        .{ .expr = "'a' + 'b' + 'c'", .expected = "abc" },
    };
    for (cases) |case| {
        try expectFolded(&environment, case.expr, null, null, case.expected, null, null);
    }
}

test "constant folding - stdlib function on literals" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();

    // size("hello") -> 5
    try expectFolded(&environment, "size('hello')", 5, null, null, null, null);
}

test "constant folding - logical short-circuit" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();
    const b = environment.types.builtins;
    try environment.addVarTyped("x", b.bool_type);

    // true || x -> true (regardless of x)
    {
        var prog = try compile_mod.compile(testing.allocator, &environment, "true || x");
        defer prog.deinit();
        optimize(testing.allocator, &prog, &environment, &.{constantFolding}) catch {};

        // The root node should now be a literal bool.
        const root = prog.ast.node(prog.ast.root.?);
        try testing.expectEqual(ast.Tag.literal_bool, root.tag());
        try testing.expectEqual(true, root.data.literal_bool);
    }

    // false && x -> false (regardless of x)
    {
        var prog = try compile_mod.compile(testing.allocator, &environment, "false && x");
        defer prog.deinit();
        optimize(testing.allocator, &prog, &environment, &.{constantFolding}) catch {};

        const root = prog.ast.node(prog.ast.root.?);
        try testing.expectEqual(ast.Tag.literal_bool, root.tag());
        try testing.expectEqual(false, root.data.literal_bool);
    }
}

test "constant folding - identity elimination" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();
    const b = environment.types.builtins;
    try environment.addVarTyped("x", b.bool_type);

    // true && x -> x (identity: the root should become an ident, not a binary)
    {
        var prog = try compile_mod.compile(testing.allocator, &environment, "true && x");
        defer prog.deinit();
        optimize(testing.allocator, &prog, &environment, &.{constantFolding}) catch {};

        const root = prog.ast.node(prog.ast.root.?);
        try testing.expectEqual(ast.Tag.ident, root.tag());
    }

    // false || x -> x
    {
        var prog = try compile_mod.compile(testing.allocator, &environment, "false || x");
        defer prog.deinit();
        optimize(testing.allocator, &prog, &environment, &.{constantFolding}) catch {};

        const root = prog.ast.node(prog.ast.root.?);
        try testing.expectEqual(ast.Tag.ident, root.tag());
    }
}

test "dead branch elimination" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();

    // true ? 42 : 0 -> 42
    try expectFolded(&environment, "true ? 42 : 0", 42, null, null, null, null);

    // false ? 0 : 99 -> 99
    try expectFolded(&environment, "false ? 0 : 99", 99, null, null, null, null);

    // Nested: true ? (1 + 2) : 0 -> 3
    try expectFolded(&environment, "true ? (1 + 2) : 0", 3, null, null, null, null);
}

test "partial folding with variables" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();
    const b = environment.types.builtins;
    try environment.addVarTyped("x", b.int_type);
    try environment.addVarTyped("flag", b.bool_type);

    // Expressions mixing constants and variables should still evaluate correctly.
    const cases = [_]struct { expr: []const u8, vars: struct { x: i64, flag: bool }, expected_int: ?i64 = null, expected_bool: ?bool = null }{
        .{ .expr = "x + (1 + 2)", .vars = .{ .x = 10, .flag = true }, .expected_int = 13 },
        .{ .expr = "(2 * 3) + x", .vars = .{ .x = 5, .flag = true }, .expected_int = 11 },
        .{ .expr = "true && flag", .vars = .{ .x = 0, .flag = true }, .expected_bool = true },
        .{ .expr = "true && flag", .vars = .{ .x = 0, .flag = false }, .expected_bool = false },
        .{ .expr = "false || flag", .vars = .{ .x = 0, .flag = true }, .expected_bool = true },
    };
    for (cases) |case| {
        var prog = try compile_mod.compile(testing.allocator, &environment, case.expr);
        defer prog.deinit();

        optimize(testing.allocator, &prog, &environment, &.{constantFolding}) catch {};

        var activation = activation_mod.Activation.init(testing.allocator);
        defer activation.deinit();
        try activation.put("x", .{ .int = case.vars.x });
        try activation.put("flag", .{ .bool = case.vars.flag });

        var result = try eval_mod.eval(testing.allocator, &prog, &activation);
        defer result.deinit(testing.allocator);

        if (case.expected_int) |exp| try testing.expectEqual(exp, result.int);
        if (case.expected_bool) |exp| try testing.expectEqual(exp, result.bool);
    }
}

test "constant folding - no-op on variable-only expressions" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();
    const b = environment.types.builtins;
    try environment.addVarTyped("a", b.int_type);
    try environment.addVarTyped("b_var", b.int_type);

    // Pure variable expression should remain unchanged (no crash, correct eval).
    var prog = try compile_mod.compile(testing.allocator, &environment, "a + b_var");
    defer prog.deinit();
    optimize(testing.allocator, &prog, &environment, &.{constantFolding}) catch {};

    var activation = activation_mod.Activation.init(testing.allocator);
    defer activation.deinit();
    try activation.put("a", .{ .int = 3 });
    try activation.put("b_var", .{ .int = 7 });

    var result = try eval_mod.eval(testing.allocator, &prog, &activation);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 10), result.int);
}

test "constant folding - double arithmetic" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();

    try expectFolded(&environment, "1.5 + 2.5", null, null, null, null, 4.0);
    try expectFolded(&environment, "3.0 * 2.0", null, null, null, null, 6.0);
}

test "optimize with empty pass list is no-op" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();

    var prog = try compile_mod.compile(testing.allocator, &environment, "1 + 2");
    defer prog.deinit();

    try optimize(testing.allocator, &prog, &environment, &.{});

    var activation = activation_mod.Activation.init(testing.allocator);
    defer activation.deinit();
    var result = try eval_mod.eval(testing.allocator, &prog, &activation);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 3), result.int);
}
