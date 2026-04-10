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
/// Walks the AST bottom-up, iterating until no more changes occur (capped
/// at 100 passes). For each node whose operands are all compile-time
/// constants, evaluates the sub-expression and replaces the AST node with
/// the resulting literal.
///
/// Also handles:
/// - Logical short-circuit: `true || x` -> `true`, `false && x` -> `false`
/// - Identity elimination: `true && x` -> `x`, `false || x` -> `x`
/// - Dead branch elimination: `true ? a : b` -> `a`, `false ? a : b` -> `b`
/// - `x in []` -> `false` (empty-list membership always false)
/// - Aggregate literal propagation: `[1,2,3].size()` -> `3`
/// - Field access on literal maps/messages: `{"a":1}.a` -> `1`
pub fn constantFolding(
    allocator: std.mem.Allocator,
    program: *Program,
    _: *const Env,
) anyerror!void {
    const root = program.ast.root orelse return;
    var iterations: u32 = 0;
    while (iterations < 100) : (iterations += 1) {
        var changed = false;
        _ = foldNode(allocator, program, root, &changed) catch return;
        if (!changed) break;
    }
}

/// Returns true when a node is all-constant (scalar literal or aggregate
/// whose children are all constant). The `changed` flag is set whenever
/// a node is replaced, signaling the multi-pass loop to re-run.
fn foldNode(
    allocator: std.mem.Allocator,
    program: *Program,
    index: ast.Index,
    changed: *bool,
) anyerror!bool {
    const node = program.ast.node(index);
    switch (node.data) {
        .literal_int,
        .literal_uint,
        .literal_double,
        .literal_string,
        .literal_bytes,
        .literal_bool,
        .literal_null,
        => return true,

        .ident => |name_ref| {
            // Inline environment constants: if the ident resolves to a
            // compile-time constant in the Env, replace it with the value.
            if (name_ref.segments.len == 1 and !name_ref.absolute) {
                const id = program.ast.name_segments.items[name_ref.segments.start];
                const name = program.ast.strings.get(id);
                if (program.env.lookupConst(name)) |constant| {
                    if (try valueToData(&program.ast, constant.value)) |data| {
                        program.ast.nodes.items[@intFromEnum(index)].data = data;
                        changed.* = true;
                        return true;
                    }
                }
            }
            return false;
        },

        .unary => |u| {
            const child_is_lit = try foldNode(allocator, program, u.expr, changed);
            if (child_is_lit) {
                return tryEvalAndReplace(allocator, program, index, changed);
            }
            return false;
        },

        .binary => |b| {
            const left_is_lit = try foldNode(allocator, program, b.left, changed);
            const right_is_lit = try foldNode(allocator, program, b.right, changed);

            // Both literal: evaluate whole expression.
            if (left_is_lit and right_is_lit) {
                return tryEvalAndReplace(allocator, program, index, changed);
            }

            // `x in []` is always false regardless of x.
            if (b.op == .in_set and isEmptyAggregate(program, b.right)) {
                program.ast.nodes.items[@intFromEnum(index)].data = .{ .literal_bool = false };
                changed.* = true;
                return true;
            }

            // Partial folding for logical operators.
            if (b.op == .logical_and or b.op == .logical_or) {
                return tryFoldLogical(program, index, b, left_is_lit, right_is_lit, changed);
            }

            return false;
        },

        .conditional => |c| {
            const cond_is_lit = try foldNode(allocator, program, c.condition, changed);
            _ = try foldNode(allocator, program, c.then_expr, changed);
            _ = try foldNode(allocator, program, c.else_expr, changed);

            if (cond_is_lit) {
                const cond_node = program.ast.node(c.condition);
                if (cond_node.data == .literal_bool) {
                    const kept = if (cond_node.data.literal_bool) c.then_expr else c.else_expr;
                    const kept_node = program.ast.node(kept);
                    program.ast.nodes.items[@intFromEnum(index)].data = kept_node.data;
                    changed.* = true;
                    return isLiteral(kept_node.tag());
                }
            }
            return false;
        },

        .call => |call| {
            var all_lit = true;
            const arg_indices = program.ast.expr_ranges.items[call.args.start..][0..call.args.len];
            for (arg_indices) |arg_idx| {
                const is_lit = try foldNode(allocator, program, arg_idx, changed);
                if (!is_lit) all_lit = false;
            }
            if (all_lit) {
                return tryEvalAndReplace(allocator, program, index, changed);
            }
            return false;
        },

        .receiver_call => |call| {
            const target_is_lit = try foldNode(allocator, program, call.target, changed);
            var all_lit = target_is_lit;
            const arg_indices = program.ast.expr_ranges.items[call.args.start..][0..call.args.len];
            for (arg_indices) |arg_idx| {
                const is_lit = try foldNode(allocator, program, arg_idx, changed);
                if (!is_lit) all_lit = false;
            }
            if (all_lit) {
                return tryEvalAndReplace(allocator, program, index, changed);
            }
            // Comprehension macros (.all, .exists, .map, .filter, etc.)
            // bind their loop variable internally during evaluation, so
            // we can fold them when the target iterable is all-literal
            // even though the predicate references the loop variable.
            // If the predicate also references external variables, eval
            // will fail and tryEvalAndReplace returns false harmlessly.
            if (target_is_lit and isMacroResolution(program, index)) {
                return tryEvalAndReplace(allocator, program, index, changed);
            }
            return false;
        },

        .select => |sel| {
            const target_is_lit = try foldNode(allocator, program, sel.target, changed);
            if (target_is_lit) {
                return tryEvalAndReplace(allocator, program, index, changed);
            }
            return false;
        },

        .index => |acc| {
            const target_is_lit = try foldNode(allocator, program, acc.target, changed);
            const idx_is_lit = try foldNode(allocator, program, acc.index, changed);
            if (target_is_lit and idx_is_lit) {
                return tryEvalAndReplace(allocator, program, index, changed);
            }
            return false;
        },

        .list => |range| {
            const items = program.ast.list_items.items[range.start..][0..range.len];
            var all_lit = true;
            for (items) |item| {
                if (item.optional) all_lit = false;
                const is_lit = try foldNode(allocator, program, item.value, changed);
                if (!is_lit) all_lit = false;
            }
            return all_lit;
        },

        .map => |range| {
            const entries = program.ast.map_entries.items[range.start..][0..range.len];
            var all_lit = true;
            for (entries) |entry| {
                if (entry.optional) all_lit = false;
                const k = try foldNode(allocator, program, entry.key, changed);
                const v = try foldNode(allocator, program, entry.value, changed);
                if (!k or !v) all_lit = false;
            }
            return all_lit;
        },

        .message => |msg| {
            const fields = program.ast.field_inits.items[msg.fields.start..][0..msg.fields.len];
            var all_lit = true;
            for (fields) |field| {
                if (field.optional) all_lit = false;
                const is_lit = try foldNode(allocator, program, field.value, changed);
                if (!is_lit) all_lit = false;
            }
            return all_lit;
        },
    }
}

fn isMacroResolution(program: *const Program, index: ast.Index) bool {
    const idx = @intFromEnum(index);
    if (idx >= program.call_resolution.items.len) return false;
    return program.call_resolution.items[idx] == .macro;
}

/// Compile-time argument preparation pass.
///
/// Walks every dynamic function call. When the function declares a
/// Precompile hook, gathers each argument as either a literal Value
/// or null (for runtime arguments) and calls prepare(). The function
/// decides whether it can precompile based on which slots are literal.
/// Must run after constantFolding so that foldable arguments are
/// already reduced to literal nodes.
pub fn precompileArguments(
    _: std.mem.Allocator,
    program: *Program,
    _: *const Env,
) anyerror!void {
    const node_count = program.ast.nodes.items.len;
    if (program.prepared.items.len < node_count) {
        const old_len = program.prepared.items.len;
        try program.prepared.resize(program.analysis_allocator, node_count);
        @memset(program.prepared.items[old_len..], null);
    }

    var arg_buffer: [16]?value_mod.Value = undefined;

    for (program.ast.nodes.items, 0..) |node, raw_idx| {
        if (raw_idx >= program.call_resolution.items.len) continue;
        const resolution = program.call_resolution.items[raw_idx];
        const dyn = switch (resolution) {
            .dynamic => |d| program.env.dynamicFunctionAt(d.ref),
            else => continue,
        };
        const precompile = dyn.precompile orelse continue;

        var arg_count: usize = 0;
        const ok = gatherArgs(program, node, &arg_buffer, &arg_count);
        if (!ok) continue;

        const prepared_ptr = precompile.prepare(program.analysis_allocator, arg_buffer[0..arg_count]) catch continue;
        // Destroy any stale context at this slot before overwriting so
        // re-running the pass on the same Program does not leak.
        if (program.prepared.items[raw_idx]) |old| {
            old.destroy(program.analysis_allocator, old.ptr);
        }
        program.prepared.items[raw_idx] = .{
            .ptr = prepared_ptr,
            .destroy = precompile.destroy,
        };
    }
}

/// Build the optional-value argument list for a call node. Each slot
/// is non-null when the corresponding AST node is a literal. Returns
/// false only if the call has more arguments than the buffer can hold,
/// or if the node is not a call kind. Literal string/bytes Values
/// point into the AST string table -- the caller must not deinit them.
fn gatherArgs(
    program: *const Program,
    node: ast.Node,
    buffer: []?value_mod.Value,
    out_count: *usize,
) bool {
    var count: usize = 0;
    switch (node.data) {
        .receiver_call => |call| {
            if (1 + call.args.len > buffer.len) return false;
            buffer[count] = literalNodeToValue(program, call.target);
            count += 1;
            const args = program.ast.expr_ranges.items[call.args.start..][0..call.args.len];
            for (args) |a| {
                buffer[count] = literalNodeToValue(program, a);
                count += 1;
            }
        },
        .call => |call| {
            if (call.args.len > buffer.len) return false;
            const args = program.ast.expr_ranges.items[call.args.start..][0..call.args.len];
            for (args) |a| {
                buffer[count] = literalNodeToValue(program, a);
                count += 1;
            }
        },
        else => return false,
    }
    out_count.* = count;
    return true;
}

/// Convert a literal AST node into a borrowed Value. Returns null if
/// the node is not a literal. String/bytes values point into the AST
/// string table -- do not deinit them.
fn literalNodeToValue(program: *const Program, index: ast.Index) ?value_mod.Value {
    return switch (program.ast.node(index).data) {
        .literal_int => |v| .{ .int = v },
        .literal_uint => |v| .{ .uint = v },
        .literal_double => |v| .{ .double = v },
        .literal_bool => |v| .{ .bool = v },
        .literal_null => .null,
        .literal_string => |id| .{ .string = @constCast(program.ast.strings.get(id)) },
        .literal_bytes => |id| .{ .bytes = @constCast(program.ast.strings.get(id)) },
        else => null,
    };
}

fn isEmptyAggregate(program: *const Program, index: ast.Index) bool {
    const data = program.ast.node(index).data;
    return switch (data) {
        .list => |r| r.len == 0,
        .map => |r| r.len == 0,
        else => false,
    };
}


/// Try to evaluate a sub-expression rooted at `index` and replace the node
/// with the resulting literal. Returns true on success.
fn tryEvalAndReplace(
    allocator: std.mem.Allocator,
    program: *Program,
    index: ast.Index,
    changed: *bool,
) !bool {
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
        changed.* = true;
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
    changed: *bool,
) !bool {
    if (b.op == .logical_or) {
        if (left_is_lit) {
            const left_node = program.ast.node(b.left);
            if (left_node.data == .literal_bool and left_node.data.literal_bool) {
                program.ast.nodes.items[@intFromEnum(index)].data = .{ .literal_bool = true };
                changed.* = true;
                return true;
            }
        }
        if (right_is_lit) {
            const right_node = program.ast.node(b.right);
            if (right_node.data == .literal_bool and right_node.data.literal_bool) {
                program.ast.nodes.items[@intFromEnum(index)].data = .{ .literal_bool = true };
                changed.* = true;
                return true;
            }
        }
        if (left_is_lit) {
            const left_node = program.ast.node(b.left);
            if (left_node.data == .literal_bool and !left_node.data.literal_bool) {
                const right_node = program.ast.node(b.right);
                program.ast.nodes.items[@intFromEnum(index)].data = right_node.data;
                changed.* = true;
                return isLiteral(right_node.tag());
            }
        }
        if (right_is_lit) {
            const right_node = program.ast.node(b.right);
            if (right_node.data == .literal_bool and !right_node.data.literal_bool) {
                const left_node = program.ast.node(b.left);
                program.ast.nodes.items[@intFromEnum(index)].data = left_node.data;
                changed.* = true;
                return isLiteral(left_node.tag());
            }
        }
    }

    if (b.op == .logical_and) {
        if (left_is_lit) {
            const left_node = program.ast.node(b.left);
            if (left_node.data == .literal_bool and !left_node.data.literal_bool) {
                program.ast.nodes.items[@intFromEnum(index)].data = .{ .literal_bool = false };
                changed.* = true;
                return true;
            }
        }
        if (right_is_lit) {
            const right_node = program.ast.node(b.right);
            if (right_node.data == .literal_bool and !right_node.data.literal_bool) {
                program.ast.nodes.items[@intFromEnum(index)].data = .{ .literal_bool = false };
                changed.* = true;
                return true;
            }
        }
        if (left_is_lit) {
            const left_node = program.ast.node(b.left);
            if (left_node.data == .literal_bool and left_node.data.literal_bool) {
                const right_node = program.ast.node(b.right);
                program.ast.nodes.items[@intFromEnum(index)].data = right_node.data;
                changed.* = true;
                return isLiteral(right_node.tag());
            }
        }
        if (right_is_lit) {
            const right_node = program.ast.node(b.right);
            if (right_node.data == .literal_bool and right_node.data.literal_bool) {
                const left_node = program.ast.node(b.left);
                program.ast.nodes.items[@intFromEnum(index)].data = left_node.data;
                changed.* = true;
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

test "aggregate literal folding - list receiver calls fold" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();

    // [1, 2, 3].size() should fold to 3 at compile time.
    try expectFolded(&environment, "[1, 2, 3].size()", 3, null, null, null, null);
    // String method on literal.
    try expectFolded(&environment, "'hello world'.contains('world')", null, true, null, null, null);
    // Nested: size of a list built from literals.
    try expectFolded(&environment, "size([1, 2])", 2, null, null, null, null);
}

test "aggregate literal folding - map field access folds" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();

    // {"a": 1}.a should fold to 1.
    try expectFolded(&environment, "{\"a\": 42}.a", 42, null, null, null, null);
    // Map index access.
    try expectFolded(&environment, "{\"k\": true}[\"k\"]", null, true, null, null, null);
}

test "in on empty list folds to false" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();
    const b = environment.types.builtins;
    try environment.addVarTyped("x", b.int_type);

    var prog = try compile_mod.compile(testing.allocator, &environment, "x in []");
    defer prog.deinit();
    optimize(testing.allocator, &prog, &environment, &.{constantFolding}) catch {};

    // The root should now be a literal false regardless of x.
    const root = prog.ast.node(prog.ast.root.?);
    try testing.expectEqual(ast.Tag.literal_bool, root.tag());
    try testing.expectEqual(false, root.data.literal_bool);
}

test "multi-pass catches cascading opportunities" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();
    const b = environment.types.builtins;
    try environment.addVarTyped("x", b.bool_type);

    // `true && (1 + 2 == 3)`: first pass folds `1+2` to `3`, then `3==3`
    // to `true`, then `true && true` to `true`. Requires multiple passes
    // (or bottom-up handles it in one, but the point is it converges).
    try expectFolded(&environment, "true && (1 + 2 == 3)", null, true, null, null, null);

    // Identity then fold: `false || (2 * 3 > 5)` -> `2*3 > 5` -> `6 > 5` -> `true`
    try expectFolded(&environment, "false || (2 * 3 > 5)", null, true, null, null, null);
}

test "variable inlining replaces env constants" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();
    const b = environment.types.builtins;
    try environment.addVarTyped("x", b.int_type);
    try environment.addConst("MAX_SIZE", b.int_type, .{ .int = 100 });
    try environment.addConst("PREFIX", b.string_type, try value_mod.string(testing.allocator, "api/"));

    // MAX_SIZE is a constant, so `x < MAX_SIZE` inlines to `x < 100`.
    // Can't fold further (x is a variable), but the constant is gone.
    {
        var prog = try compile_mod.compile(testing.allocator, &environment, "x < MAX_SIZE");
        defer prog.deinit();
        optimize(testing.allocator, &prog, &environment, &.{constantFolding}) catch {};

        var activation = activation_mod.Activation.init(testing.allocator);
        defer activation.deinit();
        try activation.put("x", .{ .int = 50 });
        var result = try eval_mod.eval(testing.allocator, &prog, &activation);
        defer result.deinit(testing.allocator);
        try testing.expectEqual(true, result.bool);
    }

    // Two constants fold away entirely: `MAX_SIZE + 1` -> 101.
    try expectFolded(&environment, "MAX_SIZE + 1", 101, null, null, null, null);

    // String constant inlines.
    try expectFolded(&environment, "size(PREFIX)", 4, null, null, null, null);
}

test "precompileArguments caches regex matches() patterns" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();
    const b = environment.types.builtins;
    try environment.addVarTyped("text", b.string_type);

    var prog = try compile_mod.compile(testing.allocator, &environment, "text.matches('h.*o')");
    defer prog.deinit();
    try optimize(testing.allocator, &prog, &environment, &.{
        constantFolding,
        precompileArguments,
    });

    // The matches() node should have a precompiled context.
    var has_prepared = false;
    for (prog.prepared.items) |maybe| {
        if (maybe != null) { has_prepared = true; break; }
    }
    try testing.expect(has_prepared);

    // Evaluate twice and verify both produce correct results via the
    // cached pattern.
    var activation = activation_mod.Activation.init(testing.allocator);
    defer activation.deinit();
    try activation.putString("text", "hello");
    var r1 = try eval_mod.eval(testing.allocator, &prog, &activation);
    defer r1.deinit(testing.allocator);
    try testing.expectEqual(true, r1.bool);

    activation.clearRetainingCapacity();
    try activation.putString("text", "world");
    var r2 = try eval_mod.eval(testing.allocator, &prog, &activation);
    defer r2.deinit(testing.allocator);
    try testing.expectEqual(false, r2.bool);
}

test "precompileArguments is idempotent on re-run (no leak)" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();
    const b = environment.types.builtins;
    try environment.addVarTyped("text", b.string_type);

    var prog = try compile_mod.compile(testing.allocator, &environment, "text.matches('h.*o')");
    defer prog.deinit();

    // Running the pass twice must not leak the first context.
    try optimize(testing.allocator, &prog, &environment, &.{
        constantFolding,
        precompileArguments,
    });
    try optimize(testing.allocator, &prog, &environment, &.{
        precompileArguments,
    });

    // Eval still works after the re-run.
    var activation = activation_mod.Activation.init(testing.allocator);
    defer activation.deinit();
    try activation.putString("text", "hello");
    var r = try eval_mod.eval(testing.allocator, &prog, &activation);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(true, r.bool);
}

test "precompileArguments skips when pattern is not a literal" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();
    const b = environment.types.builtins;
    try environment.addVarTyped("text", b.string_type);
    try environment.addVarTyped("pat", b.string_type);

    var prog = try compile_mod.compile(testing.allocator, &environment, "text.matches(pat)");
    defer prog.deinit();
    try optimize(testing.allocator, &prog, &environment, &.{
        constantFolding,
        precompileArguments,
    });

    // No precompiled context because the pattern arg is a variable.
    for (prog.prepared.items) |maybe| {
        try testing.expect(maybe == null);
    }

    // Falls through to the normal implementation; eval still works.
    var activation = activation_mod.Activation.init(testing.allocator);
    defer activation.deinit();
    try activation.putString("text", "hello");
    try activation.putString("pat", "h.*o");
    var r = try eval_mod.eval(testing.allocator, &prog, &activation);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(true, r.bool);
}

test "comprehension folding on literal iterables" {
    var environment = try Env.initDefault(testing.allocator);
    defer environment.deinit();

    // exists with literal list and literal predicate folds to true.
    try expectFolded(&environment, "[1, 2, 3].exists(x, x > 2)", null, true, null, null, null);
    // all with literal list folds.
    try expectFolded(&environment, "[1, 2, 3].all(x, x > 0)", null, true, null, null, null);
    try expectFolded(&environment, "[1, 2, 3].all(x, x > 5)", null, false, null, null, null);
    // exists_one.
    try expectFolded(&environment, "[1, 2, 3].exists_one(x, x == 2)", null, true, null, null, null);
    // filter produces a list, which can't become a literal, so the
    // root stays a receiver_call. But size(filter(...)) should fold.
    try expectFolded(&environment, "[1, 2, 3].filter(x, x > 1).size()", 2, null, null, null, null);
    // map then size.
    try expectFolded(&environment, "[1, 2].map(x, x * 2).size()", 2, null, null, null, null);
}

