const std = @import("std");
const cel = @import("cel");

test "scratch-backed scalar evaluation stays allocation-free across many iterations" {
    var environment = try cel.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("a", environment.types.builtins.int_type);
    try environment.addVarTyped("b", environment.types.builtins.int_type);
    try environment.addVarTyped("c", environment.types.builtins.int_type);

    var program = try cel.compile(std.testing.allocator, &environment, "a < b && c == 9");
    defer program.deinit();

    var activation = cel.Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.put("a", .{ .int = 1 });
    try activation.put("b", .{ .int = 2 });
    try activation.put("c", .{ .int = 9 });

    var storage: [1]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(storage[0..]);
    var scratch = cel.EvalScratch.init(fba.allocator());
    defer scratch.deinit();

    var i: usize = 0;
    while (i < 50_000) : (i += 1) {
        var result = try cel.evaluateWithScratch(&scratch, &program, &activation);
        defer result.deinit(fba.allocator());
        try std.testing.expect(result == .bool);
        try std.testing.expect(result.bool);
    }
}

test "scratch-backed function calls avoid per-call allocations" {
    const Helpers = struct {
        fn twice(allocator: std.mem.Allocator, args: []const cel.value.Value) cel.env.EvalError!cel.value.Value {
            _ = allocator;
            if (args.len != 1 or args[0] != .int) return cel.value.RuntimeError.NoMatchingOverload;
            return .{ .int = args[0].int * 2 };
        }
    };

    var environment = try cel.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.int_type);
    _ = try environment.addFunction(
        "twice",
        false,
        &.{environment.types.builtins.int_type},
        environment.types.builtins.int_type,
        Helpers.twice,
    );

    var program = try cel.compile(std.testing.allocator, &environment, "twice(x) == 10");
    defer program.deinit();

    var activation = cel.Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.put("x", .{ .int = 5 });

    var storage: [1]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(storage[0..]);
    var scratch = cel.EvalScratch.init(fba.allocator());
    defer scratch.deinit();

    var i: usize = 0;
    while (i < 50_000) : (i += 1) {
        var result = try cel.evaluateWithScratch(&scratch, &program, &activation);
        defer result.deinit(fba.allocator());
        try std.testing.expect(result == .bool);
        try std.testing.expect(result.bool);
    }
}

test "borrowed scratch evaluation supports repeated composite results" {
    var environment = try cel.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var program = try cel.compile(
        std.testing.allocator,
        &environment,
        "[1, 2, 3, 4, 5, 6].filter(x, x % 2 == 0).map(x, x * x)",
    );
    defer program.deinit();

    var activation = cel.Activation.init(std.testing.allocator);
    defer activation.deinit();

    var storage: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(storage[0..]);
    var scratch = cel.EvalScratch.init(fba.allocator());
    defer scratch.deinit();

    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const result = try cel.evaluateBorrowedWithScratch(&scratch, &program, &activation);
        try std.testing.expect(result == .list);
        try std.testing.expectEqual(@as(usize, 3), result.list.items.len);
        try std.testing.expectEqual(@as(i64, 4), result.list.items[0].int);
        try std.testing.expectEqual(@as(i64, 16), result.list.items[1].int);
        try std.testing.expectEqual(@as(i64, 36), result.list.items[2].int);
    }
}

test "borrowed scratch evaluation can be promoted to owned when needed" {
    var environment = try cel.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var program = try cel.compile(
        std.testing.allocator,
        &environment,
        "[1, 2, 3].map(x, x * 2)",
    );
    defer program.deinit();

    var activation = cel.Activation.init(std.testing.allocator);
    defer activation.deinit();

    var storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(storage[0..]);
    var scratch = cel.EvalScratch.init(fba.allocator());
    defer scratch.deinit();

    const borrowed = try cel.evaluateBorrowedWithScratch(&scratch, &program, &activation);
    var owned = try borrowed.clone(std.testing.allocator);
    defer owned.deinit(std.testing.allocator);

    try std.testing.expect(owned == .list);
    try std.testing.expectEqual(@as(usize, 3), owned.list.items.len);
    try std.testing.expectEqual(@as(i64, 2), owned.list.items[0].int);
    try std.testing.expectEqual(@as(i64, 4), owned.list.items[1].int);
    try std.testing.expectEqual(@as(i64, 6), owned.list.items[2].int);
}

test "long logical chains compile and evaluate correctly" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "flag");
    for (0..512) |_| {
        try source.appendSlice(std.testing.allocator, " && flag");
    }

    var environment = try cel.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("flag", environment.types.builtins.bool_type);

    var program = try cel.compile(std.testing.allocator, &environment, source.items);
    defer program.deinit();

    var activation = cel.Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.put("flag", .{ .bool = true });

    var result = try cel.evaluate(std.testing.allocator, &program, &activation, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .bool);
    try std.testing.expect(result.bool);
}
