const std = @import("std");
const ast = @import("../parse/ast.zig");
const compiler_program = @import("../compiler/program.zig");
const env_mod = @import("../env/env.zig");

pub const CostEstimate = struct {
    min: u64,
    max: u64,

    fn add(a: CostEstimate, b: CostEstimate) CostEstimate {
        return .{
            .min = a.min +| b.min,
            .max = a.max +| b.max,
        };
    }

    fn addScalar(self: CostEstimate, n: u64) CostEstimate {
        return .{
            .min = self.min +| n,
            .max = self.max +| n,
        };
    }

    fn maxOf(a: CostEstimate, b: CostEstimate) CostEstimate {
        return .{
            .min = @max(a.min, b.min),
            .max = @max(a.max, b.max),
        };
    }
};

const Program = compiler_program.Program;
const MacroCall = compiler_program.MacroCall;
const CallResolution = compiler_program.CallResolution;

/// Walk a checked Program's AST and produce a static cost estimate.
pub fn estimateCost(program: *const Program) CostEstimate {
    const root = program.ast.root orelse return .{ .min = 0, .max = 0 };
    return estimateNode(program, root);
}

fn estimateNode(program: *const Program, index: ast.Index) CostEstimate {
    const node = program.ast.node(index);
    return switch (node.data) {
        .literal_int,
        .literal_uint,
        .literal_double,
        .literal_bool,
        .literal_null,
        .literal_string,
        .literal_bytes,
        => .{ .min = 0, .max = 0 },

        .ident => .{ .min = 1, .max = 1 },

        .unary => |u| estimateNode(program, u.expr).addScalar(1),

        .binary => |b| blk: {
            const left = estimateNode(program, b.left);
            const right = estimateNode(program, b.right);
            break :blk left.add(right).addScalar(1);
        },

        .conditional => |c| blk: {
            const cond = estimateNode(program, c.condition);
            const then_cost = estimateNode(program, c.then_expr);
            const else_cost = estimateNode(program, c.else_expr);
            break :blk cond.add(CostEstimate.maxOf(then_cost, else_cost)).addScalar(1);
        },

        .list => |range| blk: {
            var sum = CostEstimate{ .min = 0, .max = 0 };
            for (0..range.len) |i| {
                const item = program.ast.list_items.items[range.start + i];
                sum = sum.add(estimateNode(program, item.value));
            }
            break :blk sum.addScalar(10);
        },

        .map => |range| blk: {
            var sum = CostEstimate{ .min = 0, .max = 0 };
            for (0..range.len) |i| {
                const entry = program.ast.map_entries.items[range.start + i];
                sum = sum.add(estimateNode(program, entry.key));
                sum = sum.add(estimateNode(program, entry.value));
            }
            break :blk sum.addScalar(30);
        },

        .message => |msg| blk: {
            var sum = CostEstimate{ .min = 0, .max = 0 };
            for (0..msg.fields.len) |i| {
                const field = program.ast.field_inits.items[msg.fields.start + i];
                sum = sum.add(estimateNode(program, field.value));
            }
            break :blk sum.addScalar(40);
        },

        .select => |sel| estimateNode(program, sel.target).addScalar(1),

        .index => |access| blk: {
            const target = estimateNode(program, access.target);
            const idx = estimateNode(program, access.index);
            break :blk target.add(idx).addScalar(1);
        },

        .call => |call| estimateCall(program, index, call.args, null),

        .receiver_call => |call| estimateCall(program, index, call.args, call.target),
    };
}

fn estimateCall(
    program: *const Program,
    node_index: ast.Index,
    args_range: ast.Range,
    maybe_target: ?ast.Index,
) CostEstimate {
    const resolution = program.call_resolution.items[@intFromEnum(node_index)];

    switch (resolution) {
        .macro => |macro_call| return estimateMacro(program, macro_call, args_range, maybe_target),
        else => {},
    }

    // Regular function call: cost 10 + sum(args) + target if present
    var sum = CostEstimate{ .min = 0, .max = 0 };
    if (maybe_target) |target| {
        sum = sum.add(estimateNode(program, target));
    }
    for (0..args_range.len) |i| {
        const arg_index = program.ast.expr_ranges.items[args_range.start + i];
        sum = sum.add(estimateNode(program, arg_index));
    }

    // Check if this is a matches/regex call by looking at function name
    if (isMatchesCall(program, node_index)) {
        return sum.addScalar(30);
    }

    return sum.addScalar(10);
}

fn isMatchesCall(program: *const Program, node_index: ast.Index) bool {
    const node = program.ast.node(node_index);
    switch (node.data) {
        .receiver_call => |call| {
            const name = program.ast.strings.get(call.name);
            return std.mem.eql(u8, name, "matches");
        },
        else => return false,
    }
}

fn estimateMacro(
    program: *const Program,
    macro_call: MacroCall,
    args_range: ast.Range,
    maybe_target: ?ast.Index,
) CostEstimate {
    switch (macro_call) {
        // has(x.field) => cost 1
        .has => return .{ .min = 1, .max = 1 },

        // cel.bind(var, init, body) => cost 1 + init + body
        .bind => {
            if (args_range.len >= 3) {
                const init_expr = program.ast.expr_ranges.items[args_range.start + 1];
                const body_expr = program.ast.expr_ranges.items[args_range.start + 2];
                const init_cost = estimateNode(program, init_expr);
                const body_cost = estimateNode(program, body_expr);
                return init_cost.add(body_cost).addScalar(1);
            }
            return .{ .min = 1, .max = 1 };
        },

        // block => cost 1 + sum(bindings) + body
        .block => {
            var sum = CostEstimate{ .min = 0, .max = 0 };
            for (0..args_range.len) |i| {
                const arg_index = program.ast.expr_ranges.items[args_range.start + i];
                sum = sum.add(estimateNode(program, arg_index));
            }
            return sum.addScalar(1);
        },

        // Comprehension macros: cost 1 + target + iteration_range * body_cost
        .all,
        .exists,
        .exists_one,
        .filter,
        .map,
        .map_filter,
        .sort_by,
        .transform_list,
        .transform_list_filter,
        .transform_map,
        .transform_map_filter,
        .transform_map_entry,
        .transform_map_entry_filter,
        => {
            var target_cost = CostEstimate{ .min = 0, .max = 0 };
            if (maybe_target) |target| {
                target_cost = estimateNode(program, target);
            }

            // The last arg in the range is typically the body expression
            var body_cost = CostEstimate{ .min = 1, .max = 1 };
            if (args_range.len > 0) {
                const body_index = program.ast.expr_ranges.items[args_range.start + args_range.len - 1];
                body_cost = estimateNode(program, body_index);
            }

            // Unknown collection size: min=1 iteration, max=1000
            return .{
                .min = 1 +| target_cost.min +| 1 *| body_cost.min,
                .max = 1 +| target_cost.max +| 1000 *| body_cost.max,
            };
        },

        // opt_map / opt_flat_map: cost 1 + target + body
        .opt_map, .opt_flat_map => {
            var sum = CostEstimate{ .min = 0, .max = 0 };
            if (maybe_target) |target| {
                sum = sum.add(estimateNode(program, target));
            }
            if (args_range.len > 0) {
                const body_index = program.ast.expr_ranges.items[args_range.start + args_range.len - 1];
                sum = sum.add(estimateNode(program, body_index));
            }
            return sum.addScalar(1);
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const compile_mod = @import("../compiler/compile.zig");

test "static cost estimation" {
    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const b = environment.types.builtins;
    try environment.addVarTyped("x", b.int_type);
    try environment.addVarTyped("y", b.int_type);
    try environment.addVarTyped("s", b.string_type);
    try environment.addVarTyped("flag", b.bool_type);
    try environment.addVarTyped("items", try environment.types.listOf(b.int_type));

    const cases = [_]struct { expr: []const u8, expected_min: u64, expected_max: u64 }{
        // Literals (cel-go: cost 0)
        .{ .expr = "1", .expected_min = 0, .expected_max = 0 },
        .{ .expr = "true", .expected_min = 0, .expected_max = 0 },
        .{ .expr = "null", .expected_min = 0, .expected_max = 0 },
        .{ .expr = "'hello'", .expected_min = 0, .expected_max = 0 },
        .{ .expr = "1.5", .expected_min = 0, .expected_max = 0 },
        .{ .expr = "42u", .expected_min = 0, .expected_max = 0 },

        // Identifiers (cost 1)
        .{ .expr = "x", .expected_min = 1, .expected_max = 1 },

        // Unary (1 + child)
        .{ .expr = "!flag", .expected_min = 2, .expected_max = 2 },
        .{ .expr = "-x", .expected_min = 2, .expected_max = 2 },

        // Binary (1 + children)
        .{ .expr = "1 + 2", .expected_min = 1, .expected_max = 1 },
        .{ .expr = "x + y", .expected_min = 3, .expected_max = 3 },
        .{ .expr = "x + y + 1", .expected_min = 4, .expected_max = 4 },
        .{ .expr = "x == y", .expected_min = 3, .expected_max = 3 },

        // Conditional (1 + cond + max(then, else))
        .{ .expr = "flag ? x : y", .expected_min = 3, .expected_max = 3 },
        .{ .expr = "flag ? 1 + 2 : 3", .expected_min = 3, .expected_max = 3 },

        // List construction (cel-go: 10 + sum(elems))
        .{ .expr = "[1, 2, 3]", .expected_min = 10, .expected_max = 10 },
        .{ .expr = "[]", .expected_min = 10, .expected_max = 10 },

        // Map construction (cel-go: 30 + sum(entries))
        .{ .expr = "{1: 2}", .expected_min = 30, .expected_max = 30 },

        // Index access (1 + target + index)
        .{ .expr = "items[0]", .expected_min = 2, .expected_max = 2 },

        // Function call (cost 10 + sum(args))
        .{ .expr = "size(items)", .expected_min = 11, .expected_max = 11 },
        .{ .expr = "int(1.5)", .expected_min = 10, .expected_max = 10 },

        // Receiver call (cost 10 + target + sum(args))
        .{ .expr = "s.size()", .expected_min = 11, .expected_max = 11 },
    };

    for (cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        const est = estimateCost(&program);
        if (est.min != case.expected_min or est.max != case.expected_max) {
            std.debug.print("FAIL: '{s}' => min={d}, max={d}, expected min={d}, max={d}\n", .{
                case.expr, est.min, est.max, case.expected_min, case.expected_max,
            });
        }
        try std.testing.expectEqual(case.expected_min, est.min);
        try std.testing.expectEqual(case.expected_max, est.max);
    }
}

test "comprehension cost estimation has range" {
    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const b = environment.types.builtins;
    try environment.addVarTyped("items", try environment.types.listOf(b.int_type));

    const cases = [_]struct { expr: []const u8, expect_min_gt: u64, expect_max_gt: u64 }{
        // all/exists/filter have min < max due to unknown collection size
        .{ .expr = "items.all(x, x > 0)", .expect_min_gt = 2, .expect_max_gt = 100 },
        .{ .expr = "items.exists(x, x > 0)", .expect_min_gt = 2, .expect_max_gt = 100 },
        .{ .expr = "items.filter(x, x > 0)", .expect_min_gt = 2, .expect_max_gt = 100 },
        .{ .expr = "items.map(x, x + 1)", .expect_min_gt = 2, .expect_max_gt = 100 },
    };

    for (cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        const est = estimateCost(&program);
        try std.testing.expect(est.min >= case.expect_min_gt);
        try std.testing.expect(est.max >= case.expect_max_gt);
        // Comprehensions must have max > min
        try std.testing.expect(est.max > est.min);
    }
}

test "cost estimate properties" {
    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    // Empty program (no root)
    const empty_est = estimateCost(&Program{
        .env = @ptrCast(&environment),
        .ast = ast.Ast.init(std.testing.allocator),
        .analysis_allocator = std.testing.allocator,
        .result_type = environment.types.builtins.dyn_type,
    });
    try std.testing.expectEqual(@as(u64, 0), empty_est.min);
    try std.testing.expectEqual(@as(u64, 0), empty_est.max);

    // min <= max for all expressions
    const exprs = [_][]const u8{
        "1",
        "1 + 2",
        "true ? 1 : 2",
        "[1, 2]",
        "{1: 2}",
    };
    for (exprs) |expr| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        const est = estimateCost(&program);
        try std.testing.expect(est.min <= est.max);
    }
}

// Cost calibration benchmark lives in src/perf.zig (run via `make bench`).
// The test runner suppresses debug output, so benchmarks must be standalone binaries.
