const std = @import("std");
const schema = @import("../env/schema.zig");
const types = @import("../env/types.zig");

pub fn optionalInnerType(self: anytype, ty: types.TypeRef) ?types.TypeRef {
    return self.env.types.optionalInner(ty);
}

pub fn isBoolish(self: anytype, ref: types.TypeRef) bool {
    return switch (self.env.types.spec(ref)) {
        .bool, .dyn, .type_param => true,
        .wrapper => |inner| isBoolish(self, inner),
        else => false,
    };
}

pub fn unwrapWrapperType(self: anytype, ref: types.TypeRef) ?types.TypeRef {
    return switch (self.env.types.spec(ref)) {
        .wrapper => |inner| inner,
        else => null,
    };
}

pub fn joinTypes(comptime ErrorType: type, self: anytype, previous: types.TypeRef, current: types.TypeRef) ErrorType!types.TypeRef {
    const mark = self.type_mappings.items.len;
    if (try isAssignableType(ErrorType, self, previous, current)) {
        return mostGeneral(ErrorType, self, previous, current);
    }

    self.type_mappings.items.len = mark;
    if (try isAssignableType(ErrorType, self, current, previous)) {
        return mostGeneral(ErrorType, self, current, previous);
    }

    self.type_mappings.items.len = mark;
    return self.env.types.builtins.dyn_type;
}

pub fn newTypeVar(comptime ErrorType: type, self: anytype) ErrorType!types.TypeRef {
    var buffer: [32]u8 = undefined;
    const name = std.fmt.bufPrint(buffer[0..], "_var{d}", .{self.free_type_var_counter}) catch unreachable;
    self.free_type_var_counter += 1;
    return self.env.types.typeParamOf(name);
}

pub fn lookupTypeMapping(self: anytype, param: types.TypeRef) ?types.TypeRef {
    for (self.type_mappings.items) |mapping| {
        if (mapping.param == param) return mapping.replacement;
    }
    return null;
}

pub fn setTypeMapping(comptime ErrorType: type, self: anytype, param: types.TypeRef, replacement: types.TypeRef) ErrorType!void {
    for (self.type_mappings.items) |*mapping| {
        if (mapping.param == param) {
            mapping.replacement = replacement;
            return;
        }
    }
    try self.type_mappings.append(self.allocator, .{
        .param = param,
        .replacement = replacement,
    });
}

pub fn substituteType(comptime ErrorType: type, self: anytype, ty: types.TypeRef, type_param_to_dyn: bool) ErrorType!types.TypeRef {
    if (lookupTypeMapping(self, ty)) |mapped| {
        return substituteType(ErrorType, self, mapped, type_param_to_dyn);
    }

    return switch (self.env.types.spec(ty)) {
        .type_param => if (type_param_to_dyn) self.env.types.builtins.dyn_type else ty,
        .list => |elem| self.env.types.listOf(try substituteType(ErrorType, self, elem, type_param_to_dyn)),
        .map => |pair| self.env.types.mapOf(
            try substituteType(ErrorType, self, pair.key, type_param_to_dyn),
            try substituteType(ErrorType, self, pair.value, type_param_to_dyn),
        ),
        .abstract => |abstract_ty| blk: {
            var params: std.ArrayListUnmanaged(types.TypeRef) = .empty;
            defer params.deinit(self.allocator);
            try params.ensureTotalCapacity(self.allocator, abstract_ty.params.len);
            for (abstract_ty.params) |param| {
                params.appendAssumeCapacity(try substituteType(ErrorType, self, param, type_param_to_dyn));
            }
            break :blk try self.env.types.abstractOfParams(abstract_ty.name, params.items);
        },
        .wrapper => |inner| self.env.types.wrapperOf(try substituteType(ErrorType, self, inner, type_param_to_dyn)),
        else => ty,
    };
}

pub fn mostGeneral(comptime ErrorType: type, self: anytype, a: types.TypeRef, b: types.TypeRef) ErrorType!types.TypeRef {
    const sub_a = try substituteType(ErrorType, self, a, false);
    const sub_b = try substituteType(ErrorType, self, b, false);
    return if (isEqualOrLessSpecific(self, sub_a, sub_b)) sub_a else sub_b;
}

pub fn isEqualOrLessSpecific(self: anytype, a: types.TypeRef, b: types.TypeRef) bool {
    if (a == b) return true;

    const a_spec = self.env.types.spec(a);
    const b_spec = self.env.types.spec(b);
    if (a_spec == .dyn or a_spec == .type_param) return true;
    if (b_spec == .dyn or b_spec == .type_param) return false;
    if (b_spec == .null_type and isNullableType(self, a)) return true;
    if (a_spec == .null_type) return false;

    return switch (a_spec) {
            .list => |a_elem| switch (b_spec) {
                .list => |b_elem| isEqualOrLessSpecific(self, a_elem, b_elem),
                else => false,
            },
            .map => |a_map| switch (b_spec) {
                .map => |b_map| isEqualOrLessSpecific(self, a_map.key, b_map.key) and
                    isEqualOrLessSpecific(self, a_map.value, b_map.value),
                else => false,
            },
        .abstract => |a_opaque| switch (b_spec) {
            .abstract => |b_opaque| blk: {
                if (!std.mem.eql(u8, a_opaque.name, b_opaque.name)) break :blk false;
                if (a_opaque.params.len != b_opaque.params.len) break :blk false;
                for (a_opaque.params, b_opaque.params) |a_param, b_param| {
                        if (!isEqualOrLessSpecific(self, a_param, b_param)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
            .wrapper => |a_inner| switch (b_spec) {
                .wrapper => |b_inner| isEqualOrLessSpecific(self, a_inner, b_inner),
                else => isEqualOrLessSpecific(self, a_inner, b),
            },
        else => false,
    };
}

pub fn isNullableType(self: anytype, ty: types.TypeRef) bool {
    return switch (self.env.types.spec(ty)) {
        .wrapper, .abstract, .message => true,
        .null_type, .dyn => true,
        else => ty == self.env.types.builtins.timestamp_type or ty == self.env.types.builtins.duration_type,
    };
}

pub fn notReferencedIn(self: anytype, param: types.TypeRef, within: types.TypeRef) bool {
    if (param == within) return false;
    if (lookupTypeMapping(self, within)) |mapped| {
        return notReferencedIn(self, param, mapped);
    }

    return switch (self.env.types.spec(within)) {
        .list => |elem| notReferencedIn(self, param, elem),
        .map => |pair| notReferencedIn(self, param, pair.key) and notReferencedIn(self, param, pair.value),
        .abstract => |abstract_ty| blk: {
            for (abstract_ty.params) |item| {
                if (!notReferencedIn(self, param, item)) break :blk false;
            }
            break :blk true;
        },
        .wrapper => |inner| notReferencedIn(self, param, inner),
        else => true,
    };
}

pub fn bindTypeParam(comptime ErrorType: type, self: anytype, param: types.TypeRef, candidate: types.TypeRef) ErrorType!bool {
    if (param == candidate) return true;
    if (lookupTypeMapping(self, param)) |existing| {
        const mark = self.type_mappings.items.len;
        if (try isAssignableType(ErrorType, self, existing, candidate)) {
            try setTypeMapping(ErrorType, self, param, try mostGeneral(ErrorType, self, existing, candidate));
            return true;
        }
        self.type_mappings.items.len = mark;
        if (try isAssignableType(ErrorType, self, candidate, existing)) {
            try setTypeMapping(ErrorType, self, param, try mostGeneral(ErrorType, self, candidate, existing));
            return true;
        }
        self.type_mappings.items.len = mark;
        return false;
    }

    if (!notReferencedIn(self, param, candidate)) return false;
    try setTypeMapping(ErrorType, self, param, candidate);
    return true;
}

pub fn isAssignableType(comptime ErrorType: type, self: anytype, expected: types.TypeRef, actual: types.TypeRef) ErrorType!bool {
    const resolved_expected = try substituteType(ErrorType, self, expected, false);
    const resolved_actual = try substituteType(ErrorType, self, actual, false);
    if (resolved_expected == resolved_actual) return true;

    const expected_spec = self.env.types.spec(resolved_expected);
    const actual_spec = self.env.types.spec(resolved_actual);
    if (expected_spec == .type_param) return bindTypeParam(ErrorType, self, resolved_expected, resolved_actual);
    if (actual_spec == .type_param) return bindTypeParam(ErrorType, self, resolved_actual, resolved_expected);
    if (expected_spec == .dyn or actual_spec == .dyn) return true;
    if (actual_spec == .null_type) return isNullableType(self, resolved_expected);
    if (expected_spec == .null_type) return isNullableType(self, resolved_actual);

    return switch (expected_spec) {
        .list => |expected_elem| switch (actual_spec) {
            .list => |actual_elem| try isAssignableType(ErrorType, self, expected_elem, actual_elem),
            else => false,
        },
        .map => |expected_map| switch (actual_spec) {
            .map => |actual_map| (try isAssignableType(ErrorType, self, expected_map.key, actual_map.key)) and
                (try isAssignableType(ErrorType, self, expected_map.value, actual_map.value)),
            else => false,
        },
        .abstract => |expected_opaque| switch (actual_spec) {
            .abstract => |actual_opaque| blk: {
                if (!std.mem.eql(u8, expected_opaque.name, actual_opaque.name)) break :blk false;
                if (expected_opaque.params.len != actual_opaque.params.len) break :blk false;
                    for (expected_opaque.params, actual_opaque.params) |expected_param, actual_param| {
                        if (!(try isAssignableType(ErrorType, self, expected_param, actual_param))) break :blk false;
                    }
                    break :blk true;
                },
                else => false,
            },
        .wrapper => |expected_inner| switch (actual_spec) {
            .wrapper => |actual_inner| try isAssignableType(ErrorType, self, expected_inner, actual_inner),
            else => try isAssignableType(ErrorType, self, expected_inner, resolved_actual),
        },
        else => false,
    };
}

pub fn isFieldAssignmentValid(self: anytype, field: *const schema.FieldDecl, expr_ty: types.TypeRef) bool {
    const mark = self.type_mappings.items.len;
    if (isAssignableType(anyerror, self, field.ty, expr_ty) catch false) return true;
    self.type_mappings.items.len = mark;
    if (self.env.types.spec(expr_ty) == .null_type) {
        return switch (field.encoding) {
            .singular => |raw| switch (raw) {
                .message => |name| blk: {
                    const desc = self.env.lookupMessage(name) orelse break :blk false;
                    break :blk desc.kind == .any or desc.kind == .value or schema.isWrapperKind(desc.kind);
                },
                else => false,
            },
            else => false,
        };
    }
    return false;
}

pub fn isValidMapKey(self: anytype, ref: types.TypeRef) bool {
    return switch (self.env.types.spec(ref)) {
        .int, .uint, .bool, .string, .dyn, .type_param => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestContext = struct {
    env: *TestEnv,
    allocator: std.mem.Allocator,
    type_mappings: std.ArrayListUnmanaged(TypeMapping),
    free_type_var_counter: u32 = 0,

    const TypeMapping = struct {
        param: types.TypeRef,
        replacement: types.TypeRef,
    };

    fn init(allocator: std.mem.Allocator, test_env: *TestEnv) TestContext {
        return .{
            .env = test_env,
            .allocator = allocator,
            .type_mappings = .empty,
        };
    }

    fn deinit(self: *TestContext) void {
        self.type_mappings.deinit(self.allocator);
    }
};

const TestEnv = struct {
    types: types.TypeProvider,

    fn init(allocator: std.mem.Allocator) !TestEnv {
        return .{ .types = try types.TypeProvider.init(allocator) };
    }

    fn deinit(self: *TestEnv) void {
        self.types.deinit();
    }
};

test "isBoolish" {
    var te = try TestEnv.init(std.testing.allocator);
    defer te.deinit();
    var ctx = TestContext.init(std.testing.allocator, &te);
    defer ctx.deinit();
    const b = te.types.builtins;
    const wrapped_bool = try te.types.wrapperOf(b.bool_type);

    const true_cases = [_]types.TypeRef{ b.bool_type, b.dyn_type, wrapped_bool };
    for (true_cases) |ty| try std.testing.expect(isBoolish(&ctx, ty));

    const false_cases = [_]types.TypeRef{ b.int_type, b.string_type, b.double_type, b.uint_type, b.bytes_type, b.null_type };
    for (false_cases) |ty| try std.testing.expect(!isBoolish(&ctx, ty));
}

test "unwrapWrapperType" {
    var te = try TestEnv.init(std.testing.allocator);
    defer te.deinit();
    var ctx = TestContext.init(std.testing.allocator, &te);
    defer ctx.deinit();
    const b = te.types.builtins;

    const wrapped = try te.types.wrapperOf(b.int_type);
    try std.testing.expectEqual(b.int_type, unwrapWrapperType(&ctx, wrapped).?);
    try std.testing.expectEqual(@as(?types.TypeRef, null), unwrapWrapperType(&ctx, b.int_type));
    try std.testing.expectEqual(@as(?types.TypeRef, null), unwrapWrapperType(&ctx, b.string_type));
}

test "optionalInnerType" {
    var te = try TestEnv.init(std.testing.allocator);
    defer te.deinit();
    var ctx = TestContext.init(std.testing.allocator, &te);
    defer ctx.deinit();
    const b = te.types.builtins;

    const opt = try te.types.optionalOf(b.string_type);
    try std.testing.expectEqual(b.string_type, optionalInnerType(&ctx, opt).?);
    try std.testing.expectEqual(@as(?types.TypeRef, null), optionalInnerType(&ctx, b.int_type));
    try std.testing.expectEqual(@as(?types.TypeRef, null), optionalInnerType(&ctx, b.string_type));
}

test "joinTypes" {
    var te = try TestEnv.init(std.testing.allocator);
    defer te.deinit();
    var ctx = TestContext.init(std.testing.allocator, &te);
    defer ctx.deinit();
    const b = te.types.builtins;

    // Same type → that type; different → dyn
    const cases = [_]struct { a: types.TypeRef, bb: types.TypeRef, expected: types.TypeRef }{
        .{ .a = b.int_type, .bb = b.int_type, .expected = b.int_type },
        .{ .a = b.string_type, .bb = b.string_type, .expected = b.string_type },
        .{ .a = b.int_type, .bb = b.string_type, .expected = b.dyn_type },
        .{ .a = b.bool_type, .bb = b.double_type, .expected = b.dyn_type },
    };
    for (cases) |case| {
        ctx.type_mappings.items.len = 0;
        const result = try joinTypes(anyerror, &ctx, case.a, case.bb);
        try std.testing.expectEqual(case.expected, result);
    }
}

test "isAssignableType" {
    var te = try TestEnv.init(std.testing.allocator);
    defer te.deinit();
    var ctx = TestContext.init(std.testing.allocator, &te);
    defer ctx.deinit();
    const b = te.types.builtins;
    const list_int = try te.types.listOf(b.int_type);
    const list_str = try te.types.listOf(b.string_type);
    const map_si = try te.types.mapOf(b.string_type, b.int_type);
    const map_ss = try te.types.mapOf(b.string_type, b.string_type);
    const wrapped = try te.types.wrapperOf(b.int_type);

    const true_cases = [_]struct { expected: types.TypeRef, actual: types.TypeRef }{
        .{ .expected = b.int_type, .actual = b.int_type },       // same type
        .{ .expected = b.dyn_type, .actual = b.int_type },       // dyn accepts anything
        .{ .expected = b.int_type, .actual = b.dyn_type },       // anything assignable to dyn
        .{ .expected = list_int, .actual = list_int },            // structural list
        .{ .expected = map_si, .actual = map_si },                // structural map
        .{ .expected = b.dyn_type, .actual = b.null_type },      // null to nullable
        .{ .expected = wrapped, .actual = b.int_type },          // wrapper unwraps
    };
    for (true_cases) |case| {
        ctx.type_mappings.items.len = 0;
        try std.testing.expect(try isAssignableType(anyerror, &ctx, case.expected, case.actual));
    }

    const false_cases = [_]struct { expected: types.TypeRef, actual: types.TypeRef }{
        .{ .expected = b.int_type, .actual = b.string_type },
        .{ .expected = list_int, .actual = list_str },
        .{ .expected = map_si, .actual = map_ss },
        .{ .expected = b.int_type, .actual = b.null_type },
    };
    for (false_cases) |case| {
        ctx.type_mappings.items.len = 0;
        try std.testing.expect(!try isAssignableType(anyerror, &ctx, case.expected, case.actual));
    }
}

test "isValidMapKey" {
    var te = try TestEnv.init(std.testing.allocator);
    defer te.deinit();
    var ctx = TestContext.init(std.testing.allocator, &te);
    defer ctx.deinit();
    const b = te.types.builtins;

    const valid = [_]types.TypeRef{ b.int_type, b.uint_type, b.bool_type, b.string_type, b.dyn_type };
    for (valid) |ty| try std.testing.expect(isValidMapKey(&ctx, ty));

    const invalid = [_]types.TypeRef{ b.double_type, b.bytes_type, b.null_type };
    for (invalid) |ty| try std.testing.expect(!isValidMapKey(&ctx, ty));
}

test "isNullableType" {
    var te = try TestEnv.init(std.testing.allocator);
    defer te.deinit();
    var ctx = TestContext.init(std.testing.allocator, &te);
    defer ctx.deinit();
    const b = te.types.builtins;
    const wrapped = try te.types.wrapperOf(b.int_type);

    const nullable = [_]types.TypeRef{ b.dyn_type, b.null_type, b.timestamp_type, b.duration_type, wrapped };
    for (nullable) |ty| try std.testing.expect(isNullableType(&ctx, ty));

    const non_nullable = [_]types.TypeRef{ b.int_type, b.string_type, b.bool_type, b.uint_type, b.double_type };
    for (non_nullable) |ty| try std.testing.expect(!isNullableType(&ctx, ty));
}

test "isEqualOrLessSpecific" {
    var te = try TestEnv.init(std.testing.allocator);
    defer te.deinit();
    var ctx = TestContext.init(std.testing.allocator, &te);
    defer ctx.deinit();
    const b = te.types.builtins;
    const list_dyn = try te.types.listOf(b.dyn_type);
    const list_int = try te.types.listOf(b.int_type);

    // (a, b) → a is equal or less specific than b
    const true_cases = [_]struct { a: types.TypeRef, b: types.TypeRef }{
        .{ .a = b.int_type, .b = b.int_type },
        .{ .a = b.dyn_type, .b = b.int_type },
        .{ .a = list_dyn, .b = list_int },
    };
    for (true_cases) |case| try std.testing.expect(isEqualOrLessSpecific(&ctx, case.a, case.b));

    const false_cases = [_]struct { a: types.TypeRef, b: types.TypeRef }{
        .{ .a = b.int_type, .b = b.dyn_type },
        .{ .a = list_int, .b = list_dyn },
    };
    for (false_cases) |case| try std.testing.expect(!isEqualOrLessSpecific(&ctx, case.a, case.b));
}
