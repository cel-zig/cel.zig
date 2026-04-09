const std = @import("std");
const span = @import("span.zig");
const strings = @import("string_table.zig");

pub const Index = enum(u32) { _ };

pub const UnaryOp = enum {
    logical_not,
    negate,
};

pub const BinaryOp = enum {
    logical_or,
    logical_and,
    less,
    less_equal,
    greater,
    greater_equal,
    equal,
    not_equal,
    in_set,
    add,
    subtract,
    multiply,
    divide,
    remainder,
};

pub const Range = struct {
    start: u32,
    len: u32,
};

pub const NameRef = struct {
    absolute: bool,
    segments: Range,
};

pub const Unary = struct {
    op: UnaryOp,
    expr: Index,
};

pub const Binary = struct {
    op: BinaryOp,
    left: Index,
    right: Index,
};

pub const Conditional = struct {
    condition: Index,
    then_expr: Index,
    else_expr: Index,
};

pub const Call = struct {
    name: NameRef,
    args: Range,
};

pub const ReceiverCall = struct {
    target: Index,
    name: strings.StringTable.Id,
    args: Range,
};

pub const Select = struct {
    target: Index,
    field: strings.StringTable.Id,
    optional: bool,
};

pub const IndexAccess = struct {
    target: Index,
    index: Index,
    optional: bool,
};

pub const ListItem = struct {
    optional: bool,
    value: Index,
};

pub const MapEntry = struct {
    optional: bool,
    key: Index,
    value: Index,
};

pub const FieldInit = struct {
    optional: bool,
    name: strings.StringTable.Id,
    value: Index,
};

pub const MessageInit = struct {
    name: NameRef,
    fields: Range,
};

pub const Data = union(enum) {
    ident: NameRef,
    literal_int: i64,
    literal_uint: u64,
    literal_double: f64,
    literal_string: strings.StringTable.Id,
    literal_bytes: strings.StringTable.Id,
    literal_bool: bool,
    literal_null: void,
    unary: Unary,
    binary: Binary,
    conditional: Conditional,
    list: Range,
    map: Range,
    message: MessageInit,
    call: Call,
    receiver_call: ReceiverCall,
    select: Select,
    index: IndexAccess,
};

pub const Tag = std.meta.Tag(Data);

pub const Node = struct {
    where: span.Span,
    data: Data,

    pub fn tag(self: Node) Tag {
        return std.meta.activeTag(self.data);
    }
};

pub const Ast = struct {
    allocator: std.mem.Allocator,
    strings: strings.StringTable = .{},
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    expr_ranges: std.ArrayListUnmanaged(Index) = .empty,
    list_items: std.ArrayListUnmanaged(ListItem) = .empty,
    map_entries: std.ArrayListUnmanaged(MapEntry) = .empty,
    field_inits: std.ArrayListUnmanaged(FieldInit) = .empty,
    name_segments: std.ArrayListUnmanaged(strings.StringTable.Id) = .empty,
    root: ?Index = null,

    pub fn init(allocator: std.mem.Allocator) Ast {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Ast) void {
        self.strings.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.expr_ranges.deinit(self.allocator);
        self.list_items.deinit(self.allocator);
        self.map_entries.deinit(self.allocator);
        self.field_inits.deinit(self.allocator);
        self.name_segments.deinit(self.allocator);
    }

    pub fn addNode(self: *Ast, value: Node) !Index {
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, value);
        return @enumFromInt(idx);
    }

    pub fn node(self: *const Ast, index: Index) Node {
        return self.nodes.items[@intFromEnum(index)];
    }

    pub fn appendExprRange(self: *Ast, values: []const Index) !Range {
        const start: u32 = @intCast(self.expr_ranges.items.len);
        try self.expr_ranges.appendSlice(self.allocator, values);
        return .{
            .start = start,
            .len = @intCast(values.len),
        };
    }

    pub fn appendListItems(self: *Ast, values: []const ListItem) !Range {
        const start: u32 = @intCast(self.list_items.items.len);
        try self.list_items.appendSlice(self.allocator, values);
        return .{
            .start = start,
            .len = @intCast(values.len),
        };
    }

    pub fn appendMapEntries(self: *Ast, values: []const MapEntry) !Range {
        const start: u32 = @intCast(self.map_entries.items.len);
        try self.map_entries.appendSlice(self.allocator, values);
        return .{
            .start = start,
            .len = @intCast(values.len),
        };
    }

    pub fn appendFieldInits(self: *Ast, values: []const FieldInit) !Range {
        const start: u32 = @intCast(self.field_inits.items.len);
        try self.field_inits.appendSlice(self.allocator, values);
        return .{
            .start = start,
            .len = @intCast(values.len),
        };
    }

    pub fn appendName(self: *Ast, absolute: bool, values: []const strings.StringTable.Id) !NameRef {
        const start: u32 = @intCast(self.name_segments.items.len);
        try self.name_segments.appendSlice(self.allocator, values);
        return .{
            .absolute = absolute,
            .segments = .{
                .start = start,
                .len = @intCast(values.len),
            },
        };
    }
};

test "ast addNode and node roundtrip" {
    var a = Ast.init(std.testing.allocator);
    defer a.deinit();

    const idx = try a.addNode(.{
        .where = span.Span.init(0, 5),
        .data = .{ .literal_int = 42 },
    });
    const n = a.node(idx);
    try std.testing.expectEqual(Tag.literal_int, n.tag());
    try std.testing.expectEqual(@as(i64, 42), n.data.literal_int);
    try std.testing.expectEqual(@as(u32, 0), n.where.start);
    try std.testing.expectEqual(@as(u32, 5), n.where.end);
}

test "ast addNode multiple nodes" {
    var a = Ast.init(std.testing.allocator);
    defer a.deinit();

    const idx0 = try a.addNode(.{
        .where = span.Span.init(0, 1),
        .data = .{ .literal_int = 1 },
    });
    const idx1 = try a.addNode(.{
        .where = span.Span.init(2, 3),
        .data = .{ .literal_int = 2 },
    });
    try std.testing.expect(idx0 != idx1);
    try std.testing.expectEqual(@as(i64, 1), a.node(idx0).data.literal_int);
    try std.testing.expectEqual(@as(i64, 2), a.node(idx1).data.literal_int);
}

test "ast appendExprRange" {
    var a = Ast.init(std.testing.allocator);
    defer a.deinit();

    const n0 = try a.addNode(.{ .where = span.Span.init(0, 1), .data = .{ .literal_int = 10 } });
    const n1 = try a.addNode(.{ .where = span.Span.init(2, 3), .data = .{ .literal_int = 20 } });

    const range = try a.appendExprRange(&.{ n0, n1 });
    try std.testing.expectEqual(@as(u32, 2), range.len);
    try std.testing.expectEqual(n0, a.expr_ranges.items[range.start]);
    try std.testing.expectEqual(n1, a.expr_ranges.items[range.start + 1]);
}

test "ast appendExprRange empty" {
    var a = Ast.init(std.testing.allocator);
    defer a.deinit();

    const range = try a.appendExprRange(&.{});
    try std.testing.expectEqual(@as(u32, 0), range.len);
}

test "ast appendListItems" {
    var a = Ast.init(std.testing.allocator);
    defer a.deinit();

    const n0 = try a.addNode(.{ .where = span.Span.init(0, 1), .data = .{ .literal_int = 1 } });
    const items = [_]ListItem{
        .{ .optional = false, .value = n0 },
        .{ .optional = true, .value = n0 },
    };
    const range = try a.appendListItems(&items);
    try std.testing.expectEqual(@as(u32, 2), range.len);
    try std.testing.expect(!a.list_items.items[range.start].optional);
    try std.testing.expect(a.list_items.items[range.start + 1].optional);
}

test "ast appendMapEntries" {
    var a = Ast.init(std.testing.allocator);
    defer a.deinit();

    const n0 = try a.addNode(.{ .where = span.Span.init(0, 1), .data = .{ .literal_int = 1 } });
    const n1 = try a.addNode(.{ .where = span.Span.init(2, 3), .data = .{ .literal_int = 2 } });
    const entries = [_]MapEntry{
        .{ .optional = false, .key = n0, .value = n1 },
    };
    const range = try a.appendMapEntries(&entries);
    try std.testing.expectEqual(@as(u32, 1), range.len);
    try std.testing.expectEqual(n0, a.map_entries.items[range.start].key);
    try std.testing.expectEqual(n1, a.map_entries.items[range.start].value);
}

test "ast appendFieldInits" {
    var a = Ast.init(std.testing.allocator);
    defer a.deinit();

    const n0 = try a.addNode(.{ .where = span.Span.init(0, 1), .data = .{ .literal_int = 1 } });
    const str_id = try a.strings.intern(std.testing.allocator, "field");
    const fields = [_]FieldInit{
        .{ .optional = false, .name = str_id, .value = n0 },
    };
    const range = try a.appendFieldInits(&fields);
    try std.testing.expectEqual(@as(u32, 1), range.len);
    try std.testing.expectEqualStrings("field", a.strings.get(a.field_inits.items[range.start].name));
}

test "ast appendName" {
    var a = Ast.init(std.testing.allocator);
    defer a.deinit();

    const id1 = try a.strings.intern(std.testing.allocator, "pkg");
    const id2 = try a.strings.intern(std.testing.allocator, "Msg");
    const name_ref = try a.appendName(true, &.{ id1, id2 });
    try std.testing.expect(name_ref.absolute);
    try std.testing.expectEqual(@as(u32, 2), name_ref.segments.len);
    try std.testing.expectEqualStrings("pkg", a.strings.get(a.name_segments.items[name_ref.segments.start]));
    try std.testing.expectEqualStrings("Msg", a.strings.get(a.name_segments.items[name_ref.segments.start + 1]));
}

test "range struct" {
    const r = Range{ .start = 3, .len = 5 };
    try std.testing.expectEqual(@as(u32, 3), r.start);
    try std.testing.expectEqual(@as(u32, 5), r.len);
}

test "node tag extraction for all data variants" {
    const n_int = Node{ .where = span.Span.init(0, 1), .data = .{ .literal_int = 0 } };
    try std.testing.expectEqual(Tag.literal_int, n_int.tag());

    const n_uint = Node{ .where = span.Span.init(0, 1), .data = .{ .literal_uint = 0 } };
    try std.testing.expectEqual(Tag.literal_uint, n_uint.tag());

    const n_dbl = Node{ .where = span.Span.init(0, 1), .data = .{ .literal_double = 0.0 } };
    try std.testing.expectEqual(Tag.literal_double, n_dbl.tag());

    const n_bool = Node{ .where = span.Span.init(0, 1), .data = .{ .literal_bool = true } };
    try std.testing.expectEqual(Tag.literal_bool, n_bool.tag());

    const n_null = Node{ .where = span.Span.init(0, 1), .data = .literal_null };
    try std.testing.expectEqual(Tag.literal_null, n_null.tag());
}
