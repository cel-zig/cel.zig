const std = @import("std");
const ast = @import("../parse/ast.zig");
const value = @import("../env/value.zig");

/// A decorator is a pluggable interceptor that wraps eval steps for
/// instrumentation, tracing, or custom dispatch.
pub const Decorator = struct {
    /// Called before evaluating a node. Return non-null to skip evaluation
    /// and use the returned value instead.
    before_eval: ?*const fn (ctx: *anyopaque, node_index: ast.Index) ?value.Value = null,

    /// Called after evaluating a node with the result.
    after_eval: ?*const fn (ctx: *anyopaque, node_index: ast.Index, result: value.Value) void = null,

    /// User context pointer.
    context: *anyopaque,
};

/// Counts how many nodes were evaluated.
pub const NodeCounter = struct {
    count: u64 = 0,

    pub fn decorator(self: *NodeCounter) Decorator {
        return .{
            .context = @ptrCast(self),
            .after_eval = &afterEval,
        };
    }

    fn afterEval(ctx: *anyopaque, _: ast.Index, _: value.Value) void {
        const self: *NodeCounter = @ptrCast(@alignCast(ctx));
        self.count += 1;
    }
};

/// Records which nodes were evaluated.
pub const TraceCollector = struct {
    entries: std.ArrayListUnmanaged(TraceEntry),
    allocator: std.mem.Allocator,

    pub const TraceEntry = struct {
        node_index: u32,
        result_tag: std.meta.Tag(value.Value),
    };

    pub fn init(allocator: std.mem.Allocator) TraceCollector {
        return .{
            .entries = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TraceCollector) void {
        self.entries.deinit(self.allocator);
    }

    pub fn decorator(self: *TraceCollector) Decorator {
        return .{
            .context = @ptrCast(self),
            .after_eval = &afterEval,
        };
    }

    fn afterEval(ctx: *anyopaque, node_index: ast.Index, result: value.Value) void {
        const self: *TraceCollector = @ptrCast(@alignCast(ctx));
        self.entries.append(self.allocator, .{
            .node_index = @intFromEnum(node_index),
            .result_tag = std.meta.activeTag(result),
        }) catch {};
    }
};

test "node counter decorator" {
    const compile_mod = @import("../compiler/compile.zig");
    const eval_impl = @import("eval.zig");
    const Activation = @import("activation.zig").Activation;
    const Env = @import("../env/env.zig").Env;

    var environment = try Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const cases = [_]struct { expr: []const u8, expected_count: u64 }{
        .{ .expr = "1", .expected_count = 1 },
        .{ .expr = "1 + 2", .expected_count = 3 },
        .{ .expr = "true ? 1 : 2", .expected_count = 3 },
        .{ .expr = "true && false", .expected_count = 3 },
        .{ .expr = "!true", .expected_count = 2 },
    };

    for (cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var activation = Activation.init(std.testing.allocator);
        defer activation.deinit();

        var counter = NodeCounter{};
        const decorators = [_]Decorator{counter.decorator()};
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{
            .decorators = &decorators,
        });
        defer result.deinit(std.testing.allocator);

        try std.testing.expectEqual(case.expected_count, counter.count);
    }
}

test "trace collector decorator" {
    const compile_mod = @import("../compiler/compile.zig");
    const eval_impl = @import("eval.zig");
    const Activation = @import("activation.zig").Activation;
    const Env = @import("../env/env.zig").Env;

    var environment = try Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var program = try compile_mod.compile(std.testing.allocator, &environment, "1 + 2");
    defer program.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var tracer = TraceCollector.init(std.testing.allocator);
    defer tracer.deinit();
    const decorators = [_]Decorator{tracer.decorator()};
    var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{
        .decorators = &decorators,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), tracer.entries.items.len);
    // Both literals should be int, and the binary result should be int
    for (tracer.entries.items) |entry| {
        try std.testing.expectEqual(std.meta.Tag(value.Value).int, entry.result_tag);
    }
}

test "multiple decorators compose" {
    const compile_mod = @import("../compiler/compile.zig");
    const eval_impl = @import("eval.zig");
    const Activation = @import("activation.zig").Activation;
    const Env = @import("../env/env.zig").Env;

    var environment = try Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var program = try compile_mod.compile(std.testing.allocator, &environment, "1 + 2");
    defer program.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var counter = NodeCounter{};
    var tracer = TraceCollector.init(std.testing.allocator);
    defer tracer.deinit();

    const decorators = [_]Decorator{ counter.decorator(), tracer.decorator() };
    var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{
        .decorators = &decorators,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 3), counter.count);
    try std.testing.expectEqual(@as(usize, 3), tracer.entries.items.len);
}

test "before_eval can short-circuit" {
    const compile_mod = @import("../compiler/compile.zig");
    const eval_impl = @import("eval.zig");
    const Activation = @import("activation.zig").Activation;
    const Env = @import("../env/env.zig").Env;

    var environment = try Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    // Compile "1 + 2" but intercept to always return 42
    var program = try compile_mod.compile(std.testing.allocator, &environment, "1 + 2");
    defer program.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const Interceptor = struct {
        called: u64 = 0,

        fn beforeEval(ctx: *anyopaque, _: ast.Index) ?value.Value {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called += 1;
            // Short-circuit: always return 42 for the root node (called first)
            if (self.called == 1) return .{ .int = 42 };
            return null;
        }
    };

    var interceptor = Interceptor{};
    const decorators = [_]Decorator{.{
        .context = @ptrCast(&interceptor),
        .before_eval = &Interceptor.beforeEval,
    }};
    var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{
        .decorators = &decorators,
    });
    defer result.deinit(std.testing.allocator);

    // The interceptor returned 42 on the first (root) node, so no children
    // were evaluated and the final result should be 42.
    try std.testing.expectEqual(@as(i64, 42), result.int);
    try std.testing.expectEqual(@as(u64, 1), interceptor.called);
}
