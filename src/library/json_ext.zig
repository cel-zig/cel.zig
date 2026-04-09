const std = @import("std");
const cel_time = @import("cel_time.zig");
const cel_env = @import("../env/env.zig");
const types = @import("../env/types.zig");
const value = @import("../env/value.zig");
const compile_mod = @import("../compiler/compile.zig");
const eval_impl = @import("../eval/eval.zig");
const Activation = @import("../eval/activation.zig").Activation;

pub const json_library = cel_env.Library{
    .name = "cel.lib.ext.json",
    .install = installJsonLibrary,
};

fn installJsonLibrary(environment: *cel_env.Env) !void {
    const t = environment.types.builtins;
    _ = try environment.addFunction("json.unmarshal", false, &.{t.string_type}, t.dyn_type, evalJsonUnmarshal);
    _ = try environment.addDynamicFunction("json.marshal", false, matchMarshalJson, evalJsonMarshal);
}

fn matchMarshalJson(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 1) return null;
    return environment.types.builtins.string_type;
}

fn evalJsonUnmarshal(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args[0].string, .{
        .duplicate_field_behavior = .use_last,
        .ignore_unknown_fields = true,
        .parse_numbers = true,
    }) catch return value.RuntimeError.TypeMismatch;
    defer parsed.deinit();
    return jsonToValue(allocator, parsed.value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return value.RuntimeError.TypeMismatch,
    };
}

fn evalJsonMarshal(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var jws: std.json.Stringify = .{
        .writer = &writer.writer,
        .options = .{},
    };

    stringifyValueAsJson(allocator, args[0], &jws) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.OutOfMemory,
        error.UnsupportedJsonValue => return value.RuntimeError.TypeMismatch,
    };

    return .{ .string = try writer.toOwnedSlice() };
}

fn jsonToValue(allocator: std.mem.Allocator, json: std.json.Value) !value.Value {
    return switch (json) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .double = f },
        .number_string => |text| blk: {
            if (std.fmt.parseInt(i64, text, 10)) |i| break :blk .{ .int = i } else |_| {}
            if (std.fmt.parseInt(u64, text, 10)) |u| break :blk .{ .uint = u } else |_| {}
            if (std.fmt.parseFloat(f64, text)) |f| break :blk .{ .double = f } else |_| {}
            return error.TypeMismatch;
        },
        .string => |text| try value.string(allocator, text),
        .array => |arr| blk: {
            var out: std.ArrayListUnmanaged(value.Value) = .empty;
            errdefer {
                for (out.items) |*item| item.deinit(allocator);
                out.deinit(allocator);
            }
            try out.ensureTotalCapacity(allocator, arr.items.len);
            for (arr.items) |item| {
                out.appendAssumeCapacity(try jsonToValue(allocator, item));
            }
            break :blk .{ .list = out };
        },
        .object => |obj| blk: {
            var out: std.ArrayListUnmanaged(value.MapEntry) = .empty;
            errdefer {
                for (out.items) |*entry| {
                    entry.key.deinit(allocator);
                    entry.value.deinit(allocator);
                }
                out.deinit(allocator);
            }
            try out.ensureTotalCapacity(allocator, obj.count());
            var it = obj.iterator();
            while (it.next()) |entry| {
                out.appendAssumeCapacity(.{
                    .key = try value.string(allocator, entry.key_ptr.*),
                    .value = try jsonToValue(allocator, entry.value_ptr.*),
                });
            }
            break :blk .{ .map = out };
        },
    };
}

const JsonStringifyError = error{ UnsupportedJsonValue, WriteFailed } || std.mem.Allocator.Error;

fn stringifyValueAsJson(
    allocator: std.mem.Allocator,
    v: value.Value,
    jws: *std.json.Stringify,
) JsonStringifyError!void {
    switch (v) {
        .null => try jws.write(null),
        .bool => |b| try jws.write(b),
        .int => |i| try jws.write(i),
        .uint => |u| try jws.write(u),
        .double => |d| {
            if (!std.math.isFinite(d)) return error.UnsupportedJsonValue;
            try jws.write(d);
        },
        .string => |s| try jws.write(s),
        .bytes => |data| {
            const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
            const encoded = try allocator.alloc(u8, encoded_len);
            defer allocator.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, data);
            try jws.write(encoded);
        },
        .timestamp => |ts| {
            const text = try cel_time.formatTimestamp(allocator, ts);
            defer allocator.free(text);
            try jws.write(text);
        },
        .duration => |dur| {
            const text = try cel_time.formatDuration(allocator, dur);
            defer allocator.free(text);
            try jws.write(text);
        },
        .enum_value => |enum_value| try jws.write(enum_value.value),
        .optional => |opt| {
            if (opt.value) |inner| {
                try stringifyValueAsJson(allocator, inner.*, jws);
            } else {
                try jws.write(null);
            }
        },
        .list => |items| {
            try jws.beginArray();
            for (items.items) |item| {
                try stringifyValueAsJson(allocator, item, jws);
            }
            try jws.endArray();
        },
        .map => |entries| {
            try jws.beginObject();
            for (entries.items) |entry| {
                if (entry.key != .string) return error.UnsupportedJsonValue;
                try jws.objectField(entry.key.string);
                try stringifyValueAsJson(allocator, entry.value, jws);
            }
            try jws.endObject();
        },
        .message => |msg| {
            try jws.beginObject();
            for (msg.fields.items) |field| {
                try jws.objectField(field.name);
                try stringifyValueAsJson(allocator, field.value, jws);
            }
            try jws.endObject();
        },
        .host, .unknown, .type_name => return error.UnsupportedJsonValue,
    }
}

test "json library marshals and unmarshals" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(json_library);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_][]const u8{
        "json.unmarshal('{\"a\":1,\"b\":[true,null]}').a == 1",
        "json.unmarshal('{\"a\":1,\"b\":[true,null]}').b[0] == true",
        "json.marshal({'name':'test','count':42}) == '{\"name\":\"test\",\"count\":42}' || json.marshal({'name':'test','count':42}) == '{\"count\":42,\"name\":\"test\"}'",
    };
    for (cases) |expr| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.bool);
    }
}

test "json helpers convert duplicate fields and numeric strings" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"a\":1,\"a\":2}", .{
        .duplicate_field_behavior = .use_last,
        .ignore_unknown_fields = true,
        .parse_numbers = true,
    });
    defer parsed.deinit();

    var converted = try jsonToValue(std.testing.allocator, parsed.value);
    defer converted.deinit(std.testing.allocator);
    try std.testing.expect(converted == .map);

    var saw_last_value = false;
    for (converted.map.items) |entry| {
        if (entry.key == .string and std.mem.eql(u8, entry.key.string, "a")) {
            try std.testing.expect(entry.value == .int);
            try std.testing.expectEqual(@as(i64, 2), entry.value.int);
            saw_last_value = true;
        }
    }
    try std.testing.expect(saw_last_value);

    var uint_value = try jsonToValue(std.testing.allocator, .{ .number_string = "18446744073709551615" });
    defer uint_value.deinit(std.testing.allocator);
    try std.testing.expect(uint_value == .uint);
    try std.testing.expectEqual(std.math.maxInt(u64), uint_value.uint);

    var double_value = try jsonToValue(std.testing.allocator, .{ .number_string = "1.25e2" });
    defer double_value.deinit(std.testing.allocator);
    try std.testing.expect(double_value == .double);
    try std.testing.expectApproxEqAbs(@as(f64, 125.0), double_value.double, 0.000_001);
}

test "json marshal covers bytes and optionals and rejects unsupported values" {
    var bytes_value = try value.bytesValue(std.testing.allocator, "hi");
    defer bytes_value.deinit(std.testing.allocator);

    var marshaled_bytes = try evalJsonMarshal(std.testing.allocator, &.{bytes_value});
    defer marshaled_bytes.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\"aGk=\"", marshaled_bytes.string);

    var marshaled_none = try evalJsonMarshal(std.testing.allocator, &.{value.optionalNone()});
    defer marshaled_none.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("null", marshaled_none.string);

    var unsupported: value.Value = .{ .type_name = try std.testing.allocator.dupe(u8, "int") };
    defer unsupported.deinit(std.testing.allocator);
    try std.testing.expectError(value.RuntimeError.TypeMismatch, evalJsonMarshal(std.testing.allocator, &.{unsupported}));
}
