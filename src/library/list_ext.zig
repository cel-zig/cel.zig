const std = @import("std");
const cel_time = @import("cel_time.zig");
const cel_env = @import("../env/env.zig");
const types = @import("../env/types.zig");
const value = @import("../env/value.zig");

pub const list_library = cel_env.Library{
    .name = "cel.lib.ext.lists",
    .install = installListLibrary,
};

fn installListLibrary(environment: *cel_env.Env) !void {
    const t = environment.types.builtins;
    const list_dyn = try environment.types.listOf(t.dyn_type);
    const list_int = try environment.types.listOf(t.int_type);

    // Receiver-style: first param is the receiver
    _ = try environment.addDynamicFunction("sort", true, matchSort, evalSort);
    _ = try environment.addDynamicFunction("flatten", true, matchFlatten, evalFlatten);
    _ = try environment.addFunction("slice", true, &.{ list_dyn, t.int_type, t.int_type }, list_dyn, evalSlice);
    _ = try environment.addDynamicFunction("distinct", true, matchDistinct, evalDistinct);
    _ = try environment.addDynamicFunction("reverse", true, matchReverse, evalReverse);
    _ = try environment.addDynamicFunction("first", true, matchFirstLast, evalFirst);
    _ = try environment.addDynamicFunction("last", true, matchFirstLast, evalLast);
    _ = try environment.addDynamicFunction("isSorted", true, matchListComparableUnary, evalListIsSorted);
    _ = try environment.addDynamicFunction("sum", true, matchListSumUnary, evalListSum);
    _ = try environment.addDynamicFunction("min", true, matchListComparableUnary, evalListMin);
    _ = try environment.addDynamicFunction("max", true, matchListComparableUnary, evalListMax);
    _ = try environment.addDynamicFunction("indexOf", true, matchListIndexOf, evalListIndexOf);
    _ = try environment.addDynamicFunction("lastIndexOf", true, matchListIndexOf, evalListLastIndexOf);
    _ = try environment.addDynamicFunction("lists.setAtIndex", false, matchListSetAtIndex, evalListSetAtIndex);
    _ = try environment.addDynamicFunction("lists.insertAtIndex", false, matchListSetAtIndex, evalListInsertAtIndex);
    _ = try environment.addDynamicFunction("lists.removeAtIndex", false, matchListRemoveAtIndex, evalListRemoveAtIndex);

    _ = try environment.addDynamicFunction("zip", true, matchZip, evalZip);

    // Keep the historical alias for compatibility, but prefer lists.range().
    _ = try environment.addFunction("list.range", false, &.{t.int_type}, list_int, evalRange);
    _ = try environment.addFunction("lists.range", false, &.{t.int_type}, list_int, evalRange);
}

fn matchSort(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 1) return null;
    const t = environment.types.builtins;
    return switch (environment.types.spec(params[0])) {
        .list => |elem_ty| if (environment.types.isSimpleComparable(elem_ty) or
            environment.types.spec(elem_ty) == .dyn or
            environment.types.spec(elem_ty) == .type_param)
            params[0]
        else
            null,
        .dyn => t.dyn_type,
        else => null,
    };
}

fn matchFlatten(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 1 and params.len != 2) return null;
    if (!isListLike(environment, params[0])) return null;
    if (params.len == 2 and !isTypeOrDyn(environment, params[1], environment.types.builtins.int_type)) return null;
    // Flatten returns list(dyn) since inner type is unknown at type-check time.
    const t = environment.types.builtins;
    return environment.types.listOf(t.dyn_type) catch return null;
}

fn matchDistinct(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 1) return null;
    return if (isListLike(environment, params[0])) params[0] else null;
}

fn matchFirstLast(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 1) return null;
    const t = environment.types.builtins;
    return switch (environment.types.spec(params[0])) {
        .list => |elem_ty| environment.types.optionalOf(elem_ty) catch null,
        .dyn => environment.types.optionalOf(t.dyn_type) catch null,
        else => null,
    };
}

fn matchListComparableUnary(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 1) return null;
    const t = environment.types.builtins;
    return switch (environment.types.spec(params[0])) {
        .list => |elem_ty| if (environment.types.isSimpleComparable(elem_ty) or environment.types.spec(elem_ty) == .dyn)
            params[0]
        else
            null,
        .dyn => t.dyn_type,
        else => null,
    };
}

fn matchListSumUnary(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 1) return null;
    const t = environment.types.builtins;
    return switch (environment.types.spec(params[0])) {
        .list => |elem_ty| if (environment.types.isNumeric(elem_ty) or environment.types.isDurationType(elem_ty) or environment.types.spec(elem_ty) == .dyn)
            elem_ty
        else
            null,
        .dyn => t.dyn_type,
        else => null,
    };
}

fn matchListIndexOf(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 2) return null;
    const t = environment.types.builtins;
    return switch (environment.types.spec(params[0])) {
        .list => |elem_ty| if (elem_ty == params[1] or environment.types.spec(elem_ty) == .dyn or environment.types.spec(params[1]) == .dyn)
            t.int_type
        else
            null,
        .dyn => t.int_type,
        else => null,
    };
}

fn matchListSetAtIndex(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 3) return null;
    const t = environment.types.builtins;
    if (!isListLike(environment, params[0])) return null;
    if (!isTypeOrDyn(environment, params[1], t.int_type)) return null;
    return params[0];
}

fn matchListRemoveAtIndex(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 2) return null;
    const t = environment.types.builtins;
    if (!isListLike(environment, params[0])) return null;
    if (!isTypeOrDyn(environment, params[1], t.int_type)) return null;
    return params[0];
}

fn isListLike(environment: *const cel_env.Env, actual: types.TypeRef) bool {
    return switch (environment.types.spec(actual)) {
        .list, .dyn => true,
        else => false,
    };
}

fn isTypeOrDyn(environment: *const cel_env.Env, actual: types.TypeRef, expected: types.TypeRef) bool {
    return actual == expected or environment.types.spec(actual) == .dyn;
}

// ---------------------------------------------------------------------------
// first / last
// ---------------------------------------------------------------------------

fn evalFirst(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .list) return value.RuntimeError.TypeMismatch;
    const items = args[0].list.items;
    if (items.len == 0) return value.optionalNone();
    return value.optionalSome(allocator, try items[0].clone(allocator));
}

fn evalLast(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .list) return value.RuntimeError.TypeMismatch;
    const items = args[0].list.items;
    if (items.len == 0) return value.optionalNone();
    return value.optionalSome(allocator, try items[items.len - 1].clone(allocator));
}

// ---------------------------------------------------------------------------
// sort
// ---------------------------------------------------------------------------

fn evalSort(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .list) return value.RuntimeError.TypeMismatch;
    const src = args[0].list.items;

    var out: std.ArrayListUnmanaged(value.Value) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, src.len);
    for (src) |item| {
        out.appendAssumeCapacity(try item.clone(allocator));
    }

    try validateSortableValues(out.items);
    std.mem.sortUnstable(value.Value, out.items, {}, sortableValueLessThan);

    return .{ .list = out };
}

fn validateSortableValues(items: []const value.Value) cel_env.EvalError!void {
    if (items.len == 0) return;
    const first_tag = std.meta.activeTag(items[0]);
    if (!isSortableValue(items[0])) return value.RuntimeError.TypeMismatch;
    if (items[0] == .double and std.math.isNan(items[0].double)) return value.RuntimeError.TypeMismatch;
    for (items[1..]) |item| {
        if (std.meta.activeTag(item) != first_tag) return value.RuntimeError.TypeMismatch;
        if (!isSortableValue(item)) return value.RuntimeError.TypeMismatch;
        if (item == .double and std.math.isNan(item.double)) return value.RuntimeError.TypeMismatch;
    }
}

fn isSortableValue(v: value.Value) bool {
    return switch (v) {
        .int, .uint, .double, .bool, .string, .bytes, .timestamp, .duration => true,
        else => false,
    };
}

fn sortableValueLessThan(_: void, lhs: value.Value, rhs: value.Value) bool {
    return switch (lhs) {
        .int => lhs.int < rhs.int,
        .uint => lhs.uint < rhs.uint,
        .double => lhs.double < rhs.double,
        .bool => @intFromBool(lhs.bool) < @intFromBool(rhs.bool),
        .string => std.mem.order(u8, lhs.string, rhs.string) == .lt,
        .bytes => std.mem.order(u8, lhs.bytes, rhs.bytes) == .lt,
        .timestamp => if (lhs.timestamp.seconds == rhs.timestamp.seconds)
            lhs.timestamp.nanos < rhs.timestamp.nanos
        else
            lhs.timestamp.seconds < rhs.timestamp.seconds,
        .duration => if (lhs.duration.seconds == rhs.duration.seconds)
            lhs.duration.nanos < rhs.duration.nanos
        else
            lhs.duration.seconds < rhs.duration.seconds,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// flatten
// ---------------------------------------------------------------------------

fn evalFlatten(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if ((args.len != 1 and args.len != 2) or args[0] != .list) return value.RuntimeError.TypeMismatch;
    const src = args[0].list.items;
    const depth: usize = if (args.len == 2) blk: {
        if (args[1] != .int) return value.RuntimeError.TypeMismatch;
        if (args[1].int < 0) return value.RuntimeError.InvalidIndex;
        break :blk @intCast(args[1].int);
    } else 1;

    var out: std.ArrayListUnmanaged(value.Value) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }

    for (src) |item| {
        try appendFlattened(allocator, &out, item, depth);
    }

    return .{ .list = out };
}

fn appendFlattened(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(value.Value),
    item: value.Value,
    depth: usize,
) cel_env.EvalError!void {
    if (item == .list and depth > 0) {
        for (item.list.items) |inner| {
            try appendFlattened(allocator, out, inner, depth - 1);
        }
        return;
    }
    try out.append(allocator, try item.clone(allocator));
}

// ---------------------------------------------------------------------------
// slice
// ---------------------------------------------------------------------------

fn evalSlice(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 3 or args[0] != .list or args[1] != .int or args[2] != .int)
        return value.RuntimeError.TypeMismatch;
    const src = args[0].list.items;
    const start_raw = args[1].int;
    const end_raw = args[2].int;
    if (start_raw < 0 or end_raw < 0) return value.RuntimeError.InvalidIndex;
    const start: usize = @intCast(start_raw);
    const end: usize = @intCast(end_raw);
    if (start > src.len or end > src.len or start > end) return value.RuntimeError.InvalidIndex;

    var out: std.ArrayListUnmanaged(value.Value) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, end - start);
    for (src[start..end]) |item| {
        out.appendAssumeCapacity(try item.clone(allocator));
    }

    return .{ .list = out };
}

// ---------------------------------------------------------------------------
// distinct
// ---------------------------------------------------------------------------

fn evalDistinct(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .list) return value.RuntimeError.TypeMismatch;
    const src = args[0].list.items;

    var out: std.ArrayListUnmanaged(value.Value) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }

    for (src) |item| {
        var found = false;
        for (out.items) |existing| {
            if (item.eql(existing)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try out.append(allocator, try item.clone(allocator));
        }
    }

    return .{ .list = out };
}

// ---------------------------------------------------------------------------
// list.range
// ---------------------------------------------------------------------------

fn evalRange(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .int) return value.RuntimeError.TypeMismatch;
    const n = args[0].int;
    if (n < 0) return value.RuntimeError.InvalidIndex;
    const count: usize = @intCast(n);

    var out: std.ArrayListUnmanaged(value.Value) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, count);
    for (0..count) |i| {
        out.appendAssumeCapacity(.{ .int = @intCast(i) });
    }

    return .{ .list = out };
}

// ---------------------------------------------------------------------------
// reverse
// ---------------------------------------------------------------------------

fn matchReverse(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 1) return null;
    return if (isListLike(environment, params[0])) params[0] else null;
}

fn evalReverse(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .list) return value.RuntimeError.TypeMismatch;
    const src = args[0].list.items;

    var out: std.ArrayListUnmanaged(value.Value) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, src.len);

    var i: usize = src.len;
    while (i > 0) {
        i -= 1;
        out.appendAssumeCapacity(try src[i].clone(allocator));
    }

    return .{ .list = out };
}

fn evalListIsSorted(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1 or args[0] != .list) return value.RuntimeError.TypeMismatch;
    const items = args[0].list.items;
    if (items.len < 2) return .{ .bool = true };
    var prev = items[0];
    for (items[1..]) |item| {
        if ((try compareOrderedValues(prev, item)) == .gt) return .{ .bool = false };
        prev = item;
    }
    return .{ .bool = true };
}

fn evalListSum(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1 or args[0] != .list) return value.RuntimeError.TypeMismatch;
    const items = args[0].list.items;
    if (items.len == 0) return .{ .int = 0 };

    var acc = items[0];
    for (items[1..]) |item| {
        acc = try addSummableValues(acc, item);
    }
    return switch (acc) {
        .int, .uint, .double, .duration => acc,
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalListMin(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .list) return value.RuntimeError.TypeMismatch;
    const items = args[0].list.items;
    if (items.len == 0) return value.RuntimeError.TypeMismatch;
    var best = items[0];
    for (items[1..]) |item| {
        if ((try compareOrderedValues(item, best)) == .lt) best = item;
    }
    return best.clone(allocator);
}

fn evalListMax(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .list) return value.RuntimeError.TypeMismatch;
    const items = args[0].list.items;
    if (items.len == 0) return value.RuntimeError.TypeMismatch;
    var best = items[0];
    for (items[1..]) |item| {
        if ((try compareOrderedValues(item, best)) == .gt) best = item;
    }
    return best.clone(allocator);
}

fn evalListIndexOf(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 2 or args[0] != .list) return value.RuntimeError.TypeMismatch;
    for (args[0].list.items, 0..) |item, i| {
        if (valuesEqual(item, args[1])) return .{ .int = @intCast(i) };
    }
    return .{ .int = -1 };
}

fn evalListLastIndexOf(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 2 or args[0] != .list) return value.RuntimeError.TypeMismatch;
    var i = args[0].list.items.len;
    while (i > 0) {
        i -= 1;
        if (valuesEqual(args[0].list.items[i], args[1])) return .{ .int = @intCast(i) };
    }
    return .{ .int = -1 };
}

fn evalListSetAtIndex(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 3 or args[0] != .list or args[1] != .int) return value.RuntimeError.TypeMismatch;
    const src = args[0].list.items;
    const idx = args[1].int;
    if (idx < 0 or idx >= src.len) return value.RuntimeError.InvalidIndex;

    var out: std.ArrayListUnmanaged(value.Value) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, src.len);
    for (src, 0..) |item, i| {
        if (i == @as(usize, @intCast(idx))) {
            out.appendAssumeCapacity(try args[2].clone(allocator));
        } else {
            out.appendAssumeCapacity(try item.clone(allocator));
        }
    }
    return .{ .list = out };
}

fn evalListInsertAtIndex(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 3 or args[0] != .list or args[1] != .int) return value.RuntimeError.TypeMismatch;
    const src = args[0].list.items;
    const idx = args[1].int;
    if (idx < 0 or idx > src.len) return value.RuntimeError.InvalidIndex;
    const index: usize = @intCast(idx);

    var out: std.ArrayListUnmanaged(value.Value) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, src.len + 1);
    for (src, 0..) |item, i| {
        if (i == index) out.appendAssumeCapacity(try args[2].clone(allocator));
        out.appendAssumeCapacity(try item.clone(allocator));
    }
    if (index == src.len) out.appendAssumeCapacity(try args[2].clone(allocator));
    return .{ .list = out };
}

fn evalListRemoveAtIndex(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 2 or args[0] != .list or args[1] != .int) return value.RuntimeError.TypeMismatch;
    const src = args[0].list.items;
    const idx = args[1].int;
    if (idx < 0 or idx >= src.len) return value.RuntimeError.InvalidIndex;

    var out: std.ArrayListUnmanaged(value.Value) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, src.len - 1);
    for (src, 0..) |item, i| {
        if (i == @as(usize, @intCast(idx))) continue;
        out.appendAssumeCapacity(try item.clone(allocator));
    }
    return .{ .list = out };
}

fn compareOrderedValues(lhs: value.Value, rhs: value.Value) value.RuntimeError!std.math.Order {
    if (isNumericValue(lhs) and isNumericValue(rhs)) return compareNumericValues(lhs, rhs);
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return value.RuntimeError.TypeMismatch;
    return switch (lhs) {
        .bool => std.math.order(@intFromBool(lhs.bool), @intFromBool(rhs.bool)),
        .string => std.mem.order(u8, lhs.string, rhs.string),
        .bytes => std.mem.order(u8, lhs.bytes, rhs.bytes),
        .timestamp => blk: {
            const sec_order = std.math.order(lhs.timestamp.seconds, rhs.timestamp.seconds);
            if (sec_order != .eq) break :blk sec_order;
            break :blk std.math.order(lhs.timestamp.nanos, rhs.timestamp.nanos);
        },
        .duration => blk: {
            const sec_order = std.math.order(lhs.duration.seconds, rhs.duration.seconds);
            if (sec_order != .eq) break :blk sec_order;
            break :blk std.math.order(lhs.duration.nanos, rhs.duration.nanos);
        },
        else => value.RuntimeError.TypeMismatch,
    };
}

fn addSummableValues(lhs: value.Value, rhs: value.Value) value.RuntimeError!value.Value {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return value.RuntimeError.TypeMismatch;
    return switch (lhs) {
        .int => .{ .int = std.math.add(i64, lhs.int, rhs.int) catch return value.RuntimeError.Overflow },
        .uint => .{ .uint = std.math.add(u64, lhs.uint, rhs.uint) catch return value.RuntimeError.Overflow },
        .double => .{ .double = lhs.double + rhs.double },
        .duration => .{ .duration = cel_time.addDurations(lhs.duration, rhs.duration) catch return value.RuntimeError.Overflow },
        else => value.RuntimeError.TypeMismatch,
    };
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
    return (compareNumericValues(lhs, rhs) catch return false) == .eq;
}

fn compareNumericValues(lhs: value.Value, rhs: value.Value) value.RuntimeError!std.math.Order {
    return switch (lhs) {
        .int => |left| switch (rhs) {
            .int => std.math.order(left, rhs.int),
            .uint => if (left < 0) .lt else std.math.order(@as(u64, @intCast(left)), rhs.uint),
            .double => std.math.order(@as(f64, @floatFromInt(left)), rhs.double),
            else => value.RuntimeError.TypeMismatch,
        },
        .uint => |left| switch (rhs) {
            .int => if (rhs.int < 0) .gt else std.math.order(left, @as(u64, @intCast(rhs.int))),
            .uint => std.math.order(left, rhs.uint),
            .double => std.math.order(@as(f64, @floatFromInt(left)), rhs.double),
            else => value.RuntimeError.TypeMismatch,
        },
        .double => |left| switch (rhs) {
            .int => std.math.order(left, @as(f64, @floatFromInt(rhs.int))),
            .uint => std.math.order(left, @as(f64, @floatFromInt(rhs.uint))),
            .double => std.math.order(left, rhs.double),
            else => value.RuntimeError.TypeMismatch,
        },
        else => value.RuntimeError.TypeMismatch,
    };
}

fn matchZip(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 2) return null;
    const t = environment.types.builtins;
    const spec0 = environment.types.spec(params[0]);
    const spec1 = environment.types.spec(params[1]);
    if ((spec0 != .list and spec0 != .dyn) or (spec1 != .list and spec1 != .dyn)) return null;
    const inner = environment.types.listOf(t.dyn_type) catch return null;
    return environment.types.listOf(inner) catch null;
}

fn evalZip(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 2 or args[0] != .list or args[1] != .list)
        return value.RuntimeError.TypeMismatch;

    const list0 = args[0].list.items;
    const list1 = args[1].list.items;
    const len = @min(list0.len, list1.len);

    var out: std.ArrayListUnmanaged(value.Value) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, len);

    for (0..len) |i| {
        var pair: std.ArrayListUnmanaged(value.Value) = .empty;
        errdefer {
            for (pair.items) |*item| item.deinit(allocator);
            pair.deinit(allocator);
        }
        try pair.ensureTotalCapacity(allocator, 2);
        pair.appendAssumeCapacity(try list0[i].clone(allocator));
        errdefer pair.items[0].deinit(allocator);
        pair.appendAssumeCapacity(try list1[i].clone(allocator));
        out.appendAssumeCapacity(.{ .list = pair });
    }

    return .{ .list = out };
}

// ===========================================================================
// Tests
// ===========================================================================

const compile_mod = @import("../compiler/compile.zig");
const eval_impl = @import("../eval/eval.zig");
const Activation = @import("../eval/activation.zig").Activation;

test "list.sort returns sorted list" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(list_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected_ints: []const i64 }{
        .{ .expr = "[3,1,2].sort()", .expected_ints = &.{ 1, 2, 3 } },
        .{ .expr = "[1].sort()", .expected_ints = &.{1} },
        .{ .expr = "[].sort()", .expected_ints = &.{} },
        .{ .expr = "[5,3,5,1].sort()", .expected_ints = &.{ 1, 3, 5, 5 } },
        .{ .expr = "[10,0,-5,7,-3].sort()", .expected_ints = &.{ -5, -3, 0, 7, 10 } },
        .{ .expr = "[1,1,1].sort()", .expected_ints = &.{ 1, 1, 1 } },
        .{ .expr = "[2,1].sort()", .expected_ints = &.{ 1, 2 } },
    };
    for (cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected_ints.len, result.list.items.len);
        for (case.expected_ints, 0..) |exp, i| {
            try std.testing.expectEqual(exp, result.list.items[i].int);
        }
    }
}

test "list.sort with strings" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(list_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var program = try compile_mod.compile(std.testing.allocator, &environment, "['c','a','b'].sort()");
    defer program.deinit();
    var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.list.items.len);
    try std.testing.expectEqualStrings("a", result.list.items[0].string);
    try std.testing.expectEqualStrings("b", result.list.items[1].string);
    try std.testing.expectEqualStrings("c", result.list.items[2].string);
}

test "list.flatten flattens one level" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(list_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected_ints: []const i64 }{
        .{ .expr = "[[1,2],[3,4]].flatten()", .expected_ints = &.{ 1, 2, 3, 4 } },
        .{ .expr = "[].flatten()", .expected_ints = &.{} },
        .{ .expr = "[[1],[],[2,3]].flatten()", .expected_ints = &.{ 1, 2, 3 } },
        .{ .expr = "[[1]].flatten()", .expected_ints = &.{1} },
        .{ .expr = "[[]].flatten()", .expected_ints = &.{} },
    };
    for (cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected_ints.len, result.list.items.len);
        for (case.expected_ints, 0..) |exp, i| {
            try std.testing.expectEqual(exp, result.list.items[i].int);
        }
    }
}

test "list.flatten supports explicit depth" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(list_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_][]const u8{
        "[1,[2,[3,[4]]]].flatten(2) == [1,2,3,[4]]",
        "[1,[2,[3,[4]]]].flatten(0) == [1,[2,[3,[4]]]]",
    };
    for (cases) |expr| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.bool);
    }

    var bad_program = try compile_mod.compile(std.testing.allocator, &environment, "[1,[2]].flatten(-1)");
    defer bad_program.deinit();
    try std.testing.expectError(
        value.RuntimeError.InvalidIndex,
        eval_impl.evalWithOptions(std.testing.allocator, &bad_program, &activation, .{}),
    );
}

test "list.flatten with non-list elements passes through" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(list_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var program = try compile_mod.compile(std.testing.allocator, &environment, "[1,[2,3],4].flatten()");
    defer program.deinit();
    var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), result.list.items.len);
    try std.testing.expectEqual(@as(i64, 1), result.list.items[0].int);
    try std.testing.expectEqual(@as(i64, 2), result.list.items[1].int);
    try std.testing.expectEqual(@as(i64, 3), result.list.items[2].int);
    try std.testing.expectEqual(@as(i64, 4), result.list.items[3].int);
}

test "list.slice returns sub-list" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(list_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected_ints: []const i64 }{
        .{ .expr = "[1,2,3,4].slice(1, 3)", .expected_ints = &.{ 2, 3 } },
        .{ .expr = "[1,2,3,4].slice(0, 4)", .expected_ints = &.{ 1, 2, 3, 4 } },
        .{ .expr = "[1,2,3,4].slice(0, 0)", .expected_ints = &.{} },
        .{ .expr = "[1,2,3,4].slice(2, 2)", .expected_ints = &.{} },
        .{ .expr = "[1,2,3].slice(0, 1)", .expected_ints = &.{1} },
        .{ .expr = "[1,2,3].slice(2, 3)", .expected_ints = &.{3} },
        .{ .expr = "[10,20,30,40,50].slice(1, 4)", .expected_ints = &.{ 20, 30, 40 } },
    };
    for (cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected_ints.len, result.list.items.len);
        for (case.expected_ints, 0..) |exp, i| {
            try std.testing.expectEqual(exp, result.list.items[i].int);
        }
    }
}

test "list.distinct deduplicates" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(list_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected_ints: []const i64 }{
        .{ .expr = "[1,2,1,3,2].distinct()", .expected_ints = &.{ 1, 2, 3 } },
        .{ .expr = "[].distinct()", .expected_ints = &.{} },
        .{ .expr = "[1].distinct()", .expected_ints = &.{1} },
        .{ .expr = "[1,1,1].distinct()", .expected_ints = &.{1} },
        .{ .expr = "[3,2,1].distinct()", .expected_ints = &.{ 3, 2, 1 } },
        .{ .expr = "[1,2,3,1,2,3].distinct()", .expected_ints = &.{ 1, 2, 3 } },
    };
    for (cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected_ints.len, result.list.items.len);
        for (case.expected_ints, 0..) |exp, i| {
            try std.testing.expectEqual(exp, result.list.items[i].int);
        }
    }
}

test "list.range generates sequence" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(list_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected_ints: []const i64 }{
        .{ .expr = "list.range(5)", .expected_ints = &.{ 0, 1, 2, 3, 4 } },
        .{ .expr = "lists.range(0)", .expected_ints = &.{} },
        .{ .expr = "lists.range(1)", .expected_ints = &.{0} },
        .{ .expr = "lists.range(3)", .expected_ints = &.{ 0, 1, 2 } },
    };
    for (cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected_ints.len, result.list.items.len);
        for (case.expected_ints, 0..) |exp, i| {
            try std.testing.expectEqual(exp, result.list.items[i].int);
        }
    }
}

test "list.first and last return optionals" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(@import("stdlib.zig").standard_library);
    try environment.addLibrary(list_library);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_][]const u8{
        "[1, 2, 3].first().value() == 1",
        "[1, 2, 3].last().value() == 3",
        "[].first().hasValue() == false",
        "[].last().hasValue() == false",
    };
    for (cases) |expr| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.bool);
    }
}

test "list.sortBy orders by computed keys" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(list_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_][]const u8{
        "[3, 1, 2].sortBy(x, x) == [1, 2, 3]",
        "[3, 1, 2].sortBy(x, -x) == [3, 2, 1]",
    };
    for (cases) |expr| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.bool);
    }

    var bad_program = try compile_mod.compile(std.testing.allocator, &environment, "[1, 'a'].sortBy(x, x)");
    defer bad_program.deinit();
    try std.testing.expectError(
        value.RuntimeError.TypeMismatch,
        eval_impl.evalWithOptions(std.testing.allocator, &bad_program, &activation, .{}),
    );
}

test "list.reverse reverses list" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(list_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected_ints: []const i64 }{
        .{ .expr = "[3,1,2].reverse()", .expected_ints = &.{ 2, 1, 3 } },
        .{ .expr = "[].reverse()", .expected_ints = &.{} },
        .{ .expr = "[1].reverse()", .expected_ints = &.{1} },
        .{ .expr = "[5,4,3,2,1].reverse()", .expected_ints = &.{ 1, 2, 3, 4, 5 } },
        .{ .expr = "[1,1,1].reverse()", .expected_ints = &.{ 1, 1, 1 } },
        .{ .expr = "[10,20].reverse()", .expected_ints = &.{ 20, 10 } },
    };
    for (cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected_ints.len, result.list.items.len);
        for (case.expected_ints, 0..) |exp, i| {
            try std.testing.expectEqual(exp, result.list.items[i].int);
        }
    }
}

test "list ext covers sortedness aggregates and search" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(list_library);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_][]const u8{
        "[1, 2, 3].isSorted()",
        "[1, 3].sum() == 4",
        "[1, 3].min() == 1",
        "[1, 3].max() == 3",
        "[1, 2, 2, 3].indexOf(2) == 1",
        "['a', 'b', 'b', 'c'].lastIndexOf('b') == 2",
    };
    for (cases) |expr| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.bool);
    }
}

test "list mutation helpers cover updates append and invalid indices" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(list_library);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const ok_cases = [_][]const u8{
        "lists.setAtIndex([1, 2, 3], 1, 99) == [1, 99, 3]",
        "lists.insertAtIndex([1, 2, 3], 1, 99) == [1, 99, 2, 3]",
        "lists.insertAtIndex([1, 2], 2, 3) == [1, 2, 3]",
        "lists.removeAtIndex([1, 2, 3], 1) == [1, 3]",
    };
    for (ok_cases) |expr| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.bool);
    }

    const invalid_cases = [_][]const u8{
        "lists.setAtIndex([1], -1, 0)",
        "lists.insertAtIndex([1, 2], 3, 0)",
        "lists.removeAtIndex([1], 1)",
    };
    for (invalid_cases) |expr| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        try std.testing.expectError(value.RuntimeError.InvalidIndex, eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{}));
    }
}

test "list.zip pairs elements from two lists" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(list_library);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_][]const u8{
        "[1, 2, 3].zip([4, 5, 6]) == [[1, 4], [2, 5], [3, 6]]",
        "[1, 2].zip([3, 4, 5]) == [[1, 3], [2, 4]]",
        "[1, 2, 3].zip([4]) == [[1, 4]]",
        "[].zip([1, 2]) == []",
        "[1].zip([]) == []",
        "[].zip([]) == []",
        "['a', 'b'].zip([1, 2]) == [['a', 1], ['b', 2]]",
    };
    for (cases) |expr| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.bool);
    }
}
