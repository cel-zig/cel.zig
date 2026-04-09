const std = @import("std");
const cel_time = @import("../library/cel_time.zig");
const partial = @import("../eval/partial.zig");

pub const RuntimeError = error{
    NoMatchingOverload,
    NoSuchField,
    DuplicateMapKey,
    DuplicateMessageField,
    Overflow,
    DivisionByZero,
    InvalidIndex,
    TypeMismatch,
};

pub const MapEntry = struct {
    key: Value,
    value: Value,
};

pub const MessageField = struct {
    name: []u8,
    value: Value,
};

pub const DynamicMessage = struct {
    name: []u8,
    fields: std.ArrayListUnmanaged(MessageField) = .empty,
};

pub const HostValueVTable = struct {
    type_name: []const u8,
    clone: *const fn (allocator: std.mem.Allocator, ptr: *const anyopaque) std.mem.Allocator.Error!*anyopaque,
    deinit: *const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void,
    eql: *const fn (lhs: *const anyopaque, rhs: *const anyopaque) bool,
    getField: ?*const fn (allocator: std.mem.Allocator, ptr: *const anyopaque, field: []const u8) RuntimeError!?Value = null,
};

pub const HostValue = struct {
    ptr: *anyopaque,
    vtable: *const HostValueVTable,
};

pub const OptionalValue = struct {
    value: ?*Value,
};

pub const EnumValue = struct {
    type_name: []u8,
    value: i32,
};

pub const Value = union(enum) {
    int: i64,
    uint: u64,
    double: f64,
    bool: bool,
    string: []u8,
    bytes: []u8,
    timestamp: cel_time.Timestamp,
    duration: cel_time.Duration,
    enum_value: EnumValue,
    host: HostValue,
    null,
    unknown: partial.UnknownSet,
    optional: OptionalValue,
    type_name: []u8,
    list: std.ArrayListUnmanaged(Value),
    map: std.ArrayListUnmanaged(MapEntry),
    message: DynamicMessage,

    /// Extract bool value, or null if not a bool.
    pub fn toBool(self: Value) ?bool {
        return if (self == .bool) self.bool else null;
    }

    /// Extract int value, or null if not an int.
    pub fn toInt(self: Value) ?i64 {
        return if (self == .int) self.int else null;
    }

    /// Extract uint value, or null if not a uint.
    pub fn toUint(self: Value) ?u64 {
        return if (self == .uint) self.uint else null;
    }

    /// Extract double value, or null if not a double.
    pub fn toDouble(self: Value) ?f64 {
        return if (self == .double) self.double else null;
    }

    /// Extract string value, or null if not a string.
    /// The returned slice is owned by the Value — do not free it.
    pub fn toString(self: Value) ?[]const u8 {
        return if (self == .string) self.string else null;
    }

    /// Extract bytes value, or null if not bytes.
    pub fn toBytes(self: Value) ?[]const u8 {
        return if (self == .bytes) self.bytes else null;
    }

    /// Returns true if this value is null.
    pub fn isNull(self: Value) bool {
        return self == .null;
    }

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |text| allocator.free(text),
            .bytes => |data| allocator.free(data),
            .enum_value => |enum_value| allocator.free(enum_value.type_name),
            .type_name => |name| allocator.free(name),
            .host => |host| host.vtable.deinit(allocator, host.ptr),
            .unknown => |*unknown| unknown.deinit(allocator),
            .optional => |opt| {
                if (opt.value) |ptr| {
                    ptr.deinit(allocator);
                    allocator.destroy(ptr);
                }
            },
            .list => |*items| {
                if (!valuesAreSelfContained(items.items)) {
                    for (items.items) |*item| item.deinit(allocator);
                }
                items.deinit(allocator);
            },
            .map => |*entries| {
                if (!mapEntriesAreSelfContained(entries.items)) {
                    for (entries.items) |*entry| {
                        entry.key.deinit(allocator);
                        entry.value.deinit(allocator);
                    }
                }
                entries.deinit(allocator);
            },
            .message => |*msg| {
                allocator.free(msg.name);
                for (msg.fields.items) |*field| {
                    allocator.free(field.name);
                    field.value.deinit(allocator);
                }
                msg.fields.deinit(allocator);
            },
            else => {},
        }
    }

    pub fn clone(self: Value, allocator: std.mem.Allocator) !Value {
        return switch (self) {
            .int, .uint, .double, .bool, .timestamp, .duration, .null => self,
            .string => |text| .{ .string = try allocator.dupe(u8, text) },
            .bytes => |data| .{ .bytes = try allocator.dupe(u8, data) },
            .enum_value => |enum_value| .{ .enum_value = .{
                .type_name = try allocator.dupe(u8, enum_value.type_name),
                .value = enum_value.value,
            } },
            .host => |host| .{ .host = .{
                .ptr = try host.vtable.clone(allocator, host.ptr),
                .vtable = host.vtable,
            } },
            .unknown => |unknown| .{ .unknown = try unknown.clone(allocator) },
            .optional => |opt| blk: {
                if (opt.value == null) break :blk optionalNone();
                const inner = try allocator.create(Value);
                errdefer allocator.destroy(inner);
                inner.* = try opt.value.?.*.clone(allocator);
                break :blk .{ .optional = .{ .value = inner } };
            },
            .type_name => |name| .{ .type_name = try allocator.dupe(u8, name) },
            .list => |items| blk: {
                var out: std.ArrayListUnmanaged(Value) = .empty;
                errdefer {
                    for (out.items) |*item| item.deinit(allocator);
                    out.deinit(allocator);
                }
                try out.ensureTotalCapacity(allocator, items.items.len);
                if (valuesAreSelfContained(items.items)) {
                    out.appendSliceAssumeCapacity(items.items);
                } else {
                    for (items.items) |item| {
                        out.appendAssumeCapacity(try item.clone(allocator));
                    }
                }
                break :blk .{ .list = out };
            },
            .map => |entries| blk: {
                var out: std.ArrayListUnmanaged(MapEntry) = .empty;
                errdefer {
                    for (out.items) |*entry| {
                        entry.key.deinit(allocator);
                        entry.value.deinit(allocator);
                    }
                    out.deinit(allocator);
                }
                try out.ensureTotalCapacity(allocator, entries.items.len);
                if (mapEntriesAreSelfContained(entries.items)) {
                    out.appendSliceAssumeCapacity(entries.items);
                } else {
                    for (entries.items) |entry| {
                        out.appendAssumeCapacity(.{
                            .key = try entry.key.clone(allocator),
                            .value = try entry.value.clone(allocator),
                        });
                    }
                }
                break :blk .{ .map = out };
            },
            .message => |msg| blk: {
                var out = DynamicMessage{
                    .name = try allocator.dupe(u8, msg.name),
                };
                errdefer {
                    allocator.free(out.name);
                    for (out.fields.items) |*field| {
                        allocator.free(field.name);
                        field.value.deinit(allocator);
                    }
                    out.fields.deinit(allocator);
                }
                try out.fields.ensureTotalCapacity(allocator, msg.fields.items.len);
                for (msg.fields.items) |field| {
                    out.fields.appendAssumeCapacity(.{
                        .name = try allocator.dupe(u8, field.name),
                        .value = try field.value.clone(allocator),
                    });
                }
                break :blk .{ .message = out };
            },
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        const tag_a = std.meta.activeTag(a);
        const tag_b = std.meta.activeTag(b);
        if (tag_a != tag_b) return false;

        return switch (a) {
            .int => |v| v == b.int,
            .uint => |v| v == b.uint,
            .double => |v| {
                if (std.math.isNan(v) and std.math.isNan(b.double)) return true;
                return v == b.double;
            },
            .bool => |v| v == b.bool,
            .string => |v| std.mem.eql(u8, v, b.string),
            .bytes => |v| std.mem.eql(u8, v, b.bytes),
            .timestamp => |v| v.seconds == b.timestamp.seconds and v.nanos == b.timestamp.nanos,
            .duration => |v| v.seconds == b.duration.seconds and v.nanos == b.duration.nanos,
            .enum_value => |enum_value| enum_value.value == b.enum_value.value and
                std.mem.eql(u8, enum_value.type_name, b.enum_value.type_name),
            .host => |host| host.vtable == b.host.vtable and host.vtable.eql(host.ptr, b.host.ptr),
            .null => true,
            .unknown => |unknown| unknown.eql(&b.unknown),
            .optional => |opt| blk: {
                if (opt.value == null) break :blk b.optional.value == null;
                if (b.optional.value == null) break :blk false;
                break :blk opt.value.?.*.eql(b.optional.value.?.*);
            },
            .type_name => |v| std.mem.eql(u8, v, b.type_name),
            .list => |items| {
                if (items.items.len != b.list.items.len) return false;
                for (items.items, b.list.items) |lhs, rhs| {
                    if (!lhs.eql(rhs)) return false;
                }
                return true;
            },
            .map => |entries| {
                if (entries.items.len != b.map.items.len) return false;
                for (entries.items, b.map.items) |lhs, rhs| {
                    if (!lhs.key.eql(rhs.key) or !lhs.value.eql(rhs.value)) return false;
                }
                return true;
            },
            .message => |msg| {
                if (!std.mem.eql(u8, msg.name, b.message.name)) return false;
                if (msg.fields.items.len != b.message.fields.items.len) return false;
                for (msg.fields.items, b.message.fields.items) |lhs, rhs| {
                    if (!std.mem.eql(u8, lhs.name, rhs.name)) return false;
                    if (!lhs.value.eql(rhs.value)) return false;
                }
                return true;
            },
        };
    }

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .int => "int",
            .uint => "uint",
            .double => "double",
            .bool => "bool",
            .string => "string",
            .bytes => "bytes",
            .timestamp => "google.protobuf.Timestamp",
            .duration => "google.protobuf.Duration",
            .enum_value => |enum_value| enum_value.type_name,
            .host => |host| host.vtable.type_name,
            .null => "null_type",
            .unknown => "unknown",
            .optional => "optional_type",
            .type_name => "type",
            .list => "list",
            .map => "map",
            .message => |msg| msg.name,
        };
    }
};

pub fn string(allocator: std.mem.Allocator, text: []const u8) !Value {
    return .{ .string = try allocator.dupe(u8, text) };
}

pub fn bytesValue(allocator: std.mem.Allocator, data: []const u8) !Value {
    return .{ .bytes = try allocator.dupe(u8, data) };
}

pub fn typeNameValue(allocator: std.mem.Allocator, text: []const u8) !Value {
    return .{ .type_name = try allocator.dupe(u8, text) };
}

pub fn hostValue(ptr: *anyopaque, vtable: *const HostValueVTable) Value {
    return .{ .host = .{
        .ptr = ptr,
        .vtable = vtable,
    } };
}

pub fn enumValue(allocator: std.mem.Allocator, type_name: []const u8, raw_value: i32) !Value {
    return .{ .enum_value = .{
        .type_name = try allocator.dupe(u8, type_name),
        .value = raw_value,
    } };
}

pub fn optionalNone() Value {
    return .{ .optional = .{ .value = null } };
}

pub fn optionalSome(allocator: std.mem.Allocator, inner: Value) !Value {
    const ptr = try allocator.create(Value);
    errdefer allocator.destroy(ptr);
    ptr.* = inner;
    return .{ .optional = .{ .value = ptr } };
}

fn valuesAreSelfContained(items: []const Value) bool {
    for (items) |item| {
        if (!valueIsSelfContained(item)) return false;
    }
    return true;
}

fn mapEntriesAreSelfContained(entries: []const MapEntry) bool {
    for (entries) |entry| {
        if (!valueIsSelfContained(entry.key) or !valueIsSelfContained(entry.value)) return false;
    }
    return true;
}

fn valueIsSelfContained(v: Value) bool {
    return switch (v) {
        .int, .uint, .double, .bool, .timestamp, .duration, .null => true,
        else => false,
    };
}

pub fn unknownFromSet(set: partial.UnknownSet) Value {
    return .{ .unknown = set };
}

test "value clone and equality work recursively" {
    var list: std.ArrayListUnmanaged(Value) = .empty;
    defer {
        var v: Value = .{ .list = list };
        v.deinit(std.testing.allocator);
    }

    try list.append(std.testing.allocator, .{ .int = 1 });
    try list.append(std.testing.allocator, try string(std.testing.allocator, "x"));

    const original: Value = .{ .list = list };
    var cloned = try original.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expect(original.eql(cloned));
}

test "int value creation and clone" {
    var v: Value = .{ .int = 42 };
    var c = try v.clone(std.testing.allocator);
    defer c.deinit(std.testing.allocator);

    try std.testing.expect(v.eql(c));
    try std.testing.expectEqual(@as(i64, 42), c.int);
}

test "uint value creation and clone" {
    var v: Value = .{ .uint = 100 };
    var c = try v.clone(std.testing.allocator);
    defer c.deinit(std.testing.allocator);

    try std.testing.expect(v.eql(c));
    try std.testing.expectEqual(@as(u64, 100), c.uint);
}

test "double value creation and clone" {
    var v: Value = .{ .double = 3.14 };
    var c = try v.clone(std.testing.allocator);
    defer c.deinit(std.testing.allocator);

    try std.testing.expect(v.eql(c));
    try std.testing.expectEqual(@as(f64, 3.14), c.double);
}

test "bool value creation and clone" {
    var t: Value = .{ .bool = true };
    const f: Value = .{ .bool = false };
    try std.testing.expect(t.eql(.{ .bool = true }));
    try std.testing.expect(!t.eql(f));

    var tc = try t.clone(std.testing.allocator);
    defer tc.deinit(std.testing.allocator);
    try std.testing.expect(tc.bool);
}

test "null value creation" {
    const v: Value = .null;
    try std.testing.expect(v.eql(.null));
    try std.testing.expectEqualStrings("null_type", v.typeName());
}

test "string value creation, clone, and deinit frees" {
    var v = try string(std.testing.allocator, "hello");
    defer v.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hello", v.string);

    var c = try v.clone(std.testing.allocator);
    defer c.deinit(std.testing.allocator);

    try std.testing.expect(v.eql(c));
    // Ensure they are separate allocations.
    try std.testing.expect(v.string.ptr != c.string.ptr);
}

test "bytes value creation, clone, and deinit frees" {
    var v = try bytesValue(std.testing.allocator, &.{ 0xDE, 0xAD });
    defer v.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), v.bytes.len);

    var c = try v.clone(std.testing.allocator);
    defer c.deinit(std.testing.allocator);

    try std.testing.expect(v.eql(c));
    try std.testing.expect(v.bytes.ptr != c.bytes.ptr);
}

test "timestamp value creation and clone" {
    var v: Value = .{ .timestamp = .{ .seconds = 1000, .nanos = 500 } };
    var c = try v.clone(std.testing.allocator);
    defer c.deinit(std.testing.allocator);

    try std.testing.expect(v.eql(c));
    try std.testing.expectEqual(@as(i64, 1000), c.timestamp.seconds);
    try std.testing.expectEqual(@as(u32, 500), c.timestamp.nanos);
    try std.testing.expectEqualStrings("google.protobuf.Timestamp", v.typeName());
}

test "duration value creation and clone" {
    var v: Value = .{ .duration = .{ .seconds = 60, .nanos = 0 } };
    var c = try v.clone(std.testing.allocator);
    defer c.deinit(std.testing.allocator);

    try std.testing.expect(v.eql(c));
    try std.testing.expectEqual(@as(i64, 60), c.duration.seconds);
    try std.testing.expectEqualStrings("google.protobuf.Duration", v.typeName());
}

test "enum value creation and clone" {
    var v = try enumValue(std.testing.allocator, "my.Status", 1);
    defer v.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i32, 1), v.enum_value.value);
    try std.testing.expectEqualStrings("my.Status", v.enum_value.type_name);

    var c = try v.clone(std.testing.allocator);
    defer c.deinit(std.testing.allocator);

    try std.testing.expect(v.eql(c));
    // Separate allocation for type_name.
    try std.testing.expect(v.enum_value.type_name.ptr != c.enum_value.type_name.ptr);
}

test "optional value: some and none" {
    // None.
    const none = optionalNone();
    try std.testing.expect(none.optional.value == null);
    try std.testing.expectEqualStrings("optional_type", none.typeName());

    // Some.
    var some = try optionalSome(std.testing.allocator, .{ .int = 7 });
    defer some.deinit(std.testing.allocator);
    try std.testing.expect(some.optional.value != null);
    try std.testing.expectEqual(@as(i64, 7), some.optional.value.?.int);

    // Clone some.
    var cloned = try some.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);
    try std.testing.expect(some.eql(cloned));

    // Clone none.
    var cloned_none = try none.clone(std.testing.allocator);
    defer cloned_none.deinit(std.testing.allocator);
    try std.testing.expect(none.eql(cloned_none));

    // None != Some.
    try std.testing.expect(!none.eql(some));
}

test "type_name value creation and clone" {
    var v = try typeNameValue(std.testing.allocator, "int");
    defer v.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("int", v.type_name);
    try std.testing.expectEqualStrings("type", v.typeName());

    var c = try v.clone(std.testing.allocator);
    defer c.deinit(std.testing.allocator);
    try std.testing.expect(v.eql(c));
}

test "list value creation and clone" {
    var items: std.ArrayListUnmanaged(Value) = .empty;
    try items.append(std.testing.allocator, .{ .int = 1 });
    try items.append(std.testing.allocator, .{ .int = 2 });
    try items.append(std.testing.allocator, .{ .int = 3 });

    var v: Value = .{ .list = items };
    defer v.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), v.list.items.len);
    try std.testing.expectEqual(@as(i64, 2), v.list.items[1].int);

    var c = try v.clone(std.testing.allocator);
    defer c.deinit(std.testing.allocator);
    try std.testing.expect(v.eql(c));
    try std.testing.expectEqual(@as(usize, 3), c.list.items.len);
}

test "map value creation and clone" {
    var entries: std.ArrayListUnmanaged(MapEntry) = .empty;
    defer {
        for (entries.items) |*e| {
            e.key.deinit(std.testing.allocator);
            e.value.deinit(std.testing.allocator);
        }
        entries.deinit(std.testing.allocator);
    }

    try entries.append(std.testing.allocator, .{
        .key = try string(std.testing.allocator, "a"),
        .value = .{ .int = 1 },
    });
    try entries.append(std.testing.allocator, .{
        .key = try string(std.testing.allocator, "b"),
        .value = .{ .int = 2 },
    });

    const original: Value = .{ .map = entries };

    var c = try original.clone(std.testing.allocator);
    defer c.deinit(std.testing.allocator);
    try std.testing.expect(original.eql(c));
    try std.testing.expectEqual(@as(usize, 2), c.map.items.len);
}

test "message value creation and clone" {
    var fields: std.ArrayListUnmanaged(MessageField) = .empty;
    try fields.append(std.testing.allocator, .{
        .name = try std.testing.allocator.dupe(u8, "x"),
        .value = .{ .int = 10 },
    });

    const msg_name = try std.testing.allocator.dupe(u8, "example.Point");

    var v: Value = .{ .message = .{
        .name = msg_name,
        .fields = fields,
    } };
    defer v.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("example.Point", v.message.name);
    try std.testing.expectEqual(@as(usize, 1), v.message.fields.items.len);

    var c = try v.clone(std.testing.allocator);
    defer c.deinit(std.testing.allocator);
    try std.testing.expect(v.eql(c));
    // Separate allocations.
    try std.testing.expect(v.message.name.ptr != c.message.name.ptr);
}

test "clone of clone (deep copy verification)" {
    var v = try string(std.testing.allocator, "deep");
    defer v.deinit(std.testing.allocator);

    var c1 = try v.clone(std.testing.allocator);
    defer c1.deinit(std.testing.allocator);

    var c2 = try c1.clone(std.testing.allocator);
    defer c2.deinit(std.testing.allocator);

    try std.testing.expect(v.eql(c1));
    try std.testing.expect(c1.eql(c2));
    try std.testing.expect(v.eql(c2));

    // All three are separate allocations.
    try std.testing.expect(v.string.ptr != c1.string.ptr);
    try std.testing.expect(c1.string.ptr != c2.string.ptr);
}

test "list with nested string values clone is deep" {
    var items: std.ArrayListUnmanaged(Value) = .empty;
    try items.append(std.testing.allocator, try string(std.testing.allocator, "hello"));
    try items.append(std.testing.allocator, try string(std.testing.allocator, "world"));

    var v: Value = .{ .list = items };
    defer v.deinit(std.testing.allocator);

    var c = try v.clone(std.testing.allocator);
    defer c.deinit(std.testing.allocator);

    try std.testing.expect(v.eql(c));
    // Inner strings should be separate allocations.
    try std.testing.expect(v.list.items[0].string.ptr != c.list.items[0].string.ptr);
}

test "eql returns false for different types" {
    const a: Value = .{ .int = 1 };
    const b: Value = .{ .uint = 1 };
    try std.testing.expect(!a.eql(b));
}

test "typeName returns correct names" {
    try std.testing.expectEqualStrings("int", (Value{ .int = 0 }).typeName());
    try std.testing.expectEqualStrings("uint", (Value{ .uint = 0 }).typeName());
    try std.testing.expectEqualStrings("double", (Value{ .double = 0 }).typeName());
    try std.testing.expectEqualStrings("bool", (Value{ .bool = false }).typeName());
    const null_val: Value = .null;
    try std.testing.expectEqualStrings("null_type", null_val.typeName());
    try std.testing.expectEqualStrings("list", (Value{ .list = .empty }).typeName());
    try std.testing.expectEqualStrings("map", (Value{ .map = .empty }).typeName());
}
