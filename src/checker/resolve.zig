const std = @import("std");
const ast = @import("../parse/ast.zig");
const strings = @import("../parse/string_table.zig");
const types = @import("../env/types.zig");

pub const QualifiedName = struct {
    absolute: bool,
    text: []u8,
};

pub fn lookupQualifiedExpr(comptime ErrorType: type, self: anytype, index: ast.Index) ErrorType!?types.TypeRef {
    const qualified = try joinQualifiedExpr(ErrorType, self, index);
    defer if (qualified) |name| self.allocator.free(name.text);
    const name = qualified orelse return null;
    if (try self.env.lookupVarScoped(self.allocator, name.text, name.absolute)) |resolved| {
        return resolved;
    }
    if (try self.env.lookupConstScoped(self.allocator, name.text, name.absolute)) |constant| {
        return constant.ty;
    }
    if (types.isBuiltinTypeDenotation(name.text)) {
        return self.env.types.builtins.type_type;
    }
    if (try self.env.lookupMessageScoped(self.allocator, name.text, name.absolute)) |_| {
        return self.env.types.builtins.type_type;
    }
    return null;
}

pub fn joinQualifiedExpr(comptime ErrorType: type, self: anytype, index: ast.Index) ErrorType!?QualifiedName {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buffer.deinit(self.allocator);
    var absolute = false;
    if (!try appendQualifiedExpr(ErrorType, self, index, &buffer, &absolute)) return null;
    return .{
        .absolute = absolute,
        .text = try buffer.toOwnedSlice(self.allocator),
    };
}

fn appendQualifiedExpr(
    comptime ErrorType: type,
    self: anytype,
    index: ast.Index,
    buffer: *std.ArrayListUnmanaged(u8),
    absolute: *bool,
) ErrorType!bool {
    switch (self.ast.node(index).data) {
        .ident => |name_ref| {
            absolute.* = name_ref.absolute;
            for (0..name_ref.segments.len) |i| {
                if (buffer.items.len > 0) try buffer.append(self.allocator, '.');
                const id = self.ast.name_segments.items[name_ref.segments.start + i];
                try buffer.appendSlice(self.allocator, self.ast.strings.get(id));
            }
            return true;
        },
        .select => |select| {
            if (select.optional) return false;
            if (!try appendQualifiedExpr(ErrorType, self, select.target, buffer, absolute)) return false;
            try buffer.append(self.allocator, '.');
            try buffer.appendSlice(self.allocator, self.ast.strings.get(select.field));
            return true;
        },
        else => return false,
    }
}

pub fn joinQualifiedCallName(comptime ErrorType: type, self: anytype, target: ast.Index, field: strings.StringTable.Id) ErrorType!?QualifiedName {
    var qualified = try joinQualifiedExpr(ErrorType, self, target) orelse return null;
    errdefer self.allocator.free(qualified.text);
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(self.allocator);
    try buffer.appendSlice(self.allocator, qualified.text);
    try buffer.append(self.allocator, '.');
    try buffer.appendSlice(self.allocator, self.ast.strings.get(field));
    self.allocator.free(qualified.text);
    qualified.text = try buffer.toOwnedSlice(self.allocator);
    return qualified;
}

pub fn joinNameRef(comptime ErrorType: type, self: anytype, name_ref: ast.NameRef) ErrorType![]u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(self.allocator);
    const joined = try joinNameRefInto(ErrorType, self, name_ref, &buffer, &.{});
    return try self.allocator.dupe(u8, joined);
}

pub fn joinNameRefInto(
    comptime ErrorType: type,
    self: anytype,
    name_ref: ast.NameRef,
    dynamic: *std.ArrayListUnmanaged(u8),
    fixed: []u8,
) ErrorType![]const u8 {
    const needed = joinedNameRefLen(self.ast, name_ref);
    const out = if (needed <= fixed.len)
        fixed[0..needed]
    else blk: {
        try dynamic.resize(self.allocator, needed);
        break :blk dynamic.items[0..needed];
    };
    writeJoinedNameRef(self.ast, name_ref, out);
    return out;
}

pub fn qualifiedExprShadowedByLocal(self: anytype, index: ast.Index) bool {
    return switch (self.ast.node(index).data) {
        .ident => |name_ref| blk: {
            if (name_ref.absolute or name_ref.segments.len != 1) break :blk false;
            break :blk isLocalBinding(self, self.ast.name_segments.items[name_ref.segments.start]);
        },
        .select => |select| qualifiedExprShadowedByLocal(self, select.target),
        else => false,
    };
}

pub fn isLocalBinding(self: anytype, id: strings.StringTable.Id) bool {
    var i = self.local_bindings.items.len;
    while (i > 0) {
        i -= 1;
        switch (self.local_bindings.items[i].name) {
            .ident => |binding_id| if (binding_id == id) return true,
            else => {},
        }
    }
    return false;
}

pub fn buildScopedName(
    allocator: std.mem.Allocator,
    dynamic: *std.ArrayListUnmanaged(u8),
    fixed: []u8,
    prefix: []const u8,
    name: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const needed = prefix.len + 1 + name.len;
    if (needed <= fixed.len) {
        @memcpy(fixed[0..prefix.len], prefix);
        fixed[prefix.len] = '.';
        @memcpy(fixed[prefix.len + 1 .. needed], name);
        return fixed[0..needed];
    }

    try dynamic.resize(allocator, needed);
    @memcpy(dynamic.items[0..prefix.len], prefix);
    dynamic.items[prefix.len] = '.';
    @memcpy(dynamic.items[prefix.len + 1 .. needed], name);
    return dynamic.items[0..needed];
}

pub fn joinedNameRefLen(tree: *const ast.Ast, name_ref: ast.NameRef) usize {
    var total: usize = 0;
    for (0..name_ref.segments.len) |i| {
        if (i > 0) total += 1;
        const id = tree.name_segments.items[name_ref.segments.start + i];
        total += tree.strings.get(id).len;
    }
    return total;
}

pub fn writeJoinedNameRef(tree: *const ast.Ast, name_ref: ast.NameRef, out: []u8) void {
    var cursor: usize = 0;
    for (0..name_ref.segments.len) |i| {
        if (i > 0) {
            out[cursor] = '.';
            cursor += 1;
        }
        const id = tree.name_segments.items[name_ref.segments.start + i];
        const segment = tree.strings.get(id);
        @memcpy(out[cursor .. cursor + segment.len], segment);
        cursor += segment.len;
    }
    std.debug.assert(cursor == out.len);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildScopedName fits in fixed buffer" {
    var dynamic: std.ArrayListUnmanaged(u8) = .empty;
    defer dynamic.deinit(std.testing.allocator);
    var fixed: [256]u8 = undefined;
    const result = try buildScopedName(std.testing.allocator, &dynamic, fixed[0..], "com.example", "Foo");
    try std.testing.expectEqualStrings("com.example.Foo", result);
    // Should have used fixed buffer, so dynamic should still be empty
    try std.testing.expectEqual(@as(usize, 0), dynamic.items.len);
}

test "buildScopedName spills to dynamic when fixed is too small" {
    var dynamic: std.ArrayListUnmanaged(u8) = .empty;
    defer dynamic.deinit(std.testing.allocator);
    var fixed: [4]u8 = undefined;
    const result = try buildScopedName(std.testing.allocator, &dynamic, fixed[0..], "com.example", "Foo");
    try std.testing.expectEqualStrings("com.example.Foo", result);
    try std.testing.expect(dynamic.items.len > 0);
}

test "buildScopedName concatenates prefix dot name" {
    var dynamic: std.ArrayListUnmanaged(u8) = .empty;
    defer dynamic.deinit(std.testing.allocator);
    var fixed: [256]u8 = undefined;
    const result = try buildScopedName(std.testing.allocator, &dynamic, fixed[0..], "a.b", "c");
    try std.testing.expectEqualStrings("a.b.c", result);
}

test "joinedNameRefLen single segment" {
    var tree = ast.Ast.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.strings.intern(std.testing.allocator, "hello");
    try tree.name_segments.append(std.testing.allocator, id);

    const name_ref = ast.NameRef{
        .absolute = false,
        .segments = .{ .start = 0, .len = 1 },
    };
    const len = joinedNameRefLen(&tree, name_ref);
    try std.testing.expectEqual(@as(usize, 5), len);
}

test "joinedNameRefLen multi segment" {
    var tree = ast.Ast.init(std.testing.allocator);
    defer tree.deinit();

    const id_a = try tree.strings.intern(std.testing.allocator, "a");
    const id_b = try tree.strings.intern(std.testing.allocator, "b");
    const id_c = try tree.strings.intern(std.testing.allocator, "c");
    try tree.name_segments.append(std.testing.allocator, id_a);
    try tree.name_segments.append(std.testing.allocator, id_b);
    try tree.name_segments.append(std.testing.allocator, id_c);

    const name_ref = ast.NameRef{
        .absolute = false,
        .segments = .{ .start = 0, .len = 3 },
    };
    // "a.b.c" = 5 chars
    const len = joinedNameRefLen(&tree, name_ref);
    try std.testing.expectEqual(@as(usize, 5), len);
}

test "writeJoinedNameRef single segment" {
    var tree = ast.Ast.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.strings.intern(std.testing.allocator, "foo");
    try tree.name_segments.append(std.testing.allocator, id);

    const name_ref = ast.NameRef{
        .absolute = false,
        .segments = .{ .start = 0, .len = 1 },
    };
    var buf: [3]u8 = undefined;
    writeJoinedNameRef(&tree, name_ref, buf[0..]);
    try std.testing.expectEqualStrings("foo", buf[0..]);
}

test "writeJoinedNameRef multi segment" {
    var tree = ast.Ast.init(std.testing.allocator);
    defer tree.deinit();

    const id_x = try tree.strings.intern(std.testing.allocator, "x");
    const id_y = try tree.strings.intern(std.testing.allocator, "y");
    try tree.name_segments.append(std.testing.allocator, id_x);
    try tree.name_segments.append(std.testing.allocator, id_y);

    const name_ref = ast.NameRef{
        .absolute = false,
        .segments = .{ .start = 0, .len = 2 },
    };
    var buf: [3]u8 = undefined;
    writeJoinedNameRef(&tree, name_ref, buf[0..]);
    try std.testing.expectEqualStrings("x.y", buf[0..]);
}
