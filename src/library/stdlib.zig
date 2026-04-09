const std = @import("std");
const cel_env = @import("../env/env.zig");
const cel_regex = @import("cel_regex.zig");
const cel_time = @import("cel_time.zig");
const types = @import("../env/types.zig");
const value = @import("../env/value.zig");

pub const standard_library = cel_env.Library{
    .name = "cel.lib.std",
    .install = installStandardLibrary,
};

pub fn installStandardLibrary(environment: *cel_env.Env) !void {
    const optional_param = try environment.types.typeParamOf("optional_T");
    const optional_type = try environment.types.optionalOf(optional_param);

    _ = try environment.addConst(
        "optional_type",
        environment.types.builtins.type_type,
        try value.typeNameValue(environment.allocator, "optional_type"),
    );

    _ = try environment.addFunction("optional.none", false, &.{}, optional_type, evalOptionalNone);
    _ = try environment.addFunction("optional.of", false, &.{optional_param}, optional_type, evalOptionalOf);
    _ = try environment.addFunction("optional.ofNonZeroValue", false, &.{optional_param}, optional_type, evalOptionalOfNonZeroValue);
    _ = try environment.addFunction("hasValue", true, &.{optional_type}, environment.types.builtins.bool_type, evalOptionalHasValue);
    _ = try environment.addFunction("value", true, &.{optional_type}, optional_param, evalOptionalValue);
    _ = try environment.addFunction("or", true, &.{ optional_type, optional_type }, optional_type, evalOptionalOr);
    _ = try environment.addFunction("orValue", true, &.{ optional_type, optional_param }, optional_param, evalOptionalOrValue);

    _ = try environment.addDynamicFunction("size", false, matchSize, evalSize);
    _ = try environment.addDynamicFunction("size", true, matchSize, evalSize);
    _ = try environment.addDynamicFunction("startsWith", true, matchStringBinaryReceiver, evalStartsWith);
    _ = try environment.addDynamicFunction("endsWith", true, matchStringBinaryReceiver, evalEndsWith);
    _ = try environment.addDynamicFunction("contains", true, matchStringBinaryReceiver, evalContains);
    _ = try environment.addDynamicFunction("matches", true, matchStringBinaryReceiver, evalMatches);

    _ = try environment.addDynamicFunction("base64.encode", false, matchBase64Encode, evalBase64Encode);
    _ = try environment.addDynamicFunction("base64.decode", false, matchBase64Decode, evalBase64Decode);

    _ = try environment.addDynamicFunction("type", false, matchAnyUnaryType, evalType);
    _ = try environment.addDynamicFunction("dyn", false, matchAnyUnaryDyn, evalDyn);

    _ = try environment.addDynamicFunction("duration", false, matchDurationConversion, evalDuration);
    _ = try environment.addDynamicFunction("timestamp", false, matchTimestampConversion, evalTimestamp);
    _ = try environment.addDynamicFunction("string", false, matchStringConversion, evalString);
    _ = try environment.addDynamicFunction("int", false, matchIntConversion, evalInt);
    _ = try environment.addDynamicFunction("uint", false, matchUintConversion, evalUint);
    _ = try environment.addDynamicFunction("double", false, matchDoubleConversion, evalDouble);
    _ = try environment.addDynamicFunction("bool", false, matchBoolConversion, evalBool);
    _ = try environment.addDynamicFunction("bytes", false, matchBytesConversion, evalBytes);

    _ = try environment.addDynamicFunction("getDate", true, matchTimestampAccessor, evalTimestampGetDate);
    _ = try environment.addDynamicFunction("getDayOfMonth", true, matchTimestampAccessor, evalTimestampGetDayOfMonth);
    _ = try environment.addDynamicFunction("getDayOfWeek", true, matchTimestampAccessor, evalTimestampGetDayOfWeek);
    _ = try environment.addDynamicFunction("getDayOfYear", true, matchTimestampAccessor, evalTimestampGetDayOfYear);
    _ = try environment.addDynamicFunction("getFullYear", true, matchTimestampAccessor, evalTimestampGetFullYear);
    _ = try environment.addDynamicFunction("getHours", true, matchTimeAccessor, evalGetHours);
    _ = try environment.addDynamicFunction("getMilliseconds", true, matchTimeAccessor, evalGetMilliseconds);
    _ = try environment.addDynamicFunction("getMinutes", true, matchTimeAccessor, evalGetMinutes);
    _ = try environment.addDynamicFunction("getMonth", true, matchTimestampAccessor, evalTimestampGetMonth);
    _ = try environment.addDynamicFunction("getSeconds", true, matchTimeAccessor, evalGetSeconds);
}

fn evalOptionalNone(_: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 0) return value.RuntimeError.TypeMismatch;
    return value.optionalNone();
}

fn evalOptionalOf(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return value.optionalSome(allocator, try args[0].clone(allocator));
}

fn evalOptionalOfNonZeroValue(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    if (isZeroValue(args[0])) return value.optionalNone();
    return value.optionalSome(allocator, try args[0].clone(allocator));
}

fn evalOptionalHasValue(_: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .optional) return value.RuntimeError.TypeMismatch;
    return .{ .bool = args[0].optional.value != null };
}

fn evalOptionalValue(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .optional) return value.RuntimeError.TypeMismatch;
    const inner = args[0].optional.value orelse return value.RuntimeError.NoSuchField;
    return inner.*.clone(allocator);
}

fn evalOptionalOr(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 2 or args[0] != .optional or args[1] != .optional) return value.RuntimeError.TypeMismatch;
    if (args[0].optional.value != null) return args[0].clone(allocator);
    return args[1].clone(allocator);
}

fn evalOptionalOrValue(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 2 or args[0] != .optional) return value.RuntimeError.TypeMismatch;
    if (args[0].optional.value) |inner| return inner.*.clone(allocator);
    return args[1].clone(allocator);
}

fn matchSize(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 1) return null;
    return switch (environment.types.spec(params[0])) {
        .string, .bytes, .list, .map, .dyn => environment.types.builtins.int_type,
        else => null,
    };
}

fn matchStringBinaryReceiver(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 2) return null;
    const t = environment.types.builtins;
    if (!isTypeOrDyn(environment, params[0], t.string_type)) return null;
    if (!isTypeOrDyn(environment, params[1], t.string_type)) return null;
    return t.bool_type;
}

fn matchBase64Encode(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    const t = environment.types.builtins;
    if (params.len != 1) return null;
    if (!isTypeOrDyn(environment, params[0], t.bytes_type)) return null;
    return t.string_type;
}

fn matchBase64Decode(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    const t = environment.types.builtins;
    if (params.len != 1) return null;
    if (!isTypeOrDyn(environment, params[0], t.string_type)) return null;
    return t.bytes_type;
}

fn matchAnyUnaryType(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 1) return null;
    return environment.types.builtins.type_type;
}

fn matchAnyUnaryDyn(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 1) return null;
    return environment.types.builtins.dyn_type;
}

fn matchDurationConversion(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    const t = environment.types.builtins;
    if (params.len != 1) return null;
    if (params[0] == t.duration_type or params[0] == t.string_type or environment.types.spec(params[0]) == .dyn) {
        return t.duration_type;
    }
    return null;
}

fn matchTimestampConversion(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    const t = environment.types.builtins;
    if (params.len != 1) return null;
    if (params[0] == t.timestamp_type or params[0] == t.int_type or params[0] == t.string_type or environment.types.spec(params[0]) == .dyn) {
        return t.timestamp_type;
    }
    return null;
}

fn matchStringConversion(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    const t = environment.types.builtins;
    if (params.len != 1) return null;
    if (params[0] == t.string_type or
        params[0] == t.bool_type or
        params[0] == t.int_type or
        params[0] == t.uint_type or
        params[0] == t.double_type or
        params[0] == t.bytes_type or
        params[0] == t.timestamp_type or
        params[0] == t.duration_type or
        environment.types.spec(params[0]) == .dyn)
    {
        return t.string_type;
    }
    return null;
}

fn matchIntConversion(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    const t = environment.types.builtins;
    if (params.len != 1) return null;
    if (params[0] == t.int_type or
        params[0] == t.uint_type or
        params[0] == t.double_type or
        params[0] == t.string_type or
        params[0] == t.timestamp_type or
        environment.types.isEnumType(params[0]) or
        environment.types.spec(params[0]) == .dyn)
    {
        return t.int_type;
    }
    return null;
}

fn matchUintConversion(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    const t = environment.types.builtins;
    if (params.len != 1) return null;
    if (params[0] == t.uint_type or
        params[0] == t.int_type or
        params[0] == t.double_type or
        params[0] == t.string_type or
        environment.types.spec(params[0]) == .dyn)
    {
        return t.uint_type;
    }
    return null;
}

fn matchDoubleConversion(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    const t = environment.types.builtins;
    if (params.len != 1) return null;
    if (params[0] == t.double_type or
        params[0] == t.int_type or
        params[0] == t.uint_type or
        params[0] == t.string_type or
        environment.types.spec(params[0]) == .dyn)
    {
        return t.double_type;
    }
    return null;
}

fn matchBoolConversion(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    const t = environment.types.builtins;
    if (params.len != 1) return null;
    if (params[0] == t.bool_type or params[0] == t.string_type or environment.types.spec(params[0]) == .dyn) {
        return t.bool_type;
    }
    return null;
}

fn matchBytesConversion(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    const t = environment.types.builtins;
    if (params.len != 1) return null;
    if (params[0] == t.bytes_type or params[0] == t.string_type or environment.types.spec(params[0]) == .dyn) {
        return t.bytes_type;
    }
    return null;
}

fn matchTimestampAccessor(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    const t = environment.types.builtins;
    if (params.len == 1) {
        if (params[0] == t.timestamp_type or environment.types.spec(params[0]) == .dyn) return t.int_type;
        return null;
    }
    if (params.len == 2) {
        if ((params[0] == t.timestamp_type or environment.types.spec(params[0]) == .dyn) and
            isTypeOrDyn(environment, params[1], t.string_type)) return t.int_type;
    }
    return null;
}

fn matchTimeAccessor(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    const t = environment.types.builtins;
    if (params.len == 1) {
        if (params[0] == t.timestamp_type or params[0] == t.duration_type or environment.types.spec(params[0]) == .dyn) return t.int_type;
        return null;
    }
    if (params.len == 2) {
        if ((params[0] == t.timestamp_type or environment.types.spec(params[0]) == .dyn) and
            isTypeOrDyn(environment, params[1], t.string_type)) return t.int_type;
    }
    return null;
}

fn isTypeOrDyn(environment: *const cel_env.Env, actual: types.TypeRef, expected: types.TypeRef) bool {
    return actual == expected or environment.types.spec(actual) == .dyn;
}

fn isZeroValue(val: value.Value) bool {
    return switch (val) {
        .int => |v| v == 0,
        .uint => |v| v == 0,
        .double => |v| v == 0,
        .bool => |v| !v,
        .string => |text| text.len == 0,
        .bytes => |data| data.len == 0,
        .timestamp => |ts| ts.seconds == 0 and ts.nanos == 0,
        .duration => |d| d.seconds == 0 and d.nanos == 0,
        .enum_value => |enum_value| enum_value.value == 0,
        .null => true,
        .unknown => false,
        .optional => |optional| if (optional.value) |inner| isZeroValue(inner.*) else true,
        .type_name => |name| name.len == 0,
        .list => |items| items.items.len == 0,
        .map => |entries| entries.items.len == 0,
        .message => |msg| blk: {
            for (msg.fields.items) |field| {
                if (!isZeroValue(field.value)) break :blk false;
            }
            break :blk true;
        },
        .host => false,
    };
}

fn evalSize(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return switch (args[0]) {
        .string => .{ .int = @intCast(std.unicode.utf8CountCodepoints(args[0].string) catch return value.RuntimeError.TypeMismatch) },
        .bytes => .{ .int = @intCast(args[0].bytes.len) },
        .list => .{ .int = @intCast(args[0].list.items.len) },
        .map => .{ .int = @intCast(args[0].map.items.len) },
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalStartsWith(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 2 or args[0] != .string or args[1] != .string) return value.RuntimeError.TypeMismatch;
    return .{ .bool = std.mem.startsWith(u8, args[0].string, args[1].string) };
}

fn evalEndsWith(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 2 or args[0] != .string or args[1] != .string) return value.RuntimeError.TypeMismatch;
    return .{ .bool = std.mem.endsWith(u8, args[0].string, args[1].string) };
}

fn evalContains(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 2 or args[0] != .string or args[1] != .string) return value.RuntimeError.TypeMismatch;
    return .{ .bool = std.mem.indexOf(u8, args[0].string, args[1].string) != null };
}

fn evalMatches(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 2 or args[0] != .string or args[1] != .string) return value.RuntimeError.TypeMismatch;
    return .{ .bool = cel_regex.matches(allocator, args[0].string, args[1].string) catch |err| switch (err) {
        error.InvalidPattern => return value.RuntimeError.TypeMismatch,
        error.OutOfMemory => return error.OutOfMemory,
    } };
}

fn evalBase64Encode(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .bytes) return value.RuntimeError.TypeMismatch;
    const encoded_len = std.base64.standard.Encoder.calcSize(args[0].bytes.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, args[0].bytes);
    return .{ .string = encoded };
}

fn evalBase64Decode(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    const text = args[0].string;
    const remainder = text.len % 4;
    const padded = if (remainder == 0)
        try allocator.dupe(u8, text)
    else blk: {
        const needed = text.len + (4 - remainder);
        const buffer = try allocator.alloc(u8, needed);
        @memcpy(buffer[0..text.len], text);
        @memset(buffer[text.len..needed], '=');
        break :blk buffer;
    };
    defer allocator.free(padded);

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(padded) catch return value.RuntimeError.TypeMismatch;
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, padded) catch return value.RuntimeError.TypeMismatch;
    return .{ .bytes = decoded };
}

fn evalType(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return value.typeNameValue(allocator, args[0].typeName());
}

fn evalDyn(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return args[0].clone(allocator);
}

fn evalDuration(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return switch (args[0]) {
        .duration => args[0].clone(allocator),
        .string => .{ .duration = cel_time.parseDuration(args[0].string) catch return value.RuntimeError.TypeMismatch },
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalTimestamp(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return switch (args[0]) {
        .timestamp => args[0].clone(allocator),
        .int => .{ .timestamp = .{ .seconds = args[0].int, .nanos = 0 } },
        .string => .{ .timestamp = cel_time.parseTimestamp(args[0].string) catch return value.RuntimeError.TypeMismatch },
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalString(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return switch (args[0]) {
        .string => args[0].clone(allocator),
        .bool => if (args[0].bool) value.string(allocator, "true") else value.string(allocator, "false"),
        .int => .{ .string = try std.fmt.allocPrint(allocator, "{d}", .{args[0].int}) },
        .uint => .{ .string = try std.fmt.allocPrint(allocator, "{d}", .{args[0].uint}) },
        .double => .{ .string = try std.fmt.allocPrint(allocator, "{d}", .{args[0].double}) },
        .timestamp => .{ .string = try cel_time.formatTimestamp(allocator, args[0].timestamp) },
        .duration => .{ .string = try cel_time.formatDuration(allocator, args[0].duration) },
        .bytes => blk: {
            if (!std.unicode.utf8ValidateSlice(args[0].bytes)) return value.RuntimeError.TypeMismatch;
            break :blk value.string(allocator, args[0].bytes);
        },
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalInt(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return switch (args[0]) {
        .int => args[0],
        .enum_value => |enum_value| .{ .int = enum_value.value },
        .uint => .{ .int = std.math.cast(i64, args[0].uint) orelse return value.RuntimeError.Overflow },
        .double => blk: {
            const truncated = @trunc(args[0].double);
            if (!std.math.isFinite(truncated) or truncated <= -0x1p63 or truncated >= 0x1p63) {
                return value.RuntimeError.Overflow;
            }
            break :blk .{ .int = @as(i64, @intFromFloat(truncated)) };
        },
        .string => .{ .int = std.fmt.parseInt(i64, args[0].string, 10) catch |err| switch (err) {
            error.Overflow => return value.RuntimeError.Overflow,
            else => return value.RuntimeError.TypeMismatch,
        } },
        .timestamp => .{ .int = args[0].timestamp.seconds },
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalUint(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return switch (args[0]) {
        .uint => args[0],
        .int => blk: {
            if (args[0].int < 0) return value.RuntimeError.Overflow;
            break :blk .{ .uint = @intCast(args[0].int) };
        },
        .double => blk: {
            const truncated = @trunc(args[0].double);
            if (!std.math.isFinite(truncated) or truncated < 0 or truncated >= 0x1p64) return value.RuntimeError.Overflow;
            break :blk .{ .uint = @as(u64, @intFromFloat(truncated)) };
        },
        .string => .{ .uint = std.fmt.parseInt(u64, args[0].string, 10) catch |err| switch (err) {
            error.Overflow => return value.RuntimeError.Overflow,
            else => return value.RuntimeError.TypeMismatch,
        } },
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalDouble(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return switch (args[0]) {
        .double => args[0],
        .int => .{ .double = @floatFromInt(args[0].int) },
        .uint => .{ .double = @floatFromInt(args[0].uint) },
        .string => .{ .double = std.fmt.parseFloat(f64, args[0].string) catch return value.RuntimeError.TypeMismatch },
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalBool(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return switch (args[0]) {
        .bool => args[0],
        .string => blk: {
            if (isAcceptedTrueString(args[0].string)) break :blk value.Value{ .bool = true };
            if (isAcceptedFalseString(args[0].string)) break :blk value.Value{ .bool = false };
            return value.RuntimeError.TypeMismatch;
        },
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalBytes(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return switch (args[0]) {
        .bytes => args[0].clone(allocator),
        .string => value.bytesValue(allocator, args[0].string),
        else => value.RuntimeError.TypeMismatch,
    };
}

const TimestampField = enum {
    date,
    day_of_month,
    day_of_week,
    day_of_year,
    full_year,
    hours,
    milliseconds,
    minutes,
    month,
    seconds,
};

fn evalTimestampGetDate(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    return evalTimestampAccessor(args, .date);
}

fn evalTimestampGetDayOfMonth(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    return evalTimestampAccessor(args, .day_of_month);
}

fn evalTimestampGetDayOfWeek(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    return evalTimestampAccessor(args, .day_of_week);
}

fn evalTimestampGetDayOfYear(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    return evalTimestampAccessor(args, .day_of_year);
}

fn evalTimestampGetFullYear(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    return evalTimestampAccessor(args, .full_year);
}

fn evalTimestampGetMonth(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    return evalTimestampAccessor(args, .month);
}

fn evalGetHours(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    return switch (args[0]) {
        .timestamp => evalTimestampAccessor(args, .hours),
        .duration => evalDurationHours(args),
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalGetMilliseconds(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    return switch (args[0]) {
        .timestamp => evalTimestampAccessor(args, .milliseconds),
        .duration => evalDurationMilliseconds(args),
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalGetMinutes(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    return switch (args[0]) {
        .timestamp => evalTimestampAccessor(args, .minutes),
        .duration => evalDurationMinutes(args),
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalGetSeconds(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    return switch (args[0]) {
        .timestamp => evalTimestampAccessor(args, .seconds),
        .duration => evalDurationSeconds(args),
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalTimestampAccessor(args: []const value.Value, field: TimestampField) value.RuntimeError!value.Value {
    if (args.len != 1 and args.len != 2) return value.RuntimeError.TypeMismatch;
    if (args[0] != .timestamp) return value.RuntimeError.TypeMismatch;
    const timezone: ?[]const u8 = if (args.len == 2) blk: {
        if (args[1] != .string) return value.RuntimeError.TypeMismatch;
        break :blk args[1].string;
    } else null;
    const fields = cel_time.timestampFields(args[0].timestamp, timezone) catch return value.RuntimeError.TypeMismatch;
    return switch (field) {
        .date => .{ .int = fields.day },
        .day_of_month => .{ .int = @as(i64, fields.day) - 1 },
        .day_of_week => .{ .int = cel_time.timestampDayOfWeek(args[0].timestamp, timezone) catch return value.RuntimeError.TypeMismatch },
        .day_of_year => .{ .int = cel_time.timestampDayOfYear(args[0].timestamp, timezone) catch return value.RuntimeError.TypeMismatch },
        .full_year => .{ .int = fields.year },
        .hours => .{ .int = fields.hour },
        .milliseconds => .{ .int = @divTrunc(@as(i64, args[0].timestamp.nanos), cel_time.nanos_per_millisecond) },
        .minutes => .{ .int = fields.minute },
        .month => .{ .int = @as(i64, fields.month) - 1 },
        .seconds => .{ .int = fields.second },
    };
}

fn evalDurationHours(args: []const value.Value) value.RuntimeError!value.Value {
    if (args.len != 1 or args[0] != .duration) return value.RuntimeError.TypeMismatch;
    return .{ .int = cel_time.durationHours(args[0].duration) };
}

fn evalDurationMilliseconds(args: []const value.Value) value.RuntimeError!value.Value {
    if (args.len != 1 or args[0] != .duration) return value.RuntimeError.TypeMismatch;
    return .{ .int = cel_time.durationMillisecondsPortion(args[0].duration) };
}

fn evalDurationMinutes(args: []const value.Value) value.RuntimeError!value.Value {
    if (args.len != 1 or args[0] != .duration) return value.RuntimeError.TypeMismatch;
    return .{ .int = cel_time.durationMinutes(args[0].duration) };
}

fn evalDurationSeconds(args: []const value.Value) value.RuntimeError!value.Value {
    if (args.len != 1 or args[0] != .duration) return value.RuntimeError.TypeMismatch;
    return .{ .int = cel_time.durationSeconds(args[0].duration) };
}

fn isAcceptedTrueString(text: []const u8) bool {
    return std.mem.eql(u8, text, "1") or
        std.mem.eql(u8, text, "t") or
        std.mem.eql(u8, text, "T") or
        std.mem.eql(u8, text, "true") or
        std.mem.eql(u8, text, "TRUE") or
        std.mem.eql(u8, text, "True");
}

fn isAcceptedFalseString(text: []const u8) bool {
    return std.mem.eql(u8, text, "0") or
        std.mem.eql(u8, text, "f") or
        std.mem.eql(u8, text, "F") or
        std.mem.eql(u8, text, "false") or
        std.mem.eql(u8, text, "FALSE") or
        std.mem.eql(u8, text, "False");
}

test "standard library installs dynamic bindings" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(standard_library);

    const t = environment.types.builtins;
    try std.testing.expect(environment.findDynamicFunction("size", false, &.{try environment.types.listOf(t.int_type)}) != null);
    const host_ty = try environment.addHostType("example.Foo");
    try std.testing.expect(environment.findDynamicFunction("type", false, &.{host_ty}) != null);
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

const compile_mod = @import("../compiler/compile.zig");
const eval_impl = @import("../eval/eval.zig");
const Activation = @import("../eval/activation.zig").Activation;

const TestResult = union(enum) {
    int: i64,
    uint: u64,
    double: f64,
    bool_val: bool,
    string_val: []const u8,
    bytes_val: []const u8,
    type_name: []const u8,
    is_null: void,
    optional_none: void,
};

fn expectCelResult(environment: *cel_env.Env, expr: []const u8, expected: TestResult) !void {
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var program = try compile_mod.compile(std.testing.allocator, environment, expr);
    defer program.deinit();

    var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
    defer result.deinit(std.testing.allocator);

    switch (expected) {
        .int => |v| try std.testing.expectEqual(v, result.int),
        .uint => |v| try std.testing.expectEqual(v, result.uint),
        .double => |v| try std.testing.expectEqual(v, result.double),
        .bool_val => |v| try std.testing.expectEqual(v, result.bool),
        .string_val => |v| try std.testing.expectEqualStrings(v, result.string),
        .bytes_val => |v| try std.testing.expectEqualStrings(v, result.bytes),
        .type_name => |v| try std.testing.expectEqualStrings(v, result.type_name),
        .is_null => try std.testing.expectEqual(.null, result),
        .optional_none => {
            try std.testing.expect(result == .optional);
            try std.testing.expectEqual(@as(?*value.Value, null), result.optional.value);
        },
    }
}

fn expectCelError(environment: *cel_env.Env, expr: []const u8) !void {
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var program = compile_mod.compile(std.testing.allocator, environment, expr) catch return;
    defer program.deinit();

    const result = eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
    if (result) |*r| {
        var v = r.*;
        v.deinit(std.testing.allocator);
        return error.TestExpectedError;
    } else |_| {}
}

fn makeStdEnv() !cel_env.Env {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    errdefer environment.deinit();
    try environment.addLibrary(standard_library);
    return environment;
}

// ---------------------------------------------------------------------------
// size() tests
// ---------------------------------------------------------------------------

test "stdlib size" {
    var env = try makeStdEnv();
    defer env.deinit();

    const cases = .{
        .{ "size('hello')", TestResult{ .int = 5 } },
        .{ "size('')", TestResult{ .int = 0 } },
        .{ "size('abc')", TestResult{ .int = 3 } },
        .{ "'hello'.size()", TestResult{ .int = 5 } },
        .{ "size(b'\\x00\\x01\\x02')", TestResult{ .int = 3 } },
        .{ "size(b'')", TestResult{ .int = 0 } },
        .{ "size([1, 2, 3])", TestResult{ .int = 3 } },
        .{ "size([])", TestResult{ .int = 0 } },
        .{ "size({1: 'a', 2: 'b'})", TestResult{ .int = 2 } },
        .{ "size({})", TestResult{ .int = 0 } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// type() tests
// ---------------------------------------------------------------------------

test "stdlib type" {
    var env = try makeStdEnv();
    defer env.deinit();

    const cases = .{
        .{ "type(1)", TestResult{ .type_name = "int" } },
        .{ "type(1u)", TestResult{ .type_name = "uint" } },
        .{ "type(1.0)", TestResult{ .type_name = "double" } },
        .{ "type(true)", TestResult{ .type_name = "bool" } },
        .{ "type('hello')", TestResult{ .type_name = "string" } },
        .{ "type(null)", TestResult{ .type_name = "null_type" } },
        .{ "type([1])", TestResult{ .type_name = "list" } },
        .{ "type({1: 2})", TestResult{ .type_name = "map" } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// dyn() tests
// ---------------------------------------------------------------------------

test "stdlib dyn" {
    var env = try makeStdEnv();
    defer env.deinit();

    const cases = .{
        .{ "dyn(42)", TestResult{ .int = 42 } },
        .{ "dyn('abc')", TestResult{ .string_val = "abc" } },
        .{ "dyn(true)", TestResult{ .bool_val = true } },
        .{ "dyn(1.5)", TestResult{ .double = 1.5 } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// base64.encode / base64.decode roundtrip tests
// ---------------------------------------------------------------------------

test "stdlib base64 encode" {
    var env = try makeStdEnv();
    defer env.deinit();

    const cases = .{
        .{ "base64.encode(b'')", TestResult{ .string_val = "" } },
        .{ "base64.encode(b'hello')", TestResult{ .string_val = "aGVsbG8=" } },
        .{ "base64.encode(b'a')", TestResult{ .string_val = "YQ==" } },
        .{ "base64.encode(b'ab')", TestResult{ .string_val = "YWI=" } },
        .{ "base64.encode(b'abc')", TestResult{ .string_val = "YWJj" } },
        .{ "base64.encode(b'\\x00\\xff')", TestResult{ .string_val = "AP8=" } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

test "stdlib base64 decode" {
    var env = try makeStdEnv();
    defer env.deinit();

    const cases = .{
        .{ "base64.decode('')", TestResult{ .bytes_val = "" } },
        .{ "base64.decode('aGVsbG8=')", TestResult{ .bytes_val = "hello" } },
        .{ "base64.decode('YQ==')", TestResult{ .bytes_val = "a" } },
        .{ "base64.decode('YWI=')", TestResult{ .bytes_val = "ab" } },
        .{ "base64.decode('YWJj')", TestResult{ .bytes_val = "abc" } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// int() conversion tests
// ---------------------------------------------------------------------------

test "stdlib int conversion" {
    var env = try makeStdEnv();
    defer env.deinit();

    const cases = .{
        .{ "int(42)", TestResult{ .int = 42 } },
        .{ "int(-1)", TestResult{ .int = -1 } },
        .{ "int(0)", TestResult{ .int = 0 } },
        .{ "int(3u)", TestResult{ .int = 3 } },
        .{ "int(0u)", TestResult{ .int = 0 } },
        .{ "int(3.9)", TestResult{ .int = 3 } },
        .{ "int(-3.9)", TestResult{ .int = -3 } },
        .{ "int(0.0)", TestResult{ .int = 0 } },
        .{ "int('42')", TestResult{ .int = 42 } },
        .{ "int('-100')", TestResult{ .int = -100 } },
        .{ "int('0')", TestResult{ .int = 0 } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

test "stdlib int conversion errors" {
    var env = try makeStdEnv();
    defer env.deinit();

    try expectCelError(&env, "int('abc')");
    try expectCelError(&env, "int('')");
}

// ---------------------------------------------------------------------------
// uint() conversion tests
// ---------------------------------------------------------------------------

test "stdlib uint conversion" {
    var env = try makeStdEnv();
    defer env.deinit();

    const cases = .{
        .{ "uint(42u)", TestResult{ .uint = 42 } },
        .{ "uint(0u)", TestResult{ .uint = 0 } },
        .{ "uint(5)", TestResult{ .uint = 5 } },
        .{ "uint(0)", TestResult{ .uint = 0 } },
        .{ "uint(3.9)", TestResult{ .uint = 3 } },
        .{ "uint(0.0)", TestResult{ .uint = 0 } },
        .{ "uint('100')", TestResult{ .uint = 100 } },
        .{ "uint('0')", TestResult{ .uint = 0 } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

test "stdlib uint conversion errors" {
    var env = try makeStdEnv();
    defer env.deinit();

    try expectCelError(&env, "uint(-1)");
    try expectCelError(&env, "uint('abc')");
    try expectCelError(&env, "uint(-1.0)");
}

// ---------------------------------------------------------------------------
// double() conversion tests
// ---------------------------------------------------------------------------

test "stdlib double conversion" {
    var env = try makeStdEnv();
    defer env.deinit();

    const cases = .{
        .{ "double(1.5)", TestResult{ .double = 1.5 } },
        .{ "double(0.0)", TestResult{ .double = 0.0 } },
        .{ "double(42)", TestResult{ .double = 42.0 } },
        .{ "double(-7)", TestResult{ .double = -7.0 } },
        .{ "double(0)", TestResult{ .double = 0.0 } },
        .{ "double(10u)", TestResult{ .double = 10.0 } },
        .{ "double(0u)", TestResult{ .double = 0.0 } },
        .{ "double('3.14')", TestResult{ .double = 3.14 } },
        .{ "double('0')", TestResult{ .double = 0.0 } },
        .{ "double('-1.5')", TestResult{ .double = -1.5 } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

test "stdlib double conversion errors" {
    var env = try makeStdEnv();
    defer env.deinit();

    try expectCelError(&env, "double('abc')");
    try expectCelError(&env, "double('')");
}

// ---------------------------------------------------------------------------
// string() conversion tests
// ---------------------------------------------------------------------------

test "stdlib string conversion" {
    var env = try makeStdEnv();
    defer env.deinit();

    const cases = .{
        .{ "string('hello')", TestResult{ .string_val = "hello" } },
        .{ "string('')", TestResult{ .string_val = "" } },
        .{ "string(true)", TestResult{ .string_val = "true" } },
        .{ "string(false)", TestResult{ .string_val = "false" } },
        .{ "string(42)", TestResult{ .string_val = "42" } },
        .{ "string(-1)", TestResult{ .string_val = "-1" } },
        .{ "string(0)", TestResult{ .string_val = "0" } },
        .{ "string(10u)", TestResult{ .string_val = "10" } },
        .{ "string(0u)", TestResult{ .string_val = "0" } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// bool() conversion tests
// ---------------------------------------------------------------------------

test "stdlib bool conversion" {
    var env = try makeStdEnv();
    defer env.deinit();

    const cases = .{
        .{ "bool(true)", TestResult{ .bool_val = true } },
        .{ "bool(false)", TestResult{ .bool_val = false } },
        .{ "bool('true')", TestResult{ .bool_val = true } },
        .{ "bool('false')", TestResult{ .bool_val = false } },
        .{ "bool('True')", TestResult{ .bool_val = true } },
        .{ "bool('False')", TestResult{ .bool_val = false } },
        .{ "bool('TRUE')", TestResult{ .bool_val = true } },
        .{ "bool('FALSE')", TestResult{ .bool_val = false } },
        .{ "bool('t')", TestResult{ .bool_val = true } },
        .{ "bool('f')", TestResult{ .bool_val = false } },
        .{ "bool('T')", TestResult{ .bool_val = true } },
        .{ "bool('F')", TestResult{ .bool_val = false } },
        .{ "bool('1')", TestResult{ .bool_val = true } },
        .{ "bool('0')", TestResult{ .bool_val = false } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

test "stdlib bool conversion errors" {
    var env = try makeStdEnv();
    defer env.deinit();

    try expectCelError(&env, "bool('yes')");
    try expectCelError(&env, "bool('no')");
    try expectCelError(&env, "bool('')");
}

// ---------------------------------------------------------------------------
// bytes() conversion tests
// ---------------------------------------------------------------------------

test "stdlib bytes conversion" {
    var env = try makeStdEnv();
    defer env.deinit();

    const cases = .{
        .{ "bytes('hello')", TestResult{ .bytes_val = "hello" } },
        .{ "bytes('')", TestResult{ .bytes_val = "" } },
        .{ "bytes('abc')", TestResult{ .bytes_val = "abc" } },
        .{ "bytes(b'raw')", TestResult{ .bytes_val = "raw" } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// timestamp() and duration() string parsing tests
// ---------------------------------------------------------------------------

test "stdlib duration parsing" {
    var env = try makeStdEnv();
    defer env.deinit();

    const cases = .{
        .{ "duration('0s') == duration('0s')", TestResult{ .bool_val = true } },
        .{ "duration('1s') == duration('1s')", TestResult{ .bool_val = true } },
        .{ "duration('1h') == duration('3600s')", TestResult{ .bool_val = true } },
        .{ "duration('1m') == duration('60s')", TestResult{ .bool_val = true } },
        .{ "duration('1500ms') == duration('1.5s')", TestResult{ .bool_val = true } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

test "stdlib timestamp parsing" {
    var env = try makeStdEnv();
    defer env.deinit();

    const cases = .{
        .{ "timestamp('1970-01-01T00:00:00Z') == timestamp('1970-01-01T00:00:00Z')", TestResult{ .bool_val = true } },
        .{ "timestamp('2023-06-15T12:30:00Z') == timestamp('2023-06-15T12:30:00Z')", TestResult{ .bool_val = true } },
        .{ "int(timestamp('1970-01-01T00:00:00Z'))", TestResult{ .int = 0 } },
        .{ "timestamp(0) == timestamp('1970-01-01T00:00:00Z')", TestResult{ .bool_val = true } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// optional functions tests
// ---------------------------------------------------------------------------

test "stdlib optional.none and optional.of" {
    var env = try makeStdEnv();
    defer env.deinit();

    try expectCelResult(&env, "optional.none().hasValue()", TestResult{ .bool_val = false });
    try expectCelResult(&env, "optional.of(42).hasValue()", TestResult{ .bool_val = true });
    try expectCelResult(&env, "optional.of(42).value()", TestResult{ .int = 42 });
    try expectCelResult(&env, "optional.of('hi').value()", TestResult{ .string_val = "hi" });
    try expectCelResult(&env, "optional.of(true).value()", TestResult{ .bool_val = true });
}

test "stdlib optional.or and optional.orValue" {
    var env = try makeStdEnv();
    defer env.deinit();

    try expectCelResult(&env, "optional.none().or(optional.of(5)).value()", TestResult{ .int = 5 });
    try expectCelResult(&env, "optional.of(3).or(optional.of(5)).value()", TestResult{ .int = 3 });
    try expectCelResult(&env, "optional.none().orValue(10)", TestResult{ .int = 10 });
    try expectCelResult(&env, "optional.of(3).orValue(10)", TestResult{ .int = 3 });
    try expectCelResult(&env, "optional.none().or(optional.none()).hasValue()", TestResult{ .bool_val = false });
}

test "stdlib optional.value on none errors" {
    var env = try makeStdEnv();
    defer env.deinit();

    try expectCelError(&env, "optional.none().value()");
}

// ---------------------------------------------------------------------------
// startsWith / endsWith / contains tests
// ---------------------------------------------------------------------------

test "stdlib startsWith endsWith contains" {
    var env = try makeStdEnv();
    defer env.deinit();

    const cases = .{
        .{ "'hello'.startsWith('hel')", TestResult{ .bool_val = true } },
        .{ "'hello'.startsWith('world')", TestResult{ .bool_val = false } },
        .{ "'hello'.startsWith('')", TestResult{ .bool_val = true } },
        .{ "'hello'.startsWith('hello')", TestResult{ .bool_val = true } },
        .{ "'hello'.endsWith('llo')", TestResult{ .bool_val = true } },
        .{ "'hello'.endsWith('hel')", TestResult{ .bool_val = false } },
        .{ "'hello'.endsWith('')", TestResult{ .bool_val = true } },
        .{ "'hello'.endsWith('hello')", TestResult{ .bool_val = true } },
        .{ "'hello world'.contains('lo wo')", TestResult{ .bool_val = true } },
        .{ "'hello'.contains('xyz')", TestResult{ .bool_val = false } },
        .{ "'hello'.contains('')", TestResult{ .bool_val = true } },
        .{ "''.contains('')", TestResult{ .bool_val = true } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}
