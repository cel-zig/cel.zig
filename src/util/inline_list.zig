const std = @import("std");

pub fn InlineList(comptime T: type, comptime inline_capacity: usize) type {
    return struct {
        allocator: std.mem.Allocator,
        dynamic: std.ArrayListUnmanaged(T) = .empty,
        inline_storage: [inline_capacity]T = undefined,
        inline_len: usize = 0,
        using_dynamic: bool = false,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.dynamic.deinit(self.allocator);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            if (self.using_dynamic) {
                self.dynamic.clearRetainingCapacity();
            } else {
                self.inline_len = 0;
            }
        }

        pub fn items(self: *const Self) []const T {
            return if (self.using_dynamic) self.dynamic.items else self.inline_storage[0..self.inline_len];
        }

        pub fn itemsMut(self: *Self) []T {
            return if (self.using_dynamic) self.dynamic.items else self.inline_storage[0..self.inline_len];
        }

        pub fn ensureTotalCapacity(self: *Self, total_len: usize) !void {
            if (self.using_dynamic) {
                try self.dynamic.ensureTotalCapacity(self.allocator, total_len);
                return;
            }
            if (total_len <= inline_capacity) return;

            try self.dynamic.ensureTotalCapacity(self.allocator, total_len);
            self.dynamic.appendSliceAssumeCapacity(self.inline_storage[0..self.inline_len]);
            self.using_dynamic = true;
        }

        pub fn append(self: *Self, item: T) !void {
            if (self.using_dynamic) {
                try self.dynamic.append(self.allocator, item);
                return;
            }
            if (self.inline_len < inline_capacity) {
                self.inline_storage[self.inline_len] = item;
                self.inline_len += 1;
                return;
            }

            try self.ensureTotalCapacity(self.inline_len + 1);
            self.dynamic.appendAssumeCapacity(item);
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            if (self.using_dynamic) {
                self.dynamic.appendAssumeCapacity(item);
                return;
            }
            std.debug.assert(self.inline_len < inline_capacity);
            self.inline_storage[self.inline_len] = item;
            self.inline_len += 1;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "inline list append and spill behavior" {
    // Cases: (capacity, values_to_add, expect_dynamic)
    const cases = .{
        .{ 4, &[_]u32{ 10, 20, 30 }, false },       // within capacity
        .{ 2, &[_]u32{ 1, 2 }, false },              // exactly at capacity
        .{ 2, &[_]u32{ 1, 2, 3 }, true },            // spills
        .{ 1, &[_]u32{ 1, 2, 3, 4, 5 }, true },     // spills with many
    };
    inline for (cases) |case| {
        var list = InlineList(u32, case[0]).init(std.testing.allocator);
        defer list.deinit();
        for (case[1]) |v| try list.append(v);
        try std.testing.expectEqual(case[2], list.using_dynamic);
        try std.testing.expectEqual(case[1].len, list.items().len);
        for (case[1], 0..) |v, i| try std.testing.expectEqual(v, list.items()[i]);
    }
}

test "inline list ensureTotalCapacity spill threshold" {
    // Within inline capacity — no spill
    var a = InlineList(u32, 8).init(std.testing.allocator);
    defer a.deinit();
    try a.ensureTotalCapacity(4);
    try std.testing.expect(!a.using_dynamic);

    // Beyond inline capacity — spills, preserves data
    var b = InlineList(u32, 2).init(std.testing.allocator);
    defer b.deinit();
    try b.append(10);
    try b.ensureTotalCapacity(10);
    try std.testing.expect(b.using_dynamic);
    try std.testing.expectEqual(@as(u32, 10), b.items()[0]);
}

test "inline list clearRetainingCapacity in both modes" {
    // Inline mode
    var a = InlineList(u32, 4).init(std.testing.allocator);
    defer a.deinit();
    try a.append(1);
    try a.append(2);
    a.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), a.items().len);

    // Dynamic mode
    var b = InlineList(u32, 1).init(std.testing.allocator);
    defer b.deinit();
    try b.append(1);
    try b.append(2);
    try std.testing.expect(b.using_dynamic);
    b.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), b.items().len);
}

test "inline list appendAssumeCapacity and itemsMut" {
    var list = InlineList(u32, 4).init(std.testing.allocator);
    defer list.deinit();

    list.appendAssumeCapacity(42);
    try std.testing.expectEqual(@as(u32, 42), list.items()[0]);

    list.itemsMut()[0] = 99;
    try std.testing.expectEqual(@as(u32, 99), list.items()[0]);
}

test "inline list deinit is safe in both modes" {
    var a = InlineList(u32, 4).init(std.testing.allocator);
    try a.append(42);
    a.deinit();

    var b = InlineList(u32, 1).init(std.testing.allocator);
    try b.append(1);
    try b.append(2);
    b.deinit();
}
