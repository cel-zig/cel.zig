const std = @import("std");
const cel_time = @import("cel_time.zig");
const env = @import("../env/env.zig");
const schema = @import("../env/schema.zig");
const types = @import("../env/types.zig");
const value = @import("../env/value.zig");

pub const MessageFieldInit = struct {
    field: *const schema.FieldDecl,
    value: value.Value,
};

pub const DecodeError = std.mem.Allocator.Error || value.RuntimeError || error{
    InvalidValue,
};

pub fn buildMessageLiteral(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    desc: *const schema.MessageDecl,
    inits: []const MessageFieldInit,
) env.EvalError!value.Value {
    return switch (desc.kind) {
        .plain => buildPlainMessageLiteral(allocator, desc, inits),
        .timestamp => buildTimestampLiteral(inits),
        .duration => buildDurationLiteral(inits),
        .list_value => buildListValueLiteral(allocator, inits),
        .struct_value => buildStructLiteral(allocator, inits),
        .value => buildValueLiteral(allocator, inits),
        .any => buildAnyLiteral(allocator, environment, inits),
        else => buildWrapperLiteral(allocator, environment, desc.kind, inits),
    };
}

pub fn defaultFieldValue(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    field: *const schema.FieldDecl,
) env.EvalError!value.Value {
    if (field.default_value) |default_value| {
        return cloneFieldDefaultValue(allocator, environment, field.ty, default_value);
    }
    return switch (field.encoding) {
        .repeated => .{ .list = .empty },
        .map => .{ .map = .empty },
        .singular => |raw| defaultProtoValue(allocator, environment, field.ty, raw, true),
    };
}

pub fn coerceFieldValue(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    field: *const schema.FieldDecl,
    input: value.Value,
) env.EvalError!?value.Value {
    return switch (field.encoding) {
        .singular => |raw| switch (raw) {
            .scalar => |scalar| coerceScalarValue(allocator, environment, field.ty, scalar, input, false),
            .message => coerceSingular(allocator, environment, field.ty, raw, input, true),
        },
        .repeated => |repeated| coerceRepeated(allocator, environment, field.ty, repeated, input),
        .map => |map| coerceMap(allocator, environment, field.ty, map, input),
    };
}

pub fn decodeMessage(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    message_name: []const u8,
    data: []const u8,
) DecodeError!value.Value {
    const desc = environment.lookupMessage(message_name) orelse return value.RuntimeError.NoSuchField;
    return switch (desc.kind) {
        .plain => decodePlainMessage(allocator, environment, desc, data),
        .timestamp => decodeTimestamp(data),
        .duration => decodeDuration(data),
        .list_value => decodeListValue(allocator, environment, data),
        .struct_value => decodeStruct(allocator, environment, data),
        .value => decodeValueMessage(allocator, environment, data),
        .any => decodeAnyMessage(allocator, environment, data),
        else => decodeWrapperMessage(allocator, environment, desc.kind, data),
    };
}

fn buildPlainMessageLiteral(
    allocator: std.mem.Allocator,
    desc: *const schema.MessageDecl,
    inits: []const MessageFieldInit,
) env.EvalError!value.Value {
    var out = value.DynamicMessage{
        .name = try allocator.dupe(u8, desc.name),
    };
    errdefer {
        allocator.free(out.name);
        for (out.fields.items) |*field| {
            allocator.free(field.name);
            field.value.deinit(allocator);
        }
        out.fields.deinit(allocator);
    }

    try out.fields.ensureTotalCapacity(allocator, inits.len);
    for (inits) |init| {
        if (findFieldIndex(out.fields.items, init.field.name) != null) return value.RuntimeError.DuplicateMessageField;
        out.fields.appendAssumeCapacity(.{
            .name = try allocator.dupe(u8, init.field.name),
            .value = try init.value.clone(allocator),
        });
    }
    return .{ .message = out };
}

fn buildTimestampLiteral(inits: []const MessageFieldInit) env.EvalError!value.Value {
    var seconds: i64 = 0;
    var nanos: i64 = 0;
    for (inits) |init| {
        if (std.mem.eql(u8, init.field.name, "seconds")) {
            seconds = switch (init.value) {
                .int => |v| v,
                else => return value.RuntimeError.TypeMismatch,
            };
            continue;
        }
        if (std.mem.eql(u8, init.field.name, "nanos")) {
            nanos = switch (init.value) {
                .int => |v| v,
                else => return value.RuntimeError.TypeMismatch,
            };
        }
    }
    return .{ .timestamp = cel_time.Timestamp.fromComponents(seconds, @intCast(nanos)) catch return value.RuntimeError.Overflow };
}

fn buildDurationLiteral(inits: []const MessageFieldInit) env.EvalError!value.Value {
    var seconds: i64 = 0;
    var nanos: i64 = 0;
    for (inits) |init| {
        if (std.mem.eql(u8, init.field.name, "seconds")) {
            seconds = switch (init.value) {
                .int => |v| v,
                else => return value.RuntimeError.TypeMismatch,
            };
            continue;
        }
        if (std.mem.eql(u8, init.field.name, "nanos")) {
            nanos = switch (init.value) {
                .int => |v| v,
                else => return value.RuntimeError.TypeMismatch,
            };
        }
    }
    return .{ .duration = cel_time.Duration.fromComponents(seconds, @intCast(nanos)) catch return value.RuntimeError.Overflow };
}

fn buildWrapperLiteral(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    kind: schema.MessageKind,
    inits: []const MessageFieldInit,
) env.EvalError!value.Value {
    const scalar = schema.wrapperScalar(kind) orelse return value.RuntimeError.TypeMismatch;
    if (inits.len == 0) return defaultScalarValue(allocator, environment, null, scalar);
    if (inits.len != 1 or !std.mem.eql(u8, inits[0].field.name, "value")) return value.RuntimeError.TypeMismatch;
    return (try coerceSingular(allocator, environment, null, .{ .scalar = scalar }, inits[0].value, false)) orelse
        value.RuntimeError.TypeMismatch;
}

fn buildListValueLiteral(
    allocator: std.mem.Allocator,
    inits: []const MessageFieldInit,
) env.EvalError!value.Value {
    if (inits.len == 0) return .{ .list = .empty };
    if (inits.len != 1 or !std.mem.eql(u8, inits[0].field.name, "values")) return value.RuntimeError.TypeMismatch;
    return inits[0].value.clone(allocator);
}

fn buildStructLiteral(
    allocator: std.mem.Allocator,
    inits: []const MessageFieldInit,
) env.EvalError!value.Value {
    if (inits.len == 0) return .{ .map = .empty };
    if (inits.len != 1 or !std.mem.eql(u8, inits[0].field.name, "fields")) return value.RuntimeError.TypeMismatch;
    return inits[0].value.clone(allocator);
}

fn buildValueLiteral(
    allocator: std.mem.Allocator,
    inits: []const MessageFieldInit,
) env.EvalError!value.Value {
    if (inits.len == 0) return .null;
    if (inits.len != 1) return value.RuntimeError.TypeMismatch;
    if (std.mem.eql(u8, inits[0].field.name, "null_value")) return .null;
    return switch (inits[0].value) {
        .null => .null,
        else => inits[0].value.clone(allocator),
    };
}

fn buildAnyLiteral(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    inits: []const MessageFieldInit,
) env.EvalError!value.Value {
    if (inits.len == 0) return value.RuntimeError.TypeMismatch;
    if (inits.len == 1 and std.mem.eql(u8, inits[0].field.name, "value")) {
        return inits[0].value.clone(allocator);
    }
    if (inits.len == 2) {
        var type_url: ?[]const u8 = null;
        var payload: ?[]const u8 = null;
        for (inits) |init| {
            if (std.mem.eql(u8, init.field.name, "type_url")) {
                type_url = switch (init.value) {
                    .string => |text| text,
                    else => return value.RuntimeError.TypeMismatch,
                };
                continue;
            }
            if (std.mem.eql(u8, init.field.name, "value")) {
                payload = switch (init.value) {
                    .bytes => |bytes| bytes,
                    else => return value.RuntimeError.TypeMismatch,
                };
            }
        }
        const url = type_url orelse return value.RuntimeError.TypeMismatch;
        const bytes = payload orelse return value.RuntimeError.TypeMismatch;
        const prefix = "type.googleapis.com/";
        if (!std.mem.startsWith(u8, url, prefix)) return rawAnyMessage(allocator, type_url, payload);
        return decodeMessage(allocator, environment, url[prefix.len..], bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return rawAnyMessage(allocator, type_url, payload),
        };
    }
    return value.RuntimeError.TypeMismatch;
}

fn rawAnyMessage(
    allocator: std.mem.Allocator,
    type_url: ?[]const u8,
    payload: ?[]const u8,
) std.mem.Allocator.Error!value.Value {
    var out = value.DynamicMessage{
        .name = try allocator.dupe(u8, "google.protobuf.Any"),
    };
    errdefer {
        allocator.free(out.name);
        for (out.fields.items) |*field| {
            allocator.free(field.name);
            field.value.deinit(allocator);
        }
        out.fields.deinit(allocator);
    }

    if (type_url != null and payload != null) try out.fields.ensureTotalCapacity(allocator, 2) else if (type_url != null or payload != null) try out.fields.ensureTotalCapacity(allocator, 1);

    if (type_url) |url| {
        out.fields.appendAssumeCapacity(.{
            .name = try allocator.dupe(u8, "type_url"),
            .value = try value.string(allocator, url),
        });
    }
    if (payload) |bytes| {
        out.fields.appendAssumeCapacity(.{
            .name = try allocator.dupe(u8, "value"),
            .value = try value.bytesValue(allocator, bytes),
        });
    }
    return .{ .message = out };
}

fn coerceRepeated(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    field_ty: types.TypeRef,
    repeated: schema.RepeatedDecl,
    input: value.Value,
) env.EvalError!?value.Value {
    const items = switch (input) {
        .list => |list| list.items,
        else => return value.RuntimeError.TypeMismatch,
    };

    var out: std.ArrayListUnmanaged(value.Value) = .empty;
    errdefer {
        for (out.items) |*entry| entry.deinit(allocator);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, items.len);
    const elem_ty = switch (environment.types.spec(field_ty)) {
        .list => |inner| inner,
        else => null,
    };
    for (items) |item| {
        const coerced = try coerceSingular(allocator, environment, elem_ty, repeated.element, item, false) orelse continue;
        out.appendAssumeCapacity(coerced);
    }
    return .{ .list = out };
}

fn coerceMap(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    field_ty: types.TypeRef,
    map_decl: schema.MapDecl,
    input: value.Value,
) env.EvalError!?value.Value {
    const entries = switch (input) {
        .map => |map| map.items,
        else => return value.RuntimeError.TypeMismatch,
    };

    var out: std.ArrayListUnmanaged(value.MapEntry) = .empty;
    errdefer {
        for (out.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, entries.len);
    const value_ty = switch (environment.types.spec(field_ty)) {
        .map => |pair| pair.value,
        else => null,
    };
    for (entries) |entry| {
        const key = try coerceMapKey(allocator, map_decl.key, entry.key);
        errdefer {
            var temp_key = key;
            temp_key.deinit(allocator);
        }
        const coerced_value = try coerceSingular(allocator, environment, value_ty, map_decl.value, entry.value, false) orelse {
            var temp_key = key;
            temp_key.deinit(allocator);
            continue;
        };
        out.appendAssumeCapacity(.{
            .key = key,
            .value = coerced_value,
        });
    }
    return .{ .map = out };
}

fn coerceMapKey(
    allocator: std.mem.Allocator,
    scalar: schema.ProtoScalarKind,
    input: value.Value,
) env.EvalError!value.Value {
    return (try coerceScalarValue(allocator, null, null, scalar, input, false)) orelse value.RuntimeError.TypeMismatch;
}

fn coerceSingular(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    expected_ty: ?types.TypeRef,
    raw: schema.ProtoValueType,
    input: value.Value,
    unset_on_null: bool,
) env.EvalError!?value.Value {
    return switch (raw) {
        .scalar => |scalar| coerceScalarValue(allocator, environment, expected_ty, scalar, input, unset_on_null),
        .message => |name| coerceMessageValue(allocator, environment, name, input, unset_on_null),
    };
}

fn coerceScalarValue(
    allocator: std.mem.Allocator,
    environment: ?*const env.Env,
    expected_ty: ?types.TypeRef,
    scalar: schema.ProtoScalarKind,
    input: value.Value,
    unset_on_null: bool,
) env.EvalError!?value.Value {
    if (unset_on_null and input == .null and scalar != .enum_value) return null;

    return switch (scalar) {
        .bool => switch (input) {
            .bool => |v| .{ .bool = v },
            else => value.RuntimeError.TypeMismatch,
        },
        .int32, .sint32, .sfixed32 => switch (input) {
            .int => |v| blk: {
                if (v < std.math.minInt(i32) or v > std.math.maxInt(i32)) return value.RuntimeError.Overflow;
                break :blk .{ .int = v };
            },
            else => value.RuntimeError.TypeMismatch,
        },
        .int64, .sint64, .sfixed64 => switch (input) {
            .int => |v| .{ .int = v },
            else => value.RuntimeError.TypeMismatch,
        },
        .uint32, .fixed32 => switch (input) {
            .uint => |v| blk: {
                if (v > std.math.maxInt(u32)) return value.RuntimeError.Overflow;
                break :blk .{ .uint = v };
            },
            else => value.RuntimeError.TypeMismatch,
        },
        .uint64, .fixed64 => switch (input) {
            .uint => |v| .{ .uint = v },
            else => value.RuntimeError.TypeMismatch,
        },
        .float => switch (input) {
            .double => |v| .{ .double = @as(f64, @floatCast(@as(f32, @floatCast(v)))) },
            else => value.RuntimeError.TypeMismatch,
        },
        .double => switch (input) {
            .double => |v| .{ .double = v },
            else => value.RuntimeError.TypeMismatch,
        },
        .string => switch (input) {
            .string => |text| try value.string(allocator, text),
            else => value.RuntimeError.TypeMismatch,
        },
        .bytes => switch (input) {
            .bytes => |data| try value.bytesValue(allocator, data),
            else => value.RuntimeError.TypeMismatch,
        },
        .enum_value => blk: {
            const maybe_enum_name = if (environment != null and expected_ty != null) switch (environment.?.types.spec(expected_ty.?)) {
                .enum_type => |name| name,
                else => null,
            } else null;
            if (maybe_enum_name) |enum_name| {
                switch (input) {
                    .enum_value => |enum_value| {
                        if (!std.mem.eql(u8, enum_value.type_name, enum_name)) return value.RuntimeError.TypeMismatch;
                        break :blk try value.enumValue(allocator, enum_name, enum_value.value);
                    },
                    else => return value.RuntimeError.TypeMismatch,
                }
            }
            switch (input) {
                .int => |v| {
                    if (v < std.math.minInt(i32) or v > std.math.maxInt(i32)) return value.RuntimeError.Overflow;
                    break :blk .{ .int = v };
                },
                else => return value.RuntimeError.TypeMismatch,
            }
        },
    };
}

fn coerceMessageValue(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    message_name: []const u8,
    input: value.Value,
    unset_on_null: bool,
) env.EvalError!?value.Value {
    const desc = environment.lookupMessage(message_name) orelse return value.RuntimeError.NoSuchField;
    return switch (desc.kind) {
        .timestamp => switch (input) {
            .timestamp => |v| .{ .timestamp = v },
            .null => null,
            else => value.RuntimeError.TypeMismatch,
        },
        .duration => switch (input) {
            .duration => |v| .{ .duration = v },
            .null => null,
            else => value.RuntimeError.TypeMismatch,
        },
        .list_value => if (input == .null)
            value.RuntimeError.TypeMismatch
        else
            try coerceJsonList(allocator, environment, input),
        .struct_value => if (input == .null)
            value.RuntimeError.TypeMismatch
        else
            try coerceJsonMap(allocator, environment, input),
        .value => try coerceJsonValue(allocator, environment, input),
        .any => if (input == .null and unset_on_null)
            .null
        else
            try input.clone(allocator),
        else => if (schema.isWrapperKind(desc.kind))
            coerceScalarValue(allocator, environment, null, schema.wrapperScalar(desc.kind).?, input, true)
        else switch (input) {
            .message => |msg| if (std.mem.eql(u8, msg.name, message_name))
                try input.clone(allocator)
            else
                value.RuntimeError.TypeMismatch,
            .null => null,
            else => value.RuntimeError.TypeMismatch,
        },
    };
}

fn coerceJsonValue(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    input: value.Value,
) env.EvalError!value.Value {
    return switch (input) {
        .null => .null,
        .bool => |v| .{ .bool = v },
        .double => |v| .{ .double = v },
        .timestamp => |ts| blk: {
            const rendered = try cel_time.formatTimestamp(allocator, ts);
            defer allocator.free(rendered);
            break :blk try value.string(allocator, rendered);
        },
        .duration => |d| blk: {
            const rendered = try cel_time.formatDuration(allocator, d);
            defer allocator.free(rendered);
            break :blk try value.string(allocator, rendered);
        },
        .string => |text| try value.string(allocator, text),
        .bytes => |data| blk: {
            const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
            const encoded = try allocator.alloc(u8, encoded_len);
            defer allocator.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, data);
            break :blk try value.string(allocator, encoded);
        },
        .int => |v| if (isJsonSafeInteger(v))
            .{ .double = @as(f64, @floatFromInt(v)) }
        else blk: {
            var buf: [32]u8 = undefined;
            const text = std.fmt.bufPrint(buf[0..], "{d}", .{v}) catch unreachable;
            break :blk try value.string(allocator, text);
        },
        .uint => |v| if (v <= 9_007_199_254_740_991)
            .{ .double = @as(f64, @floatFromInt(v)) }
        else blk: {
            var buf: [32]u8 = undefined;
            const text = std.fmt.bufPrint(buf[0..], "{d}", .{v}) catch unreachable;
            break :blk try value.string(allocator, text);
        },
        .list => try coerceJsonList(allocator, environment, input),
        .map => try coerceJsonMap(allocator, environment, input),
        .message => |msg| {
            if (std.mem.eql(u8, msg.name, "google.protobuf.Empty")) return .{ .map = .empty };
            if (std.mem.eql(u8, msg.name, "google.protobuf.FieldMask")) return coerceFieldMaskJson(allocator, input);
            return value.RuntimeError.TypeMismatch;
        },
        else => value.RuntimeError.TypeMismatch,
    };
}

fn coerceFieldMaskJson(
    allocator: std.mem.Allocator,
    input: value.Value,
) env.EvalError!value.Value {
    const msg = switch (input) {
        .message => |message| message,
        else => return value.RuntimeError.TypeMismatch,
    };
    const field_index = findFieldIndex(msg.fields.items, "paths") orelse return try value.string(allocator, "");
    const paths = switch (msg.fields.items[field_index].value) {
        .list => |list| list.items,
        else => return value.RuntimeError.TypeMismatch,
    };

    var builder: std.ArrayListUnmanaged(u8) = .empty;
    defer builder.deinit(allocator);
    for (paths, 0..) |entry, i| {
        const segment = switch (entry) {
            .string => |text| text,
            else => return value.RuntimeError.TypeMismatch,
        };
        if (i != 0) try builder.append(allocator, ',');
        try builder.appendSlice(allocator, segment);
    }
    return value.string(allocator, builder.items);
}

fn coerceJsonList(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    input: value.Value,
) env.EvalError!value.Value {
    const items = switch (input) {
        .list => |list| list.items,
        else => return value.RuntimeError.TypeMismatch,
    };
    var out: std.ArrayListUnmanaged(value.Value) = .empty;
    errdefer {
        for (out.items) |*entry| entry.deinit(allocator);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, items.len);
    for (items) |item| out.appendAssumeCapacity(try coerceJsonValue(allocator, environment, item));
    return .{ .list = out };
}

fn coerceJsonMap(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    input: value.Value,
) env.EvalError!value.Value {
    const entries = switch (input) {
        .map => |map| map.items,
        else => return value.RuntimeError.TypeMismatch,
    };
    var out: std.ArrayListUnmanaged(value.MapEntry) = .empty;
    errdefer {
        for (out.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, entries.len);
    for (entries) |entry| {
        const key = switch (entry.key) {
            .string => |text| try value.string(allocator, text),
            else => return value.RuntimeError.TypeMismatch,
        };
        errdefer {
            var temp_key = key;
            temp_key.deinit(allocator);
        }
        out.appendAssumeCapacity(.{
            .key = key,
            .value = try coerceJsonValue(allocator, environment, entry.value),
        });
    }
    return .{ .map = out };
}

fn defaultProtoValue(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    expected_ty: types.TypeRef,
    raw: schema.ProtoValueType,
    missing_field: bool,
) (std.mem.Allocator.Error || value.RuntimeError)!value.Value {
    return switch (raw) {
        .scalar => |scalar| defaultScalarValue(allocator, environment, expected_ty, scalar),
        .message => |name| defaultMessageValue(allocator, environment, name, missing_field),
    };
}

fn defaultScalarValue(
    allocator: std.mem.Allocator,
    environment: ?*const env.Env,
    expected_ty: ?types.TypeRef,
    scalar: schema.ProtoScalarKind,
) std.mem.Allocator.Error!value.Value {
    return switch (scalar) {
        .bool => .{ .bool = false },
        .int32, .int64, .sint32, .sint64, .sfixed32, .sfixed64 => .{ .int = 0 },
        .enum_value => blk: {
            const maybe_enum_name = if (environment != null and expected_ty != null) switch (environment.?.types.spec(expected_ty.?)) {
                .enum_type => |name| name,
                else => null,
            } else null;
            if (maybe_enum_name) |enum_name| break :blk try value.enumValue(allocator, enum_name, 0);
            break :blk .{ .int = 0 };
        },
        .uint32, .uint64, .fixed32, .fixed64 => .{ .uint = 0 },
        .float, .double => .{ .double = 0 },
        .string => try value.string(allocator, ""),
        .bytes => try value.bytesValue(allocator, ""),
    };
}

fn cloneFieldDefaultValue(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    field_ty: types.TypeRef,
    default_value: schema.FieldDefault,
) std.mem.Allocator.Error!value.Value {
    return switch (default_value) {
        .bool => |v| .{ .bool = v },
        .int => |v| blk: {
            switch (environment.types.spec(field_ty)) {
                .enum_type => |enum_name| {
                    const raw_value: i32 = @intCast(v);
                    break :blk try value.enumValue(allocator, enum_name, raw_value);
                },
                else => break :blk .{ .int = v },
            }
        },
        .uint => |v| .{ .uint = v },
        .double => |v| .{ .double = v },
        .string => |text| try value.string(allocator, text),
        .bytes => |data| try value.bytesValue(allocator, data),
    };
}

fn defaultMessageValue(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    message_name: []const u8,
    missing_field: bool,
) (std.mem.Allocator.Error || value.RuntimeError)!value.Value {
    const desc = environment.lookupMessage(message_name) orelse return value.RuntimeError.NoSuchField;
    return switch (desc.kind) {
        .timestamp => .{ .timestamp = .{ .seconds = 0, .nanos = 0 } },
        .duration => .{ .duration = .{ .seconds = 0, .nanos = 0 } },
        .any, .value => .null,
        .list_value => .{ .list = .empty },
        .struct_value => .{ .map = .empty },
        else => if (schema.isWrapperKind(desc.kind) and missing_field)
            .null
        else if (schema.isWrapperKind(desc.kind))
            try defaultScalarValue(allocator, environment, null, schema.wrapperScalar(desc.kind).?)
        else
            emptyMessageValue(allocator, desc.name),
    };
}

fn emptyMessageValue(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!value.Value {
    return .{ .message = .{
        .name = try allocator.dupe(u8, name),
    } };
}

fn decodePlainMessage(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    desc: *const schema.MessageDecl,
    data: []const u8,
) DecodeError!value.Value {
    var out = value.DynamicMessage{
        .name = try allocator.dupe(u8, desc.name),
    };
    errdefer {
        allocator.free(out.name);
        for (out.fields.items) |*field| {
            allocator.free(field.name);
            field.value.deinit(allocator);
        }
        out.fields.deinit(allocator);
    }

    var cursor: usize = 0;
    while (cursor < data.len) {
        const key = try decodeVarint(data, &cursor);
        const field_number: u32 = @intCast(key >> 3);
        const wire_type = key & 0x7;
        const field = desc.lookupFieldNumber(field_number) orelse {
            try skipWireValue(data, &cursor, wire_type);
            continue;
        };
        try decodeFieldIntoMessage(allocator, environment, field, data, &cursor, wire_type, &out);
    }
    return .{ .message = out };
}

fn decodeFieldIntoMessage(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    field: *const schema.FieldDecl,
    data: []const u8,
    cursor: *usize,
    wire_type: u64,
    out: *value.DynamicMessage,
) DecodeError!void {
    switch (field.encoding) {
        .singular => |raw| {
            var decoded = try decodeProtoValue(allocator, environment, raw, data, cursor, wire_type);
            errdefer decoded.deinit(allocator);
            decoded = try adaptDecodedValueToType(allocator, environment, field.ty, decoded);
            if (findFieldIndex(out.fields.items, field.name)) |idx| {
                out.fields.items[idx].value.deinit(allocator);
                out.fields.items[idx].value = decoded;
                return;
            }
            try out.fields.append(allocator, .{
                .name = try allocator.dupe(u8, field.name),
                .value = decoded,
            });
        },
        .repeated => |repeated| {
            const idx = try ensureAggregateField(allocator, out, field.name, .list);
            var target = &out.fields.items[idx].value.list;
            const elem_ty = switch (environment.types.spec(field.ty)) {
                .list => |inner| inner,
                else => environment.types.builtins.dyn_type,
            };
            if (repeated.@"packed" and wire_type == 2) {
                const packed_bytes = try readLengthDelimited(data, cursor);
                var packed_cursor: usize = 0;
                while (packed_cursor < packed_bytes.len) {
                    var decoded = try decodeProtoValue(
                        allocator,
                        environment,
                        repeated.element,
                        packed_bytes,
                        &packed_cursor,
                        packedWireType(repeated.element),
                    );
                    errdefer decoded.deinit(allocator);
                    decoded = try adaptDecodedValueToType(allocator, environment, elem_ty, decoded);
                    try target.append(allocator, decoded);
                }
                return;
            }
            var decoded = try decodeProtoValue(allocator, environment, repeated.element, data, cursor, wire_type);
            errdefer decoded.deinit(allocator);
            decoded = try adaptDecodedValueToType(allocator, environment, elem_ty, decoded);
            try target.append(allocator, decoded);
        },
        .map => |map_decl| {
            const idx = try ensureAggregateField(allocator, out, field.name, .map);
            var target = &out.fields.items[idx].value.map;
            const entry_bytes = try readLengthDelimited(data, cursor);
            var entry = try decodeMapEntry(allocator, environment, field.ty, map_decl, entry_bytes);
            errdefer {
                entry.key.deinit(allocator);
                entry.value.deinit(allocator);
            }
            try target.append(allocator, entry);
        },
    }
}

const AggregateKind = enum { list, map };

fn ensureAggregateField(
    allocator: std.mem.Allocator,
    out: *value.DynamicMessage,
    name: []const u8,
    kind: AggregateKind,
) std.mem.Allocator.Error!usize {
    if (findFieldIndex(out.fields.items, name)) |idx| return idx;
    try out.fields.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .value = switch (kind) {
            .list => .{ .list = .empty },
            .map => .{ .map = .empty },
        },
    });
    return out.fields.items.len - 1;
}

fn decodeMapEntry(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    field_ty: types.TypeRef,
    map_decl: schema.MapDecl,
    data: []const u8,
) DecodeError!value.MapEntry {
    var cursor: usize = 0;
    var key: ?value.Value = null;
    var val: ?value.Value = null;
    const value_ty = switch (environment.types.spec(field_ty)) {
        .map => |pair| pair.value,
        else => environment.types.builtins.dyn_type,
    };
    errdefer {
        if (key) |*entry| entry.deinit(allocator);
        if (val) |*entry| entry.deinit(allocator);
    }

    while (cursor < data.len) {
        const key_raw = try decodeVarint(data, &cursor);
        const field_number = key_raw >> 3;
        const wire_type = key_raw & 0x7;
        switch (field_number) {
            1 => key = try decodeScalarValue(allocator, map_decl.key, data, &cursor, wire_type),
            2 => {
                var decoded = try decodeProtoValue(allocator, environment, map_decl.value, data, &cursor, wire_type);
                errdefer decoded.deinit(allocator);
                val = try adaptDecodedValueToType(allocator, environment, value_ty, decoded);
            },
            else => try skipWireValue(data, &cursor, wire_type),
        }
    }

    return .{
        .key = key orelse try defaultScalarValue(allocator, null, null, map_decl.key),
        .value = val orelse try defaultProtoValue(allocator, environment, value_ty, map_decl.value, false),
    };
}

fn adaptDecodedValueToType(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    expected_ty: types.TypeRef,
    decoded: value.Value,
) DecodeError!value.Value {
    switch (environment.types.spec(expected_ty)) {
        .enum_type => |enum_name| switch (decoded) {
            .int => |raw| {
                if (raw < std.math.minInt(i32) or raw > std.math.maxInt(i32)) return value.RuntimeError.Overflow;
                return value.enumValue(allocator, enum_name, @intCast(raw));
            },
            .enum_value => return decoded,
            else => return value.RuntimeError.TypeMismatch,
        },
        else => return decoded,
    }
}

fn decodeProtoValue(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    raw: schema.ProtoValueType,
    data: []const u8,
    cursor: *usize,
    wire_type: u64,
) DecodeError!value.Value {
    return switch (raw) {
        .scalar => |scalar| try decodeScalarValue(allocator, scalar, data, cursor, wire_type),
        .message => |name| blk: {
            const bytes = try readLengthDelimited(data, cursor);
            break :blk try decodeMessage(allocator, environment, name, bytes);
        },
    };
}

fn decodeScalarValue(
    allocator: std.mem.Allocator,
    scalar: schema.ProtoScalarKind,
    data: []const u8,
    cursor: *usize,
    wire_type: u64,
) DecodeError!value.Value {
    return switch (scalar) {
        .bool => blk: {
            if (wire_type != 0) return error.InvalidValue;
            break :blk .{ .bool = (try decodeVarint(data, cursor)) != 0 };
        },
        .int32 => blk: {
            if (wire_type != 0) return error.InvalidValue;
            const raw = try decodeVarint(data, cursor);
            break :blk .{ .int = @as(i32, @bitCast(@as(u32, @truncate(raw)))) };
        },
        .int64 => blk: {
            if (wire_type != 0) return error.InvalidValue;
            const raw = try decodeVarint(data, cursor);
            break :blk .{ .int = @bitCast(raw) };
        },
        .sint32 => blk: {
            if (wire_type != 0) return error.InvalidValue;
            break :blk .{ .int = zigZagDecode32(try decodeVarint(data, cursor)) };
        },
        .sint64 => blk: {
            if (wire_type != 0) return error.InvalidValue;
            break :blk .{ .int = zigZagDecode64(try decodeVarint(data, cursor)) };
        },
        .uint32 => blk: {
            if (wire_type != 0) return error.InvalidValue;
            break :blk .{ .uint = @truncate(try decodeVarint(data, cursor)) };
        },
        .uint64 => blk: {
            if (wire_type != 0) return error.InvalidValue;
            break :blk .{ .uint = try decodeVarint(data, cursor) };
        },
        .fixed32 => blk: {
            if (wire_type != 5) return error.InvalidValue;
            break :blk .{ .uint = try readFixed32(data, cursor) };
        },
        .fixed64 => blk: {
            if (wire_type != 1) return error.InvalidValue;
            break :blk .{ .uint = try readFixed64(data, cursor) };
        },
        .sfixed32 => blk: {
            if (wire_type != 5) return error.InvalidValue;
            break :blk .{ .int = @as(i32, @bitCast(try readFixed32(data, cursor))) };
        },
        .sfixed64 => blk: {
            if (wire_type != 1) return error.InvalidValue;
            break :blk .{ .int = @bitCast(try readFixed64(data, cursor)) };
        },
        .float => blk: {
            if (wire_type != 5) return error.InvalidValue;
            const bits = try readFixed32(data, cursor);
            break :blk .{ .double = @as(f64, @floatCast(@as(f32, @bitCast(bits)))) };
        },
        .double => blk: {
            if (wire_type != 1) return error.InvalidValue;
            const bits = try readFixed64(data, cursor);
            break :blk .{ .double = @bitCast(bits) };
        },
        .string => blk: {
            if (wire_type != 2) return error.InvalidValue;
            break :blk try value.string(allocator, try readLengthDelimited(data, cursor));
        },
        .bytes => blk: {
            if (wire_type != 2) return error.InvalidValue;
            break :blk try value.bytesValue(allocator, try readLengthDelimited(data, cursor));
        },
        .enum_value => blk: {
            if (wire_type != 0) return error.InvalidValue;
            break :blk .{ .int = @bitCast(try decodeVarint(data, cursor)) };
        },
    };
}

fn decodeTimestamp(data: []const u8) DecodeError!value.Value {
    const fields = try decodeSecondsNanos(data);
    return .{ .timestamp = cel_time.Timestamp.fromComponents(fields.seconds, fields.nanos) catch return value.RuntimeError.Overflow };
}

fn decodeDuration(data: []const u8) DecodeError!value.Value {
    const fields = try decodeSecondsNanos(data);
    return .{ .duration = cel_time.Duration.fromComponents(fields.seconds, fields.nanos) catch return value.RuntimeError.Overflow };
}

fn decodeWrapperMessage(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    kind: schema.MessageKind,
    data: []const u8,
) DecodeError!value.Value {
    const scalar = schema.wrapperScalar(kind) orelse return value.RuntimeError.TypeMismatch;
    var cursor: usize = 0;
    while (cursor < data.len) {
        const key = try decodeVarint(data, &cursor);
        const field_number = key >> 3;
        const wire_type = key & 0x7;
        if (field_number == 1) {
            return try decodeScalarValue(allocator, scalar, data, &cursor, wire_type);
        }
        try skipWireValue(data, &cursor, wire_type);
    }
    _ = environment;
    return defaultScalarValue(allocator, null, null, scalar);
}

fn decodeListValue(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    data: []const u8,
) DecodeError!value.Value {
    var out: std.ArrayListUnmanaged(value.Value) = .empty;
    errdefer {
        for (out.items) |*entry| entry.deinit(allocator);
        out.deinit(allocator);
    }
    var cursor: usize = 0;
    while (cursor < data.len) {
        const key = try decodeVarint(data, &cursor);
        const field_number = key >> 3;
        const wire_type = key & 0x7;
        if (field_number != 1) {
            try skipWireValue(data, &cursor, wire_type);
            continue;
        }
        const bytes = try readLengthDelimited(data, &cursor);
        try out.append(allocator, try decodeMessage(allocator, environment, "google.protobuf.Value", bytes));
    }
    return .{ .list = out };
}

fn decodeStruct(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    data: []const u8,
) DecodeError!value.Value {
    var out: std.ArrayListUnmanaged(value.MapEntry) = .empty;
    errdefer {
        for (out.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        out.deinit(allocator);
    }

    var cursor: usize = 0;
    while (cursor < data.len) {
        const key = try decodeVarint(data, &cursor);
        const field_number = key >> 3;
        const wire_type = key & 0x7;
        if (field_number != 1) {
            try skipWireValue(data, &cursor, wire_type);
            continue;
        }
        const entry_bytes = try readLengthDelimited(data, &cursor);
        var entry_cursor: usize = 0;
        var entry_key: ?value.Value = null;
        var entry_value: ?value.Value = null;
        errdefer {
            if (entry_key) |*k| k.deinit(allocator);
            if (entry_value) |*v| v.deinit(allocator);
        }
        while (entry_cursor < entry_bytes.len) {
            const entry_tag = try decodeVarint(entry_bytes, &entry_cursor);
            const entry_number = entry_tag >> 3;
            const entry_wire = entry_tag & 0x7;
            switch (entry_number) {
                1 => entry_key = try decodeScalarValue(allocator, .string, entry_bytes, &entry_cursor, entry_wire),
                2 => {
                    const nested = try readLengthDelimited(entry_bytes, &entry_cursor);
                    entry_value = try decodeMessage(allocator, environment, "google.protobuf.Value", nested);
                },
                else => try skipWireValue(entry_bytes, &entry_cursor, entry_wire),
            }
        }
        try out.append(allocator, .{
            .key = entry_key orelse try value.string(allocator, ""),
            .value = entry_value orelse .null,
        });
    }
    return .{ .map = out };
}

fn decodeValueMessage(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    data: []const u8,
) DecodeError!value.Value {
    var cursor: usize = 0;
    while (cursor < data.len) {
        const key = try decodeVarint(data, &cursor);
        const field_number = key >> 3;
        const wire_type = key & 0x7;
        switch (field_number) {
            1 => {
                _ = try decodeVarint(data, &cursor);
                return .null;
            },
            2 => return try decodeScalarValue(allocator, .double, data, &cursor, wire_type),
            3 => return try decodeScalarValue(allocator, .string, data, &cursor, wire_type),
            4 => return try decodeScalarValue(allocator, .bool, data, &cursor, wire_type),
            5 => {
                const bytes = try readLengthDelimited(data, &cursor);
                return try decodeMessage(allocator, environment, "google.protobuf.Struct", bytes);
            },
            6 => {
                const bytes = try readLengthDelimited(data, &cursor);
                return try decodeMessage(allocator, environment, "google.protobuf.ListValue", bytes);
            },
            else => try skipWireValue(data, &cursor, wire_type),
        }
    }
    return .null;
}

fn decodeAnyMessage(
    allocator: std.mem.Allocator,
    environment: *const env.Env,
    data: []const u8,
) DecodeError!value.Value {
    var cursor: usize = 0;
    var type_url: ?[]u8 = null;
    defer if (type_url) |url| allocator.free(url);
    var payload: ?[]u8 = null;
    defer if (payload) |bytes| allocator.free(bytes);

    while (cursor < data.len) {
        const key = try decodeVarint(data, &cursor);
        const field_number = key >> 3;
        const wire_type = key & 0x7;
        switch (field_number) {
            1 => {
                var url = try decodeScalarValue(allocator, .string, data, &cursor, wire_type);
                defer url.deinit(allocator);
                type_url = try allocator.dupe(u8, url.string);
            },
            2 => {
                const bytes = try readLengthDelimited(data, &cursor);
                payload = try allocator.dupe(u8, bytes);
            },
            else => try skipWireValue(data, &cursor, wire_type),
        }
    }

    const resolved = type_url orelse return rawAnyMessage(allocator, null, payload);
    const body = payload orelse return rawAnyMessage(allocator, type_url, null);
    const prefix = "type.googleapis.com/";
    if (!std.mem.startsWith(u8, resolved, prefix)) return rawAnyMessage(allocator, type_url, payload);
    return decodeMessage(allocator, environment, resolved[prefix.len..], body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return rawAnyMessage(allocator, type_url, payload),
    };
}

fn decodeSecondsNanos(data: []const u8) DecodeError!struct { seconds: i64, nanos: i32 } {
    var cursor: usize = 0;
    var seconds: i64 = 0;
    var nanos: i32 = 0;
    while (cursor < data.len) {
        const key = try decodeVarint(data, &cursor);
        const field_number = key >> 3;
        const wire_type = key & 0x7;
        switch (field_number) {
            1 => {
                if (wire_type != 0) return error.InvalidValue;
                seconds = @bitCast(try decodeVarint(data, &cursor));
            },
            2 => {
                if (wire_type != 0) return error.InvalidValue;
                const raw = try decodeVarint(data, &cursor);
                nanos = @bitCast(@as(u32, @truncate(raw)));
            },
            else => try skipWireValue(data, &cursor, wire_type),
        }
    }
    return .{ .seconds = seconds, .nanos = nanos };
}

fn packedWireType(raw: schema.ProtoValueType) u64 {
    return switch (raw) {
        .scalar => |scalar| switch (scalar) {
            .float, .fixed32, .sfixed32 => 5,
            .double, .fixed64, .sfixed64 => 1,
            else => 0,
        },
        .message => 2,
    };
}

fn readLengthDelimited(data: []const u8, cursor: *usize) ![]const u8 {
    const len = try decodeVarint(data, cursor);
    if (cursor.* + len > data.len) return error.InvalidValue;
    const slice = data[cursor.* .. cursor.* + len];
    cursor.* += len;
    return slice;
}

fn readFixed32(data: []const u8, cursor: *usize) !u32 {
    if (cursor.* + 4 > data.len) return error.InvalidValue;
    const result = std.mem.readInt(u32, data[cursor.*..][0..4], .little);
    cursor.* += 4;
    return result;
}

fn readFixed64(data: []const u8, cursor: *usize) !u64 {
    if (cursor.* + 8 > data.len) return error.InvalidValue;
    const result = std.mem.readInt(u64, data[cursor.*..][0..8], .little);
    cursor.* += 8;
    return result;
}

fn zigZagDecode32(raw: u64) i64 {
    const truncated: u32 = @truncate(raw);
    const shifted: i32 = @intCast(truncated >> 1);
    return shifted ^ -@as(i32, @intCast(truncated & 1));
}

fn zigZagDecode64(raw: u64) i64 {
    const shifted: i64 = @intCast(raw >> 1);
    return shifted ^ -@as(i64, @intCast(raw & 1));
}

pub fn decodeVarint(data: []const u8, cursor: *usize) !u64 {
    var shift: u6 = 0;
    var result: u64 = 0;
    while (cursor.* < data.len and shift < 64) : (shift += 7) {
        const byte = data[cursor.*];
        cursor.* += 1;
        result |= @as(u64, byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) return result;
    }
    return error.InvalidValue;
}

pub fn skipWireValue(data: []const u8, cursor: *usize, wire_type: u64) !void {
    switch (wire_type) {
        0 => _ = try decodeVarint(data, cursor),
        1 => {
            if (cursor.* + 8 > data.len) return error.InvalidValue;
            cursor.* += 8;
        },
        2 => {
            const len = try decodeVarint(data, cursor);
            if (cursor.* + len > data.len) return error.InvalidValue;
            cursor.* += len;
        },
        5 => {
            if (cursor.* + 4 > data.len) return error.InvalidValue;
            cursor.* += 4;
        },
        else => return error.InvalidValue,
    }
}

fn findFieldIndex(fields: []const value.MessageField, name: []const u8) ?usize {
    for (fields, 0..) |field, i| {
        if (std.mem.eql(u8, field.name, name)) return i;
    }
    return null;
}

fn isJsonSafeInteger(v: i64) bool {
    return v >= -9_007_199_254_740_991 and v <= 9_007_199_254_740_991;
}

test "wrapper field defaults differ from wrapper literals" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    _ = try environment.addMessage("example.Container");
    try environment.addProtobufField("example.Container", "wrapped", 1, environment.types.builtins.int_type, .{
        .singular = .{ .message = "google.protobuf.Int32Value" },
    });

    const container = environment.lookupMessage("example.Container").?;
    const field = container.lookupField("wrapped").?;

    var default_field = try defaultFieldValue(std.testing.allocator, &environment, field);
    defer default_field.deinit(std.testing.allocator);
    try std.testing.expect(default_field == .null);

    const msg = environment.lookupMessage("google.protobuf.Int32Value").?;
    var literal = try buildMessageLiteral(std.testing.allocator, &environment, msg, &.{});
    defer literal.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 0), literal.int);
}

test "plain message literal construction and field access" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const t = environment.types.builtins;

    _ = try environment.addMessage("test.Person");
    try environment.addMessageField("test.Person", "name", t.string_type);
    try environment.addMessageField("test.Person", "age", t.int_type);

    const desc = environment.lookupMessage("test.Person").?;
    const name_field = desc.lookupField("name").?;
    const age_field = desc.lookupField("age").?;

    var name_val = try value.string(std.testing.allocator, "Alice");
    defer name_val.deinit(std.testing.allocator);

    var result = try buildMessageLiteral(std.testing.allocator, &environment, desc, &.{
        .{ .field = name_field, .value = name_val },
        .{ .field = age_field, .value = .{ .int = 30 } },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result == .message);
    try std.testing.expectEqualStrings("test.Person", result.message.name);
    try std.testing.expectEqual(@as(usize, 2), result.message.fields.items.len);

    const idx_name = findFieldIndex(result.message.fields.items, "name").?;
    try std.testing.expectEqualStrings("Alice", result.message.fields.items[idx_name].value.string);

    const idx_age = findFieldIndex(result.message.fields.items, "age").?;
    try std.testing.expectEqual(@as(i64, 30), result.message.fields.items[idx_age].value.int);
}

test "plain message duplicate field is rejected" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const t = environment.types.builtins;

    _ = try environment.addMessage("test.Dup");
    try environment.addMessageField("test.Dup", "x", t.int_type);

    const desc = environment.lookupMessage("test.Dup").?;
    const x_field = desc.lookupField("x").?;

    try std.testing.expectError(value.RuntimeError.DuplicateMessageField, buildMessageLiteral(
        std.testing.allocator,
        &environment,
        desc,
        &.{
            .{ .field = x_field, .value = .{ .int = 1 } },
            .{ .field = x_field, .value = .{ .int = 2 } },
        },
    ));
}

test "timestamp and duration well-known type literals" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    // Timestamp literal from seconds/nanos
    const ts_desc = environment.lookupMessage("google.protobuf.Timestamp").?;
    const ts_sec = ts_desc.lookupField("seconds").?;
    const ts_ns = ts_desc.lookupField("nanos").?;
    var ts_val = try buildMessageLiteral(std.testing.allocator, &environment, ts_desc, &.{
        .{ .field = ts_sec, .value = .{ .int = 1_000_000 } },
        .{ .field = ts_ns, .value = .{ .int = 500 } },
    });
    defer ts_val.deinit(std.testing.allocator);
    try std.testing.expect(ts_val == .timestamp);
    try std.testing.expectEqual(@as(i64, 1_000_000), ts_val.timestamp.seconds);
    try std.testing.expectEqual(@as(u32, 500), ts_val.timestamp.nanos);

    // Duration literal from seconds/nanos
    const dur_desc = environment.lookupMessage("google.protobuf.Duration").?;
    const dur_sec = dur_desc.lookupField("seconds").?;
    const dur_ns = dur_desc.lookupField("nanos").?;
    var dur_val = try buildMessageLiteral(std.testing.allocator, &environment, dur_desc, &.{
        .{ .field = dur_sec, .value = .{ .int = 60 } },
        .{ .field = dur_ns, .value = .{ .int = 0 } },
    });
    defer dur_val.deinit(std.testing.allocator);
    try std.testing.expect(dur_val == .duration);
    try std.testing.expectEqual(@as(i64, 60), dur_val.duration.seconds);
    try std.testing.expectEqual(@as(i32, 0), dur_val.duration.nanos);
}

test "wrapper type literals for all well-known wrapper types" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    // Int32Value with a value
    const int32_desc = environment.lookupMessage("google.protobuf.Int32Value").?;
    const int32_field = int32_desc.lookupField("value").?;
    var int32_val = try buildMessageLiteral(std.testing.allocator, &environment, int32_desc, &.{
        .{ .field = int32_field, .value = .{ .int = 42 } },
    });
    defer int32_val.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 42), int32_val.int);

    // Int64Value
    const int64_desc = environment.lookupMessage("google.protobuf.Int64Value").?;
    const int64_field = int64_desc.lookupField("value").?;
    var int64_val = try buildMessageLiteral(std.testing.allocator, &environment, int64_desc, &.{
        .{ .field = int64_field, .value = .{ .int = 9999 } },
    });
    defer int64_val.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 9999), int64_val.int);

    // BoolValue
    const bool_desc = environment.lookupMessage("google.protobuf.BoolValue").?;
    const bool_field = bool_desc.lookupField("value").?;
    var bool_val = try buildMessageLiteral(std.testing.allocator, &environment, bool_desc, &.{
        .{ .field = bool_field, .value = .{ .bool = true } },
    });
    defer bool_val.deinit(std.testing.allocator);
    try std.testing.expectEqual(true, bool_val.bool);

    // StringValue
    const str_desc = environment.lookupMessage("google.protobuf.StringValue").?;
    const str_field = str_desc.lookupField("value").?;
    var str_input = try value.string(std.testing.allocator, "hello");
    defer str_input.deinit(std.testing.allocator);
    var str_val = try buildMessageLiteral(std.testing.allocator, &environment, str_desc, &.{
        .{ .field = str_field, .value = str_input },
    });
    defer str_val.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", str_val.string);

    // DoubleValue
    const dbl_desc = environment.lookupMessage("google.protobuf.DoubleValue").?;
    const dbl_field = dbl_desc.lookupField("value").?;
    var dbl_val = try buildMessageLiteral(std.testing.allocator, &environment, dbl_desc, &.{
        .{ .field = dbl_field, .value = .{ .double = 3.14 } },
    });
    defer dbl_val.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 3.14), dbl_val.double);

    // UInt64Value
    const uint64_desc = environment.lookupMessage("google.protobuf.UInt64Value").?;
    const uint64_field = uint64_desc.lookupField("value").?;
    var uint64_val = try buildMessageLiteral(std.testing.allocator, &environment, uint64_desc, &.{
        .{ .field = uint64_field, .value = .{ .uint = 123 } },
    });
    defer uint64_val.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 123), uint64_val.uint);
}

test "wrapper type empty literal returns default scalar" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const cases = [_]struct { name: []const u8, tag: std.meta.Tag(value.Value) }{
        .{ .name = "google.protobuf.BoolValue", .tag = .bool },
        .{ .name = "google.protobuf.Int32Value", .tag = .int },
        .{ .name = "google.protobuf.Int64Value", .tag = .int },
        .{ .name = "google.protobuf.UInt32Value", .tag = .uint },
        .{ .name = "google.protobuf.UInt64Value", .tag = .uint },
        .{ .name = "google.protobuf.DoubleValue", .tag = .double },
        .{ .name = "google.protobuf.FloatValue", .tag = .double },
        .{ .name = "google.protobuf.StringValue", .tag = .string },
        .{ .name = "google.protobuf.BytesValue", .tag = .bytes },
    };
    for (cases) |case| {
        const desc = environment.lookupMessage(case.name).?;
        var result = try buildMessageLiteral(std.testing.allocator, &environment, desc, &.{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.tag, std.meta.activeTag(result));
    }
}

test "default field values for scalar proto fields" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const t = environment.types.builtins;

    _ = try environment.addMessage("test.Defaults");
    try environment.addProtobufField("test.Defaults", "b", 1, t.bool_type, .{ .singular = .{ .scalar = .bool } });
    try environment.addProtobufField("test.Defaults", "i", 2, t.int_type, .{ .singular = .{ .scalar = .int64 } });
    try environment.addProtobufField("test.Defaults", "u", 3, t.uint_type, .{ .singular = .{ .scalar = .uint64 } });
    try environment.addProtobufField("test.Defaults", "d", 4, t.double_type, .{ .singular = .{ .scalar = .double } });
    try environment.addProtobufField("test.Defaults", "s", 5, t.string_type, .{ .singular = .{ .scalar = .string } });
    try environment.addProtobufField("test.Defaults", "by", 6, t.bytes_type, .{ .singular = .{ .scalar = .bytes } });

    const desc = environment.lookupMessage("test.Defaults").?;
    const fields = [_]struct { name: []const u8, tag: std.meta.Tag(value.Value) }{
        .{ .name = "b", .tag = .bool },
        .{ .name = "i", .tag = .int },
        .{ .name = "u", .tag = .uint },
        .{ .name = "d", .tag = .double },
        .{ .name = "s", .tag = .string },
        .{ .name = "by", .tag = .bytes },
    };
    for (fields) |f| {
        const field = desc.lookupField(f.name).?;
        var result = try defaultFieldValue(std.testing.allocator, &environment, field);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(f.tag, std.meta.activeTag(result));
    }
}

test "repeated field default is empty list" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const t = environment.types.builtins;
    const list_ty = try environment.types.listOf(t.int_type);

    _ = try environment.addMessage("test.Rep");
    try environment.addProtobufField("test.Rep", "items", 1, list_ty, .{
        .repeated = .{ .element = .{ .scalar = .int64 } },
    });

    const desc = environment.lookupMessage("test.Rep").?;
    const field = desc.lookupField("items").?;
    var result = try defaultFieldValue(std.testing.allocator, &environment, field);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .list);
    try std.testing.expectEqual(@as(usize, 0), result.list.items.len);
}

test "map field default is empty map" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const t = environment.types.builtins;
    const map_ty = try environment.types.mapOf(t.string_type, t.int_type);

    _ = try environment.addMessage("test.MapMsg");
    try environment.addProtobufField("test.MapMsg", "labels", 1, map_ty, .{
        .map = .{ .key = .string, .value = .{ .scalar = .int64 } },
    });

    const desc = environment.lookupMessage("test.MapMsg").?;
    const field = desc.lookupField("labels").?;
    var result = try defaultFieldValue(std.testing.allocator, &environment, field);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .map);
    try std.testing.expectEqual(@as(usize, 0), result.map.items.len);
}

test "coerce field value for scalar types" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const t = environment.types.builtins;

    _ = try environment.addMessage("test.Coerce");
    try environment.addProtobufField("test.Coerce", "flag", 1, t.bool_type, .{ .singular = .{ .scalar = .bool } });
    try environment.addProtobufField("test.Coerce", "count", 2, t.int_type, .{ .singular = .{ .scalar = .int64 } });
    try environment.addProtobufField("test.Coerce", "name", 3, t.string_type, .{ .singular = .{ .scalar = .string } });

    const desc = environment.lookupMessage("test.Coerce").?;

    // Bool coercion
    const flag_field = desc.lookupField("flag").?;
    var flag_result = (try coerceFieldValue(std.testing.allocator, &environment, flag_field, .{ .bool = true })).?;
    defer flag_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(true, flag_result.bool);

    // Int coercion
    const count_field = desc.lookupField("count").?;
    var count_result = (try coerceFieldValue(std.testing.allocator, &environment, count_field, .{ .int = 99 })).?;
    defer count_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 99), count_result.int);

    // String coercion
    const name_field = desc.lookupField("name").?;
    var name_input = try value.string(std.testing.allocator, "hello");
    defer name_input.deinit(std.testing.allocator);
    var name_result = (try coerceFieldValue(std.testing.allocator, &environment, name_field, name_input)).?;
    defer name_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", name_result.string);
}

test "coerce field value rejects type mismatch" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const t = environment.types.builtins;

    _ = try environment.addMessage("test.Mismatch");
    try environment.addProtobufField("test.Mismatch", "flag", 1, t.bool_type, .{ .singular = .{ .scalar = .bool } });

    const desc = environment.lookupMessage("test.Mismatch").?;
    const field = desc.lookupField("flag").?;

    // Passing int where bool is expected
    try std.testing.expectError(value.RuntimeError.TypeMismatch, coerceFieldValue(
        std.testing.allocator,
        &environment,
        field,
        .{ .int = 1 },
    ));
}

test "enum field default and coercion" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const enum_ty = try environment.addEnum("test.Status");
    try environment.addEnumValue("test.Status", "UNKNOWN", 0);
    try environment.addEnumValue("test.Status", "ACTIVE", 1);

    _ = try environment.addMessage("test.WithEnum");
    try environment.addProtobufField("test.WithEnum", "status", 1, enum_ty, .{
        .singular = .{ .scalar = .enum_value },
    });

    const desc = environment.lookupMessage("test.WithEnum").?;
    const field = desc.lookupField("status").?;

    // Default is enum with value 0
    var default_val = try defaultFieldValue(std.testing.allocator, &environment, field);
    defer default_val.deinit(std.testing.allocator);
    try std.testing.expect(default_val == .enum_value);
    try std.testing.expectEqual(@as(i32, 0), default_val.enum_value.value);

    // Coerce valid enum value
    var enum_input = try value.enumValue(std.testing.allocator, "test.Status", 1);
    defer enum_input.deinit(std.testing.allocator);
    var coerced = (try coerceFieldValue(std.testing.allocator, &environment, field, enum_input)).?;
    defer coerced.deinit(std.testing.allocator);
    try std.testing.expect(coerced == .enum_value);
    try std.testing.expectEqual(@as(i32, 1), coerced.enum_value.value);
}

test "protobuf message field access via CEL eval" {
    const compile_mod = @import("../compiler/compile.zig");
    const eval_impl = @import("../eval/eval.zig");
    const env_mod = @import("../env/env.zig");
    const Activation = @import("../eval/activation.zig").Activation;

    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const t = environment.types.builtins;

    const msg_ty = try environment.addMessage("test.Item");
    try environment.addMessageField("test.Item", "name", t.string_type);
    try environment.addMessageField("test.Item", "count", t.int_type);
    try environment.addVarTyped("item", msg_ty);

    // Build a message value for the activation
    const desc = environment.lookupMessage("test.Item").?;
    const name_field = desc.lookupField("name").?;
    const count_field = desc.lookupField("count").?;
    var name_val = try value.string(std.testing.allocator, "widget");
    defer name_val.deinit(std.testing.allocator);
    var msg_val = try buildMessageLiteral(std.testing.allocator, &environment, desc, &.{
        .{ .field = name_field, .value = name_val },
        .{ .field = count_field, .value = .{ .int = 5 } },
    });
    defer msg_val.deinit(std.testing.allocator);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.put("item", msg_val);

    // Access string field
    {
        var program = try compile_mod.compile(std.testing.allocator, &environment, "item.name");
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("widget", result.string);
    }

    // Access int field
    {
        var program = try compile_mod.compile(std.testing.allocator, &environment, "item.count");
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(i64, 5), result.int);
    }

    // has() on present field
    {
        var program = try compile_mod.compile(std.testing.allocator, &environment, "has(item.name)");
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(true, result.bool);
    }
}

test "has() on missing message field returns false" {
    const compile_mod = @import("../compiler/compile.zig");
    const eval_impl = @import("../eval/eval.zig");
    const env_mod = @import("../env/env.zig");
    const Activation = @import("../eval/activation.zig").Activation;

    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const t = environment.types.builtins;

    const msg_ty = try environment.addMessage("test.Sparse");
    try environment.addMessageField("test.Sparse", "present", t.string_type);
    try environment.addMessageField("test.Sparse", "absent", t.string_type);
    try environment.addVarTyped("obj", msg_ty);

    // Build a message with only "present" set
    const desc = environment.lookupMessage("test.Sparse").?;
    const present_field = desc.lookupField("present").?;
    var present_val = try value.string(std.testing.allocator, "yes");
    defer present_val.deinit(std.testing.allocator);
    var msg_val = try buildMessageLiteral(std.testing.allocator, &environment, desc, &.{
        .{ .field = present_field, .value = present_val },
    });
    defer msg_val.deinit(std.testing.allocator);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.put("obj", msg_val);

    // has() on present field should be true
    {
        var program = try compile_mod.compile(std.testing.allocator, &environment, "has(obj.present)");
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(true, result.bool);
    }

    // has() on absent field should be false
    {
        var program = try compile_mod.compile(std.testing.allocator, &environment, "has(obj.absent)");
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(false, result.bool);
    }
}

test "protobuf decode plain message roundtrip" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const t = environment.types.builtins;

    _ = try environment.addMessage("test.Simple");
    try environment.addProtobufField("test.Simple", "id", 1, t.int_type, .{ .singular = .{ .scalar = .int64 } });
    try environment.addProtobufField("test.Simple", "active", 2, t.bool_type, .{ .singular = .{ .scalar = .bool } });

    // Encode: field 1 (int64, wire type 0) = 42, field 2 (bool, wire type 0) = 1
    // field 1: key = (1 << 3) | 0 = 0x08, value = 42 (varint)
    // field 2: key = (2 << 3) | 0 = 0x10, value = 1 (varint)
    const data = &[_]u8{ 0x08, 42, 0x10, 1 };
    var result = try decodeMessage(std.testing.allocator, &environment, "test.Simple", data);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result == .message);
    const id_idx = findFieldIndex(result.message.fields.items, "id").?;
    try std.testing.expectEqual(@as(i64, 42), result.message.fields.items[id_idx].value.int);
    const active_idx = findFieldIndex(result.message.fields.items, "active").?;
    try std.testing.expectEqual(true, result.message.fields.items[active_idx].value.bool);
}

test "protobuf decode timestamp and duration" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    // Timestamp with seconds=100, nanos=0
    // field 1 (seconds, int64, wire 0): key=0x08, value=100
    const ts_data = &[_]u8{ 0x08, 100 };
    var ts_result = try decodeMessage(std.testing.allocator, &environment, "google.protobuf.Timestamp", ts_data);
    defer ts_result.deinit(std.testing.allocator);
    try std.testing.expect(ts_result == .timestamp);
    try std.testing.expectEqual(@as(i64, 100), ts_result.timestamp.seconds);

    // Duration with seconds=60
    const dur_data = &[_]u8{ 0x08, 60 };
    var dur_result = try decodeMessage(std.testing.allocator, &environment, "google.protobuf.Duration", dur_data);
    defer dur_result.deinit(std.testing.allocator);
    try std.testing.expect(dur_result == .duration);
    try std.testing.expectEqual(@as(i64, 60), dur_result.duration.seconds);
}

test "protobuf decode unknown message name" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    try std.testing.expectError(value.RuntimeError.NoSuchField, decodeMessage(
        std.testing.allocator,
        &environment,
        "nonexistent.Message",
        &.{},
    ));
}
