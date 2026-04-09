const std = @import("std");
const appendFormat = @import("../util/fmt.zig").appendFormat;
const cel_env = @import("../env/env.zig");
const cel_time = @import("cel_time.zig");
const types = @import("../env/types.zig");
const value = @import("../env/value.zig");

extern "c" fn snprintf(str: ?[*]u8, size: usize, format: [*:0]const u8, ...) c_int;

pub const string_library = cel_env.Library{
    .name = "cel.lib.ext.strings",
    .install = installStringLibrary,
};

pub const math_library = cel_env.Library{
    .name = "cel.lib.ext.math",
    .install = installMathLibrary,
};

pub const proto_library = cel_env.Library{
    .name = "cel.lib.ext.proto",
    .install = installProtoLibrary,
};

pub fn installStringLibrary(environment: *cel_env.Env) !void {
    const t = environment.types.builtins;
    const list_string = try environment.types.listOf(t.string_type);

    _ = try environment.addFunction("charAt", true, &.{ t.string_type, t.int_type }, t.string_type, evalCharAt);
    _ = try environment.addFunction("indexOf", true, &.{ t.string_type, t.string_type }, t.int_type, evalIndexOf);
    _ = try environment.addFunction("indexOf", true, &.{ t.string_type, t.string_type, t.int_type }, t.int_type, evalIndexOfFrom);
    _ = try environment.addFunction("lastIndexOf", true, &.{ t.string_type, t.string_type }, t.int_type, evalLastIndexOf);
    _ = try environment.addFunction("lastIndexOf", true, &.{ t.string_type, t.string_type, t.int_type }, t.int_type, evalLastIndexOfFrom);
    _ = try environment.addFunction("lowerAscii", true, &.{t.string_type}, t.string_type, evalLowerAscii);
    _ = try environment.addFunction("upperAscii", true, &.{t.string_type}, t.string_type, evalUpperAscii);
    _ = try environment.addFunction("replace", true, &.{ t.string_type, t.string_type, t.string_type }, t.string_type, evalReplaceAll);
    _ = try environment.addFunction("replace", true, &.{ t.string_type, t.string_type, t.string_type, t.int_type }, t.string_type, evalReplaceN);
    _ = try environment.addFunction("split", true, &.{ t.string_type, t.string_type }, list_string, evalSplit);
    _ = try environment.addFunction("split", true, &.{ t.string_type, t.string_type, t.int_type }, list_string, evalSplitN);
    _ = try environment.addFunction("substring", true, &.{ t.string_type, t.int_type }, t.string_type, evalSubstringFrom);
    _ = try environment.addFunction("substring", true, &.{ t.string_type, t.int_type, t.int_type }, t.string_type, evalSubstringRange);
    _ = try environment.addFunction("trim", true, &.{t.string_type}, t.string_type, evalTrim);
    _ = try environment.addFunction("reverse", true, &.{t.string_type}, t.string_type, evalReverse);
    _ = try environment.addFunction("strings.quote", false, &.{t.string_type}, t.string_type, evalQuote);

    _ = try environment.addDynamicFunction("join", true, matchJoin, evalJoin);
    _ = try environment.addDynamicFunction("format", true, matchFormat, evalFormat);
}

pub fn installMathLibrary(environment: *cel_env.Env) !void {
    _ = try environment.addDynamicFunction("math.greatest", false, matchMathGreatestLeast, evalMathGreatest);
    _ = try environment.addDynamicFunction("math.least", false, matchMathGreatestLeast, evalMathLeast);
    _ = try environment.addDynamicFunction("math.ceil", false, matchMathUnaryDouble, evalMathCeil);
    _ = try environment.addDynamicFunction("math.floor", false, matchMathUnaryDouble, evalMathFloor);
    _ = try environment.addDynamicFunction("math.round", false, matchMathUnaryDouble, evalMathRound);
    _ = try environment.addDynamicFunction("math.trunc", false, matchMathUnaryDouble, evalMathTrunc);
    _ = try environment.addDynamicFunction("math.sqrt", false, matchMathSqrt, evalMathSqrt);
    _ = try environment.addDynamicFunction("math.abs", false, matchMathAbs, evalMathAbs);
    _ = try environment.addDynamicFunction("math.sign", false, matchMathSign, evalMathSign);
    _ = try environment.addDynamicFunction("math.isNaN", false, matchMathUnaryPredicate, evalMathIsNaN);
    _ = try environment.addDynamicFunction("math.isInf", false, matchMathUnaryPredicate, evalMathIsInf);
    _ = try environment.addDynamicFunction("math.isFinite", false, matchMathUnaryPredicate, evalMathIsFinite);
    _ = try environment.addDynamicFunction("math.bitAnd", false, matchMathBitwiseBinary, evalMathBitAnd);
    _ = try environment.addDynamicFunction("math.bitOr", false, matchMathBitwiseBinary, evalMathBitOr);
    _ = try environment.addDynamicFunction("math.bitXor", false, matchMathBitwiseBinary, evalMathBitXor);
    _ = try environment.addDynamicFunction("math.bitNot", false, matchMathBitNot, evalMathBitNot);
    _ = try environment.addDynamicFunction("math.bitShiftLeft", false, matchMathBitShift, evalMathBitShiftLeft);
    _ = try environment.addDynamicFunction("math.bitShiftRight", false, matchMathBitShift, evalMathBitShiftRight);
}

pub fn installProtoLibrary(environment: *cel_env.Env) !void {
    _ = try environment.addDynamicFunction("proto.hasExt", false, matchProtoExtPredicate, evalProtoHasExt);
    _ = try environment.addDynamicFunction("proto.getExt", false, matchProtoGetExt, evalProtoGetExt);
}

fn matchJoin(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    const t = environment.types.builtins;
    if (params.len != 1 and params.len != 2) return null;
    if (!isListLike(environment, params[0])) return null;
    if (params.len == 2 and !isTypeOrDyn(environment, params[1], t.string_type)) return null;
    return t.string_type;
}

fn matchFormat(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    const t = environment.types.builtins;
    if (params.len != 2) return null;
    if (!isTypeOrDyn(environment, params[0], t.string_type)) return null;
    const arg_spec = environment.types.spec(params[1]);
    if (arg_spec != .dyn and arg_spec != .list) return null;
    return t.string_type;
}

fn matchMathGreatestLeast(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len == 0) return null;
    if (params.len == 1) {
        switch (environment.types.spec(params[0])) {
            .list => |elem_ty| {
                if (environment.types.isNumeric(elem_ty)) return elem_ty;
                if (environment.types.spec(elem_ty) == .dyn) return environment.types.builtins.dyn_type;
                return null;
            },
            .dyn => return environment.types.builtins.dyn_type,
            else => {},
        }
    }
    var saw_dyn = false;
    const first = params[0];
    if (!isNumericOrDyn(environment, first)) return null;
    for (params[1..]) |param| {
        if (!isNumericOrDyn(environment, param)) return null;
        if (param != first) saw_dyn = true;
        if (environment.types.spec(param) == .dyn) saw_dyn = true;
    }
    if (environment.types.spec(first) == .dyn or saw_dyn) return environment.types.builtins.dyn_type;
    return first;
}

fn matchMathUnaryDouble(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 1) return null;
    if (!isTypeOrDyn(environment, params[0], environment.types.builtins.double_type)) return null;
    return environment.types.builtins.double_type;
}

fn matchMathAbs(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 1) return null;
    const t = environment.types.builtins;
    if (params[0] == t.int_type or params[0] == t.uint_type or params[0] == t.double_type) return params[0];
    if (environment.types.spec(params[0]) == .dyn) return t.dyn_type;
    return null;
}

fn matchMathSqrt(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 1) return null;
    const t = environment.types.builtins;
    if (params[0] == t.int_type or params[0] == t.uint_type or params[0] == t.double_type) return t.double_type;
    if (environment.types.spec(params[0]) == .dyn) return t.dyn_type;
    return null;
}

fn matchMathSign(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    return matchMathAbs(environment, params);
}

fn matchMathUnaryPredicate(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 1) return null;
    if (!isTypeOrDyn(environment, params[0], environment.types.builtins.double_type)) return null;
    return environment.types.builtins.bool_type;
}

fn matchMathBitwiseBinary(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 2) return null;
    const t = environment.types.builtins;
    if (params[0] == t.int_type and params[1] == t.int_type) return t.int_type;
    if (params[0] == t.uint_type and params[1] == t.uint_type) return t.uint_type;
    if (environment.types.spec(params[0]) == .dyn or environment.types.spec(params[1]) == .dyn) return t.dyn_type;
    return null;
}

fn matchMathBitNot(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 1) return null;
    const t = environment.types.builtins;
    if (params[0] == t.int_type or params[0] == t.uint_type) return params[0];
    if (environment.types.spec(params[0]) == .dyn) return t.dyn_type;
    return null;
}

fn matchMathBitShift(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 2) return null;
    const t = environment.types.builtins;
    const lhs_dyn = environment.types.spec(params[0]) == .dyn;
    const rhs_dyn = environment.types.spec(params[1]) == .dyn;
    if (!lhs_dyn and params[0] != t.int_type and params[0] != t.uint_type) return null;
    if (!rhs_dyn and params[1] != t.int_type) return null;
    if (lhs_dyn or rhs_dyn) return t.dyn_type;
    return params[0];
}

fn matchProtoExtPredicate(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 2) return null;
    if (!isMessageLike(environment, params[0])) return null;
    if (!isTypeOrDyn(environment, params[1], environment.types.builtins.string_type)) return null;
    return environment.types.builtins.bool_type;
}

fn matchProtoGetExt(environment: *const cel_env.Env, params: []const types.TypeRef) ?types.TypeRef {
    if (params.len != 2) return null;
    if (!isMessageLike(environment, params[0])) return null;
    if (!isTypeOrDyn(environment, params[1], environment.types.builtins.string_type)) return null;
    return environment.types.builtins.dyn_type;
}

fn isTypeOrDyn(environment: *const cel_env.Env, actual: types.TypeRef, expected: types.TypeRef) bool {
    const spec = environment.types.spec(actual);
    return actual == expected or spec == .dyn;
}

fn isNumericOrDyn(environment: *const cel_env.Env, actual: types.TypeRef) bool {
    return environment.types.isNumeric(actual) or environment.types.spec(actual) == .dyn;
}

fn isListLike(environment: *const cel_env.Env, actual: types.TypeRef) bool {
    return switch (environment.types.spec(actual)) {
        .list, .dyn => true,
        else => false,
    };
}

fn isMessageLike(environment: *const cel_env.Env, actual: types.TypeRef) bool {
    return switch (environment.types.spec(actual)) {
        .message, .dyn => true,
        else => false,
    };
}

fn evalProtoHasExt(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 2 or args[0] != .message or args[1] != .string) return value.RuntimeError.TypeMismatch;
    for (args[0].message.fields.items) |field| {
        if (std.mem.eql(u8, field.name, args[1].string)) return .{ .bool = true };
    }
    return .{ .bool = false };
}

fn evalProtoGetExt(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 2 or args[0] != .message or args[1] != .string) return value.RuntimeError.TypeMismatch;
    for (args[0].message.fields.items) |field| {
        if (std.mem.eql(u8, field.name, args[1].string)) return field.value.clone(allocator);
    }
    return value.RuntimeError.NoSuchField;
}

fn evalCharAt(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 2 or args[0] != .string or args[1] != .int) return value.RuntimeError.TypeMismatch;
    const count = try codepointCount(args[0].string);
    const index = try normalizeCodepointIndex(args[1].int, count, true);
    if (index == count) return value.string(allocator, "");
    const start = try byteOffsetForCodepointIndex(args[0].string, index);
    const end = try byteOffsetForCodepointIndex(args[0].string, index + 1);
    return value.string(allocator, args[0].string[start..end]);
}

fn evalIndexOf(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 2) return value.RuntimeError.NoMatchingOverload;
    return evalIndexOfImpl(args[0], args[1], null);
}

fn evalIndexOfFrom(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 3) return value.RuntimeError.NoMatchingOverload;
    return evalIndexOfImpl(args[0], args[1], args[2]);
}

fn evalIndexOfImpl(text_val: value.Value, needle_val: value.Value, from_val: ?value.Value) cel_env.EvalError!value.Value {
    if (text_val != .string or needle_val != .string) return value.RuntimeError.TypeMismatch;
    const total = try codepointCount(text_val.string);
    const start: usize = if (from_val) |from| blk: {
        if (from != .int) return value.RuntimeError.TypeMismatch;
        break :blk try normalizeCodepointIndex(from.int, total, true);
    } else 0;
    return .{ .int = try indexOfCodepoints(text_val.string, needle_val.string, start) };
}

fn evalLastIndexOf(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 2) return value.RuntimeError.NoMatchingOverload;
    return evalLastIndexOfImpl(args[0], args[1], null);
}

fn evalLastIndexOfFrom(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 3) return value.RuntimeError.NoMatchingOverload;
    return evalLastIndexOfImpl(args[0], args[1], args[2]);
}

fn evalLastIndexOfImpl(text_val: value.Value, needle_val: value.Value, from_val: ?value.Value) cel_env.EvalError!value.Value {
    if (text_val != .string or needle_val != .string) return value.RuntimeError.TypeMismatch;
    const total = try codepointCount(text_val.string);
    const from_index: ?usize = if (from_val) |from| blk: {
        if (from != .int) return value.RuntimeError.TypeMismatch;
        break :blk try normalizeCodepointIndex(from.int, total, true);
    } else null;
    return .{ .int = try lastIndexOfCodepoints(text_val.string, needle_val.string, from_index) };
}

fn evalLowerAscii(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    const out = try allocator.alloc(u8, args[0].string.len);
    for (args[0].string, 0..) |ch, i| {
        out[i] = if (ch >= 'A' and ch <= 'Z') ch + ('a' - 'A') else ch;
    }
    return .{ .string = out };
}

fn evalUpperAscii(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    const out = try allocator.alloc(u8, args[0].string.len);
    for (args[0].string, 0..) |ch, i| {
        out[i] = if (ch >= 'a' and ch <= 'z') ch - ('a' - 'A') else ch;
    }
    return .{ .string = out };
}

fn evalReplaceAll(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 3) return value.RuntimeError.NoMatchingOverload;
    return evalReplaceImpl(allocator, args[0], args[1], args[2], null);
}

fn evalReplaceN(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 4) return value.RuntimeError.NoMatchingOverload;
    return evalReplaceImpl(allocator, args[0], args[1], args[2], args[3]);
}

fn evalReplaceImpl(
    allocator: std.mem.Allocator,
    text_val: value.Value,
    needle_val: value.Value,
    repl_val: value.Value,
    count_val: ?value.Value,
) cel_env.EvalError!value.Value {
    if (text_val != .string or needle_val != .string or repl_val != .string) return value.RuntimeError.TypeMismatch;
    const limit: ?usize = if (count_val) |count| blk: {
        if (count != .int) return value.RuntimeError.TypeMismatch;
        if (count.int < 0) break :blk null;
        break :blk @as(usize, @intCast(count.int));
    } else null;
    return .{ .string = try replaceString(allocator, text_val.string, needle_val.string, repl_val.string, limit) };
}

fn evalSplit(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 2) return value.RuntimeError.NoMatchingOverload;
    return .{ .list = try splitString(allocator, args[0], args[1], null) };
}

fn evalSplitN(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 3) return value.RuntimeError.NoMatchingOverload;
    return .{ .list = try splitString(allocator, args[0], args[1], args[2]) };
}

fn evalSubstringFrom(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 2) return value.RuntimeError.NoMatchingOverload;
    return evalSubstringImpl(allocator, args[0], args[1], null);
}

fn evalSubstringRange(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 3) return value.RuntimeError.NoMatchingOverload;
    return evalSubstringImpl(allocator, args[0], args[1], args[2]);
}

fn evalSubstringImpl(
    allocator: std.mem.Allocator,
    text_val: value.Value,
    start_val: value.Value,
    end_val: ?value.Value,
) cel_env.EvalError!value.Value {
    if (text_val != .string or start_val != .int) return value.RuntimeError.TypeMismatch;
    const total = try codepointCount(text_val.string);
    const start = try normalizeCodepointIndex(start_val.int, total, true);
    const end = if (end_val) |raw_end| blk: {
        if (raw_end != .int) return value.RuntimeError.TypeMismatch;
        break :blk try normalizeCodepointIndex(raw_end.int, total, true);
    } else total;
    if (start > end) return value.RuntimeError.InvalidIndex;
    const start_byte = try byteOffsetForCodepointIndex(text_val.string, start);
    const end_byte = try byteOffsetForCodepointIndex(text_val.string, end);
    return value.string(allocator, text_val.string[start_byte..end_byte]);
}

fn evalTrim(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    const text = args[0].string;
    var start: usize = 0;
    while (start < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[start]) catch return value.RuntimeError.TypeMismatch;
        const cp = std.unicode.utf8Decode(text[start .. start + seq_len]) catch return value.RuntimeError.TypeMismatch;
        if (!isTrimSpace(cp)) break;
        start += seq_len;
    }

    var end: usize = text.len;
    while (end > start) {
        var prev = end - 1;
        while (prev > start and (text[prev] & 0b1100_0000) == 0b1000_0000) : (prev -= 1) {}
        const cp = std.unicode.utf8Decode(text[prev..end]) catch return value.RuntimeError.TypeMismatch;
        if (!isTrimSpace(cp)) break;
        end = prev;
    }
    return value.string(allocator, text[start..end]);
}

fn evalReverse(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    const text = args[0].string;
    const out = try allocator.alloc(u8, text.len);
    var src_end = text.len;
    var dst: usize = 0;
    while (src_end > 0) {
        var start = src_end - 1;
        while (start > 0 and (text[start] & 0b1100_0000) == 0b1000_0000) : (start -= 1) {}
        const slice = text[start..src_end];
        @memcpy(out[dst .. dst + slice.len], slice);
        dst += slice.len;
        src_end = start;
    }
    return .{ .string = out };
}

fn evalQuote(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    return .{ .string = try quoteString(allocator, args[0].string) };
}

fn evalJoin(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 and args.len != 2) return value.RuntimeError.TypeMismatch;
    if (args[0] != .list) return value.RuntimeError.TypeMismatch;
    const sep = if (args.len == 2) blk: {
        if (args[1] != .string) return value.RuntimeError.TypeMismatch;
        break :blk args[1].string;
    } else "";

    var total: usize = 0;
    for (args[0].list.items, 0..) |item, i| {
        if (item != .string) return value.RuntimeError.TypeMismatch;
        total += item.string.len;
        if (i != 0) total += sep.len;
    }

    const out = try allocator.alloc(u8, total);
    var cursor: usize = 0;
    for (args[0].list.items, 0..) |item, i| {
        if (i != 0) {
            @memcpy(out[cursor .. cursor + sep.len], sep);
            cursor += sep.len;
        }
        @memcpy(out[cursor .. cursor + item.string.len], item.string);
        cursor += item.string.len;
    }
    return .{ .string = out };
}

fn evalFormat(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 2 or args[0] != .string or args[1] != .list) return value.RuntimeError.TypeMismatch;
    return .{ .string = try formatString(allocator, args[0].string, args[1].list.items) };
}

fn evalMathGreatest(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    return evalGreatestLeast(allocator, args, .greatest);
}

fn evalMathLeast(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    return evalGreatestLeast(allocator, args, .least);
}

fn evalMathCeil(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1 or args[0] != .double) return value.RuntimeError.TypeMismatch;
    return .{ .double = std.math.ceil(args[0].double) };
}

fn evalMathFloor(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1 or args[0] != .double) return value.RuntimeError.TypeMismatch;
    return .{ .double = std.math.floor(args[0].double) };
}

fn evalMathRound(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1 or args[0] != .double) return value.RuntimeError.TypeMismatch;
    return .{ .double = std.math.round(args[0].double) };
}

fn evalMathTrunc(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1 or args[0] != .double) return value.RuntimeError.TypeMismatch;
    return .{ .double = std.math.trunc(args[0].double) };
}

fn evalMathSqrt(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return switch (args[0]) {
        .double => .{ .double = std.math.sqrt(args[0].double) },
        .int => .{ .double = std.math.sqrt(@as(f64, @floatFromInt(args[0].int))) },
        .uint => .{ .double = std.math.sqrt(@as(f64, @floatFromInt(args[0].uint))) },
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalMathAbs(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return switch (args[0]) {
        .int => blk: {
            if (args[0].int == std.math.minInt(i64)) return value.RuntimeError.Overflow;
            break :blk .{ .int = if (args[0].int < 0) -args[0].int else args[0].int };
        },
        .uint => .{ .uint = args[0].uint },
        .double => .{ .double = @abs(args[0].double) },
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalMathSign(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return switch (args[0]) {
        .int => .{ .int = if (args[0].int > 0) 1 else if (args[0].int < 0) -1 else 0 },
        .uint => .{ .uint = if (args[0].uint == 0) 0 else 1 },
        .double => .{ .double = if (args[0].double > 0) 1 else if (args[0].double < 0) -1 else 0 },
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalMathIsNaN(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1 or args[0] != .double) return value.RuntimeError.TypeMismatch;
    return .{ .bool = std.math.isNan(args[0].double) };
}

fn evalMathIsInf(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1 or args[0] != .double) return value.RuntimeError.TypeMismatch;
    return .{ .bool = std.math.isInf(args[0].double) };
}

fn evalMathIsFinite(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1 or args[0] != .double) return value.RuntimeError.TypeMismatch;
    return .{ .bool = std.math.isFinite(args[0].double) };
}

fn evalMathBitAnd(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    return evalBitwiseBinary(args, .and_);
}

fn evalMathBitOr(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    return evalBitwiseBinary(args, .or_);
}

fn evalMathBitXor(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    return evalBitwiseBinary(args, .xor_);
}

fn evalMathBitNot(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return switch (args[0]) {
        .int => .{ .int = ~args[0].int },
        .uint => .{ .uint = ~args[0].uint },
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalMathBitShiftLeft(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    return evalBitShift(args, .left);
}

fn evalMathBitShiftRight(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    return evalBitShift(args, .right);
}

const GreatestLeastMode = enum {
    greatest,
    least,
};

const BitwiseBinaryMode = enum {
    and_,
    or_,
    xor_,
};

const BitShiftMode = enum {
    left,
    right,
};

const RenderedMapEntry = struct {
    key: []u8,
    value_ptr: *const value.Value,
};

fn evalGreatestLeast(
    allocator: std.mem.Allocator,
    args: []const value.Value,
    mode: GreatestLeastMode,
) cel_env.EvalError!value.Value {
    if (args.len == 0) return value.RuntimeError.TypeMismatch;
    const items: []const value.Value = blk: {
        if (args.len == 1 and args[0] == .list) {
            if (args[0].list.items.len == 0) return value.RuntimeError.TypeMismatch;
            break :blk args[0].list.items;
        }
        break :blk args;
    };

    var best = items[0];
    if (!isNumericValue(best)) return value.RuntimeError.TypeMismatch;
    for (items[1..]) |arg| {
        if (!isNumericValue(arg)) return value.RuntimeError.TypeMismatch;
        const cmp = compareNumbers(arg, best);
        if ((mode == .greatest and cmp == .gt) or (mode == .least and cmp == .lt)) {
            best = arg;
        }
    }
    return best.clone(allocator);
}

fn evalBitwiseBinary(args: []const value.Value, mode: BitwiseBinaryMode) cel_env.EvalError!value.Value {
    if (args.len != 2) return value.RuntimeError.TypeMismatch;
    return switch (args[0]) {
        .int => if (args[1] == .int) .{ .int = switch (mode) {
            .and_ => args[0].int & args[1].int,
            .or_ => args[0].int | args[1].int,
            .xor_ => args[0].int ^ args[1].int,
        } } else value.RuntimeError.TypeMismatch,
        .uint => if (args[1] == .uint) .{ .uint = switch (mode) {
            .and_ => args[0].uint & args[1].uint,
            .or_ => args[0].uint | args[1].uint,
            .xor_ => args[0].uint ^ args[1].uint,
        } } else value.RuntimeError.TypeMismatch,
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalBitShift(args: []const value.Value, mode: BitShiftMode) cel_env.EvalError!value.Value {
    if (args.len != 2 or args[1] != .int) return value.RuntimeError.TypeMismatch;
    if (args[1].int < 0) return value.RuntimeError.InvalidIndex;
    if (args[1].int >= 64) {
        return switch (args[0]) {
            .int => .{ .int = 0 },
            .uint => .{ .uint = 0 },
            else => value.RuntimeError.TypeMismatch,
        };
    }
    const shift: u6 = @intCast(args[1].int);
    return switch (args[0]) {
        .int => blk: {
            const bits: u64 = @bitCast(args[0].int);
            const shifted: u64 = switch (mode) {
                .left => bits << shift,
                .right => bits >> shift,
            };
            break :blk .{ .int = @bitCast(shifted) };
        },
        .uint => blk: {
            break :blk .{ .uint = switch (mode) {
                .left => args[0].uint << shift,
                .right => args[0].uint >> shift,
            } };
        },
        else => value.RuntimeError.TypeMismatch,
    };
}

fn replaceString(
    allocator: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
    replacement: []const u8,
    limit: ?usize,
) ![]u8 {
    if (needle.len == 0) return allocator.dupe(u8, haystack);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    var replaced: usize = 0;
    while (cursor < haystack.len) {
        if (limit) |max_replacements| {
            if (replaced >= max_replacements) break;
        }
        const next = std.mem.indexOfPos(u8, haystack, cursor, needle) orelse break;
        try out.appendSlice(allocator, haystack[cursor..next]);
        try out.appendSlice(allocator, replacement);
        cursor = next + needle.len;
        replaced += 1;
    }
    try out.appendSlice(allocator, haystack[cursor..]);
    return out.toOwnedSlice(allocator);
}

fn splitString(
    allocator: std.mem.Allocator,
    text_val: value.Value,
    sep_val: value.Value,
    count_val: ?value.Value,
) cel_env.EvalError!std.ArrayListUnmanaged(value.Value) {
    if (text_val != .string or sep_val != .string) return value.RuntimeError.TypeMismatch;
    const text = text_val.string;
    const sep = sep_val.string;
    const limit: ?i64 = if (count_val) |count| blk: {
        if (count != .int) return value.RuntimeError.TypeMismatch;
        break :blk count.int;
    } else null;

    var out: std.ArrayListUnmanaged(value.Value) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }

    if (limit) |n| {
        if (n == 0) return out;
        if (n == 1) {
            try out.append(allocator, try value.string(allocator, text));
            return out;
        }
    }

    if (sep.len == 0) {
        var count: usize = 0;
        var cursor: usize = 0;
        while (cursor < text.len) {
            if (limit) |n| {
                if (n > 0 and count + 1 >= @as(usize, @intCast(n))) {
                    try out.append(allocator, try value.string(allocator, text[cursor..]));
                    return out;
                }
            }
            const len = std.unicode.utf8ByteSequenceLength(text[cursor]) catch return value.RuntimeError.TypeMismatch;
            try out.append(allocator, try value.string(allocator, text[cursor .. cursor + len]));
            cursor += len;
            count += 1;
        }
        return out;
    }

    var cursor: usize = 0;
    var pieces: usize = 0;
    while (true) {
        if (limit) |n| {
            if (n > 0 and pieces + 1 >= @as(usize, @intCast(n))) break;
        }
        const next = std.mem.indexOfPos(u8, text, cursor, sep) orelse break;
        try out.append(allocator, try value.string(allocator, text[cursor..next]));
        cursor = next + sep.len;
        pieces += 1;
    }
    try out.append(allocator, try value.string(allocator, text[cursor..]));
    return out;
}

fn quoteString(allocator: std.mem.Allocator, text: []const u8) cel_env.EvalError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');

    var cursor: usize = 0;
    while (cursor < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[cursor]) catch return value.RuntimeError.TypeMismatch;
        const cp = std.unicode.utf8Decode(text[cursor .. cursor + len]) catch return value.RuntimeError.TypeMismatch;
        switch (cp) {
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x07 => try out.appendSlice(allocator, "\\a"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0b => try out.appendSlice(allocator, "\\v"),
            0x0c => try out.appendSlice(allocator, "\\f"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            else => {
                if (cp >= 0x20 and cp != 0x7f) {
                    try out.appendSlice(allocator, text[cursor .. cursor + len]);
                } else if (cp <= 0xff) {
                    try appendFormat(&out, allocator,"\\x{X:0>2}", .{@as(u8, @intCast(cp))});
                } else if (cp <= 0xffff) {
                    try appendFormat(&out, allocator,"\\u{X:0>4}", .{@as(u16, @intCast(cp))});
                } else {
                    try appendFormat(&out, allocator,"\\U{X:0>8}", .{@as(u32, cp)});
                }
            },
        }
        cursor += len;
    }

    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

fn formatString(
    allocator: std.mem.Allocator,
    template: []const u8,
    args: []const value.Value,
) cel_env.EvalError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    var arg_index: usize = 0;

    while (cursor < template.len) {
        if (template[cursor] != '%') {
            try out.append(allocator, template[cursor]);
            cursor += 1;
            continue;
        }
        cursor += 1;
        if (cursor >= template.len) return value.RuntimeError.TypeMismatch;
        if (template[cursor] == '%') {
            try out.append(allocator, '%');
            cursor += 1;
            continue;
        }

        var precision: ?usize = null;
        if (template[cursor] == '.') {
            cursor += 1;
            const digits_start = cursor;
            while (cursor < template.len and std.ascii.isDigit(template[cursor])) : (cursor += 1) {}
            if (digits_start == cursor) return value.RuntimeError.TypeMismatch;
            precision = std.fmt.parseInt(usize, template[digits_start..cursor], 10) catch return value.RuntimeError.TypeMismatch;
        }
        if (cursor >= template.len) return value.RuntimeError.TypeMismatch;
        const clause = template[cursor];
        cursor += 1;

        if (arg_index >= args.len) return value.RuntimeError.InvalidIndex;
        try formatArg(allocator, &out, clause, precision, args[arg_index]);
        arg_index += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn formatArg(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    clause: u8,
    precision: ?usize,
    arg: value.Value,
) cel_env.EvalError!void {
    switch (clause) {
        's' => try appendStringifiedValue(allocator, out, arg),
        'd' => try appendDecimalValue(allocator, out, arg),
        'b' => try appendBinaryValue(allocator, out, arg),
        'o' => try appendOctalValue(allocator, out, arg),
        'x', 'X' => try appendHexValue(allocator, out, clause == 'X', arg),
        'f' => try appendFloatValue(allocator, out, .decimal, precision, arg),
        'e' => try appendFloatValue(allocator, out, .scientific, precision, arg),
        else => return value.RuntimeError.TypeMismatch,
    }
}

fn appendStringifiedValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    arg: value.Value,
) cel_env.EvalError!void {
    switch (arg) {
        .int => try appendFormat(out, allocator,"{d}", .{arg.int}),
        .uint => try appendFormat(out, allocator,"{d}", .{arg.uint}),
        .double => {
            if (std.math.isNan(arg.double)) {
                try out.appendSlice(allocator, "NaN");
            } else if (std.math.isPositiveInf(arg.double)) {
                try out.appendSlice(allocator, "Infinity");
            } else if (std.math.isNegativeInf(arg.double)) {
                try out.appendSlice(allocator, "-Infinity");
            } else {
                try appendFormat(out, allocator,"{d}", .{arg.double});
            }
        },
        .bool => try out.appendSlice(allocator, if (arg.bool) "true" else "false"),
        .string => try out.appendSlice(allocator, arg.string),
        .bytes => {
            if (!std.unicode.utf8ValidateSlice(arg.bytes)) return value.RuntimeError.TypeMismatch;
            try out.appendSlice(allocator, arg.bytes);
        },
        .timestamp => {
            const text = try cel_time.formatTimestamp(allocator, arg.timestamp);
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
        .duration => {
            const text = try cel_time.formatDuration(allocator, arg.duration);
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
        .enum_value => try appendFormat(out, allocator,"{d}", .{arg.enum_value.value}),
        .host => return value.RuntimeError.TypeMismatch,
        .null => try out.appendSlice(allocator, "null"),
        .unknown => return value.RuntimeError.TypeMismatch,
        .optional => return value.RuntimeError.TypeMismatch,
        .type_name => try out.appendSlice(allocator, arg.type_name),
        .list => |items| {
            try out.appendSlice(allocator, "[");
            for (items.items, 0..) |item, i| {
                if (i != 0) try out.appendSlice(allocator, ", ");
                try appendStringifiedValue(allocator, out, item);
            }
            try out.appendSlice(allocator, "]");
        },
        .map => |entries| {
            var rendered: std.ArrayListUnmanaged(RenderedMapEntry) = .empty;
            defer {
                for (rendered.items) |entry| allocator.free(entry.key);
                rendered.deinit(allocator);
            }
            try rendered.ensureTotalCapacity(allocator, entries.items.len);
            for (entries.items) |*entry| {
                var key_buf: std.ArrayListUnmanaged(u8) = .empty;
                errdefer key_buf.deinit(allocator);
                try appendStringifiedValue(allocator, &key_buf, entry.key);
                rendered.appendAssumeCapacity(.{
                    .key = try key_buf.toOwnedSlice(allocator),
                    .value_ptr = &entry.value,
                });
            }
            insertionSortMapKeys(rendered.items);
            try out.appendSlice(allocator, "{");
            for (rendered.items, 0..) |entry, i| {
                if (i != 0) try out.appendSlice(allocator, ", ");
                try out.appendSlice(allocator, entry.key);
                try out.appendSlice(allocator, ": ");
                try appendStringifiedValue(allocator, out, entry.value_ptr.*);
            }
            try out.appendSlice(allocator, "}");
        },
        .message => return value.RuntimeError.TypeMismatch,
    }
}

fn appendDecimalValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    arg: value.Value,
) cel_env.EvalError!void {
    switch (arg) {
        .int => try appendFormat(out, allocator,"{d}", .{arg.int}),
        .uint => try appendFormat(out, allocator,"{d}", .{arg.uint}),
        .double => {
            if (std.math.isNan(arg.double)) {
                try out.appendSlice(allocator, "NaN");
            } else if (std.math.isPositiveInf(arg.double)) {
                try out.appendSlice(allocator, "Infinity");
            } else if (std.math.isNegativeInf(arg.double)) {
                try out.appendSlice(allocator, "-Infinity");
            } else {
                return value.RuntimeError.TypeMismatch;
            }
        },
        else => return value.RuntimeError.TypeMismatch,
    }
}

fn appendBinaryValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    arg: value.Value,
) cel_env.EvalError!void {
    switch (arg) {
        .int => try appendFormat(out, allocator,"{b}", .{arg.int}),
        .uint => try appendFormat(out, allocator,"{b}", .{arg.uint}),
        .bool => try out.appendSlice(allocator, if (arg.bool) "1" else "0"),
        else => return value.RuntimeError.TypeMismatch,
    }
}

fn appendOctalValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    arg: value.Value,
) cel_env.EvalError!void {
    switch (arg) {
        .int => try appendFormat(out, allocator,"{o}", .{arg.int}),
        .uint => try appendFormat(out, allocator,"{o}", .{arg.uint}),
        else => return value.RuntimeError.TypeMismatch,
    }
}

fn appendHexValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    uppercase: bool,
    arg: value.Value,
) cel_env.EvalError!void {
    switch (arg) {
        .int => if (uppercase)
            try appendFormat(out, allocator,"{X}", .{arg.int})
        else
            try appendFormat(out, allocator,"{x}", .{arg.int}),
        .uint => if (uppercase)
            try appendFormat(out, allocator,"{X}", .{arg.uint})
        else
            try appendFormat(out, allocator,"{x}", .{arg.uint}),
        .string => try appendHexBytes(allocator, out, uppercase, arg.string),
        .bytes => try appendHexBytes(allocator, out, uppercase, arg.bytes),
        else => return value.RuntimeError.TypeMismatch,
    }
}

fn appendHexBytes(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    uppercase: bool,
    bytes: []const u8,
) cel_env.EvalError!void {
    const digits = if (uppercase) "0123456789ABCDEF" else "0123456789abcdef";
    try out.ensureUnusedCapacity(allocator, bytes.len * 2);
    for (bytes) |byte| {
        out.appendAssumeCapacity(digits[byte >> 4]);
        out.appendAssumeCapacity(digits[byte & 0x0f]);
    }
}

fn appendFloatValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    mode: enum { decimal, scientific },
    precision: ?usize,
    arg: value.Value,
) cel_env.EvalError!void {
    const num: f64 = switch (arg) {
        .double => arg.double,
        .int => @floatFromInt(arg.int),
        .uint => @floatFromInt(arg.uint),
        else => return value.RuntimeError.TypeMismatch,
    };

    if (std.math.isNan(num)) {
        try out.appendSlice(allocator, "NaN");
        return;
    }
    if (std.math.isPositiveInf(num)) {
        try out.appendSlice(allocator, "Infinity");
        return;
    }
    if (std.math.isNegativeInf(num)) {
        try out.appendSlice(allocator, "-Infinity");
        return;
    }

    const clause: [*:0]const u8 = switch (mode) {
        .decimal => "%.*f",
        .scientific => "%.*e",
    };
    const resolved_precision = precision orelse 6;
    const c_precision: c_int = std.math.cast(c_int, resolved_precision) orelse return value.RuntimeError.TypeMismatch;

    var stack_buffer: [128]u8 = undefined;
    const needed = snprintf(stack_buffer[0..].ptr, stack_buffer.len, clause, c_precision, num);
    if (needed < 0) return value.RuntimeError.TypeMismatch;
    const needed_len: usize = @intCast(needed);
    if (needed_len < stack_buffer.len) {
        try out.appendSlice(allocator, stack_buffer[0..needed_len]);
        return;
    }

    const heap_buffer = try allocator.alloc(u8, needed_len + 1);
    defer allocator.free(heap_buffer);
    const written = snprintf(heap_buffer.ptr, heap_buffer.len, clause, c_precision, num);
    if (written < 0 or @as(usize, @intCast(written)) != needed_len) return value.RuntimeError.TypeMismatch;
    try out.appendSlice(allocator, heap_buffer[0..needed_len]);
}

fn insertionSortMapKeys(items: []RenderedMapEntry) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const current = items[i];
        var j = i;
        while (j > 0 and std.mem.order(u8, items[j - 1].key, current.key) == .gt) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = current;
    }
}

fn normalizeCodepointIndex(raw_index: i64, total: usize, allow_end: bool) cel_env.EvalError!usize {
    if (raw_index < 0) return value.RuntimeError.InvalidIndex;
    const index: usize = @intCast(raw_index);
    if (allow_end) {
        if (index > total) return value.RuntimeError.InvalidIndex;
    } else if (index >= total) {
        return value.RuntimeError.InvalidIndex;
    }
    return index;
}

fn codepointCount(text: []const u8) cel_env.EvalError!usize {
    return std.unicode.utf8CountCodepoints(text) catch value.RuntimeError.TypeMismatch;
}

fn byteOffsetForCodepointIndex(text: []const u8, target: usize) cel_env.EvalError!usize {
    if (target == 0) return 0;
    var codepoints: usize = 0;
    var cursor: usize = 0;
    while (cursor < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[cursor]) catch return value.RuntimeError.TypeMismatch;
        cursor += len;
        codepoints += 1;
        if (codepoints == target) return cursor;
    }
    if (codepoints == target) return cursor;
    return value.RuntimeError.InvalidIndex;
}

fn indexOfCodepoints(text: []const u8, needle: []const u8, start_index: usize) cel_env.EvalError!i64 {
    if (needle.len == 0) return @intCast(start_index);
    const start_byte = try byteOffsetForCodepointIndex(text, start_index);
    var codepoint_index = start_index;
    var cursor = start_byte;
    while (cursor < text.len) {
        if (std.mem.startsWith(u8, text[cursor..], needle)) return @intCast(codepoint_index);
        const len = std.unicode.utf8ByteSequenceLength(text[cursor]) catch return value.RuntimeError.TypeMismatch;
        cursor += len;
        codepoint_index += 1;
    }
    return -1;
}

fn lastIndexOfCodepoints(text: []const u8, needle: []const u8, from_index: ?usize) cel_env.EvalError!i64 {
    const total = try codepointCount(text);
    const last_allowed = from_index orelse total;
    if (last_allowed > total) return value.RuntimeError.InvalidIndex;
    if (needle.len == 0) return @intCast(last_allowed);

    var best: ?usize = null;
    var cursor: usize = 0;
    var index: usize = 0;
    while (cursor < text.len and index <= last_allowed) {
        if (std.mem.startsWith(u8, text[cursor..], needle)) best = index;
        const len = std.unicode.utf8ByteSequenceLength(text[cursor]) catch return value.RuntimeError.TypeMismatch;
        cursor += len;
        index += 1;
    }
    return if (best) |found| @intCast(found) else -1;
}

fn isTrimSpace(cp: u21) bool {
    return switch (cp) {
        0x0009...0x000d, 0x0020, 0x0085, 0x00a0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

fn isNumericValue(v: value.Value) bool {
    return switch (v) {
        .int, .uint, .double => true,
        else => false,
    };
}

fn compareNumbers(lhs: value.Value, rhs: value.Value) std.math.Order {
    return switch (lhs) {
        .int => |left| switch (rhs) {
            .int => std.math.order(left, rhs.int),
            .uint => if (left < 0) .lt else std.math.order(@as(u64, @intCast(left)), rhs.uint),
            .double => orderFloat(@as(f64, @floatFromInt(left)), rhs.double),
            else => unreachable,
        },
        .uint => |left| switch (rhs) {
            .int => if (rhs.int < 0) .gt else std.math.order(left, @as(u64, @intCast(rhs.int))),
            .uint => std.math.order(left, rhs.uint),
            .double => orderFloat(@as(f64, @floatFromInt(left)), rhs.double),
            else => unreachable,
        },
        .double => |left| switch (rhs) {
            .int => orderFloat(left, @as(f64, @floatFromInt(rhs.int))),
            .uint => orderFloat(left, @as(f64, @floatFromInt(rhs.uint))),
            .double => orderFloat(left, rhs.double),
            else => unreachable,
        },
        else => unreachable,
    };
}

fn orderFloat(lhs: f64, rhs: f64) std.math.Order {
    if (lhs < rhs) return .lt;
    if (lhs > rhs) return .gt;
    return .eq;
}

test "string and math extension libraries install and run" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(string_library);
    try environment.addLibrary(math_library);

    const t = environment.types.builtins;
    try std.testing.expect(environment.findOverload("charAt", true, &.{ t.string_type, t.int_type }) != null);
    try std.testing.expect(environment.findDynamicFunction("math.greatest", false, &.{ t.int_type, t.double_type }) != null);
    const list_dyn = try environment.types.listOf(t.dyn_type);
    try std.testing.expect(environment.findDynamicFunction("math.greatest", false, &.{list_dyn}) != null);
}

test "string format float clauses follow CEL rounding semantics" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(string_library);

    var activation = @import("../eval/activation.zig").Activation.init(std.testing.allocator);
    defer activation.deinit();

    var program = try @import("../compiler/compile.zig").compile(std.testing.allocator, &environment, "\"%.3f|%.0f|%.6e\".format([1.2345, 2.5, 1052.032911275])");
    defer program.deinit();

    var result = try @import("../eval/eval.zig").evalWithOptions(std.testing.allocator, &program, &activation, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("1.234|2|1.052033e+03", result.string);
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

const compile_mod = @import("../compiler/compile.zig");
const eval_impl = @import("../eval/eval.zig");
const Activation = @import("../eval/activation.zig").Activation;
const stdlib = @import("stdlib.zig");

const TestResult = union(enum) {
    int: i64,
    uint: u64,
    double: f64,
    bool_val: bool,
    string_val: []const u8,
    is_error: void,
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
        .double => |v| {
            if (std.math.isNan(v)) {
                try std.testing.expect(std.math.isNan(result.double));
            } else {
                try std.testing.expectEqual(v, result.double);
            }
        },
        .bool_val => |v| try std.testing.expectEqual(v, result.bool),
        .string_val => |v| try std.testing.expectEqualStrings(v, result.string),
        .is_error => unreachable,
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

fn makeStringEnv() !cel_env.Env {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    errdefer environment.deinit();
    try environment.addLibrary(stdlib.standard_library);
    try environment.addLibrary(string_library);
    return environment;
}

fn makeMathEnv() !cel_env.Env {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    errdefer environment.deinit();
    try environment.addLibrary(stdlib.standard_library);
    try environment.addLibrary(math_library);
    return environment;
}

// ---------------------------------------------------------------------------
// charAt tests
// ---------------------------------------------------------------------------

test "ext charAt" {
    var env = try makeStringEnv();
    defer env.deinit();

    const cases = .{
        .{ "'hello'.charAt(0)", TestResult{ .string_val = "h" } },
        .{ "'hello'.charAt(1)", TestResult{ .string_val = "e" } },
        .{ "'hello'.charAt(4)", TestResult{ .string_val = "o" } },
        .{ "'a'.charAt(0)", TestResult{ .string_val = "a" } },
        .{ "'hello'.charAt(5)", TestResult{ .string_val = "" } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

test "ext charAt out of bounds" {
    var env = try makeStringEnv();
    defer env.deinit();

    try expectCelError(&env, "'hello'.charAt(6)");
    try expectCelError(&env, "'hello'.charAt(-1)");
}

// ---------------------------------------------------------------------------
// indexOf / lastIndexOf tests
// ---------------------------------------------------------------------------

test "ext indexOf" {
    var env = try makeStringEnv();
    defer env.deinit();

    const cases = .{
        .{ "'hello'.indexOf('ell')", TestResult{ .int = 1 } },
        .{ "'hello'.indexOf('h')", TestResult{ .int = 0 } },
        .{ "'hello'.indexOf('o')", TestResult{ .int = 4 } },
        .{ "'hello'.indexOf('xyz')", TestResult{ .int = -1 } },
        .{ "'hello'.indexOf('')", TestResult{ .int = 0 } },
        .{ "''.indexOf('')", TestResult{ .int = 0 } },
        .{ "''.indexOf('a')", TestResult{ .int = -1 } },
        .{ "'abcabc'.indexOf('bc')", TestResult{ .int = 1 } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

test "ext lastIndexOf" {
    var env = try makeStringEnv();
    defer env.deinit();

    const cases = .{
        .{ "'abcabc'.lastIndexOf('bc')", TestResult{ .int = 4 } },
        .{ "'abcabc'.lastIndexOf('a')", TestResult{ .int = 3 } },
        .{ "'hello'.lastIndexOf('xyz')", TestResult{ .int = -1 } },
        .{ "'hello'.lastIndexOf('')", TestResult{ .int = 5 } },
        .{ "''.lastIndexOf('')", TestResult{ .int = 0 } },
        .{ "'hello'.lastIndexOf('h')", TestResult{ .int = 0 } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// lowerAscii / upperAscii tests
// ---------------------------------------------------------------------------

test "ext lowerAscii" {
    var env = try makeStringEnv();
    defer env.deinit();

    const cases = .{
        .{ "'HELLO'.lowerAscii()", TestResult{ .string_val = "hello" } },
        .{ "'hello'.lowerAscii()", TestResult{ .string_val = "hello" } },
        .{ "'Hello World'.lowerAscii()", TestResult{ .string_val = "hello world" } },
        .{ "''.lowerAscii()", TestResult{ .string_val = "" } },
        .{ "'ABC123'.lowerAscii()", TestResult{ .string_val = "abc123" } },
        .{ "'MiXeD'.lowerAscii()", TestResult{ .string_val = "mixed" } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

test "ext upperAscii" {
    var env = try makeStringEnv();
    defer env.deinit();

    const cases = .{
        .{ "'hello'.upperAscii()", TestResult{ .string_val = "HELLO" } },
        .{ "'HELLO'.upperAscii()", TestResult{ .string_val = "HELLO" } },
        .{ "'Hello World'.upperAscii()", TestResult{ .string_val = "HELLO WORLD" } },
        .{ "''.upperAscii()", TestResult{ .string_val = "" } },
        .{ "'abc123'.upperAscii()", TestResult{ .string_val = "ABC123" } },
        .{ "'MiXeD'.upperAscii()", TestResult{ .string_val = "MIXED" } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// reverse tests
// ---------------------------------------------------------------------------

test "ext reverse" {
    var env = try makeStringEnv();
    defer env.deinit();

    const cases = .{
        .{ "'hello'.reverse()", TestResult{ .string_val = "olleh" } },
        .{ "''.reverse()", TestResult{ .string_val = "" } },
        .{ "'a'.reverse()", TestResult{ .string_val = "a" } },
        .{ "'ab'.reverse()", TestResult{ .string_val = "ba" } },
        .{ "'abcdef'.reverse()", TestResult{ .string_val = "fedcba" } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// split tests
// ---------------------------------------------------------------------------

test "ext split" {
    var env = try makeStringEnv();
    defer env.deinit();

    // split returns a list; test via size and join to verify
    const cases = .{
        .{ "'a,b,c'.split(',').size()", TestResult{ .int = 3 } },
        .{ "'hello'.split(',').size()", TestResult{ .int = 1 } },
        .{ "'a,,b'.split(',').size()", TestResult{ .int = 3 } },
        .{ "''.split(',').size()", TestResult{ .int = 1 } },
        .{ "'abc'.split('').size()", TestResult{ .int = 3 } },
        .{ "'a,b,c'.split(',', 2).size()", TestResult{ .int = 2 } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// join tests
// ---------------------------------------------------------------------------

test "ext join" {
    var env = try makeStringEnv();
    defer env.deinit();

    const cases = .{
        .{ "['a', 'b', 'c'].join(',')", TestResult{ .string_val = "a,b,c" } },
        .{ "['a', 'b', 'c'].join('')", TestResult{ .string_val = "abc" } },
        .{ "['hello'].join(',')", TestResult{ .string_val = "hello" } },
        .{ "[].join(',')", TestResult{ .string_val = "" } },
        .{ "['a', 'b'].join(' - ')", TestResult{ .string_val = "a - b" } },
        .{ "[].join('')", TestResult{ .string_val = "" } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// substring tests
// ---------------------------------------------------------------------------

test "ext substring" {
    var env = try makeStringEnv();
    defer env.deinit();

    const cases = .{
        .{ "'hello'.substring(1)", TestResult{ .string_val = "ello" } },
        .{ "'hello'.substring(0)", TestResult{ .string_val = "hello" } },
        .{ "'hello'.substring(5)", TestResult{ .string_val = "" } },
        .{ "'hello'.substring(0, 5)", TestResult{ .string_val = "hello" } },
        .{ "'hello'.substring(1, 4)", TestResult{ .string_val = "ell" } },
        .{ "'hello'.substring(0, 0)", TestResult{ .string_val = "" } },
        .{ "'hello'.substring(2, 2)", TestResult{ .string_val = "" } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

test "ext substring errors" {
    var env = try makeStringEnv();
    defer env.deinit();

    try expectCelError(&env, "'hello'.substring(-1)");
    try expectCelError(&env, "'hello'.substring(6)");
    try expectCelError(&env, "'hello'.substring(3, 2)");
}

// ---------------------------------------------------------------------------
// trim tests
// ---------------------------------------------------------------------------

test "ext trim" {
    var env = try makeStringEnv();
    defer env.deinit();

    const cases = .{
        .{ "'  hello  '.trim()", TestResult{ .string_val = "hello" } },
        .{ "'hello'.trim()", TestResult{ .string_val = "hello" } },
        .{ "'   '.trim()", TestResult{ .string_val = "" } },
        .{ "''.trim()", TestResult{ .string_val = "" } },
        .{ "' hello'.trim()", TestResult{ .string_val = "hello" } },
        .{ "'hello '.trim()", TestResult{ .string_val = "hello" } },
        .{ "' \\thello\\t '.trim()", TestResult{ .string_val = "hello" } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// replace tests
// ---------------------------------------------------------------------------

test "ext replace" {
    var env = try makeStringEnv();
    defer env.deinit();

    const cases = .{
        .{ "'hello world'.replace('world', 'there')", TestResult{ .string_val = "hello there" } },
        .{ "'aaa'.replace('a', 'b')", TestResult{ .string_val = "bbb" } },
        .{ "'hello'.replace('xyz', 'abc')", TestResult{ .string_val = "hello" } },
        .{ "''.replace('a', 'b')", TestResult{ .string_val = "" } },
        .{ "'aaa'.replace('a', 'b', 2)", TestResult{ .string_val = "bba" } },
        .{ "'aaa'.replace('a', 'b', 0)", TestResult{ .string_val = "aaa" } },
        .{ "'aaa'.replace('a', 'b', 1)", TestResult{ .string_val = "baa" } },
        .{ "'abab'.replace('ab', 'x')", TestResult{ .string_val = "xx" } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// startsWith / endsWith / contains (via string ext - already in stdlib, but test here for completeness)
// ---------------------------------------------------------------------------

test "ext startsWith endsWith contains" {
    var env = try makeStringEnv();
    defer env.deinit();

    const cases = .{
        .{ "'hello'.startsWith('he')", TestResult{ .bool_val = true } },
        .{ "'hello'.startsWith('lo')", TestResult{ .bool_val = false } },
        .{ "'hello'.endsWith('lo')", TestResult{ .bool_val = true } },
        .{ "'hello'.endsWith('he')", TestResult{ .bool_val = false } },
        .{ "'hello world'.contains('o w')", TestResult{ .bool_val = true } },
        .{ "'hello'.contains('xyz')", TestResult{ .bool_val = false } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ===========================================================================
// Math extension tests
// ===========================================================================

// ---------------------------------------------------------------------------
// math.ceil / math.floor / math.round / math.trunc
// ---------------------------------------------------------------------------

test "ext math.ceil" {
    var env = try makeMathEnv();
    defer env.deinit();

    const cases = .{
        .{ "math.ceil(1.1)", TestResult{ .double = 2.0 } },
        .{ "math.ceil(1.9)", TestResult{ .double = 2.0 } },
        .{ "math.ceil(-1.1)", TestResult{ .double = -1.0 } },
        .{ "math.ceil(-1.9)", TestResult{ .double = -1.0 } },
        .{ "math.ceil(0.0)", TestResult{ .double = 0.0 } },
        .{ "math.ceil(2.0)", TestResult{ .double = 2.0 } },
        .{ "math.ceil(-2.0)", TestResult{ .double = -2.0 } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

test "ext math.floor" {
    var env = try makeMathEnv();
    defer env.deinit();

    const cases = .{
        .{ "math.floor(1.1)", TestResult{ .double = 1.0 } },
        .{ "math.floor(1.9)", TestResult{ .double = 1.0 } },
        .{ "math.floor(-1.1)", TestResult{ .double = -2.0 } },
        .{ "math.floor(-1.9)", TestResult{ .double = -2.0 } },
        .{ "math.floor(0.0)", TestResult{ .double = 0.0 } },
        .{ "math.floor(2.0)", TestResult{ .double = 2.0 } },
        .{ "math.floor(-2.0)", TestResult{ .double = -2.0 } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

test "ext math.round" {
    var env = try makeMathEnv();
    defer env.deinit();

    const cases = .{
        .{ "math.round(1.4)", TestResult{ .double = 1.0 } },
        .{ "math.round(1.5)", TestResult{ .double = 2.0 } },
        .{ "math.round(1.6)", TestResult{ .double = 2.0 } },
        .{ "math.round(-1.4)", TestResult{ .double = -1.0 } },
        .{ "math.round(-1.5)", TestResult{ .double = -2.0 } },
        .{ "math.round(0.0)", TestResult{ .double = 0.0 } },
        .{ "math.round(3.0)", TestResult{ .double = 3.0 } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

test "ext math.trunc" {
    var env = try makeMathEnv();
    defer env.deinit();

    const cases = .{
        .{ "math.trunc(1.9)", TestResult{ .double = 1.0 } },
        .{ "math.trunc(1.1)", TestResult{ .double = 1.0 } },
        .{ "math.trunc(-1.9)", TestResult{ .double = -1.0 } },
        .{ "math.trunc(-1.1)", TestResult{ .double = -1.0 } },
        .{ "math.trunc(0.0)", TestResult{ .double = 0.0 } },
        .{ "math.trunc(5.0)", TestResult{ .double = 5.0 } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

test "ext math.sqrt" {
    var env = try makeMathEnv();
    defer env.deinit();

    const cases = .{
        .{ "math.sqrt(49.0)", TestResult{ .double = 7.0 } },
        .{ "math.sqrt(0)", TestResult{ .double = 0.0 } },
        .{ "math.sqrt(1)", TestResult{ .double = 1.0 } },
        .{ "math.sqrt(25u)", TestResult{ .double = 5.0 } },
        .{ "math.sqrt(82)", TestResult{ .double = 9.055385138137417 } },
        .{ "math.isNaN(math.sqrt(-15.34))", TestResult{ .bool_val = true } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// math.abs
// ---------------------------------------------------------------------------

test "ext math.abs" {
    var env = try makeMathEnv();
    defer env.deinit();

    const cases = .{
        .{ "math.abs(5)", TestResult{ .int = 5 } },
        .{ "math.abs(-5)", TestResult{ .int = 5 } },
        .{ "math.abs(0)", TestResult{ .int = 0 } },
        .{ "math.abs(5u)", TestResult{ .uint = 5 } },
        .{ "math.abs(0u)", TestResult{ .uint = 0 } },
        .{ "math.abs(3.14)", TestResult{ .double = 3.14 } },
        .{ "math.abs(-3.14)", TestResult{ .double = 3.14 } },
        .{ "math.abs(0.0)", TestResult{ .double = 0.0 } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// math.sign
// ---------------------------------------------------------------------------

test "ext math.sign" {
    var env = try makeMathEnv();
    defer env.deinit();

    const cases = .{
        .{ "math.sign(10)", TestResult{ .int = 1 } },
        .{ "math.sign(-10)", TestResult{ .int = -1 } },
        .{ "math.sign(0)", TestResult{ .int = 0 } },
        .{ "math.sign(10u)", TestResult{ .uint = 1 } },
        .{ "math.sign(0u)", TestResult{ .uint = 0 } },
        .{ "math.sign(1.5)", TestResult{ .double = 1.0 } },
        .{ "math.sign(-1.5)", TestResult{ .double = -1.0 } },
        .{ "math.sign(0.0)", TestResult{ .double = 0.0 } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// math.greatest / math.least
// ---------------------------------------------------------------------------

test "ext math.greatest and math.least" {
    var env = try makeMathEnv();
    defer env.deinit();

    const cases = .{
        .{ "math.greatest(1, 2)", TestResult{ .int = 2 } },
        .{ "math.greatest(3, 3)", TestResult{ .int = 3 } },
        .{ "math.greatest(-1, -5)", TestResult{ .int = -1 } },
        .{ "math.greatest(1, 2, 3)", TestResult{ .int = 3 } },
        .{ "math.least(1, 2)", TestResult{ .int = 1 } },
        .{ "math.least(3, 3)", TestResult{ .int = 3 } },
        .{ "math.least(-1, -5)", TestResult{ .int = -5 } },
        .{ "math.least(1, 2, 3)", TestResult{ .int = 1 } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// math.isNaN / math.isInf / math.isFinite
// ---------------------------------------------------------------------------

test "ext math.isNaN isInf isFinite" {
    var env = try makeMathEnv();
    defer env.deinit();

    const cases = .{
        .{ "math.isNaN(0.0/0.0)", TestResult{ .bool_val = true } },
        .{ "math.isNaN(1.0)", TestResult{ .bool_val = false } },
        .{ "math.isInf(1.0/0.0)", TestResult{ .bool_val = true } },
        .{ "math.isInf(1.0)", TestResult{ .bool_val = false } },
        .{ "math.isFinite(1.0)", TestResult{ .bool_val = true } },
        .{ "math.isFinite(1.0/0.0)", TestResult{ .bool_val = false } },
        .{ "math.isFinite(0.0/0.0)", TestResult{ .bool_val = false } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// math.bitAnd / math.bitOr / math.bitXor / math.bitNot
// ---------------------------------------------------------------------------

test "ext math.bitwise" {
    var env = try makeMathEnv();
    defer env.deinit();

    const cases = .{
        .{ "math.bitAnd(15, 9)", TestResult{ .int = 9 } },
        .{ "math.bitAnd(0, 0)", TestResult{ .int = 0 } },
        .{ "math.bitOr(5, 3)", TestResult{ .int = 7 } },
        .{ "math.bitOr(0, 0)", TestResult{ .int = 0 } },
        .{ "math.bitXor(5, 3)", TestResult{ .int = 6 } },
        .{ "math.bitXor(0, 0)", TestResult{ .int = 0 } },
        .{ "math.bitNot(0)", TestResult{ .int = -1 } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}

// ---------------------------------------------------------------------------
// math.bitShiftLeft / math.bitShiftRight
// ---------------------------------------------------------------------------

test "ext math.bitShift" {
    var env = try makeMathEnv();
    defer env.deinit();

    const cases = .{
        .{ "math.bitShiftLeft(1, 3)", TestResult{ .int = 8 } },
        .{ "math.bitShiftLeft(1, 0)", TestResult{ .int = 1 } },
        .{ "math.bitShiftRight(8, 3)", TestResult{ .int = 1 } },
        .{ "math.bitShiftRight(8, 0)", TestResult{ .int = 8 } },
        .{ "math.bitShiftLeft(1u, 3)", TestResult{ .uint = 8 } },
        .{ "math.bitShiftRight(8u, 3)", TestResult{ .uint = 1 } },
        .{ "math.bitShiftLeft(1, 64)", TestResult{ .int = 0 } },
    };
    inline for (cases) |c| {
        try expectCelResult(&env, c[0], c[1]);
    }
}
