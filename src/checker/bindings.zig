pub const BindingRef = @import("../compiler/program.zig").BindingRef;
pub const bindingRefEql = @import("../compiler/program.zig").bindingRefEql;
pub const bindingMatchesIdent = @import("../compiler/program.zig").bindingMatchesIdent;

const std = @import("std");
const strings = @import("../parse/string_table.zig");

test "bindings facade re-exports binding helpers" {
    const id: strings.StringTable.Id = @enumFromInt(7);
    const same: BindingRef = .{ .ident = id };
    const other: BindingRef = .{ .iter_var = .{ .depth = 0, .slot = 1 } };

    try std.testing.expect(bindingRefEql(same, same));
    try std.testing.expect(!bindingRefEql(same, other));
    try std.testing.expect(bindingMatchesIdent(same, id));
    try std.testing.expect(!bindingMatchesIdent(other, id));
}
