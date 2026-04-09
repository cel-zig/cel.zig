const std = @import("std");
const types = @import("types.zig");

pub const MessageKind = enum {
    plain,
    timestamp,
    duration,
    any,
    value,
    struct_value,
    list_value,
    bool_wrapper,
    bytes_wrapper,
    double_wrapper,
    float_wrapper,
    int32_wrapper,
    int64_wrapper,
    string_wrapper,
    uint32_wrapper,
    uint64_wrapper,
};

pub const ProtoScalarKind = enum {
    bool,
    int32,
    int64,
    sint32,
    sint64,
    uint32,
    uint64,
    fixed32,
    fixed64,
    sfixed32,
    sfixed64,
    float,
    double,
    string,
    bytes,
    enum_value,
};

pub const ProtoValueType = union(enum) {
    scalar: ProtoScalarKind,
    message: []const u8,
};

pub const RepeatedDecl = struct {
    element: ProtoValueType,
    @"packed": bool = false,
};

pub const MapDecl = struct {
    key: ProtoScalarKind,
    value: ProtoValueType,
};

pub const FieldEncoding = union(enum) {
    singular: ProtoValueType,
    repeated: RepeatedDecl,
    map: MapDecl,
};

pub const FieldPresence = enum {
    explicit,
    implicit,
};

pub const FieldDefault = union(enum) {
    bool: bool,
    int: i64,
    uint: u64,
    double: f64,
    string: []u8,
    bytes: []u8,

    pub fn clone(self: FieldDefault, allocator: std.mem.Allocator) !FieldDefault {
        return switch (self) {
            .bool, .int, .uint, .double => self,
            .string => |text| .{ .string = try allocator.dupe(u8, text) },
            .bytes => |data| .{ .bytes = try allocator.dupe(u8, data) },
        };
    }

    pub fn deinit(self: *FieldDefault, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |text| allocator.free(text),
            .bytes => |data| allocator.free(data),
            else => {},
        }
    }
};

pub const FieldDecl = struct {
    name: []u8,
    number: u32,
    ty: types.TypeRef,
    encoding: FieldEncoding,
    presence: FieldPresence,
    default_value: ?FieldDefault = null,

    pub fn supportsPresence(self: *const FieldDecl) bool {
        _ = self;
        return true;
    }
};

pub const MessageDecl = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    kind: MessageKind = .plain,
    result_ty: types.TypeRef,
    fields: std.ArrayListUnmanaged(FieldDecl) = .empty,
    field_names: std.StringHashMapUnmanaged(u32) = .empty,
    field_numbers: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        kind: MessageKind,
        result_ty: types.TypeRef,
    ) !MessageDecl {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .kind = kind,
            .result_ty = result_ty,
        };
    }

    pub fn deinit(self: *MessageDecl) void {
        for (self.fields.items) |*field| {
            self.allocator.free(field.name);
            if (field.default_value) |*default_value| default_value.deinit(self.allocator);
            deinitFieldEncoding(self.allocator, &field.encoding);
        }
        self.fields.deinit(self.allocator);
        self.field_names.deinit(self.allocator);
        self.field_numbers.deinit(self.allocator);
        self.allocator.free(self.name);
    }

    pub fn addField(
        self: *MessageDecl,
        name: []const u8,
        number: u32,
        ty: types.TypeRef,
        encoding: FieldEncoding,
        presence: FieldPresence,
    ) !void {
        return self.addFieldWithDefault(name, number, ty, encoding, presence, null);
    }

    pub fn addFieldWithDefault(
        self: *MessageDecl,
        name: []const u8,
        number: u32,
        ty: types.TypeRef,
        encoding: FieldEncoding,
        presence: FieldPresence,
        default_value: ?FieldDefault,
    ) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        var owned_encoding = try cloneFieldEncoding(self.allocator, encoding);
        errdefer deinitFieldEncoding(self.allocator, &owned_encoding);
        var owned_default = if (default_value) |value| try value.clone(self.allocator) else null;
        errdefer if (owned_default) |*value| value.deinit(self.allocator);

        const idx: u32 = @intCast(self.fields.items.len);
        try self.fields.append(self.allocator, .{
            .name = owned_name,
            .number = number,
            .ty = ty,
            .encoding = owned_encoding,
            .presence = presence,
            .default_value = owned_default,
        });
        errdefer _ = self.fields.pop();

        try self.field_names.put(self.allocator, owned_name, idx);
        errdefer _ = self.field_names.remove(owned_name);
        try self.field_numbers.put(self.allocator, number, idx);
    }

    pub fn lookupField(self: *const MessageDecl, name: []const u8) ?*const FieldDecl {
        const idx = self.field_names.get(name) orelse return null;
        return &self.fields.items[idx];
    }

    pub fn lookupFieldNumber(self: *const MessageDecl, number: u32) ?*const FieldDecl {
        const idx = self.field_numbers.get(number) orelse return null;
        return &self.fields.items[idx];
    }
};

pub fn wrapperScalar(kind: MessageKind) ?ProtoScalarKind {
    return switch (kind) {
        .bool_wrapper => .bool,
        .bytes_wrapper => .bytes,
        .double_wrapper => .double,
        .float_wrapper => .float,
        .int32_wrapper => .int32,
        .int64_wrapper => .int64,
        .string_wrapper => .string,
        .uint32_wrapper => .uint32,
        .uint64_wrapper => .uint64,
        else => null,
    };
}

pub fn isWrapperKind(kind: MessageKind) bool {
    return wrapperScalar(kind) != null;
}

pub fn isDynamicWellKnownKind(kind: MessageKind) bool {
    return switch (kind) {
        .any, .value, .struct_value, .list_value => true,
        else => isWrapperKind(kind),
    };
}

fn cloneFieldEncoding(allocator: std.mem.Allocator, encoding: FieldEncoding) !FieldEncoding {
    return switch (encoding) {
        .singular => |value_ty| .{ .singular = try cloneProtoValueType(allocator, value_ty) },
        .repeated => |repeated| .{ .repeated = .{
            .element = try cloneProtoValueType(allocator, repeated.element),
            .@"packed" = repeated.@"packed",
        } },
        .map => |map| .{ .map = .{
            .key = map.key,
            .value = try cloneProtoValueType(allocator, map.value),
        } },
    };
}

fn deinitFieldEncoding(allocator: std.mem.Allocator, encoding: *FieldEncoding) void {
    switch (encoding.*) {
        .singular => |*value_ty| deinitProtoValueType(allocator, value_ty),
        .repeated => |*repeated| deinitProtoValueType(allocator, &repeated.element),
        .map => |*map| deinitProtoValueType(allocator, &map.value),
    }
}

fn cloneProtoValueType(allocator: std.mem.Allocator, value_ty: ProtoValueType) !ProtoValueType {
    return switch (value_ty) {
        .scalar => value_ty,
        .message => |name| .{ .message = try allocator.dupe(u8, name) },
    };
}

fn deinitProtoValueType(allocator: std.mem.Allocator, value_ty: *ProtoValueType) void {
    switch (value_ty.*) {
        .scalar => {},
        .message => |name| allocator.free(name),
    }
}

test "message descriptor stores fields by name and number" {
    var arena = try types.TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    var desc = try MessageDecl.init(
        std.testing.allocator,
        "example.Account",
        .plain,
        try arena.messageOf("example.Account"),
    );
    defer desc.deinit();

    try desc.addField("enabled", 1, arena.builtins.bool_type, .{
        .singular = .{ .scalar = .bool },
    }, .explicit);

    try std.testing.expect(desc.lookupField("enabled") != null);
    try std.testing.expect(desc.lookupFieldNumber(1) != null);
    try std.testing.expect(desc.lookupField("enabled").?.supportsPresence());
}

test "field lookup by name: found and not found" {
    var arena = try types.TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    var desc = try MessageDecl.init(
        std.testing.allocator,
        "example.Msg",
        .plain,
        try arena.messageOf("example.Msg"),
    );
    defer desc.deinit();

    try desc.addField("name", 1, arena.builtins.string_type, .{
        .singular = .{ .scalar = .string },
    }, .explicit);

    try std.testing.expect(desc.lookupField("name") != null);
    try std.testing.expect(desc.lookupField("nonexistent") == null);
}

test "field presence tracking" {
    var arena = try types.TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    var desc = try MessageDecl.init(
        std.testing.allocator,
        "example.Msg",
        .plain,
        try arena.messageOf("example.Msg"),
    );
    defer desc.deinit();

    try desc.addField("explicit_field", 1, arena.builtins.int_type, .{
        .singular = .{ .scalar = .int64 },
    }, .explicit);
    try desc.addField("implicit_field", 2, arena.builtins.int_type, .{
        .singular = .{ .scalar = .int64 },
    }, .implicit);

    const f1 = desc.lookupField("explicit_field").?;
    const f2 = desc.lookupField("implicit_field").?;
    try std.testing.expectEqual(FieldPresence.explicit, f1.presence);
    try std.testing.expectEqual(FieldPresence.implicit, f2.presence);
}

test "repeated and map field encoding" {
    var arena = try types.TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    const list_ty = try arena.listOf(arena.builtins.string_type);
    const map_ty = try arena.mapOf(arena.builtins.string_type, arena.builtins.int_type);

    var desc = try MessageDecl.init(
        std.testing.allocator,
        "example.Container",
        .plain,
        try arena.messageOf("example.Container"),
    );
    defer desc.deinit();

    try desc.addField("tags", 1, list_ty, .{
        .repeated = .{ .element = .{ .scalar = .string } },
    }, .implicit);

    try desc.addField("counts", 2, map_ty, .{
        .map = .{ .key = .string, .value = .{ .scalar = .int64 } },
    }, .implicit);

    const tags = desc.lookupField("tags").?;
    try std.testing.expectEqual(FieldEncoding.repeated, std.meta.activeTag(tags.encoding));

    const counts = desc.lookupField("counts").?;
    try std.testing.expectEqual(FieldEncoding.map, std.meta.activeTag(counts.encoding));
}

test "multiple fields on same message" {
    var arena = try types.TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    var desc = try MessageDecl.init(
        std.testing.allocator,
        "example.Person",
        .plain,
        try arena.messageOf("example.Person"),
    );
    defer desc.deinit();

    try desc.addField("first_name", 1, arena.builtins.string_type, .{
        .singular = .{ .scalar = .string },
    }, .explicit);
    try desc.addField("last_name", 2, arena.builtins.string_type, .{
        .singular = .{ .scalar = .string },
    }, .explicit);
    try desc.addField("age", 3, arena.builtins.int_type, .{
        .singular = .{ .scalar = .int32 },
    }, .implicit);

    try std.testing.expectEqual(@as(usize, 3), desc.fields.items.len);
    try std.testing.expect(desc.lookupField("first_name") != null);
    try std.testing.expect(desc.lookupField("last_name") != null);
    try std.testing.expect(desc.lookupField("age") != null);
    try std.testing.expect(desc.lookupFieldNumber(1) != null);
    try std.testing.expect(desc.lookupFieldNumber(2) != null);
    try std.testing.expect(desc.lookupFieldNumber(3) != null);
    try std.testing.expect(desc.lookupFieldNumber(99) == null);
}

test "well-known type detection helpers" {
    try std.testing.expect(isWrapperKind(.bool_wrapper));
    try std.testing.expect(isWrapperKind(.int64_wrapper));
    try std.testing.expect(isWrapperKind(.string_wrapper));
    try std.testing.expect(!isWrapperKind(.plain));
    try std.testing.expect(!isWrapperKind(.timestamp));

    try std.testing.expect(isDynamicWellKnownKind(.any));
    try std.testing.expect(isDynamicWellKnownKind(.value));
    try std.testing.expect(isDynamicWellKnownKind(.struct_value));
    try std.testing.expect(isDynamicWellKnownKind(.list_value));
    try std.testing.expect(isDynamicWellKnownKind(.double_wrapper));
    try std.testing.expect(!isDynamicWellKnownKind(.plain));
    try std.testing.expect(!isDynamicWellKnownKind(.timestamp));
}

test "wrapperScalar returns correct scalar kinds" {
    try std.testing.expectEqual(ProtoScalarKind.bool, wrapperScalar(.bool_wrapper).?);
    try std.testing.expectEqual(ProtoScalarKind.bytes, wrapperScalar(.bytes_wrapper).?);
    try std.testing.expectEqual(ProtoScalarKind.double, wrapperScalar(.double_wrapper).?);
    try std.testing.expectEqual(ProtoScalarKind.float, wrapperScalar(.float_wrapper).?);
    try std.testing.expectEqual(ProtoScalarKind.int32, wrapperScalar(.int32_wrapper).?);
    try std.testing.expectEqual(ProtoScalarKind.int64, wrapperScalar(.int64_wrapper).?);
    try std.testing.expectEqual(ProtoScalarKind.string, wrapperScalar(.string_wrapper).?);
    try std.testing.expectEqual(ProtoScalarKind.uint32, wrapperScalar(.uint32_wrapper).?);
    try std.testing.expectEqual(ProtoScalarKind.uint64, wrapperScalar(.uint64_wrapper).?);
    try std.testing.expect(wrapperScalar(.plain) == null);
    try std.testing.expect(wrapperScalar(.timestamp) == null);
}

test "MessageDecl with message-typed field encoding" {
    var arena = try types.TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    const inner_ty = try arena.messageOf("example.Inner");

    var desc = try MessageDecl.init(
        std.testing.allocator,
        "example.Outer",
        .plain,
        try arena.messageOf("example.Outer"),
    );
    defer desc.deinit();

    try desc.addField("inner", 1, inner_ty, .{
        .singular = .{ .message = "example.Inner" },
    }, .explicit);

    const field = desc.lookupField("inner").?;
    try std.testing.expectEqual(FieldEncoding.singular, std.meta.activeTag(field.encoding));
    switch (field.encoding) {
        .singular => |vt| {
            try std.testing.expectEqual(ProtoValueType.message, std.meta.activeTag(vt));
            try std.testing.expectEqualStrings("example.Inner", vt.message);
        },
        else => unreachable,
    }
}

test "MessageDecl init and deinit no leaks" {
    var arena = try types.TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    var desc = try MessageDecl.init(
        std.testing.allocator,
        "example.Empty",
        .plain,
        try arena.messageOf("example.Empty"),
    );
    defer desc.deinit();

    try std.testing.expectEqualStrings("example.Empty", desc.name);
    try std.testing.expectEqual(MessageKind.plain, desc.kind);
    try std.testing.expectEqual(@as(usize, 0), desc.fields.items.len);
}
