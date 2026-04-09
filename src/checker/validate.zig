const std = @import("std");
const ast = @import("../parse/ast.zig");
const cel_regex = @import("../library/cel_regex.zig");
const cel_time = @import("../library/cel_time.zig");
const program_mod = @import("../compiler/program.zig");
const strings = @import("../parse/string_table.zig");

pub const Program = program_mod.Program;
pub const MacroCall = program_mod.MacroCall;
pub const CallResolution = program_mod.CallResolution;

pub const Issue = struct {
    message: []const u8,
    offset: u32,
    severity: Severity,
    owned: bool = false,

    pub const Severity = enum { warning, err };
};

pub const ValidationResult = struct {
    issues: std.ArrayListUnmanaged(Issue),
    allocator: std.mem.Allocator,

    pub fn hasErrors(self: *const ValidationResult) bool {
        for (self.issues.items) |issue| {
            if (issue.severity == .err) return true;
        }
        return false;
    }

    pub fn deinit(self: *ValidationResult) void {
        for (self.issues.items) |issue| {
            if (issue.owned) {
                self.allocator.free(issue.message);
            }
        }
        self.issues.deinit(self.allocator);
    }
};

pub const Validator = *const fn (
    allocator: std.mem.Allocator,
    program: *const Program,
    result: *ValidationResult,
) anyerror!void;

pub fn validate(
    allocator: std.mem.Allocator,
    program: *const Program,
    validators: []const Validator,
) !ValidationResult {
    var result = ValidationResult{
        .issues = .empty,
        .allocator = allocator,
    };
    errdefer result.deinit();

    for (validators) |v| {
        try v(allocator, program, &result);
    }
    return result;
}

// ---------------------------------------------------------------------------
// Built-in validators
// ---------------------------------------------------------------------------

const default_max_comprehension_depth: u32 = 4;
const default_max_nodes: u32 = 10_000;

/// Validate that comprehension (macro) nesting does not exceed a limit.
pub fn comprehensionDepthValidator(
    allocator: std.mem.Allocator,
    program: *const Program,
    result: *ValidationResult,
) anyerror!void {
    return comprehensionDepthValidatorWithLimit(allocator, program, result, default_max_comprehension_depth);
}

pub fn comprehensionDepthValidatorWithLimit(
    allocator: std.mem.Allocator,
    program: *const Program,
    result: *ValidationResult,
    max_depth: u32,
) anyerror!void {
    if (program.ast.root == null) return;
    try walkComprehensionDepth(allocator, program, result, program.ast.root.?, 0, max_depth);
}

fn isComprehensionMacro(macro: MacroCall) bool {
    return switch (macro) {
        .all, .exists, .exists_one, .filter, .map, .map_filter, .sort_by,
        .transform_list, .transform_list_filter, .transform_map,
        .transform_map_filter, .transform_map_entry, .transform_map_entry_filter,
        .opt_map, .opt_flat_map,
        => true,
        .has, .bind, .block => false,
    };
}

fn walkComprehensionDepth(
    allocator: std.mem.Allocator,
    program: *const Program,
    result: *ValidationResult,
    index: ast.Index,
    current_depth: u32,
    max_depth: u32,
) anyerror!void {
    const idx = @intFromEnum(index);
    const node = program.ast.node(index);

    // Check if this node is a comprehension macro.
    var depth = current_depth;
    if (idx < program.call_resolution.items.len) {
        const res = program.call_resolution.items[idx];
        switch (res) {
            .macro => |m| {
                if (isComprehensionMacro(m)) {
                    depth += 1;
                    if (depth > max_depth) {
                        const msg = try std.fmt.allocPrint(allocator, "comprehension nesting depth {d} exceeds limit of {d}", .{ depth, max_depth });
                        try result.issues.append(allocator, .{
                            .message = msg,
                            .offset = node.where.start,
                            .severity = .err,
                            .owned = true,
                        });
                        return; // No need to descend further.
                    }
                }
            },
            else => {},
        }
    }

    // Recurse into children.
    switch (node.data) {
        .unary => |u| try walkComprehensionDepth(allocator, program, result, u.expr, depth, max_depth),
        .binary => |b| {
            try walkComprehensionDepth(allocator, program, result, b.left, depth, max_depth);
            try walkComprehensionDepth(allocator, program, result, b.right, depth, max_depth);
        },
        .conditional => |c| {
            try walkComprehensionDepth(allocator, program, result, c.condition, depth, max_depth);
            try walkComprehensionDepth(allocator, program, result, c.then_expr, depth, max_depth);
            try walkComprehensionDepth(allocator, program, result, c.else_expr, depth, max_depth);
        },
        .call => |call| {
            const args = program.ast.expr_ranges.items[call.args.start..][0..call.args.len];
            for (args) |arg| {
                try walkComprehensionDepth(allocator, program, result, arg, depth, max_depth);
            }
        },
        .receiver_call => |rc| {
            try walkComprehensionDepth(allocator, program, result, rc.target, depth, max_depth);
            const args = program.ast.expr_ranges.items[rc.args.start..][0..rc.args.len];
            for (args) |arg| {
                try walkComprehensionDepth(allocator, program, result, arg, depth, max_depth);
            }
        },
        .select => |s| try walkComprehensionDepth(allocator, program, result, s.target, depth, max_depth),
        .index => |ia| {
            try walkComprehensionDepth(allocator, program, result, ia.target, depth, max_depth);
            try walkComprehensionDepth(allocator, program, result, ia.index, depth, max_depth);
        },
        .list => |range| {
            const items = program.ast.list_items.items[range.start..][0..range.len];
            for (items) |item| {
                try walkComprehensionDepth(allocator, program, result, item.value, depth, max_depth);
            }
        },
        .map => |range| {
            const entries = program.ast.map_entries.items[range.start..][0..range.len];
            for (entries) |entry| {
                try walkComprehensionDepth(allocator, program, result, entry.key, depth, max_depth);
                try walkComprehensionDepth(allocator, program, result, entry.value, depth, max_depth);
            }
        },
        .message => |msg| {
            const fields = program.ast.field_inits.items[msg.fields.start..][0..msg.fields.len];
            for (fields) |field| {
                try walkComprehensionDepth(allocator, program, result, field.value, depth, max_depth);
            }
        },
        // Leaf nodes — no children.
        .ident, .literal_int, .literal_uint, .literal_double,
        .literal_string, .literal_bytes, .literal_bool, .literal_null,
        => {},
    }
}

/// Validate that the total number of AST nodes does not exceed a limit.
pub fn nodeLimitValidator(
    allocator: std.mem.Allocator,
    program: *const Program,
    result: *ValidationResult,
) anyerror!void {
    return nodeLimitValidatorWithLimit(allocator, program, result, default_max_nodes);
}

pub fn nodeLimitValidatorWithLimit(
    allocator: std.mem.Allocator,
    program: *const Program,
    result: *ValidationResult,
    max_nodes: u32,
) anyerror!void {
    const count: u32 = @intCast(program.ast.nodes.items.len);
    if (count > max_nodes) {
        const msg = try std.fmt.allocPrint(allocator, "expression has {d} nodes, exceeding limit of {d}", .{ count, max_nodes });
        try result.issues.append(allocator, .{
            .message = msg,
            .offset = 0,
            .severity = .err,
            .owned = true,
        });
    }
}

/// Validate that regex patterns in matches() calls are valid.
pub fn regexValidator(
    allocator: std.mem.Allocator,
    program: *const Program,
    result: *ValidationResult,
) anyerror!void {
    for (program.ast.nodes.items, 0..) |node, i| {
        switch (node.data) {
            .receiver_call => |rc| {
                // Check if this is a matches() call.
                const name = program.ast.strings.get(rc.name);
                if (!std.mem.eql(u8, name, "matches")) continue;

                // The pattern is the first argument.
                if (rc.args.len < 1) continue;
                const arg_idx = program.ast.expr_ranges.items[rc.args.start];
                const arg_node = program.ast.node(arg_idx);
                switch (arg_node.data) {
                    .literal_string => |str_id| {
                        const pattern = program.ast.strings.get(str_id);
                        // Try to compile the pattern.
                        _ = cel_regex.matches(allocator, "", pattern) catch |err| switch (err) {
                            cel_regex.Error.InvalidPattern => {
                                const msg = try std.fmt.allocPrint(allocator, "invalid regex pattern: \"{s}\"", .{pattern});
                                try result.issues.append(allocator, .{
                                    .message = msg,
                                    .offset = program.ast.nodes.items[i].where.start,
                                    .severity = .err,
                                    .owned = true,
                                });
                                continue;
                            },
                            else => |other| return other,
                        };
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

/// Validate that duration() and timestamp() calls with string literal
/// arguments use valid formats.
pub fn timeLiteralValidator(
    allocator: std.mem.Allocator,
    program: *const Program,
    result: *ValidationResult,
) anyerror!void {
    for (program.ast.nodes.items, 0..) |node, i| {
        switch (node.data) {
            .call => |call| {
                // Resolve the function name from segments.
                if (call.name.segments.len != 1) continue;
                const name_id = program.ast.name_segments.items[call.name.segments.start];
                const name = program.ast.strings.get(name_id);

                const is_duration = std.mem.eql(u8, name, "duration");
                const is_timestamp = std.mem.eql(u8, name, "timestamp");
                if (!is_duration and !is_timestamp) continue;

                // Check the first argument.
                if (call.args.len < 1) continue;
                const arg_idx = program.ast.expr_ranges.items[call.args.start];
                const arg_node = program.ast.node(arg_idx);
                switch (arg_node.data) {
                    .literal_string => |str_id| {
                        const literal = program.ast.strings.get(str_id);
                        if (is_duration) {
                            _ = cel_time.parseDuration(literal) catch {
                                const msg = try std.fmt.allocPrint(allocator, "invalid duration literal: \"{s}\"", .{literal});
                                try result.issues.append(allocator, .{
                                    .message = msg,
                                    .offset = program.ast.nodes.items[i].where.start,
                                    .severity = .err,
                                    .owned = true,
                                });
                                continue;
                            };
                        } else {
                            _ = cel_time.parseTimestamp(literal) catch {
                                const msg = try std.fmt.allocPrint(allocator, "invalid timestamp literal: \"{s}\"", .{literal});
                                try result.issues.append(allocator, .{
                                    .message = msg,
                                    .offset = program.ast.nodes.items[i].where.start,
                                    .severity = .err,
                                    .owned = true,
                                });
                                continue;
                            };
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Default validation
// ---------------------------------------------------------------------------

pub fn validateDefault(
    allocator: std.mem.Allocator,
    program: *const Program,
) !ValidationResult {
    return validate(allocator, program, &.{
        comprehensionDepthValidator,
        nodeLimitValidator,
        regexValidator,
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const compile_mod = @import("../compiler/compile.zig");
const Env = @import("../env/env.zig").Env;

fn compileExpr(allocator: std.mem.Allocator, environment: *Env, expr: []const u8) !Program {
    return compile_mod.compile(allocator, environment, expr);
}

test "node count validation" {
    var environment = try Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const cases = [_]struct { expr: []const u8, max_nodes: u32, has_errors: bool }{
        .{ .expr = "1", .max_nodes = 10, .has_errors = false },
        .{ .expr = "1 + 2 + 3 + 4 + 5", .max_nodes = 3, .has_errors = true },
        .{ .expr = "1 + 2", .max_nodes = 100, .has_errors = false },
        .{ .expr = "1 + 2", .max_nodes = 3, .has_errors = false },
        .{ .expr = "1 + 2 + 3", .max_nodes = 2, .has_errors = true },
        .{ .expr = "true", .max_nodes = 1, .has_errors = false },
        .{ .expr = "true && false", .max_nodes = 2, .has_errors = true },
        .{ .expr = "'hello'", .max_nodes = 1, .has_errors = false },
        .{ .expr = "'hello' + ' ' + 'world'", .max_nodes = 2, .has_errors = true },
        .{ .expr = "1", .max_nodes = 0, .has_errors = true },
    };
    for (cases) |case| {
        var prog = try compileExpr(std.testing.allocator, &environment, case.expr);
        defer prog.deinit();
        var result = ValidationResult{ .issues = .empty, .allocator = std.testing.allocator };
        defer result.deinit();
        try nodeLimitValidatorWithLimit(std.testing.allocator, &prog, &result, case.max_nodes);
        try std.testing.expectEqual(case.has_errors, result.hasErrors());
    }
}

test "comprehension depth validation" {
    var environment = try Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const b = environment.types.builtins;
    try environment.addVarTyped("xs", try environment.types.listOf(b.int_type));
    try environment.addVarTyped("ys", try environment.types.listOf(b.int_type));
    try environment.addVarTyped("zs", try environment.types.listOf(b.int_type));
    try environment.addVarTyped("ws", try environment.types.listOf(b.int_type));
    try environment.addVarTyped("vs", try environment.types.listOf(b.int_type));

    const cases = [_]struct { expr: []const u8, max_depth: u32, has_errors: bool }{
        // No comprehension.
        .{ .expr = "1 + 2", .max_depth = 1, .has_errors = false },
        // Single level — within limit.
        .{ .expr = "xs.all(x, x > 0)", .max_depth = 1, .has_errors = false },
        // Single level — within larger limit.
        .{ .expr = "xs.exists(x, x > 0)", .max_depth = 4, .has_errors = false },
        // Two levels — within limit.
        .{ .expr = "xs.all(x, ys.all(y, true))", .max_depth = 2, .has_errors = false },
        // Two levels — exceeds limit of 1.
        .{ .expr = "xs.all(x, ys.all(y, true))", .max_depth = 1, .has_errors = true },
        // Three levels — exceeds limit of 2.
        .{ .expr = "xs.all(x, ys.all(y, zs.all(z, true)))", .max_depth = 2, .has_errors = true },
        // Filter is also a comprehension.
        .{ .expr = "xs.filter(x, x > 0)", .max_depth = 1, .has_errors = false },
        // Map is also a comprehension.
        .{ .expr = "xs.map(x, x + 1)", .max_depth = 1, .has_errors = false },
        // exists_one is a comprehension.
        .{ .expr = "xs.exists_one(x, x > 0)", .max_depth = 1, .has_errors = false },
        // Default limit (4) — 4 levels should be fine.
        .{ .expr = "xs.all(x, ys.all(y, zs.all(z, ws.all(w, true))))", .max_depth = 4, .has_errors = false },
        // 5 levels exceeds default limit of 4.
        .{ .expr = "xs.all(x, ys.all(y, zs.all(z, ws.all(w, vs.all(v, true)))))", .max_depth = 4, .has_errors = true },
    };
    for (cases) |case| {
        var prog = try compileExpr(std.testing.allocator, &environment, case.expr);
        defer prog.deinit();
        var result = ValidationResult{ .issues = .empty, .allocator = std.testing.allocator };
        defer result.deinit();
        try comprehensionDepthValidatorWithLimit(std.testing.allocator, &prog, &result, case.max_depth);
        try std.testing.expectEqual(case.has_errors, result.hasErrors());
    }
}

test "regex pattern validation" {
    var environment = try Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const cases = [_]struct { expr: []const u8, has_errors: bool }{
        // Valid patterns.
        .{ .expr = "'hello'.matches('hello')", .has_errors = false },
        .{ .expr = "'hello'.matches('h.*o')", .has_errors = false },
        .{ .expr = "'test'.matches('a+')", .has_errors = false },
        .{ .expr = "'test'.matches('(a|b)+')", .has_errors = false },
        .{ .expr = "'test'.matches('')", .has_errors = false },
        .{ .expr = "'test'.matches('a{3}')", .has_errors = false },
        // Invalid patterns.
        .{ .expr = "'test'.matches('(abc')", .has_errors = true },
        .{ .expr = "'test'.matches('abc)')", .has_errors = true },
        .{ .expr = "'test'.matches('\\\\')", .has_errors = true },
        .{ .expr = "'test'.matches('a{}')", .has_errors = true },
        .{ .expr = "'test'.matches('a{3,1}')", .has_errors = true },
    };
    for (cases) |case| {
        var prog = try compileExpr(std.testing.allocator, &environment, case.expr);
        defer prog.deinit();
        var result = ValidationResult{ .issues = .empty, .allocator = std.testing.allocator };
        defer result.deinit();
        try regexValidator(std.testing.allocator, &prog, &result);
        try std.testing.expectEqual(case.has_errors, result.hasErrors());
    }
}

test "duration literal validation" {
    var environment = try Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const cases = [_]struct { expr: []const u8, has_errors: bool }{
        // Valid durations.
        .{ .expr = "duration('1s')", .has_errors = false },
        .{ .expr = "duration('500ms')", .has_errors = false },
        .{ .expr = "duration('1h30m')", .has_errors = false },
        .{ .expr = "duration('0')", .has_errors = false },
        .{ .expr = "duration('-1s')", .has_errors = false },
        // Invalid durations.
        .{ .expr = "duration('bogus')", .has_errors = true },
        .{ .expr = "duration('')", .has_errors = true },
        .{ .expr = "duration('abc123')", .has_errors = true },
    };
    for (cases) |case| {
        var prog = try compileExpr(std.testing.allocator, &environment, case.expr);
        defer prog.deinit();
        var result = ValidationResult{ .issues = .empty, .allocator = std.testing.allocator };
        defer result.deinit();
        try timeLiteralValidator(std.testing.allocator, &prog, &result);
        try std.testing.expectEqual(case.has_errors, result.hasErrors());
    }
}

test "timestamp literal validation" {
    var environment = try Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const cases = [_]struct { expr: []const u8, has_errors: bool }{
        // Valid timestamps.
        .{ .expr = "timestamp('2023-01-01T00:00:00Z')", .has_errors = false },
        .{ .expr = "timestamp('2023-06-15T12:30:00Z')", .has_errors = false },
        .{ .expr = "timestamp('2023-01-01T00:00:00+00:00')", .has_errors = false },
        // Invalid timestamps.
        .{ .expr = "timestamp('not-a-timestamp')", .has_errors = true },
        .{ .expr = "timestamp('')", .has_errors = true },
        .{ .expr = "timestamp('2023')", .has_errors = true },
        .{ .expr = "timestamp('12:00:00')", .has_errors = true },
    };
    for (cases) |case| {
        var prog = try compileExpr(std.testing.allocator, &environment, case.expr);
        defer prog.deinit();
        var result = ValidationResult{ .issues = .empty, .allocator = std.testing.allocator };
        defer result.deinit();
        try timeLiteralValidator(std.testing.allocator, &prog, &result);
        try std.testing.expectEqual(case.has_errors, result.hasErrors());
    }
}

test "validate runs multiple validators" {
    var environment = try Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var prog = try compileExpr(std.testing.allocator, &environment, "1 + 2");
    defer prog.deinit();

    // Both validators should run without issues.
    var result = try validate(std.testing.allocator, &prog, &.{
        nodeLimitValidator,
        regexValidator,
    });
    defer result.deinit();
    try std.testing.expect(!result.hasErrors());
}

test "validateDefault runs without errors on simple expressions" {
    var environment = try Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const cases = [_][]const u8{
        "1 + 2",
        "true",
        "'hello'",
        "1 == 2",
    };
    for (cases) |expr| {
        var prog = try compileExpr(std.testing.allocator, &environment, expr);
        defer prog.deinit();
        var result = try validateDefault(std.testing.allocator, &prog);
        defer result.deinit();
        try std.testing.expect(!result.hasErrors());
    }
}

test "ValidationResult.hasErrors distinguishes severity" {
    var result = ValidationResult{
        .issues = .empty,
        .allocator = std.testing.allocator,
    };
    defer result.deinit();

    // Empty — no errors.
    try std.testing.expect(!result.hasErrors());

    // Warning only — no errors.
    try result.issues.append(std.testing.allocator, .{
        .message = "just a warning",
        .offset = 0,
        .severity = .warning,
    });
    try std.testing.expect(!result.hasErrors());

    // Add an error — now has errors.
    try result.issues.append(std.testing.allocator, .{
        .message = "an error",
        .offset = 0,
        .severity = .err,
    });
    try std.testing.expect(result.hasErrors());
}
