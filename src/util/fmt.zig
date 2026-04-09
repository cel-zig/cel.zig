const std = @import("std");

/// Formats directly into an ArrayListUnmanaged(u8), growing as needed.
/// Replaces the removed `list.writer(allocator).print(fmt, args)` pattern.
pub fn appendFormat(
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) std.mem.Allocator.Error!void {
    var buf: [256]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, fmt, args) catch {
        const formatted = try std.fmt.allocPrint(allocator, fmt, args);
        defer allocator.free(formatted);
        return list.appendSlice(allocator, formatted);
    };
    return list.appendSlice(allocator, result);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "appendFormat" {
    const cases = .{
        .{ "hello {s}", .{"world"}, "hello world" },
        .{ "num={d}", .{42}, "num=42" },
        .{ "0x{x}", .{255}, "0xff" },
        .{ "", .{}, "" },
        .{ "{s}={d}, {s}={d}", .{ "a", 1, "b", 2 }, "a=1, b=2" },
        .{ "{s}", .{"x" ** 300}, "x" ** 300 }, // exceeds 256-byte stack buffer
    };
    inline for (cases) |case| {
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(std.testing.allocator);
        try appendFormat(&list, std.testing.allocator, case[0], case[1]);
        try std.testing.expectEqualStrings(case[2], list.items);
    }
}

test "appendFormat accumulates across calls" {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.appendSlice(std.testing.allocator, "prefix:");
    try appendFormat(&list, std.testing.allocator, "{d}+{d}", .{ 1, 2 });
    try appendFormat(&list, std.testing.allocator, "={d}", .{3});
    try std.testing.expectEqualStrings("prefix:1+2=3", list.items);
}
