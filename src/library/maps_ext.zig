const std = @import("std");
const cel_env = @import("../env/env.zig");
const types = @import("../env/types.zig");
const value = @import("../env/value.zig");
const compile_mod = @import("../compiler/compile.zig");
const eval_impl = @import("../eval/eval.zig");
const Activation = @import("../eval/activation.zig").Activation;

pub const maps_library = cel_env.Library{
    .name = "cel.lib.ext.maps",
    .install = installMapsLibrary,
};

fn installMapsLibrary(environment: *cel_env.Env) !void {
    _ = try environment.addDynamicFunction("merge", true, matchMapMerge, evalMapMerge);
}

fn matchMapMerge(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 2) return null;
    if (!isMapLike(environment, params[0])) return null;
    if (!isMapLike(environment, params[1])) return null;
    const spec_a = environment.types.spec(params[0]);
    const spec_b = environment.types.spec(params[1]);
    if (spec_a == .dyn or spec_b == .dyn) return environment.types.builtins.dyn_type;
    if (params[0] != params[1]) return null;
    return params[0];
}

fn isMapLike(environment: *const cel_env.Env, actual: types.TypeRef) bool {
    return switch (environment.types.spec(actual)) {
        .map, .dyn => true,
        else => false,
    };
}

fn evalMapMerge(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 2 or args[0] != .map or args[1] != .map) return value.RuntimeError.TypeMismatch;

    var out: std.ArrayListUnmanaged(value.MapEntry) = .empty;
    errdefer {
        for (out.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        out.deinit(allocator);
    }

    try out.ensureTotalCapacity(allocator, args[0].map.items.len + args[1].map.items.len);
    for (args[0].map.items) |entry| {
        try out.append(allocator, .{
            .key = try entry.key.clone(allocator),
            .value = try entry.value.clone(allocator),
        });
    }

    for (args[1].map.items) |entry| {
        var replaced = false;
        for (out.items) |*existing| {
            if (valuesEqual(existing.key, entry.key)) {
                existing.value.deinit(allocator);
                existing.value = try entry.value.clone(allocator);
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            try out.append(allocator, .{
                .key = try entry.key.clone(allocator),
                .value = try entry.value.clone(allocator),
            });
        }
    }

    return .{ .map = out };
}

fn valuesEqual(lhs: value.Value, rhs: value.Value) bool {
    if (isNumericValue(lhs) and isNumericValue(rhs)) return numericValuesEqual(lhs, rhs);
    return lhs.eql(rhs);
}

fn isNumericValue(v: value.Value) bool {
    return switch (v) {
        .int, .uint, .double => true,
        else => false,
    };
}

fn numericValuesEqual(lhs: value.Value, rhs: value.Value) bool {
    return switch (lhs) {
        .int => |left| switch (rhs) {
            .int => left == rhs.int,
            .uint => left >= 0 and @as(u64, @intCast(left)) == rhs.uint,
            .double => equalIntAndDouble(left, rhs.double),
            else => false,
        },
        .uint => |left| switch (rhs) {
            .int => rhs.int >= 0 and left == @as(u64, @intCast(rhs.int)),
            .uint => left == rhs.uint,
            .double => equalUintAndDouble(left, rhs.double),
            else => false,
        },
        .double => |left| switch (rhs) {
            .int => equalIntAndDouble(rhs.int, left),
            .uint => equalUintAndDouble(rhs.uint, left),
            .double => if (std.math.isNan(left) and std.math.isNan(rhs.double)) true else left == rhs.double,
            else => false,
        },
        else => false,
    };
}

fn equalIntAndDouble(lhs: i64, rhs: f64) bool {
    if (!std.math.isFinite(rhs)) return false;
    if (@round(rhs) != rhs) return false;
    return rhs == @as(f64, @floatFromInt(lhs));
}

fn equalUintAndDouble(lhs: u64, rhs: f64) bool {
    if (!std.math.isFinite(rhs)) return false;
    if (@round(rhs) != rhs) return false;
    return rhs == @as(f64, @floatFromInt(lhs));
}

test "maps merge library works" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(maps_library);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var program = try compile_mod.compile(std.testing.allocator, &environment, "{'a': 1}.merge({'a': 2, 'b': 3}) == {'a': 2, 'b': 3}");
    defer program.deinit();
    var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.bool);
}

test "maps merge treats numeric keys with CEL equality" {
    var lhs: value.Value = .{ .map = .empty };
    defer lhs.deinit(std.testing.allocator);
    try lhs.map.append(std.testing.allocator, .{
        .key = .{ .int = 1 },
        .value = try value.string(std.testing.allocator, "one"),
    });

    var rhs: value.Value = .{ .map = .empty };
    defer rhs.deinit(std.testing.allocator);
    try rhs.map.append(std.testing.allocator, .{
        .key = .{ .double = 1.0 },
        .value = try value.string(std.testing.allocator, "uno"),
    });

    var merged = try evalMapMerge(std.testing.allocator, &.{ lhs, rhs });
    defer merged.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), merged.map.items.len);
    try std.testing.expect(merged.map.items[0].key == .int);
    try std.testing.expectEqual(@as(i64, 1), merged.map.items[0].key.int);
    try std.testing.expect(merged.map.items[0].value == .string);
    try std.testing.expectEqualStrings("uno", merged.map.items[0].value.string);
}

test "maps numeric equality helpers cover mixed numeric types" {
    try std.testing.expect(valuesEqual(.{ .int = 1 }, .{ .uint = 1 }));
    try std.testing.expect(valuesEqual(.{ .int = 1 }, .{ .double = 1.0 }));
    try std.testing.expect(!valuesEqual(.{ .int = 1 }, .{ .double = 1.5 }));
    try std.testing.expect(!valuesEqual(.{ .uint = 1 }, .{ .double = std.math.inf(f64) }));
    try std.testing.expect(numericValuesEqual(.{ .double = std.math.nan(f64) }, .{ .double = std.math.nan(f64) }));
    try std.testing.expectError(value.RuntimeError.TypeMismatch, evalMapMerge(std.testing.allocator, &.{ .{ .int = 1 }, .{ .map = .empty } }));
}
