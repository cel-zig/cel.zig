const std = @import("std");

pub const StringTable = struct {
    pub const Id = enum(u32) { _ };

    items: std.ArrayListUnmanaged([]const u8) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn deinit(self: *StringTable, allocator: std.mem.Allocator) void {
        for (self.items.items) |item| {
            allocator.free(item);
        }
        self.items.deinit(allocator);
        self.index.deinit(allocator);
    }

    pub fn intern(
        self: *StringTable,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) !Id {
        if (self.index.get(text)) |existing| {
            return @enumFromInt(existing);
        }

        const owned = try allocator.dupe(u8, text);
        errdefer allocator.free(owned);

        const next_index: u32 = @intCast(self.items.items.len);
        try self.items.append(allocator, owned);
        errdefer _ = self.items.pop();

        try self.index.put(allocator, owned, next_index);
        return @enumFromInt(next_index);
    }

    pub fn get(self: *const StringTable, id: Id) []const u8 {
        return self.items.items[@intFromEnum(id)];
    }
};

test "string table interns values once" {
    var table = StringTable{};
    defer table.deinit(std.testing.allocator);

    const a = try table.intern(std.testing.allocator, "foo");
    const b = try table.intern(std.testing.allocator, "foo");
    const c = try table.intern(std.testing.allocator, "bar");

    try std.testing.expectEqual(a, b);
    try std.testing.expect(std.mem.eql(u8, "foo", table.get(a)));
    try std.testing.expect(std.mem.eql(u8, "bar", table.get(c)));
}

test "intern same string twice returns same id" {
    var table = StringTable{};
    defer table.deinit(std.testing.allocator);

    const id1 = try table.intern(std.testing.allocator, "hello");
    const id2 = try table.intern(std.testing.allocator, "hello");
    try std.testing.expectEqual(id1, id2);
    try std.testing.expectEqual(@as(usize, 1), table.items.items.len);
}

test "intern different strings returns different ids" {
    var table = StringTable{};
    defer table.deinit(std.testing.allocator);

    const id1 = try table.intern(std.testing.allocator, "alpha");
    const id2 = try table.intern(std.testing.allocator, "beta");
    const id3 = try table.intern(std.testing.allocator, "gamma");
    try std.testing.expect(id1 != id2);
    try std.testing.expect(id2 != id3);
    try std.testing.expect(id1 != id3);
    try std.testing.expectEqualStrings("alpha", table.get(id1));
    try std.testing.expectEqualStrings("beta", table.get(id2));
    try std.testing.expectEqualStrings("gamma", table.get(id3));
}

test "intern empty string" {
    var table = StringTable{};
    defer table.deinit(std.testing.allocator);

    const id = try table.intern(std.testing.allocator, "");
    try std.testing.expectEqualStrings("", table.get(id));

    const id2 = try table.intern(std.testing.allocator, "");
    try std.testing.expectEqual(id, id2);
}

test "intern long string" {
    var table = StringTable{};
    defer table.deinit(std.testing.allocator);

    const long = "a" ** 1024;
    const id = try table.intern(std.testing.allocator, long);
    try std.testing.expectEqualStrings(long, table.get(id));
}

test "intern many strings" {
    var table = StringTable{};
    defer table.deinit(std.testing.allocator);

    var ids: [100]StringTable.Id = undefined;
    for (0..100) |i| {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
        ids[i] = try table.intern(std.testing.allocator, s);
    }
    try std.testing.expectEqual(@as(usize, 100), table.items.items.len);

    for (0..100) |i| {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
        try std.testing.expectEqualStrings(s, table.get(ids[i]));
    }
}
