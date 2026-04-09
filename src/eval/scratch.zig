const std = @import("std");
const ast = @import("../parse/ast.zig");
const compiler_program = @import("../compiler/program.zig");
const value = @import("../env/value.zig");

pub const LocalBinding = struct {
    name: compiler_program.BindingRef,
    val: value.Value,
};

pub const EvalState = struct {
    allocator: std.mem.Allocator,
    values: []?value.Value,
    eval_counts: []u16,
    owns_memory: bool = true,

    pub fn init(allocator: std.mem.Allocator, node_count: usize) !EvalState {
        const values = try allocator.alloc(?value.Value, node_count);
        errdefer allocator.free(values);
        @memset(values, null);

        const counts = try allocator.alloc(u16, node_count);
        errdefer allocator.free(counts);
        @memset(counts, 0);

        return .{
            .allocator = allocator,
            .values = values,
            .eval_counts = counts,
        };
    }

    pub fn initBorrowed(
        allocator: std.mem.Allocator,
        values: []?value.Value,
        eval_counts: []u16,
    ) EvalState {
        std.debug.assert(values.len == eval_counts.len);
        @memset(values, null);
        @memset(eval_counts, 0);
        return .{
            .allocator = allocator,
            .values = values,
            .eval_counts = eval_counts,
            .owns_memory = false,
        };
    }

    pub fn clear(self: *EvalState) void {
        for (self.values) |*maybe| {
            if (maybe.*) |*captured| {
                captured.deinit(self.allocator);
                maybe.* = null;
            }
        }
        @memset(self.eval_counts, 0);
    }

    pub fn deinit(self: *EvalState) void {
        self.clear();
        if (!self.owns_memory) return;
        self.allocator.free(self.values);
        self.allocator.free(self.eval_counts);
    }

    pub fn get(self: *const EvalState, index: ast.Index) ?*const value.Value {
        return if (self.values[@intFromEnum(index)]) |*captured| captured else null;
    }

    pub fn capture(self: *EvalState, index: ast.Index, result: value.Value) !void {
        if (result == .unknown) return;

        const raw_index = @intFromEnum(index);
        const next_count = std.math.add(u16, self.eval_counts[raw_index], 1) catch std.math.maxInt(u16);
        self.eval_counts[raw_index] = next_count;

        if (next_count != 1) {
            if (self.values[raw_index]) |*existing| {
                existing.deinit(self.allocator);
                self.values[raw_index] = null;
            }
            return;
        }

        self.values[raw_index] = try result.clone(self.allocator);
    }
};

pub const EvalScratch = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    local_bindings: std.ArrayListUnmanaged(LocalBinding) = .empty,
    tracked_values: []?value.Value = &.{},
    tracked_eval_counts: []u16 = &.{},
    bindings_use_transient: bool = false,

    pub fn init(allocator: std.mem.Allocator) EvalScratch {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *EvalScratch) void {
        self.clearLocalBindings();
        self.local_bindings.deinit(self.allocator);
        self.clearTracked();
        if (self.tracked_values.len != 0) self.allocator.free(self.tracked_values);
        if (self.tracked_eval_counts.len != 0) self.allocator.free(self.tracked_eval_counts);
        self.arena.deinit();
    }

    pub fn transientAllocator(self: *EvalScratch) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn prepareBindings(self: *EvalScratch, use_transient: bool) void {
        self.clearLocalBindings();
        if (self.bindings_use_transient) _ = self.arena.reset(.retain_capacity);
        self.bindings_use_transient = use_transient;
    }

    pub fn prepareTracked(self: *EvalScratch, node_count: usize) !EvalState {
        try self.ensureTrackedCapacity(node_count);
        const values = self.tracked_values[0..node_count];
        const counts = self.tracked_eval_counts[0..node_count];
        return EvalState.initBorrowed(self.allocator, values, counts);
    }

    fn ensureTrackedCapacity(self: *EvalScratch, node_count: usize) !void {
        if (self.tracked_values.len >= node_count and self.tracked_eval_counts.len >= node_count) return;

        self.clearTracked();
        if (self.tracked_values.len != 0) self.allocator.free(self.tracked_values);
        if (self.tracked_eval_counts.len != 0) self.allocator.free(self.tracked_eval_counts);

        self.tracked_values = try self.allocator.alloc(?value.Value, node_count);
        errdefer {
            self.allocator.free(self.tracked_values);
            self.tracked_values = &.{};
        }
        self.tracked_eval_counts = try self.allocator.alloc(u16, node_count);
        errdefer {
            self.allocator.free(self.tracked_eval_counts);
            self.tracked_eval_counts = &.{};
        }
    }

    fn clearLocalBindings(self: *EvalScratch) void {
        const value_allocator = if (self.bindings_use_transient) self.transientAllocator() else self.allocator;
        for (self.local_bindings.items) |*binding| binding.val.deinit(value_allocator);
        self.local_bindings.clearRetainingCapacity();
    }

    fn clearTracked(self: *EvalScratch) void {
        for (self.tracked_values) |*maybe| {
            if (maybe.*) |*captured| {
                captured.deinit(self.allocator);
                maybe.* = null;
            }
        }
        if (self.tracked_eval_counts.len != 0) @memset(self.tracked_eval_counts, 0);
    }
};

pub const TrackedResult = struct {
    value: value.Value,
    state: EvalState,

    pub fn deinit(self: *TrackedResult) void {
        self.value.deinit(self.state.allocator);
        self.state.deinit();
    }
};

test "EvalScratch init and deinit" {
    var scratch = EvalScratch.init(std.testing.allocator);
    defer scratch.deinit();

    // Verify transient allocator is usable
    const ptr = try scratch.transientAllocator().alloc(u8, 16);
    _ = ptr;
}

test "EvalScratch multiple eval cycles with reset between" {
    var scratch = EvalScratch.init(std.testing.allocator);
    defer scratch.deinit();

    // Cycle 1
    scratch.prepareBindings(false);
    try scratch.local_bindings.append(scratch.allocator, .{
        .name = .{ .iter_var = .{ .depth = 0, .slot = 0 } },
        .val = .{ .int = 10 },
    });
    try std.testing.expectEqual(@as(usize, 1), scratch.local_bindings.items.len);

    // Cycle 2 - prepareBindings clears previous bindings
    scratch.prepareBindings(false);
    try std.testing.expectEqual(@as(usize, 0), scratch.local_bindings.items.len);

    // Add new binding in cycle 2
    try scratch.local_bindings.append(scratch.allocator, .{
        .name = .{ .iter_var = .{ .depth = 0, .slot = 0 } },
        .val = .{ .int = 20 },
    });
    try std.testing.expectEqual(@as(usize, 1), scratch.local_bindings.items.len);
}

test "EvalScratch transient allocator works across cycles" {
    var scratch = EvalScratch.init(std.testing.allocator);
    defer scratch.deinit();

    scratch.prepareBindings(true);
    const data1 = try scratch.transientAllocator().alloc(u8, 64);
    @memset(data1, 0xAA);

    // After prepareBindings with transient=true, arena gets reset
    scratch.prepareBindings(true);
    const data2 = try scratch.transientAllocator().alloc(u8, 32);
    @memset(data2, 0xBB);
}

test "EvalState init clear and deinit" {
    var state = try EvalState.init(std.testing.allocator, 10);
    defer state.deinit();

    // All values start as null
    for (state.values) |maybe| {
        try std.testing.expect(maybe == null);
    }
    // All counts start at zero
    for (state.eval_counts) |count| {
        try std.testing.expectEqual(@as(u16, 0), count);
    }

    // Capture a value
    try state.capture(@enumFromInt(0), .{ .int = 42 });
    try std.testing.expect(state.get(@enumFromInt(0)) != null);
    try std.testing.expectEqual(@as(i64, 42), state.get(@enumFromInt(0)).?.int);

    // Clear resets everything
    state.clear();
    try std.testing.expect(state.get(@enumFromInt(0)) == null);
}

test "EvalState capture ignores unknowns" {
    var state = try EvalState.init(std.testing.allocator, 5);
    defer state.deinit();

    const partial_mod = @import("partial.zig");
    var unknown_set = try partial_mod.singletonUnknown(std.testing.allocator, 1, "x", &.{});
    defer unknown_set.deinit(std.testing.allocator);

    // Capture unknown value - should be ignored
    try state.capture(@enumFromInt(0), .{ .unknown = unknown_set });
    try std.testing.expect(state.get(@enumFromInt(0)) == null);
}

test "EvalState capture evicts on multi-eval" {
    var state = try EvalState.init(std.testing.allocator, 5);
    defer state.deinit();

    // First capture succeeds
    try state.capture(@enumFromInt(0), .{ .int = 1 });
    try std.testing.expect(state.get(@enumFromInt(0)) != null);
    try std.testing.expectEqual(@as(i64, 1), state.get(@enumFromInt(0)).?.int);

    // Second capture of same index evicts the value (multi-eval)
    try state.capture(@enumFromInt(0), .{ .int = 2 });
    try std.testing.expect(state.get(@enumFromInt(0)) == null);
}

test "EvalScratch prepareTracked returns borrowed state" {
    var scratch = EvalScratch.init(std.testing.allocator);
    defer scratch.deinit();

    var state = try scratch.prepareTracked(10);
    // State is borrowed, so don't call state.deinit() - scratch owns the memory
    // But we do need to clear any captured values
    state.clear();

    try std.testing.expect(!state.owns_memory);
    try std.testing.expectEqual(@as(usize, 10), state.values.len);

    // Can prepare again with larger size
    var state2 = try scratch.prepareTracked(20);
    state2.clear();
    try std.testing.expectEqual(@as(usize, 20), state2.values.len);
}
