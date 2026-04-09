const std = @import("std");
const ast = @import("../parse/ast.zig");
const env = @import("../env/env.zig");
const InlineList = @import("../util/inline_list.zig").InlineList;
const resolve = @import("resolve.zig");
const types = @import("../env/types.zig");

pub fn StaticResolution() type {
    return struct {
        ref: env.ResolutionRef,
        result: types.TypeRef,
    };
}

pub fn resolveStaticOverloadScoped(comptime ErrorType: type, self: anytype, name: []const u8, absolute: bool, receiver_style: bool, params: []const types.TypeRef) ErrorType!?StaticResolution() {
    var candidate_storage: std.ArrayListUnmanaged(u8) = .empty;
    defer candidate_storage.deinit(self.allocator);
    var small_buffer: [256]u8 = undefined;

    if (!absolute and self.env.container != null and self.env.container.?.len != 0) {
        var prefix_len = self.env.container.?.len;
        while (true) {
            const candidate = try resolve.buildScopedName(
                self.allocator,
                &candidate_storage,
                small_buffer[0..],
                self.env.container.?[0..prefix_len],
                name,
            );
            if (try resolveStaticOverload(ErrorType, self, candidate, receiver_style, params)) |resolved| return resolved;

            prefix_len = std.mem.lastIndexOfScalar(u8, self.env.container.?[0..prefix_len], '.') orelse break;
        }
    }
    return resolveStaticOverload(ErrorType, self, name, receiver_style, params);
}

pub fn resolveStaticOverload(comptime ErrorType: type, self: anytype, name: []const u8, receiver_style: bool, params: []const types.TypeRef) ErrorType!?StaticResolution() {
    return resolveStaticOverloadIn(ErrorType, self, self.env, 0, name, receiver_style, params);
}

pub fn resolveStaticOverloadIn(comptime ErrorType: type, self: anytype, scope: *const env.Env, depth: u32, name: []const u8, receiver_style: bool, params: []const types.TypeRef) ErrorType!?StaticResolution() {
    for (scope.overloads.items, 0..) |overload, i| {
        if (overload.receiver_style != receiver_style) continue;
        if (!std.mem.eql(u8, overload.name, name)) continue;
        if (overload.params.len != params.len) continue;

        var instantiations = InlineList(@TypeOf(self.*).TypeMapping, 8).init(self.allocator);
        defer instantiations.deinit();
        var candidate_params = InlineList(types.TypeRef, 8).init(self.allocator);
        defer candidate_params.deinit();
        try candidate_params.ensureTotalCapacity(overload.params.len);
        for (overload.params) |param_ty| {
            try candidate_params.append(try instantiateType(ErrorType, self, param_ty, &instantiations));
        }
        const candidate_result = try instantiateType(ErrorType, self, overload.result, &instantiations);

        const mark = self.type_mappings.items.len;
        var matched = true;
        for (candidate_params.items(), params) |expected, actual| {
            if (!(try self.isAssignableType(expected, actual))) {
                matched = false;
                break;
            }
        }
        if (!matched) {
            self.type_mappings.items.len = mark;
            continue;
        }

        return .{
            .ref = .{
                .depth = depth,
                .index = @intCast(i),
            },
            .result = try self.substituteType(candidate_result, false),
        };
    }
    const parent = scope.parent orelse return null;
    return resolveStaticOverloadIn(ErrorType, self, parent, depth + 1, name, receiver_style, params);
}

pub fn instantiateType(comptime ErrorType: type, self: anytype, ty: types.TypeRef, instantiations: anytype) ErrorType!types.TypeRef {
    return switch (self.env.types.spec(ty)) {
        .type_param => blk: {
            for (instantiations.items()) |mapping| {
                if (mapping.param == ty) break :blk mapping.replacement;
            }
            const fresh = try self.newTypeVar();
            try instantiations.append(.{
                .param = ty,
                .replacement = fresh,
            });
            break :blk fresh;
        },
        .list => |elem| self.env.types.listOf(try instantiateType(ErrorType, self, elem, instantiations)),
        .map => |pair| self.env.types.mapOf(
            try instantiateType(ErrorType, self, pair.key, instantiations),
            try instantiateType(ErrorType, self, pair.value, instantiations),
        ),
        .abstract => |abstract_ty| blk: {
            var params: std.ArrayListUnmanaged(types.TypeRef) = .empty;
            defer params.deinit(self.allocator);
            try params.ensureTotalCapacity(self.allocator, abstract_ty.params.len);
            for (abstract_ty.params) |param| {
                params.appendAssumeCapacity(try instantiateType(ErrorType, self, param, instantiations));
            }
            break :blk try self.env.types.abstractOfParams(abstract_ty.name, params.items);
        },
        .wrapper => |inner| self.env.types.wrapperOf(try instantiateType(ErrorType, self, inner, instantiations)),
        else => ty,
    };
}

pub fn resolveUnaryOperator(self: anytype, index: ast.Index, op: ast.UnaryOp, operand: types.TypeRef) ?types.TypeRef {
    const overload_ref = self.env.findOverload(env.unaryOperatorName(op), false, &.{operand}) orelse return null;
    self.operator_resolutions[@intFromEnum(index)] = overload_ref;
    return self.env.overloadAt(overload_ref).result;
}

pub fn resolveBinaryOperator(self: anytype, index: ast.Index, op: ast.BinaryOp, lhs: types.TypeRef, rhs: types.TypeRef) ?types.TypeRef {
    const overload_ref = self.env.findOverload(env.binaryOperatorName(op), false, &.{ lhs, rhs }) orelse return null;
    self.operator_resolutions[@intFromEnum(index)] = overload_ref;
    return self.env.overloadAt(overload_ref).result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const checker = @import("check.zig");
const value = @import("../env/value.zig");

fn dummyImpl(_: std.mem.Allocator, _: []const value.Value) env.EvalError!value.Value {
    return .{ .bool = true };
}

test "custom function overload resolves through compile" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const b = environment.types.builtins;

    // Register custom function: myFunc(int) -> string
    _ = try environment.addFunction("myFunc", false, &.{b.int_type}, b.string_type, dummyImpl);

    var program = try checker.compile(std.testing.allocator, &environment, "myFunc(42)");
    defer program.deinit();
    try std.testing.expectEqual(b.string_type, program.result_type);
}

test "custom receiver-style function resolves through compile" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const b = environment.types.builtins;

    // Register custom receiver function: string.myMethod() -> bool
    _ = try environment.addFunction("myMethod", true, &.{b.string_type}, b.bool_type, dummyImpl);

    var program = try checker.compile(std.testing.allocator, &environment, "'hello'.myMethod()");
    defer program.deinit();
    try std.testing.expectEqual(b.bool_type, program.result_type);
}

test "overload resolution picks matching parameter types" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const b = environment.types.builtins;

    // Two overloads: convert(int) -> string, convert(string) -> int
    _ = try environment.addFunction("convert", false, &.{b.int_type}, b.string_type, dummyImpl);
    _ = try environment.addFunction("convert", false, &.{b.string_type}, b.int_type, dummyImpl);

    const cases = [_]struct { expr: []const u8, expected: types.TypeRef }{
        .{ .expr = "convert(1)", .expected = b.string_type },
        .{ .expr = "convert('hello')", .expected = b.int_type },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        try std.testing.expectEqual(case.expected, program.result_type);
    }
}

test "overload resolution with multiple parameters" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const b = environment.types.builtins;

    // multi(int, string) -> bool
    _ = try environment.addFunction("multi", false, &.{ b.int_type, b.string_type }, b.bool_type, dummyImpl);

    var program = try checker.compile(std.testing.allocator, &environment, "multi(1, 'a')");
    defer program.deinit();
    try std.testing.expectEqual(b.bool_type, program.result_type);
}

test "overload resolution rejects mismatched parameter count" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const b = environment.types.builtins;

    // Only: singleArg(int) -> bool
    _ = try environment.addFunction("singleArg", false, &.{b.int_type}, b.bool_type, dummyImpl);

    // Calling with wrong number of args should fail
    try std.testing.expectError(
        checker.Error.InvalidCall,
        checker.compile(std.testing.allocator, &environment, "singleArg(1, 2)"),
    );
    try std.testing.expectError(
        checker.Error.InvalidCall,
        checker.compile(std.testing.allocator, &environment, "singleArg()"),
    );
}

test "overload resolution rejects mismatched parameter type" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const b = environment.types.builtins;

    // Only: typedFunc(int) -> bool
    _ = try environment.addFunction("typedFunc", false, &.{b.int_type}, b.bool_type, dummyImpl);

    // Calling with string should fail
    try std.testing.expectError(
        checker.Error.InvalidCall,
        checker.compile(std.testing.allocator, &environment, "typedFunc('hello')"),
    );
}

test "receiver-style vs function-style are distinct overloads" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const b = environment.types.builtins;

    // function-style: toStr(int) -> string
    _ = try environment.addFunction("toStr", false, &.{b.int_type}, b.string_type, dummyImpl);
    // receiver-style: int.toStr() -> bool (different result to distinguish)
    _ = try environment.addFunction("toStr", true, &.{b.int_type}, b.bool_type, dummyImpl);

    // function-style call
    var program1 = try checker.compile(std.testing.allocator, &environment, "toStr(1)");
    defer program1.deinit();
    try std.testing.expectEqual(b.string_type, program1.result_type);

    // receiver-style call
    var program2 = try checker.compile(std.testing.allocator, &environment, "1.toStr()");
    defer program2.deinit();
    try std.testing.expectEqual(b.bool_type, program2.result_type);
}

test "generic type parameter instantiation in custom functions" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const b = environment.types.builtins;
    const type_a = try environment.types.typeParamOf("A");
    const list_a = try environment.types.listOf(type_a);

    // identity(list(A)) -> A  (extracts element type)
    _ = try environment.addFunction("first", false, &.{list_a}, type_a, dummyImpl);

    // Call with list(int) -> should resolve A=int, return int
    try environment.addVarTyped("nums", try environment.types.listOf(b.int_type));
    var program = try checker.compile(std.testing.allocator, &environment, "first(nums)");
    defer program.deinit();
    try std.testing.expectEqual(b.int_type, program.result_type);
}

test "generic type parameter instantiation with list result" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const b = environment.types.builtins;
    const type_a = try environment.types.typeParamOf("T");
    const list_t = try environment.types.listOf(type_a);

    // wrap(T) -> list(T)
    _ = try environment.addFunction("wrap", false, &.{type_a}, list_t, dummyImpl);

    var program = try checker.compile(std.testing.allocator, &environment, "wrap(42)");
    defer program.deinit();
    const expected = try environment.types.listOf(b.int_type);
    try std.testing.expectEqual(expected, program.result_type);
}

test "stdlib overloads resolve for standard operations" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const b = environment.types.builtins;

    // stdlib provides size() as a receiver on string and list
    const cases = [_]struct { expr: []const u8, expected: types.TypeRef }{
        .{ .expr = "size('hello')", .expected = b.int_type },
        .{ .expr = "'hello'.size()", .expected = b.int_type },
        .{ .expr = "size([1, 2])", .expected = b.int_type },
        .{ .expr = "[1, 2].size()", .expected = b.int_type },
        .{ .expr = "'hello'.contains('lo')", .expected = b.bool_type },
        .{ .expr = "'hello'.startsWith('he')", .expected = b.bool_type },
        .{ .expr = "'hello'.endsWith('lo')", .expected = b.bool_type },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        try std.testing.expectEqual(case.expected, program.result_type);
    }
}
