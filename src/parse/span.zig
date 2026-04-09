pub const Span = struct {
    start: u32,
    end: u32,

    pub fn init(start: usize, end: usize) Span {
        return .{
            .start = @intCast(start),
            .end = @intCast(end),
        };
    }

    pub fn len(self: Span) u32 {
        return self.end - self.start;
    }
};

const std = @import("std");

test "Span init and len" {
    const s = Span.init(4, 11);
    try std.testing.expectEqual(@as(u32, 4), s.start);
    try std.testing.expectEqual(@as(u32, 11), s.end);
    try std.testing.expectEqual(@as(u32, 7), s.len());
}

test "Span zero length" {
    const s = Span.init(9, 9);
    try std.testing.expectEqual(@as(u32, 0), s.len());
}
