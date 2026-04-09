const std = @import("std");
const schema = @import("schema.zig");

pub const TypeRef = enum(u32) { _ };

pub const TypeSpec = union(enum) {
    dyn,
    null_type,
    bool,
    int,
    uint,
    double,
    string,
    bytes,
    type_type,
    list: TypeRef,
    map: struct {
        key: TypeRef,
        value: TypeRef,
    },
    abstract: struct {
        name: []const u8,
        params: []TypeRef,
    },
    wrapper: TypeRef,
    enum_type: []const u8,
    message: []const u8,
    host_scalar: []const u8,
    type_param: []const u8,
};

pub const Builtins = struct {
    dyn_type: TypeRef,
    null_type: TypeRef,
    bool_type: TypeRef,
    int_type: TypeRef,
    uint_type: TypeRef,
    double_type: TypeRef,
    string_type: TypeRef,
    bytes_type: TypeRef,
    type_type: TypeRef,
    timestamp_type: TypeRef,
    duration_type: TypeRef,
};

pub const EnumDecl = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    ty: TypeRef,
    values: std.ArrayListUnmanaged(EnumValueDecl) = .empty,
    value_names: std.StringHashMapUnmanaged(u32) = .empty,
    value_numbers: std.AutoHashMapUnmanaged(i32, u32) = .empty,

    pub fn deinit(self: *EnumDecl) void {
        for (self.values.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.full_name);
        }
        self.values.deinit(self.allocator);
        self.value_names.deinit(self.allocator);
        self.value_numbers.deinit(self.allocator);
        self.allocator.free(self.name);
    }

    pub fn addValue(self: *EnumDecl, name: []const u8, raw_value: i32) !void {
        if (self.value_names.contains(name)) return;

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const full_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ self.name, name });
        errdefer self.allocator.free(full_name);

        const idx: u32 = @intCast(self.values.items.len);
        try self.values.append(self.allocator, .{
            .name = owned_name,
            .full_name = full_name,
            .value = raw_value,
        });
        errdefer _ = self.values.pop();

        try self.value_names.put(self.allocator, owned_name, idx);
        errdefer _ = self.value_names.remove(owned_name);
        try self.value_numbers.put(self.allocator, raw_value, idx);
    }

    pub fn lookupValueName(self: *const EnumDecl, name: []const u8) ?*const EnumValueDecl {
        const idx = self.value_names.get(name) orelse return null;
        return &self.values.items[idx];
    }

    pub fn lookupValueNumber(self: *const EnumDecl, raw_value: i32) ?*const EnumValueDecl {
        const idx = self.value_numbers.get(raw_value) orelse return null;
        return &self.values.items[idx];
    }
};

pub const EnumValueDecl = struct {
    name: []u8,
    full_name: []u8,
    value: i32,
};

// -------------------------------------------------------------------------
// High-level type descriptor (resolved lazily against a TypeProvider)
// -------------------------------------------------------------------------

pub const ObjectField = struct {
    name: []const u8,
    type: Type,
};

pub const Type = union(enum) {
    // Primitives
    string,
    int,
    uint,
    double,
    boolean,
    bytes,
    null_type,
    dyn,
    timestamp,
    duration,
    // Named
    message: []const u8,
    // Composites
    list: *const Type,
    map: struct { key: *const Type, value: *const Type },
    optional: *const Type,
    // Escape hatch: pre-resolved TypeRef
    ref: TypeRef,

    pub fn resolve(self: Type, provider: *TypeProvider) !TypeRef {
        return switch (self) {
            .string => provider.builtins.string_type,
            .int => provider.builtins.int_type,
            .uint => provider.builtins.uint_type,
            .double => provider.builtins.double_type,
            .boolean => provider.builtins.bool_type,
            .bytes => provider.builtins.bytes_type,
            .null_type => provider.builtins.null_type,
            .dyn => provider.builtins.dyn_type,
            .timestamp => provider.builtins.timestamp_type,
            .duration => provider.builtins.duration_type,
            .message => |name| provider.messageOf(name),
            .list => |elem| provider.listOf(try elem.resolve(provider)),
            .map => |m| provider.mapOf(try m.key.resolve(provider), try m.value.resolve(provider)),
            .optional => |inner| provider.optionalOf(try inner.resolve(provider)),
            .ref => |r| r,
        };
    }

    pub fn listOf(comptime elem: Type) Type {
        return .{ .list = &struct {
            const t = elem;
        }.t };
    }

    pub fn mapOf(comptime key: Type, comptime val: Type) Type {
        const S = struct {
            const k = key;
            const v = val;
        };
        return .{ .map = .{ .key = &S.k, .value = &S.v } };
    }

    pub fn optionalOf(comptime inner: Type) Type {
        return .{ .optional = &struct {
            const t = inner;
        }.t };
    }
};

pub const TypeProvider = struct {
    allocator: std.mem.Allocator,
    parent: ?*const TypeProvider = null,
    parent_len: u32 = 0,
    items: std.ArrayListUnmanaged(TypeSpec) = .empty,
    builtins: Builtins = undefined,
    messages: std.ArrayListUnmanaged(schema.MessageDecl) = .empty,
    message_index: std.StringHashMapUnmanaged(u32) = .empty,
    enums: std.ArrayListUnmanaged(EnumDecl) = .empty,
    enum_index: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn init(allocator: std.mem.Allocator) !TypeProvider {
        var arena = TypeProvider{ .allocator = allocator };
        arena.builtins = .{
            .dyn_type = try arena.addCanonical(.dyn),
            .null_type = try arena.addCanonical(.null_type),
            .bool_type = try arena.addCanonical(.bool),
            .int_type = try arena.addCanonical(.int),
            .uint_type = try arena.addCanonical(.uint),
            .double_type = try arena.addCanonical(.double),
            .string_type = try arena.addCanonical(.string),
            .bytes_type = try arena.addCanonical(.bytes),
            .type_type = try arena.addCanonical(.type_type),
            .timestamp_type = try arena.addNamed(.message, "google.protobuf.Timestamp"),
            .duration_type = try arena.addNamed(.message, "google.protobuf.Duration"),
        };
        return arena;
    }

    pub fn extend(self: *const TypeProvider, allocator: std.mem.Allocator) TypeProvider {
        return .{
            .allocator = allocator,
            .parent = self,
            .parent_len = self.len(),
            .builtins = self.builtins,
        };
    }

    pub fn deinit(self: *TypeProvider) void {
        for (self.items.items) |item| {
            switch (item) {
                .abstract => |abstract_ty| {
                    self.allocator.free(abstract_ty.name);
                    self.allocator.free(abstract_ty.params);
                },
                .enum_type, .message, .host_scalar, .type_param => |text| self.allocator.free(text),
                else => {},
            }
        }
        self.items.deinit(self.allocator);
        for (self.messages.items) |*msg| msg.deinit();
        self.messages.deinit(self.allocator);
        self.message_index.deinit(self.allocator);
        for (self.enums.items) |*enum_decl| enum_decl.deinit();
        self.enums.deinit(self.allocator);
        self.enum_index.deinit(self.allocator);
    }

    pub fn spec(self: *const TypeProvider, ref: TypeRef) TypeSpec {
        const idx = @intFromEnum(ref);
        if (self.parent) |parent| {
            if (idx < self.parent_len) return parent.spec(ref);
            return self.items.items[idx - self.parent_len];
        }
        return self.items.items[idx];
    }

    pub fn dynType(self: *const TypeProvider) TypeRef {
        return self.builtins.dyn_type;
    }

    pub fn listOf(self: *TypeProvider, child: TypeRef) !TypeRef {
        return self.addCanonical(.{ .list = child });
    }

    pub fn mapOf(self: *TypeProvider, key: TypeRef, value: TypeRef) !TypeRef {
        return self.addCanonical(.{ .map = .{
            .key = key,
            .value = value,
        } });
    }

    pub fn messageOf(self: *TypeProvider, text: []const u8) !TypeRef {
        return self.addNamed(.message, text);
    }

    pub fn enumOf(self: *TypeProvider, text: []const u8) !TypeRef {
        return self.addNamed(.enum_type, text);
    }

    pub fn abstractOf(self: *TypeProvider, text: []const u8) !TypeRef {
        return self.abstractOfParams(text, &.{});
    }

    pub fn abstractOfParams(self: *TypeProvider, text: []const u8, params: []const TypeRef) !TypeRef {
        const owned_name = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_name);
        const owned_params = try self.allocator.dupe(TypeRef, params);
        errdefer self.allocator.free(owned_params);

        const abstract_spec: TypeSpec = .{
            .abstract = .{
                .name = owned_name,
                .params = owned_params,
            },
        };
        if (self.find(abstract_spec)) |existing| {
            self.allocator.free(owned_name);
            self.allocator.free(owned_params);
            return existing;
        }

        const idx = self.len();
        try self.items.append(self.allocator, abstract_spec);
        return @enumFromInt(idx);
    }

    pub fn hostScalarOf(self: *TypeProvider, text: []const u8) !TypeRef {
        return self.addNamed(.host_scalar, text);
    }

    pub fn typeParamOf(self: *TypeProvider, text: []const u8) !TypeRef {
        return self.addNamed(.type_param, text);
    }

    pub fn wrapperOf(self: *TypeProvider, inner: TypeRef) !TypeRef {
        return self.addCanonical(.{ .wrapper = inner });
    }

    pub fn optionalOf(self: *TypeProvider, inner: TypeRef) !TypeRef {
        return self.abstractOfParams("optional_type", &.{inner});
    }

    pub fn optionalInner(self: *const TypeProvider, ref: TypeRef) ?TypeRef {
        return switch (self.spec(ref)) {
            .abstract => |abstract_ty| blk: {
                if (!std.mem.eql(u8, abstract_ty.name, "optional_type")) break :blk null;
                if (abstract_ty.params.len != 1) break :blk null;
                break :blk abstract_ty.params[0];
            },
            else => null,
        };
    }

    pub fn eql(self: *const TypeProvider, a: TypeRef, b: TypeRef) bool {
        _ = self;
        return a == b;
    }

    pub fn isNumeric(self: *const TypeProvider, ref: TypeRef) bool {
        return switch (self.spec(ref)) {
            .int, .uint, .double => true,
            else => false,
        };
    }

    pub fn isSimpleComparable(self: *const TypeProvider, ref: TypeRef) bool {
        return switch (self.spec(ref)) {
            .bool, .int, .uint, .double, .string, .bytes => true,
            .message => |name| std.mem.eql(u8, name, "google.protobuf.Timestamp") or
                std.mem.eql(u8, name, "google.protobuf.Duration"),
            else => false,
        };
    }

    pub fn isTimestampType(self: *const TypeProvider, ref: TypeRef) bool {
        return switch (self.spec(ref)) {
            .message => |name| std.mem.eql(u8, name, "google.protobuf.Timestamp"),
            else => false,
        };
    }

    pub fn isDurationType(self: *const TypeProvider, ref: TypeRef) bool {
        return switch (self.spec(ref)) {
            .message => |name| std.mem.eql(u8, name, "google.protobuf.Duration"),
            else => false,
        };
    }

    pub fn isHostScalarType(self: *const TypeProvider, ref: TypeRef) bool {
        return switch (self.spec(ref)) {
            .host_scalar => true,
            else => false,
        };
    }

    pub fn isEnumType(self: *const TypeProvider, ref: TypeRef) bool {
        return switch (self.spec(ref)) {
            .enum_type => true,
            else => false,
        };
    }

    pub fn displayName(self: *const TypeProvider, ref: TypeRef) []const u8 {
        return switch (self.spec(ref)) {
            .dyn => "dyn",
            .null_type => "null_type",
            .bool => "bool",
            .int => "int",
            .uint => "uint",
            .double => "double",
            .string => "string",
            .bytes => "bytes",
            .type_type => "type",
            .list => "list",
            .map => "map",
            .abstract => |abstract_ty| abstract_ty.name,
            .wrapper => "wrapper",
            .enum_type => |n| n,
            .message => |n| n,
            .host_scalar => |n| n,
            .type_param => |n| n,
        };
    }

    fn addNamed(self: *TypeProvider, comptime tag: std.meta.Tag(TypeSpec), text: []const u8) !TypeRef {
        var idx: u32 = 0;
        while (idx < self.len()) : (idx += 1) {
            switch (self.spec(@enumFromInt(idx))) {
                .enum_type => |existing| if (tag == .enum_type and std.mem.eql(u8, existing, text)) return @enumFromInt(idx),
                .message => |existing| if (tag == .message and std.mem.eql(u8, existing, text)) return @enumFromInt(idx),
                .host_scalar => |existing| if (tag == .host_scalar and std.mem.eql(u8, existing, text)) return @enumFromInt(idx),
                .type_param => |existing| if (tag == .type_param and std.mem.eql(u8, existing, text)) return @enumFromInt(idx),
                else => {},
            }
        }

        const owned = try self.allocator.dupe(u8, text);
        const new_spec: TypeSpec = switch (tag) {
            .enum_type => .{ .enum_type = owned },
            .message => .{ .message = owned },
            .host_scalar => .{ .host_scalar = owned },
            .type_param => .{ .type_param = owned },
            else => unreachable,
        };
        const new_idx = self.len();
        try self.items.append(self.allocator, new_spec);
        return @enumFromInt(new_idx);
    }

    fn addCanonical(self: *TypeProvider, ty_spec: TypeSpec) !TypeRef {
        if (self.find(ty_spec)) |existing| {
            return existing;
        }
        const idx = self.len();
        try self.items.append(self.allocator, ty_spec);
        return @enumFromInt(idx);
    }

    fn find(self: *const TypeProvider, ty_spec: TypeSpec) ?TypeRef {
        var idx: u32 = 0;
        while (idx < self.len()) : (idx += 1) {
            if (typeSpecEql(self.spec(@enumFromInt(idx)), ty_spec)) return @enumFromInt(idx);
        }
        return null;
    }

    fn len(self: *const TypeProvider) u32 {
        return self.parent_len + @as(u32, @intCast(self.items.items.len));
    }

    // ---- Message management ------------------------------------------------

    pub fn defineMessage(self: *TypeProvider, name: []const u8, fields: []const ObjectField) !TypeRef {
        const ty = try self.addMessage(name);
        for (fields) |f| {
            const field_ty = try f.type.resolve(self);
            try self.addMessageField(name, f.name, field_ty);
        }
        return ty;
    }

    pub fn addMessage(self: *TypeProvider, name: []const u8) !TypeRef {
        return self.addMessageWithKind(name, .plain);
    }

    pub fn addMessageWithKind(self: *TypeProvider, name: []const u8, kind: schema.MessageKind) !TypeRef {
        if (self.message_index.contains(name)) {
            return self.messageOf(name);
        }
        if (self.parent) |parent| {
            if (parent.lookupMessage(name)) |message| {
                try self.cloneMessageDecl(message);
                return self.messageOf(name);
            }
        }
        const idx: u32 = @intCast(self.messages.items.len);
        try self.messages.append(self.allocator, try schema.MessageDecl.init(
            self.allocator,
            name,
            kind,
            try self.messageOf(name),
        ));
        try self.message_index.put(self.allocator, self.messages.items[idx].name, idx);
        return self.messageOf(name);
    }

    pub fn addMessageField(self: *TypeProvider, message_name: []const u8, field_name: []const u8, ty: TypeRef) !void {
        return self.addProtobufFieldWithOptions(
            message_name,
            field_name,
            0,
            ty,
            try self.defaultFieldEncoding(ty),
            .explicit,
            null,
        );
    }

    pub fn addProtobufField(
        self: *TypeProvider,
        message_name: []const u8,
        field_name: []const u8,
        number: u32,
        ty: TypeRef,
        encoding: schema.FieldEncoding,
    ) !void {
        return self.addProtobufFieldWithOptions(
            message_name,
            field_name,
            number,
            ty,
            encoding,
            inferDefaultProtobufPresence(encoding),
            null,
        );
    }

    pub fn addProtobufFieldWithPresence(
        self: *TypeProvider,
        message_name: []const u8,
        field_name: []const u8,
        number: u32,
        ty: TypeRef,
        encoding: schema.FieldEncoding,
        presence: schema.FieldPresence,
    ) !void {
        return self.addProtobufFieldWithOptions(
            message_name,
            field_name,
            number,
            ty,
            encoding,
            presence,
            null,
        );
    }

    pub fn addProtobufFieldWithOptions(
        self: *TypeProvider,
        message_name: []const u8,
        field_name: []const u8,
        number: u32,
        ty: TypeRef,
        encoding: schema.FieldEncoding,
        presence: schema.FieldPresence,
        default_value: ?schema.FieldDefault,
    ) !void {
        const idx = self.message_index.get(message_name) orelse {
            _ = try self.addMessage(message_name);
            return self.addProtobufFieldWithOptions(message_name, field_name, number, ty, encoding, presence, default_value);
        };
        try self.messages.items[idx].addFieldWithDefault(field_name, number, ty, encoding, presence, default_value);
    }

    pub fn lookupMessage(self: *const TypeProvider, name: []const u8) ?*const schema.MessageDecl {
        if (self.message_index.get(name)) |idx| return &self.messages.items[idx];
        return if (self.parent) |parent| parent.lookupMessage(name) else null;
    }

    fn cloneMessageDecl(self: *TypeProvider, source: *const schema.MessageDecl) !void {
        const idx: u32 = @intCast(self.messages.items.len);
        try self.messages.append(self.allocator, try schema.MessageDecl.init(
            self.allocator,
            source.name,
            source.kind,
            try self.messageOf(source.name),
        ));
        errdefer _ = self.messages.pop();
        try self.message_index.put(self.allocator, self.messages.items[idx].name, idx);
        errdefer _ = self.message_index.remove(self.messages.items[idx].name);

        for (source.fields.items) |field| {
            try self.messages.items[idx].addFieldWithDefault(
                field.name,
                field.number,
                field.ty,
                field.encoding,
                field.presence,
                field.default_value,
            );
        }
    }

    // ---- Enum management ---------------------------------------------------

    pub fn addEnum(self: *TypeProvider, name: []const u8) !TypeRef {
        if (self.enum_index.contains(name)) {
            return self.enumOf(name);
        }
        if (self.parent) |parent| {
            if (parent.lookupEnum(name)) |enum_decl| {
                try self.cloneEnumDecl(enum_decl);
                return self.enumOf(name);
            }
        }

        const idx: u32 = @intCast(self.enums.items.len);
        const enum_ty = try self.enumOf(name);
        try self.enums.append(self.allocator, .{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, name),
            .ty = enum_ty,
        });
        errdefer _ = self.enums.pop();

        try self.enum_index.put(self.allocator, self.enums.items[idx].name, idx);
        return enum_ty;
    }

    pub fn lookupEnum(self: *const TypeProvider, name: []const u8) ?*const EnumDecl {
        if (self.enum_index.get(name)) |idx| return &self.enums.items[idx];
        return if (self.parent) |parent| parent.lookupEnum(name) else null;
    }

    fn cloneEnumDecl(self: *TypeProvider, source: *const EnumDecl) !void {
        const idx: u32 = @intCast(self.enums.items.len);
        const enum_ty = try self.enumOf(source.name);
        try self.enums.append(self.allocator, .{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, source.name),
            .ty = enum_ty,
        });
        errdefer _ = self.enums.pop();
        try self.enum_index.put(self.allocator, self.enums.items[idx].name, idx);
        errdefer _ = self.enum_index.remove(self.enums.items[idx].name);

        for (source.values.items) |value_decl| {
            try self.enums.items[idx].addValue(value_decl.name, value_decl.value);
        }
    }

    // ---- TypeBuilder -------------------------------------------------------

    pub const TypeBuilder = struct {
        provider: *TypeProvider,
        message_name: []const u8,

        pub fn field(self_builder: *TypeBuilder, name: []const u8, ty: TypeRef) !void {
            try self_builder.provider.addMessageField(self_builder.message_name, name, ty);
        }

        pub fn ref(self_builder: *const TypeBuilder) TypeRef {
            return self_builder.provider.messageOf(self_builder.message_name) catch unreachable;
        }
    };

    pub fn define(self: *TypeProvider, name: []const u8) !TypeBuilder {
        _ = try self.addMessage(name);
        return .{ .provider = self, .message_name = name };
    }

    // ---- remove ------------------------------------------------------------

    pub fn remove(self: *TypeProvider, name: []const u8) void {
        _ = self.message_index.remove(name);
    }

    // ---- helpers -----------------------------------------------------------

    fn defaultFieldEncoding(self: *const TypeProvider, ty: TypeRef) !schema.FieldEncoding {
        return switch (self.spec(ty)) {
            .bool => .{ .singular = .{ .scalar = .bool } },
            .int => .{ .singular = .{ .scalar = .int64 } },
            .uint => .{ .singular = .{ .scalar = .uint64 } },
            .double => .{ .singular = .{ .scalar = .double } },
            .string => .{ .singular = .{ .scalar = .string } },
            .bytes => .{ .singular = .{ .scalar = .bytes } },
            .message => |name_str| .{ .singular = .{ .message = name_str } },
            else => error.UnsupportedSchemaType,
        };
    }
};


fn inferDefaultProtobufPresence(encoding: schema.FieldEncoding) schema.FieldPresence {
    return switch (encoding) {
        .singular => |value_ty| switch (value_ty) {
            .message => .explicit,
            .scalar => .implicit,
        },
        .repeated, .map => .implicit,
    };
}

pub fn isBuiltinTypeDenotation(name: []const u8) bool {
    return std.mem.eql(u8, name, "bool") or
        std.mem.eql(u8, name, "bytes") or
        std.mem.eql(u8, name, "double") or
        std.mem.eql(u8, name, "int") or
        std.mem.eql(u8, name, "list") or
        std.mem.eql(u8, name, "map") or
        std.mem.eql(u8, name, "null_type") or
        std.mem.eql(u8, name, "string") or
        std.mem.eql(u8, name, "type") or
        std.mem.eql(u8, name, "uint");
}

fn typeSpecEql(a: TypeSpec, b: TypeSpec) bool {
    const ta = std.meta.activeTag(a);
    const tb = std.meta.activeTag(b);
    if (ta != tb) return false;

    return switch (a) {
        .dyn, .null_type, .bool, .int, .uint, .double, .string, .bytes, .type_type => true,
        .list => |child| child == b.list,
        .map => |m| m.key == b.map.key and m.value == b.map.value,
        .abstract => |abstract_ty| std.mem.eql(u8, abstract_ty.name, b.abstract.name) and
            std.mem.eql(TypeRef, abstract_ty.params, b.abstract.params),
        .wrapper => |inner| inner == b.wrapper,
        .enum_type => |name| std.mem.eql(u8, name, b.enum_type),
        .message => |name| std.mem.eql(u8, name, b.message),
        .host_scalar => |name| std.mem.eql(u8, name, b.host_scalar),
        .type_param => |name| std.mem.eql(u8, name, b.type_param),
    };
}

test "type arena interns builtin and composite types" {
    var arena = try TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    const list_a = try arena.listOf(arena.builtins.int_type);
    const list_b = try arena.listOf(arena.builtins.int_type);
    const map_a = try arena.mapOf(arena.builtins.string_type, arena.builtins.bool_type);
    const map_b = try arena.mapOf(arena.builtins.string_type, arena.builtins.bool_type);

    try std.testing.expectEqual(list_a, list_b);
    try std.testing.expectEqual(map_a, map_b);
}

test "type arena extend shares parent entries and appends local tail" {
    var base = try TypeProvider.init(std.testing.allocator);
    defer base.deinit();

    const base_list = try base.listOf(base.builtins.int_type);

    var child = base.extend(std.testing.allocator);
    defer child.deinit();

    try std.testing.expectEqual(@as(usize, 0), child.items.items.len);
    try std.testing.expectEqual(base_list, try child.listOf(child.builtins.int_type));
    try std.testing.expectEqual(@as(usize, 0), child.items.items.len);

    const child_list = try child.listOf(child.builtins.string_type);
    try std.testing.expect(child_list != base_list);
    try std.testing.expectEqual(child_list, try child.listOf(child.builtins.string_type));
    try std.testing.expectEqual(@as(usize, 1), child.items.items.len);
}

test "all builtin types exist and are distinct" {
    var arena = try TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    const b = arena.builtins;
    const all = [_]TypeRef{
        b.dyn_type,    b.null_type,   b.bool_type,
        b.int_type,    b.uint_type,   b.double_type,
        b.string_type, b.bytes_type,  b.type_type,
        b.timestamp_type, b.duration_type,
    };
    // Every pair is distinct.
    for (0..all.len) |i| {
        for (i + 1..all.len) |j| {
            try std.testing.expect(all[i] != all[j]);
        }
    }
}

test "listOf same element type returns same TypeRef (interning)" {
    var arena = try TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    const a = try arena.listOf(arena.builtins.string_type);
    const b = try arena.listOf(arena.builtins.string_type);
    try std.testing.expectEqual(a, b);

    // Different element type yields different ref.
    const c = try arena.listOf(arena.builtins.int_type);
    try std.testing.expect(a != c);
}

test "mapOf same key/value returns same TypeRef (interning)" {
    var arena = try TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    const a = try arena.mapOf(arena.builtins.string_type, arena.builtins.int_type);
    const b = try arena.mapOf(arena.builtins.string_type, arena.builtins.int_type);
    try std.testing.expectEqual(a, b);

    const c = try arena.mapOf(arena.builtins.string_type, arena.builtins.bool_type);
    try std.testing.expect(a != c);
}

test "optionalOf and optionalInner roundtrip" {
    var arena = try TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    const opt = try arena.optionalOf(arena.builtins.int_type);
    const inner = arena.optionalInner(opt);
    try std.testing.expect(inner != null);
    try std.testing.expectEqual(arena.builtins.int_type, inner.?);

    // Non-optional type returns null.
    try std.testing.expect(arena.optionalInner(arena.builtins.int_type) == null);
}

test "messageOf and enumOf create named types" {
    var arena = try TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    const msg = try arena.messageOf("my.Message");
    try std.testing.expectEqual(TypeSpec.message, std.meta.activeTag(arena.spec(msg)));
    try std.testing.expectEqualStrings("my.Message", arena.spec(msg).message);

    const e = try arena.enumOf("my.Enum");
    try std.testing.expectEqual(TypeSpec.enum_type, std.meta.activeTag(arena.spec(e)));
    try std.testing.expectEqualStrings("my.Enum", arena.spec(e).enum_type);
}

test "messageOf same name returns same ref (interning)" {
    var arena = try TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    const a = try arena.messageOf("foo.Bar");
    const b = try arena.messageOf("foo.Bar");
    try std.testing.expectEqual(a, b);
}

test "typeParamOf creates type_param spec" {
    var arena = try TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    const tp = try arena.typeParamOf("T");
    try std.testing.expectEqual(TypeSpec.type_param, std.meta.activeTag(arena.spec(tp)));
    try std.testing.expectEqualStrings("T", arena.spec(tp).type_param);
}

test "abstractOf and abstractOfParams" {
    var arena = try TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    const a = try arena.abstractOf("vector");
    try std.testing.expectEqual(TypeSpec.abstract, std.meta.activeTag(arena.spec(a)));
    try std.testing.expectEqualStrings("vector", arena.spec(a).abstract.name);
    try std.testing.expectEqual(@as(usize, 0), arena.spec(a).abstract.params.len);

    // Same call is interned.
    const b = try arena.abstractOf("vector");
    try std.testing.expectEqual(a, b);

    // With params.
    const c = try arena.abstractOfParams("optional_type", &.{arena.builtins.int_type});
    try std.testing.expect(c != a);
    try std.testing.expectEqual(@as(usize, 1), arena.spec(c).abstract.params.len);
}

test "wrapperOf creates wrapper spec" {
    var arena = try TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    const w = try arena.wrapperOf(arena.builtins.bool_type);
    try std.testing.expectEqual(TypeSpec.wrapper, std.meta.activeTag(arena.spec(w)));
    try std.testing.expectEqual(arena.builtins.bool_type, arena.spec(w).wrapper);

    // Interning.
    const w2 = try arena.wrapperOf(arena.builtins.bool_type);
    try std.testing.expectEqual(w, w2);
}

test "spec returns correct TypeSpec for each builtin" {
    var arena = try TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    const cases = [_]struct { ty: TypeRef, expected: @typeInfo(TypeSpec).@"union".tag_type.? }{
        .{ .ty = arena.builtins.dyn_type, .expected = .dyn },
        .{ .ty = arena.builtins.null_type, .expected = .null_type },
        .{ .ty = arena.builtins.bool_type, .expected = .bool },
        .{ .ty = arena.builtins.int_type, .expected = .int },
        .{ .ty = arena.builtins.uint_type, .expected = .uint },
        .{ .ty = arena.builtins.double_type, .expected = .double },
        .{ .ty = arena.builtins.string_type, .expected = .string },
        .{ .ty = arena.builtins.bytes_type, .expected = .bytes },
        .{ .ty = arena.builtins.type_type, .expected = .type_type },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, std.meta.activeTag(arena.spec(case.ty)));
    }
}

test "type classification predicates" {
    var arena = try TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    const b = arena.builtins;

    // isNumeric
    const numeric_yes = [_]TypeRef{ b.int_type, b.uint_type, b.double_type };
    const numeric_no = [_]TypeRef{ b.string_type, b.bool_type, b.bytes_type, b.null_type, b.dyn_type };
    for (numeric_yes) |ty| try std.testing.expect(arena.isNumeric(ty));
    for (numeric_no) |ty| try std.testing.expect(!arena.isNumeric(ty));

    // isSimpleComparable
    const comparable_yes = [_]TypeRef{
        b.bool_type, b.int_type,       b.uint_type, b.double_type,
        b.string_type, b.bytes_type, b.timestamp_type, b.duration_type,
    };
    const comparable_no = [_]TypeRef{ b.dyn_type, b.null_type };
    for (comparable_yes) |ty| try std.testing.expect(arena.isSimpleComparable(ty));
    for (comparable_no) |ty| try std.testing.expect(!arena.isSimpleComparable(ty));

    // isTimestampType / isDurationType
    try std.testing.expect(arena.isTimestampType(b.timestamp_type));
    try std.testing.expect(!arena.isTimestampType(b.duration_type));
    try std.testing.expect(arena.isDurationType(b.duration_type));
    try std.testing.expect(!arena.isDurationType(b.timestamp_type));
}

test "isBuiltinTypeDenotation" {
    const yes_cases = [_][]const u8{
        "bool", "bytes", "double", "int", "list", "map", "null_type", "string", "type", "uint",
    };
    const no_cases = [_][]const u8{
        "dyn", "timestamp", "custom", "duration", "foo",
    };
    for (yes_cases) |name| try std.testing.expect(isBuiltinTypeDenotation(name));
    for (no_cases) |name| try std.testing.expect(!isBuiltinTypeDenotation(name));
}

test "displayName returns human-readable names" {
    var arena = try TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    const cases = [_]struct { ty: TypeRef, expected: []const u8 }{
        .{ .ty = arena.builtins.dyn_type, .expected = "dyn" },
        .{ .ty = arena.builtins.int_type, .expected = "int" },
        .{ .ty = arena.builtins.uint_type, .expected = "uint" },
        .{ .ty = arena.builtins.double_type, .expected = "double" },
        .{ .ty = arena.builtins.string_type, .expected = "string" },
        .{ .ty = arena.builtins.bool_type, .expected = "bool" },
        .{ .ty = arena.builtins.bytes_type, .expected = "bytes" },
        .{ .ty = arena.builtins.null_type, .expected = "null_type" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected, arena.displayName(case.ty));
    }

    const list = try arena.listOf(arena.builtins.int_type);
    try std.testing.expectEqualStrings("list", arena.displayName(list));

    const msg = try arena.messageOf("example.Foo");
    try std.testing.expectEqualStrings("example.Foo", arena.displayName(msg));
}

test "hostScalarOf creates host_scalar spec" {
    var arena = try TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    const hs = try arena.hostScalarOf("MyHost");
    try std.testing.expect(arena.isHostScalarType(hs));
    try std.testing.expectEqualStrings("MyHost", arena.displayName(hs));

    // Interning.
    const hs2 = try arena.hostScalarOf("MyHost");
    try std.testing.expectEqual(hs, hs2);
}

test "isEnumType" {
    var arena = try TypeProvider.init(std.testing.allocator);
    defer arena.deinit();

    const e = try arena.enumOf("my.Status");
    try std.testing.expect(arena.isEnumType(e));
    try std.testing.expect(!arena.isEnumType(arena.builtins.int_type));
}

test "child arena extend shares parent builtins" {
    var base = try TypeProvider.init(std.testing.allocator);
    defer base.deinit();

    var child = base.extend(std.testing.allocator);
    defer child.deinit();

    try std.testing.expectEqual(base.builtins.int_type, child.builtins.int_type);
    try std.testing.expectEqual(base.builtins.string_type, child.builtins.string_type);
    try std.testing.expectEqual(base.builtins.timestamp_type, child.builtins.timestamp_type);
}
