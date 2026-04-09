const span = @import("../parse/span.zig");

pub const Severity = enum {
    err,
    warning,
};

pub const Diagnostic = struct {
    severity: Severity,
    where: span.Span,
    message: []const u8,
};

const std = @import("std");

test "Diagnostic stores severity span and message" {
    const diag = Diagnostic{
        .severity = .warning,
        .where = span.Span.init(2, 5),
        .message = "bad field",
    };

    try std.testing.expectEqual(Severity.warning, diag.severity);
    try std.testing.expectEqual(@as(u32, 3), diag.where.len());
    try std.testing.expectEqualStrings("bad field", diag.message);
}
