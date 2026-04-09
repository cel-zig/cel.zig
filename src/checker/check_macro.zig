const std = @import("std");
const ast = @import("../parse/ast.zig");
const compiler_program = @import("../compiler/program.zig");
const strings = @import("../parse/string_table.zig");
const types = @import("../env/types.zig");

const BindingRef = compiler_program.BindingRef;
const MacroCall = compiler_program.MacroCall;

pub fn checkHasMacro(comptime ErrorType: type, self: anytype, index: ast.Index, call: ast.Call) ErrorType!types.TypeRef {
    if (call.args.len != 1) return ErrorType.InvalidMacro;
    const arg_index = self.ast.expr_ranges.items[call.args.start];
    switch (self.ast.node(arg_index).data) {
        .select => |select| {
            const target_ty = try self.check(select.target);
            const base_ty = self.optionalInnerType(target_ty) orelse target_ty;
            switch (self.env.types.spec(base_ty)) {
                .message => |name| {
                    const desc = self.env.lookupMessage(name) orelse return ErrorType.UnknownMessageType;
                    if (desc.kind != .plain) return ErrorType.InvalidMacro;
                    const field_name = self.ast.strings.get(select.field);
                    _ = desc.lookupField(field_name) orelse return ErrorType.UnknownMessageField;
                },
                .map, .dyn, .type_param => {},
                else => return ErrorType.InvalidMacro,
            }
        },
        .index => |access| {
            const target_ty = try self.check(access.target);
            const base_ty = self.optionalInnerType(target_ty) orelse target_ty;
            switch (self.env.types.spec(base_ty)) {
                .list, .map, .dyn, .type_param => {},
                else => return ErrorType.InvalidMacro,
            }
        },
        else => return ErrorType.InvalidMacro,
    }
    _ = try self.check(arg_index);

    self.resolutions[@intFromEnum(index)] = .{ .macro = .has };
    return self.env.types.builtins.bool_type;
}

pub fn checkBindMacro(comptime ErrorType: type, self: anytype, index: ast.Index, call: ast.Call) ErrorType!types.TypeRef {
    if (call.args.len != 3) return ErrorType.InvalidMacro;
    const binding_name = self.extractSimpleIdent(self.ast.expr_ranges.items[call.args.start]) orelse return ErrorType.InvalidMacro;
    const binding_ty = try self.check(self.ast.expr_ranges.items[call.args.start + 1]);
    try self.local_bindings.append(self.allocator, .{
        .name = .{ .ident = binding_name },
        .ty = binding_ty,
    });
    defer _ = self.local_bindings.pop();

    const body_ty = try self.check(self.ast.expr_ranges.items[call.args.start + 2]);
    self.resolutions[@intFromEnum(index)] = .{ .macro = .bind };
    return body_ty;
}

pub fn checkBlockMacro(comptime ErrorType: type, self: anytype, index: ast.Index, call: ast.Call) ErrorType!types.TypeRef {
    if (call.args.len != 2) return ErrorType.InvalidMacro;
    const bindings_index = self.ast.expr_ranges.items[call.args.start];
    const body_index = self.ast.expr_ranges.items[call.args.start + 1];
    const bindings_range = switch (self.ast.node(bindings_index).data) {
        .list => |range| range,
        else => return ErrorType.InvalidMacro,
    };

    const depth = self.block_depth;
    self.block_depth += 1;
    defer self.block_depth -= 1;

    const local_mark = self.local_bindings.items.len;
    defer self.local_bindings.items.len = local_mark;

    for (0..bindings_range.len) |i| {
        const item = self.ast.list_items.items[bindings_range.start + i];
        const expr_ty = try self.check(item.value);
        try self.local_bindings.append(self.allocator, .{
            .name = .{ .block_index = .{
                .depth = depth,
                .index = @intCast(i),
            } },
            .ty = expr_ty,
        });
    }

    const body_ty = try self.check(body_index);
    self.resolutions[@intFromEnum(index)] = .{ .macro = .block };
    return body_ty;
}

pub fn checkBlockIndexCall(comptime ErrorType: type, self: anytype, index: ast.Index, call: ast.Call) ErrorType!types.TypeRef {
    if (call.args.len != 1) return ErrorType.InvalidCall;
    if (self.block_depth == 0) return ErrorType.InvalidCall;
    const block_index = try self.parseU32LiteralArg(self.ast.expr_ranges.items[call.args.start]);
    const binding_ref: BindingRef = .{ .block_index = .{
        .depth = self.block_depth - 1,
        .index = block_index,
    } };
    const binding_ty = self.lookupBinding(binding_ref) orelse return ErrorType.InvalidCall;
    self.resolutions[@intFromEnum(index)] = .{ .block_index = .{
        .depth = binding_ref.block_index.depth,
        .index = binding_ref.block_index.index,
    } };
    return binding_ty;
}

pub fn checkIterVarCall(comptime ErrorType: type, self: anytype, index: ast.Index, call: ast.Call) ErrorType!types.TypeRef {
    const binding_ref = self.extractIterVarBindingFromCall(call) orelse return ErrorType.InvalidCall;
    const binding_ty = self.lookupBinding(binding_ref) orelse return ErrorType.InvalidCall;
    self.resolutions[@intFromEnum(index)] = .{ .iter_var = .{
        .depth = binding_ref.iter_var.depth,
        .slot = binding_ref.iter_var.slot,
    } };
    return binding_ty;
}

pub fn checkReceiverMacro(comptime ErrorType: type, self: anytype, index: ast.Index, call: ast.ReceiverCall) ErrorType!?types.TypeRef {
    const BindingPair = struct {
        first: types.TypeRef,
        second: types.TypeRef,
    };
    const macro_name = self.ast.strings.get(call.name);
    const has_list_library = self.env.hasLibrary("cel.lib.ext.lists");
    const has_two_var_library = self.env.hasLibrary("cel.lib.ext.comprev2");
    if (std.mem.eql(u8, macro_name, "bind") and receiverTargetIsNamespace(self, call.target, "cel")) {
        if (call.args.len != 3) return ErrorType.InvalidMacro;
        const binding_name = self.extractSimpleIdent(self.ast.expr_ranges.items[call.args.start]) orelse return ErrorType.InvalidMacro;
        const binding_ty = try self.check(self.ast.expr_ranges.items[call.args.start + 1]);
        try self.local_bindings.append(self.allocator, .{
            .name = .{ .ident = binding_name },
            .ty = binding_ty,
        });
        defer _ = self.local_bindings.pop();

        const body_ty = try self.check(self.ast.expr_ranges.items[call.args.start + 2]);
        self.resolutions[@intFromEnum(index)] = .{ .macro = .bind };
        return body_ty;
    }
    if (!std.mem.eql(u8, macro_name, "all") and
        !std.mem.eql(u8, macro_name, "exists") and
        !std.mem.eql(u8, macro_name, "exists_one") and
        !std.mem.eql(u8, macro_name, "existsOne") and
        !std.mem.eql(u8, macro_name, "optMap") and
        !std.mem.eql(u8, macro_name, "optFlatMap") and
        !std.mem.eql(u8, macro_name, "filter") and
        !std.mem.eql(u8, macro_name, "map") and
        !(has_list_library and std.mem.eql(u8, macro_name, "sortBy")) and
        !(has_two_var_library and std.mem.eql(u8, macro_name, "transformList")) and
        !(has_two_var_library and std.mem.eql(u8, macro_name, "transformMap")) and
        !(has_two_var_library and std.mem.eql(u8, macro_name, "transformMapEntry")))
    {
        return null;
    }

    const target_ty = try self.check(call.target);
    const target_optional_inner = self.optionalInnerType(target_ty);
    const target_spec = self.env.types.spec(target_ty);

    if (std.mem.eql(u8, macro_name, "optMap") or std.mem.eql(u8, macro_name, "optFlatMap")) {
        if (call.args.len != 2) return ErrorType.InvalidMacro;
        const binding_name = self.extractBindingRef(self.ast.expr_ranges.items[call.args.start]) orelse return ErrorType.InvalidMacro;
        const binding_ty = target_optional_inner orelse switch (target_spec) {
            .dyn, .type_param => self.env.types.builtins.dyn_type,
            else => return ErrorType.InvalidMacro,
        };

        try self.local_bindings.append(self.allocator, .{
            .name = binding_name,
            .ty = binding_ty,
        });
        defer _ = self.local_bindings.pop();

        const body_ty = try self.check(self.ast.expr_ranges.items[call.args.start + 1]);
        if (std.mem.eql(u8, macro_name, "optMap")) {
            self.resolutions[@intFromEnum(index)] = .{ .macro = .opt_map };
            return try self.env.types.optionalOf(body_ty);
        }

        self.resolutions[@intFromEnum(index)] = .{ .macro = .opt_flat_map };
        if (self.optionalInnerType(body_ty) != null or self.env.types.spec(body_ty) == .dyn) {
            return body_ty;
        }
        return ErrorType.InvalidMacro;
    }

    if (has_list_library and std.mem.eql(u8, macro_name, "sortBy")) {
        if (call.args.len != 2) return ErrorType.InvalidMacro;
        const iter_name = self.extractBindingRef(self.ast.expr_ranges.items[call.args.start]) orelse return ErrorType.InvalidMacro;
        const element_ty = switch (target_spec) {
            .list => |elem_ty| elem_ty,
            .dyn => self.env.types.builtins.dyn_type,
            else => return ErrorType.InvalidMacro,
        };

        try self.local_bindings.append(self.allocator, .{
            .name = iter_name,
            .ty = element_ty,
        });
        defer _ = self.local_bindings.pop();

        const key_ty = try self.check(self.ast.expr_ranges.items[call.args.start + 1]);
        if (!self.env.types.isSimpleComparable(key_ty) and self.env.types.spec(key_ty) != .dyn) {
            return ErrorType.InvalidMacro;
        }

        self.resolutions[@intFromEnum(index)] = .{ .macro = .sort_by };
        return target_ty;
    }

    if (std.mem.eql(u8, macro_name, "all") or
        std.mem.eql(u8, macro_name, "exists") or
        std.mem.eql(u8, macro_name, "exists_one") or
        std.mem.eql(u8, macro_name, "existsOne"))
    {
        if (call.args.len == 2) {
            const iter_name = self.extractBindingRef(self.ast.expr_ranges.items[call.args.start]) orelse return ErrorType.InvalidMacro;
            const element_ty = switch (target_spec) {
                .list => |elem_ty| elem_ty,
                .map => |m| m.key,
                .dyn => self.env.types.builtins.dyn_type,
                else => return ErrorType.InvalidMacro,
            };

            try self.local_bindings.append(self.allocator, .{
                .name = iter_name,
                .ty = element_ty,
            });
            defer _ = self.local_bindings.pop();

            const pred_ty = try self.check(self.ast.expr_ranges.items[call.args.start + 1]);
            if (!self.isBoolish(pred_ty)) return ErrorType.InvalidMacro;

            self.resolutions[@intFromEnum(index)] = .{ .macro = if (std.mem.eql(u8, macro_name, "all"))
                .all
            else if (std.mem.eql(u8, macro_name, "exists"))
                .exists
            else
                .exists_one };
            return self.env.types.builtins.bool_type;
        }

        if (call.args.len != 3) return ErrorType.InvalidMacro;
        const first_name = self.extractBindingRef(self.ast.expr_ranges.items[call.args.start]) orelse return ErrorType.InvalidMacro;
        const second_name = self.extractBindingRef(self.ast.expr_ranges.items[call.args.start + 1]) orelse return ErrorType.InvalidMacro;
        const bindings = switch (target_spec) {
            .list => |elem_ty| BindingPair{
                .first = self.env.types.builtins.int_type,
                .second = elem_ty,
            },
            .map => |m| BindingPair{
                .first = m.key,
                .second = m.value,
            },
            .dyn => BindingPair{
                .first = self.env.types.builtins.dyn_type,
                .second = self.env.types.builtins.dyn_type,
            },
            else => return ErrorType.InvalidMacro,
        };

        try self.local_bindings.append(self.allocator, .{
            .name = first_name,
            .ty = bindings.first,
        });
        defer _ = self.local_bindings.pop();
        try self.local_bindings.append(self.allocator, .{
            .name = second_name,
            .ty = bindings.second,
        });
        defer _ = self.local_bindings.pop();

        const pred_ty = try self.check(self.ast.expr_ranges.items[call.args.start + 2]);
        if (!self.isBoolish(pred_ty)) return ErrorType.InvalidMacro;

        self.resolutions[@intFromEnum(index)] = .{ .macro = if (std.mem.eql(u8, macro_name, "all"))
            .all
        else if (std.mem.eql(u8, macro_name, "exists"))
            .exists
        else
            .exists_one };
        return self.env.types.builtins.bool_type;
    }

    if (std.mem.eql(u8, macro_name, "filter")) {
        if (call.args.len != 2) return ErrorType.InvalidMacro;
        const iter_name = self.extractBindingRef(self.ast.expr_ranges.items[call.args.start]) orelse return ErrorType.InvalidMacro;
        const element_ty = switch (target_spec) {
            .list => |elem_ty| elem_ty,
            .map => |m| m.key,
            .dyn => self.env.types.builtins.dyn_type,
            else => return ErrorType.InvalidMacro,
        };

        try self.local_bindings.append(self.allocator, .{
            .name = iter_name,
            .ty = element_ty,
        });
        defer _ = self.local_bindings.pop();

        const pred_ty = try self.check(self.ast.expr_ranges.items[call.args.start + 1]);
        if (!self.isBoolish(pred_ty)) return ErrorType.InvalidMacro;

        self.resolutions[@intFromEnum(index)] = .{ .macro = .filter };
        const result_ty = switch (target_spec) {
            .list => target_ty,
            .map, .dyn => try self.env.types.listOf(element_ty),
            else => unreachable,
        };
        return result_ty;
    }

    if (std.mem.eql(u8, macro_name, "map")) {
        if (call.args.len < 2 or call.args.len > 3) return ErrorType.InvalidMacro;
        const iter_name = self.extractBindingRef(self.ast.expr_ranges.items[call.args.start]) orelse return ErrorType.InvalidMacro;
        const element_ty = switch (target_spec) {
            .list => |elem_ty| elem_ty,
            .map => |m| m.key,
            .dyn => self.env.types.builtins.dyn_type,
            else => return ErrorType.InvalidMacro,
        };

        try self.local_bindings.append(self.allocator, .{
            .name = iter_name,
            .ty = element_ty,
        });
        defer _ = self.local_bindings.pop();

        const result_ty = if (call.args.len == 2) blk: {
            break :blk try self.check(self.ast.expr_ranges.items[call.args.start + 1]);
        } else blk: {
            const pred_ty = try self.check(self.ast.expr_ranges.items[call.args.start + 1]);
            if (!self.isBoolish(pred_ty)) return ErrorType.InvalidMacro;
            break :blk try self.check(self.ast.expr_ranges.items[call.args.start + 2]);
        };

        self.resolutions[@intFromEnum(index)] = .{ .macro = if (call.args.len == 2) .map else .map_filter };
        return try self.env.types.listOf(result_ty);
    }

    if (has_two_var_library and (std.mem.eql(u8, macro_name, "transformList") or
        std.mem.eql(u8, macro_name, "transformMap") or
        std.mem.eql(u8, macro_name, "transformMapEntry")))
    {
        const expects_map = std.mem.eql(u8, macro_name, "transformMap") or std.mem.eql(u8, macro_name, "transformMapEntry");
        const entry_map = std.mem.eql(u8, macro_name, "transformMapEntry");
        if (call.args.len < 3 or call.args.len > 4) return ErrorType.InvalidMacro;
        const first_name = self.extractBindingRef(self.ast.expr_ranges.items[call.args.start]) orelse return ErrorType.InvalidMacro;
        const second_name = self.extractBindingRef(self.ast.expr_ranges.items[call.args.start + 1]) orelse return ErrorType.InvalidMacro;
        const bindings = switch (target_spec) {
            .list => |elem_ty| BindingPair{
                .first = self.env.types.builtins.int_type,
                .second = elem_ty,
            },
            .map => |m| BindingPair{
                .first = m.key,
                .second = m.value,
            },
            .dyn => BindingPair{
                .first = self.env.types.builtins.dyn_type,
                .second = self.env.types.builtins.dyn_type,
            },
            else => return ErrorType.InvalidMacro,
        };

        try self.local_bindings.append(self.allocator, .{
            .name = first_name,
            .ty = bindings.first,
        });
        defer _ = self.local_bindings.pop();
        try self.local_bindings.append(self.allocator, .{
            .name = second_name,
            .ty = bindings.second,
        });
        defer _ = self.local_bindings.pop();

        const transform_index: ast.Index = if (call.args.len == 3)
            self.ast.expr_ranges.items[call.args.start + 2]
        else
            self.ast.expr_ranges.items[call.args.start + 3];

        const result_ty = if (call.args.len == 3) blk: {
            break :blk try self.check(transform_index);
        } else blk: {
            const pred_ty = try self.check(self.ast.expr_ranges.items[call.args.start + 2]);
            if (!self.isBoolish(pred_ty)) return ErrorType.InvalidMacro;
            break :blk try self.check(transform_index);
        };

        self.resolutions[@intFromEnum(index)] = .{ .macro = if (entry_map)
            if (call.args.len == 3) .transform_map_entry else .transform_map_entry_filter
        else if (expects_map)
            if (call.args.len == 3) .transform_map else .transform_map_filter
        else if (call.args.len == 3)
            .transform_list
        else
            .transform_list_filter };
        if (entry_map) {
            return try checkSingleEntryMapTransform(ErrorType, self, transform_index, result_ty);
        }
        if (expects_map) {
            return try self.env.types.mapOf(bindings.first, result_ty);
        }
        return try self.env.types.listOf(result_ty);
    }

    return null;
}

fn checkSingleEntryMapTransform(comptime ErrorType: type, self: anytype, transform_index: ast.Index, transform_ty: types.TypeRef) ErrorType!types.TypeRef {
    return switch (self.env.types.spec(transform_ty)) {
        .dyn => try self.env.types.mapOf(self.env.types.builtins.dyn_type, self.env.types.builtins.dyn_type),
        .map => switch (self.ast.node(transform_index).data) {
            .map => |range| blk: {
                if (range.len != 1) return ErrorType.InvalidMacro;
                const entry = self.ast.map_entries.items[range.start];
                if (entry.optional) return ErrorType.InvalidMacro;
                break :blk transform_ty;
            },
            else => return ErrorType.InvalidMacro,
        },
        else => ErrorType.InvalidMacro,
    };
}

pub fn receiverTargetIsNamespace(self: anytype, target: ast.Index, namespace: []const u8) bool {
    const ident_id = self.extractSimpleIdent(target) orelse return false;
    return std.mem.eql(u8, self.ast.strings.get(ident_id), namespace);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const checker = @import("check.zig");
const env_mod = @import("../env/env.zig");
const comprehensions_ext = @import("../library/comprehensions_ext.zig");
const list_ext = @import("../library/list_ext.zig");

test "macro type inference for quantifiers returns bool" {
    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const list_int = try environment.types.listOf(environment.types.builtins.int_type);
    try environment.addVarTyped("xs", list_int);

    const b = environment.types.builtins;

    const cases = [_]struct { expr: []const u8, expected: types.TypeRef }{
        .{ .expr = "xs.all(x, x > 0)", .expected = b.bool_type },
        .{ .expr = "xs.exists(x, x > 0)", .expected = b.bool_type },
        .{ .expr = "xs.exists_one(x, x == 1)", .expected = b.bool_type },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        try std.testing.expectEqual(case.expected, program.result_type);
    }
}

test "macro filter returns same list type" {
    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const list_int = try environment.types.listOf(environment.types.builtins.int_type);
    try environment.addVarTyped("xs", list_int);

    var program = try checker.compile(std.testing.allocator, &environment, "xs.filter(x, x > 0)");
    defer program.deinit();
    try std.testing.expectEqual(list_int, program.result_type);
}

test "macro map returns list of mapped element type" {
    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const list_int = try environment.types.listOf(environment.types.builtins.int_type);
    try environment.addVarTyped("xs", list_int);

    // map(x, x > 0) maps int -> bool, result should be list(bool)
    var program = try checker.compile(std.testing.allocator, &environment, "xs.map(x, x > 0)");
    defer program.deinit();
    const expected_list = try environment.types.listOf(environment.types.builtins.bool_type);
    try std.testing.expectEqual(expected_list, program.result_type);
}

test "macro has on message field returns bool" {
    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const msg_ty = try environment.addMessage("Msg");
    try environment.addMessageField("Msg", "name", environment.types.builtins.string_type);
    try environment.addVarTyped("m", msg_ty);

    var program = try checker.compile(std.testing.allocator, &environment, "has(m.name)");
    defer program.deinit();
    try std.testing.expectEqual(environment.types.builtins.bool_type, program.result_type);
}

test "macro has on map index returns bool" {
    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const map_ty = try environment.types.mapOf(environment.types.builtins.string_type, environment.types.builtins.int_type);
    try environment.addVarTyped("m", map_ty);

    var program = try checker.compile(std.testing.allocator, &environment, "has(m['key'])");
    defer program.deinit();
    try std.testing.expectEqual(environment.types.builtins.bool_type, program.result_type);
}

test "macro error: non-iterable target for quantifiers" {
    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const cases = [_][]const u8{
        "1.all(x, true)",
        "1.exists(x, true)",
        "1.exists_one(x, true)",
        "'s'.all(x, true)",
        "'s'.filter(x, true)",
        "'s'.map(x, x)",
        "true.all(x, true)",
    };
    for (cases) |expr| {
        try std.testing.expectError(
            checker.Error.InvalidMacro,
            checker.compile(std.testing.allocator, &environment, expr),
        );
    }
}

test "macro error: has with invalid argument" {
    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    // has() requires a select or index expression as argument
    const cases = [_][]const u8{
        "has(1)",
        "has(true)",
        "has('s')",
    };
    for (cases) |expr| {
        try std.testing.expectError(
            checker.Error.InvalidMacro,
            checker.compile(std.testing.allocator, &environment, expr),
        );
    }
}

test "macro error: has on non-message select target" {
    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.int_type);

    try std.testing.expectError(
        checker.Error.InvalidMacro,
        checker.compile(std.testing.allocator, &environment, "has(x.field)"),
    );
}

test "macro quantifiers work on map keys" {
    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const map_ty = try environment.types.mapOf(environment.types.builtins.string_type, environment.types.builtins.int_type);
    try environment.addVarTyped("m", map_ty);

    const cases = [_][]const u8{
        "m.all(k, k == 'a')",
        "m.exists(k, k == 'a')",
        "m.exists_one(k, k == 'a')",
        "m.filter(k, k == 'a')",
    };
    for (cases) |expr| {
        var program = try checker.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
    }
}

test "macro map with filter predicate returns list" {
    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const list_int = try environment.types.listOf(environment.types.builtins.int_type);
    try environment.addVarTyped("xs", list_int);

    // map with 3 args: iter var, predicate, transform
    var program = try checker.compile(std.testing.allocator, &environment, "xs.map(x, x > 0, x * 2)");
    defer program.deinit();
    switch (environment.types.spec(program.result_type)) {
        .list => |elem| try std.testing.expectEqual(environment.types.builtins.int_type, elem),
        else => return error.TestUnexpectedResult,
    }
}

test "macro two-variable quantifiers on list" {
    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const list_int = try environment.types.listOf(environment.types.builtins.int_type);
    try environment.addVarTyped("xs", list_int);

    const cases = [_][]const u8{
        "xs.all(i, v, v > 0)",
        "xs.exists(i, v, v > 0)",
        "xs.exists_one(i, v, v > 0)",
    };
    for (cases) |expr| {
        var program = try checker.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        try std.testing.expectEqual(environment.types.builtins.bool_type, program.result_type);
    }
}

test "macro dyn target allows quantifiers" {
    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("d", environment.types.builtins.dyn_type);

    const cases = [_][]const u8{
        "d.all(x, x > 0)",
        "d.exists(x, true)",
        "d.filter(x, true)",
        "d.map(x, x)",
    };
    for (cases) |expr| {
        var program = try checker.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
    }
}

test "sortBy returns same list type when lists library is installed" {
    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(list_ext.list_library);
    const list_int = try environment.types.listOf(environment.types.builtins.int_type);
    try environment.addVarTyped("xs", list_int);

    var program = try checker.compile(std.testing.allocator, &environment, "xs.sortBy(x, -x)");
    defer program.deinit();
    try std.testing.expectEqual(list_int, program.result_type);
}

test "transformMapEntry infers map result when two-var library is installed" {
    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(comprehensions_ext.two_var_comprehensions_library);
    const list_int = try environment.types.listOf(environment.types.builtins.int_type);
    try environment.addVarTyped("xs", list_int);

    var program = try checker.compile(std.testing.allocator, &environment, "xs.transformMapEntry(i, v, {v: i})");
    defer program.deinit();
    const expected = try environment.types.mapOf(environment.types.builtins.int_type, environment.types.builtins.int_type);
    try std.testing.expectEqual(expected, program.result_type);

    try std.testing.expectError(
        checker.Error.InvalidMacro,
        checker.compile(std.testing.allocator, &environment, "xs.transformMapEntry(i, v, {v: i, i: v})"),
    );
}
