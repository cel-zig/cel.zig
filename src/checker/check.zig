const std = @import("std");
const ast = @import("../parse/ast.zig");
const check_macro = @import("check_macro.zig");
const check_overload = @import("check_overload.zig");
const compile_prepare = @import("../compiler/prepare.zig");
const compiler_program = @import("../compiler/program.zig");
const env = @import("../env/env.zig");
const InlineList = @import("../util/inline_list.zig").InlineList;
const parser = @import("../parse/parser.zig");
const resolve = @import("resolve.zig");
const stdlib = @import("../library/stdlib.zig");
const strings = @import("../parse/string_table.zig");
const types = @import("../env/types.zig");
const typing = @import("typing.zig");

pub const Error = parser.Error || error{
    UndefinedIdentifier,
    InvalidUnaryOperand,
    InvalidBinaryOperand,
    InvalidConditionalCondition,
    InvalidConditionalArms,
    InvalidIndexOperand,
    InvalidSelectOperand,
    InvalidCall,
    InvalidMapKeyType,
    HeterogeneousList,
    HeterogeneousMap,
    UnknownMessageType,
    UnknownMessageField,
    InvalidMessageField,
    DuplicateMessageField,
    InvalidMacro,
    InvalidOptionalLiteral,
};

pub const MacroCall = compiler_program.MacroCall;
pub const BindingRef = compiler_program.BindingRef;
pub const CallResolution = compiler_program.CallResolution;
pub const Program = compiler_program.Program;
pub const PrepareError = compile_prepare.PrepareError;
pub const bindingRefEql = compiler_program.bindingRefEql;

fn bindingMatchesIdent(binding: BindingRef, id: strings.StringTable.Id) bool {
    return compiler_program.bindingMatchesIdent(binding, id);
}

pub fn compile(
    allocator: std.mem.Allocator,
    environment: *env.Env,
    source: []const u8,
) Error!Program {
    const tree = try parser.parse(allocator, source);
    return compileParsedMode(.checked, allocator, environment, tree);
}

pub fn compileUnchecked(
    allocator: std.mem.Allocator,
    environment: *env.Env,
    source: []const u8,
) parser.Error!Program {
    const tree = try parser.parse(allocator, source);
    return compileParsedMode(.unchecked, allocator, environment, tree);
}

pub fn compileParsed(
    analysis_allocator: std.mem.Allocator,
    environment: *env.Env,
    tree: ast.Ast,
) Error!Program {
    return compileParsedMode(.checked, analysis_allocator, environment, tree);
}

pub fn compileParsedUnchecked(
    analysis_allocator: std.mem.Allocator,
    environment: *env.Env,
    tree: ast.Ast,
) parser.Error!Program {
    return compileParsedMode(.unchecked, analysis_allocator, environment, tree);
}

const CompileMode = enum {
    checked,
    unchecked,
};

fn compileParsedMode(
    comptime mode: CompileMode,
    analysis_allocator: std.mem.Allocator,
    environment: *env.Env,
    tree: ast.Ast,
) (if (mode == .checked) Error else parser.Error)!Program {
    errdefer {
        var temp = tree;
        temp.deinit();
    }
    try prepareEnvironment(environment);

    var node_types: std.ArrayListUnmanaged(types.TypeRef) = .empty;
    errdefer node_types.deinit(analysis_allocator);
    try node_types.resize(analysis_allocator, tree.nodes.items.len);
    @memset(node_types.items, environment.types.builtins.dyn_type);

    var resolutions: std.ArrayListUnmanaged(CallResolution) = .empty;
    errdefer resolutions.deinit(analysis_allocator);
    try resolutions.resize(analysis_allocator, tree.nodes.items.len);
    @memset(resolutions.items, .none);

    var operator_resolutions: std.ArrayListUnmanaged(?env.ResolutionRef) = .empty;
    errdefer operator_resolutions.deinit(analysis_allocator);
    try operator_resolutions.resize(analysis_allocator, tree.nodes.items.len);
    @memset(operator_resolutions.items, null);

    const result_type = switch (mode) {
        .checked => blk: {
            var typed_checker = Checker{
                .allocator = analysis_allocator,
                .env = environment,
                .ast = &tree,
                .node_types = node_types.items,
                .resolutions = resolutions.items,
                .operator_resolutions = operator_resolutions.items,
            };
            defer {
                typed_checker.local_bindings.deinit(analysis_allocator);
                typed_checker.type_mappings.deinit(analysis_allocator);
            }
            const raw_result = try typed_checker.check(tree.root.?);
            for (node_types.items) |*node_ty| {
                node_ty.* = try typed_checker.substituteType(node_ty.*, true);
            }
            break :blk try typed_checker.substituteType(raw_result, true);
        },
        .unchecked => blk: {
            var untyped = UncheckedCompiler{
                .allocator = analysis_allocator,
                .env = environment,
                .ast = &tree,
                .node_types = node_types.items,
                .resolutions = resolutions.items,
            };
            defer untyped.local_bindings.deinit(analysis_allocator);
            break :blk try untyped.walk(tree.root.?);
        },
    };
    node_types.deinit(analysis_allocator);
    return .{
        .env = environment,
        .ast = tree,
        .analysis_allocator = analysis_allocator,
        .call_resolution = resolutions,
        .operator_resolution = operator_resolutions,
        .result_type = result_type,
    };
}

pub fn prepareEnvironment(environment: *env.Env) PrepareError!void {
    return compile_prepare.prepareEnvironment(environment);
}

const UncheckedCompiler = struct {
    allocator: std.mem.Allocator,
    env: *env.Env,
    ast: *const ast.Ast,
    node_types: []types.TypeRef,
    resolutions: []CallResolution,
    local_bindings: std.ArrayListUnmanaged(Checker.LocalBinding) = .empty,

    fn walk(self: *UncheckedCompiler, index: ast.Index) parser.Error!types.TypeRef {
        const idx = @intFromEnum(index);
        const ty = try self.walkNode(index);
        self.node_types[idx] = ty;
        return ty;
    }

    fn walkNode(self: *UncheckedCompiler, index: ast.Index) parser.Error!types.TypeRef {
        const node = self.ast.node(index);
        return switch (node.data) {
            .literal_int => self.env.types.builtins.int_type,
            .literal_uint => self.env.types.builtins.uint_type,
            .literal_double => self.env.types.builtins.double_type,
            .literal_string => self.env.types.builtins.string_type,
            .literal_bytes => self.env.types.builtins.bytes_type,
            .literal_bool => self.env.types.builtins.bool_type,
            .literal_null => self.env.types.builtins.null_type,
            .ident => |name_ref| self.walkIdent(name_ref),
            .unary => |unary| blk: {
                _ = try self.walk(unary.expr);
                break :blk self.env.types.builtins.dyn_type;
            },
            .binary => |binary| blk: {
                _ = try self.walk(binary.left);
                _ = try self.walk(binary.right);
                break :blk switch (binary.op) {
                    .logical_and, .logical_or, .less, .less_equal, .greater, .greater_equal, .equal, .not_equal, .in_set => self.env.types.builtins.bool_type,
                    else => self.env.types.builtins.dyn_type,
                };
            },
            .conditional => |conditional| blk: {
                _ = try self.walk(conditional.condition);
                _ = try self.walk(conditional.then_expr);
                _ = try self.walk(conditional.else_expr);
                break :blk self.env.types.builtins.dyn_type;
            },
            .list => |range| blk: {
                for (0..range.len) |i| _ = try self.walk(self.ast.list_items.items[range.start + i].value);
                break :blk try self.env.types.listOf(self.env.types.builtins.dyn_type);
            },
            .map => |range| blk: {
                for (0..range.len) |i| {
                    const entry = self.ast.map_entries.items[range.start + i];
                    _ = try self.walk(entry.key);
                    _ = try self.walk(entry.value);
                }
                break :blk try self.env.types.mapOf(self.env.types.builtins.dyn_type, self.env.types.builtins.dyn_type);
            },
            .index => |access| blk: {
                _ = try self.walk(access.target);
                _ = try self.walk(access.index);
                break :blk self.env.types.builtins.dyn_type;
            },
            .select => |select| blk: {
                _ = try self.walk(select.target);
                break :blk self.env.types.builtins.dyn_type;
            },
            .call => |call| self.walkCall(index, call),
            .receiver_call => |call| self.walkReceiverCall(index, call),
            .message => |msg| blk: {
                var joined_storage: std.ArrayListUnmanaged(u8) = .empty;
                defer joined_storage.deinit(self.allocator);
                var joined_small: [256]u8 = undefined;
                const joined = try self.joinNameRefInto(msg.name, &joined_storage, joined_small[0..]);
                for (0..msg.fields.len) |i| {
                    const field = self.ast.field_inits.items[msg.fields.start + i];
                    _ = try self.walk(field.value);
                }
                const desc = self.env.lookupMessageScoped(self.allocator, joined, msg.name.absolute) catch null;
                if (desc) |resolved| {
                    break :blk try self.env.types.messageOf(resolved.name);
                }
                break :blk self.env.types.builtins.dyn_type;
            },
        };
    }

    fn walkIdent(self: *UncheckedCompiler, name_ref: ast.NameRef) parser.Error!types.TypeRef {
        if (!name_ref.absolute and name_ref.segments.len == 1) {
            const id = self.ast.name_segments.items[name_ref.segments.start];
            var i = self.local_bindings.items.len;
            while (i > 0) {
                i -= 1;
                const binding = self.local_bindings.items[i];
                if (bindingMatchesIdent(binding.name, id)) return binding.ty;
            }
        }
        var joined_storage: std.ArrayListUnmanaged(u8) = .empty;
        defer joined_storage.deinit(self.allocator);
        var joined_small: [256]u8 = undefined;
        const joined = try self.joinNameRefInto(name_ref, &joined_storage, joined_small[0..]);
        return (self.env.lookupVarScoped(self.allocator, joined, name_ref.absolute) catch null) orelse self.env.types.builtins.dyn_type;
    }

    fn walkCall(self: *UncheckedCompiler, index: ast.Index, call: ast.Call) parser.Error!types.TypeRef {
        for (0..call.args.len) |i| {
            _ = try self.walk(self.ast.expr_ranges.items[call.args.start + i]);
        }

        var joined_storage: std.ArrayListUnmanaged(u8) = .empty;
        defer joined_storage.deinit(self.allocator);
        var joined_small: [256]u8 = undefined;
        const joined = try self.joinNameRefInto(call.name, &joined_storage, joined_small[0..]);
        if (!call.name.absolute and call.name.segments.len == 1) {
            const segment_id = self.ast.name_segments.items[call.name.segments.start];
            const name = self.ast.strings.get(segment_id);
            if (std.mem.eql(u8, name, "has") and call.args.len == 1) {
                self.resolutions[@intFromEnum(index)] = .{ .macro = .has };
                return self.env.types.builtins.bool_type;
            }
        }
        if (self.env.enum_mode == .strong) {
            if (try self.env.lookupEnumScoped(self.allocator, joined, call.name.absolute)) |enum_decl| {
                if (call.args.len == 1) {
                    self.resolutions[@intFromEnum(index)] = .{ .enum_ctor = enum_decl.ty };
                    return enum_decl.ty;
                }
            }
        }
        if (!call.name.absolute and std.mem.eql(u8, joined, "cel.bind") and call.args.len == 3) {
            self.resolutions[@intFromEnum(index)] = .{ .macro = .bind };
            return self.env.types.builtins.dyn_type;
        }
        var args: [8]types.TypeRef = undefined;
        var dynamic = std.ArrayListUnmanaged(types.TypeRef).empty;
        defer dynamic.deinit(self.allocator);
        const arg_types = try self.collectArgTypes(call.args, &args, &dynamic);
        if (try self.env.findOverloadScoped(self.allocator, joined, call.name.absolute, false, arg_types)) |resolved| {
            self.resolutions[@intFromEnum(index)] = .{ .custom = .{
                .ref = resolved,
                .receiver_style = false,
            } };
            return self.env.overloadAt(resolved).result;
        }
        if (try self.env.findDynamicFunctionScoped(self.allocator, joined, call.name.absolute, false, arg_types)) |resolved| {
            self.resolutions[@intFromEnum(index)] = .{ .dynamic = .{
                .ref = resolved.ref,
                .receiver_style = false,
            } };
            return resolved.result;
        }
        return self.env.types.builtins.dyn_type;
    }

    fn walkReceiverCall(self: *UncheckedCompiler, index: ast.Index, call: ast.ReceiverCall) parser.Error!types.TypeRef {
        const name = self.ast.strings.get(call.name);
        if (self.receiverTargetIsNamespace(call.target, "cel")) {
            if (std.mem.eql(u8, name, "block") and call.args.len == 2) {
                _ = try self.walk(self.ast.expr_ranges.items[call.args.start]);
                _ = try self.walk(self.ast.expr_ranges.items[call.args.start + 1]);
                self.resolutions[@intFromEnum(index)] = .{ .macro = .block };
                return self.env.types.builtins.dyn_type;
            }
            if (std.mem.eql(u8, name, "index") and call.args.len == 1) {
                _ = try self.walk(self.ast.expr_ranges.items[call.args.start]);
                self.resolutions[@intFromEnum(index)] = .{ .block_index = .{
                    .depth = 0,
                    .index = 0,
                } };
                return self.env.types.builtins.dyn_type;
            }
            if (std.mem.eql(u8, name, "iterVar") and call.args.len == 2) {
                _ = try self.walk(self.ast.expr_ranges.items[call.args.start]);
                _ = try self.walk(self.ast.expr_ranges.items[call.args.start + 1]);
                self.resolutions[@intFromEnum(index)] = .{ .iter_var = .{
                    .depth = 0,
                    .slot = 0,
                } };
                return self.env.types.builtins.dyn_type;
            }
        }
        if (std.mem.eql(u8, name, "bind") and self.receiverTargetIsNamespace(call.target, "cel") and call.args.len == 3) {
            _ = try self.walk(self.ast.expr_ranges.items[call.args.start + 1]);
            _ = try self.walk(self.ast.expr_ranges.items[call.args.start + 2]);
            self.resolutions[@intFromEnum(index)] = .{ .macro = .bind };
            return self.env.types.builtins.dyn_type;
        }

        _ = try self.walk(call.target);
        for (0..call.args.len) |i| {
            _ = try self.walk(self.ast.expr_ranges.items[call.args.start + i]);
        }

        if ((std.mem.eql(u8, name, "all") or
            std.mem.eql(u8, name, "exists") or
            std.mem.eql(u8, name, "exists_one") or
            std.mem.eql(u8, name, "existsOne")) and (call.args.len == 2 or call.args.len == 3))
        {
            self.resolutions[@intFromEnum(index)] = .{ .macro = if (std.mem.eql(u8, name, "all"))
                .all
            else if (std.mem.eql(u8, name, "exists"))
                .exists
            else
                .exists_one };
            return self.env.types.builtins.bool_type;
        }
        if (std.mem.eql(u8, name, "filter") and call.args.len == 2) {
            self.resolutions[@intFromEnum(index)] = .{ .macro = .filter };
            return try self.env.types.listOf(self.env.types.builtins.dyn_type);
        }
        if (std.mem.eql(u8, name, "optMap") and call.args.len == 2) {
            self.resolutions[@intFromEnum(index)] = .{ .macro = .opt_map };
            return try self.env.types.optionalOf(self.env.types.builtins.dyn_type);
        }
        if (std.mem.eql(u8, name, "optFlatMap") and call.args.len == 2) {
            self.resolutions[@intFromEnum(index)] = .{ .macro = .opt_flat_map };
            return try self.env.types.optionalOf(self.env.types.builtins.dyn_type);
        }
        if (std.mem.eql(u8, name, "map") and (call.args.len == 2 or call.args.len == 3)) {
            self.resolutions[@intFromEnum(index)] = .{ .macro = if (call.args.len == 2) .map else .map_filter };
            return try self.env.types.listOf(self.env.types.builtins.dyn_type);
        }
        if (self.env.hasLibrary("cel.lib.ext.lists") and std.mem.eql(u8, name, "sortBy") and call.args.len == 2) {
            self.resolutions[@intFromEnum(index)] = .{ .macro = .sort_by };
            return self.node_types[@intFromEnum(call.target)];
        }
        if (self.env.hasLibrary("cel.lib.ext.comprev2") and std.mem.eql(u8, name, "transformList") and (call.args.len == 3 or call.args.len == 4)) {
            self.resolutions[@intFromEnum(index)] = .{ .macro = if (call.args.len == 3) .transform_list else .transform_list_filter };
            return try self.env.types.listOf(self.env.types.builtins.dyn_type);
        }
        if (self.env.hasLibrary("cel.lib.ext.comprev2") and std.mem.eql(u8, name, "transformMap") and (call.args.len == 3 or call.args.len == 4)) {
            self.resolutions[@intFromEnum(index)] = .{ .macro = if (call.args.len == 3) .transform_map else .transform_map_filter };
            return try self.env.types.mapOf(self.env.types.builtins.dyn_type, self.env.types.builtins.dyn_type);
        }
        if (self.env.hasLibrary("cel.lib.ext.comprev2") and std.mem.eql(u8, name, "transformMapEntry") and (call.args.len == 3 or call.args.len == 4)) {
            self.resolutions[@intFromEnum(index)] = .{ .macro = if (call.args.len == 3) .transform_map_entry else .transform_map_entry_filter };
            return try self.env.types.mapOf(self.env.types.builtins.dyn_type, self.env.types.builtins.dyn_type);
        }

        var small: [8]types.TypeRef = undefined;
        var dynamic = std.ArrayListUnmanaged(types.TypeRef).empty;
        defer dynamic.deinit(self.allocator);
        try dynamic.append(self.allocator, self.node_types[@intFromEnum(call.target)]);
        const arg_types = try self.collectArgTypes(call.args, small[1..], &dynamic);
        if (self.env.findOverload(name, true, arg_types)) |resolved| {
            self.resolutions[@intFromEnum(index)] = .{ .custom = .{
                .ref = resolved,
                .receiver_style = true,
            } };
            return self.env.overloadAt(resolved).result;
        }
        if (self.env.findDynamicFunction(name, true, arg_types)) |resolved| {
            self.resolutions[@intFromEnum(index)] = .{ .dynamic = .{
                .ref = resolved.ref,
                .receiver_style = true,
            } };
            return resolved.result;
        }
        return self.env.types.builtins.dyn_type;
    }

    fn collectArgTypes(
        self: *UncheckedCompiler,
        args_range: ast.Range,
        stack_buffer: []types.TypeRef,
        scratch: *std.ArrayListUnmanaged(types.TypeRef),
    ) std.mem.Allocator.Error![]const types.TypeRef {
        if (args_range.len <= stack_buffer.len) {
            for (0..args_range.len) |i| {
                stack_buffer[i] = self.node_types[@intFromEnum(self.ast.expr_ranges.items[args_range.start + i])];
            }
            return stack_buffer[0..args_range.len];
        }

        try scratch.resize(self.allocator, args_range.len);
        for (0..args_range.len) |i| {
            scratch.items[i] = self.node_types[@intFromEnum(self.ast.expr_ranges.items[args_range.start + i])];
        }
        return scratch.items;
    }

    fn receiverTargetIsNamespace(self: *UncheckedCompiler, target: ast.Index, namespace: []const u8) bool {
        const ident_id = self.extractSimpleIdent(target) orelse return false;
        return std.mem.eql(u8, self.ast.strings.get(ident_id), namespace);
    }

    fn extractSimpleIdent(self: *UncheckedCompiler, index: ast.Index) ?strings.StringTable.Id {
        const node = self.ast.node(index);
        const name_ref = switch (node.data) {
            .ident => |name| name,
            else => return null,
        };
        if (name_ref.absolute or name_ref.segments.len != 1) return null;
        return self.ast.name_segments.items[name_ref.segments.start];
    }

    fn joinNameRef(self: *UncheckedCompiler, name_ref: ast.NameRef) parser.Error![]u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        defer out.deinit(self.allocator);
        const joined = try self.joinNameRefInto(name_ref, &out, &.{});
        return self.allocator.dupe(u8, joined);
    }

    fn joinNameRefInto(
        self: *UncheckedCompiler,
        name_ref: ast.NameRef,
        dynamic: *std.ArrayListUnmanaged(u8),
        fixed: []u8,
    ) parser.Error![]const u8 {
        const needed = resolve.joinedNameRefLen(self.ast, name_ref);
        const out = if (needed <= fixed.len)
            fixed[0..needed]
        else blk: {
            try dynamic.resize(self.allocator, needed);
            break :blk dynamic.items[0..needed];
        };
        resolve.writeJoinedNameRef(self.ast, name_ref, out);
        return out;
    }
};

const Checker = struct {
    allocator: std.mem.Allocator,
    env: *env.Env,
    ast: *const ast.Ast,
    node_types: []types.TypeRef,
    resolutions: []CallResolution,
    operator_resolutions: []?env.ResolutionRef,
    local_bindings: std.ArrayListUnmanaged(LocalBinding) = .empty,
    type_mappings: std.ArrayListUnmanaged(TypeMapping) = .empty,
    free_type_var_counter: u32 = 0,
    block_depth: u32 = 0,

    const LocalBinding = struct {
        name: BindingRef,
        ty: types.TypeRef,
    };

    pub const TypeMapping = struct {
        param: types.TypeRef,
        replacement: types.TypeRef,
    };

    const StaticResolution = check_overload.StaticResolution();

    const QualifiedName = resolve.QualifiedName;

    pub fn check(self: *Checker, index: ast.Index) Error!types.TypeRef {
        const idx = @intFromEnum(index);
        const ty = try self.checkNode(index);
        self.node_types[idx] = ty;
        return ty;
    }

    fn checkNode(self: *Checker, index: ast.Index) Error!types.TypeRef {
        const node = self.ast.node(index);
        return switch (node.data) {
            .literal_int => self.env.types.builtins.int_type,
            .literal_uint => self.env.types.builtins.uint_type,
            .literal_double => self.env.types.builtins.double_type,
            .literal_string => self.env.types.builtins.string_type,
            .literal_bytes => self.env.types.builtins.bytes_type,
            .literal_bool => self.env.types.builtins.bool_type,
            .literal_null => self.env.types.builtins.null_type,
            .ident => |name_ref| self.checkIdent(name_ref),
            .unary => |u| self.checkUnary(index, u),
            .binary => |b| self.checkBinary(index, b),
            .conditional => |c| self.checkConditional(c),
            .list => |range| self.checkList(range),
            .map => |range| self.checkMap(range),
            .index => |access| self.checkIndex(access),
            .select => |select| self.checkSelect(index, select),
            .call => |call| self.checkCall(index, call),
            .receiver_call => |call| self.checkReceiverCall(index, call),
            .message => |msg| self.checkMessage(msg),
        };
    }

    fn checkIdent(self: *Checker, name_ref: ast.NameRef) Error!types.TypeRef {
        if (!name_ref.absolute and name_ref.segments.len == 1) {
            const id = self.ast.name_segments.items[name_ref.segments.start];
            var i = self.local_bindings.items.len;
            while (i > 0) {
                i -= 1;
                const binding = self.local_bindings.items[i];
                if (bindingMatchesIdent(binding.name, id)) return binding.ty;
            }
        }
        var name_storage: std.ArrayListUnmanaged(u8) = .empty;
        defer name_storage.deinit(self.allocator);
        var name_small: [256]u8 = undefined;
        const name = try self.joinNameRefInto(name_ref, &name_storage, name_small[0..]);
        if (try self.env.lookupVarScoped(self.allocator, name, name_ref.absolute)) |resolved| {
            return resolved;
        }
        if (try self.env.lookupConstScoped(self.allocator, name, name_ref.absolute)) |constant| {
            return constant.ty;
        }
        if (types.isBuiltinTypeDenotation(name)) {
            return self.env.types.builtins.type_type;
        }
        if (try self.env.lookupMessageScoped(self.allocator, name, name_ref.absolute)) |_| {
            return self.env.types.builtins.type_type;
        }
        return Error.UndefinedIdentifier;
    }

    fn checkUnary(self: *Checker, index: ast.Index, unary: ast.Unary) Error!types.TypeRef {
        const operand_ty = try self.check(unary.expr);
        const operand_base = self.unwrapWrapperType(operand_ty) orelse operand_ty;
        return switch (unary.op) {
            .logical_not => if (self.isBoolish(operand_ty))
                self.env.types.builtins.bool_type
            else if (try self.resolveUnaryOperator(index, unary.op, operand_ty)) |resolved|
                resolved
            else
                Error.InvalidUnaryOperand,
            .negate => switch (self.env.types.spec(operand_base)) {
                .int, .double => operand_base,
                .dyn, .type_param => self.env.types.builtins.dyn_type,
                else => if (try self.resolveUnaryOperator(index, unary.op, operand_ty)) |resolved|
                    resolved
                else
                    Error.InvalidUnaryOperand,
            },
        };
    }

    fn checkBinary(self: *Checker, index: ast.Index, binary: ast.Binary) Error!types.TypeRef {
        const lhs = try self.check(binary.left);
        const rhs = try self.check(binary.right);
        const lhs_spec = self.env.types.spec(lhs);
        const rhs_spec = self.env.types.spec(rhs);
        const lhs_base = self.unwrapWrapperType(lhs) orelse lhs;
        const rhs_base = self.unwrapWrapperType(rhs) orelse rhs;
        const lhs_base_spec = self.env.types.spec(lhs_base);
        const rhs_base_spec = self.env.types.spec(rhs_base);

        return switch (binary.op) {
            .logical_or, .logical_and => if (self.isBoolish(lhs) and self.isBoolish(rhs))
                self.env.types.builtins.bool_type
            else if (try self.resolveBinaryOperator(index, binary.op, lhs, rhs)) |resolved|
                resolved
            else
                Error.InvalidBinaryOperand,
            .equal, .not_equal => if (try self.resolveBinaryOperator(index, binary.op, lhs, rhs)) |resolved|
                resolved
            else
                self.env.types.builtins.bool_type,
            .less, .less_equal, .greater, .greater_equal => blk: {
                if ((lhs_base == rhs_base and self.env.types.isSimpleComparable(lhs_base)) or lhs_spec == .dyn or rhs_spec == .dyn or lhs_base_spec == .dyn or rhs_base_spec == .dyn) {
                    break :blk self.env.types.builtins.bool_type;
                }
                const mark = self.type_mappings.items.len;
                if (try self.isAssignableType(lhs_base, rhs_base)) {
                    const joined = try self.mostGeneral(lhs_base, rhs_base);
                    if (self.env.types.isSimpleComparable(joined)) break :blk self.env.types.builtins.bool_type;
                }
                self.type_mappings.items.len = mark;
                if (try self.isAssignableType(rhs_base, lhs_base)) {
                    const joined = try self.mostGeneral(rhs_base, lhs_base);
                    if (self.env.types.isSimpleComparable(joined)) break :blk self.env.types.builtins.bool_type;
                }
                self.type_mappings.items.len = mark;
                if (lhs_base_spec == .type_param or rhs_base_spec == .type_param) break :blk self.env.types.builtins.bool_type;
                if (try self.resolveBinaryOperator(index, binary.op, lhs, rhs)) |resolved| break :blk resolved;
                break :blk Error.InvalidBinaryOperand;
            },
            .add => blk: {
                if (lhs_base == rhs_base and self.env.types.isNumeric(lhs_base)) break :blk lhs_base;
                if (lhs == rhs and (lhs_spec == .string or lhs_spec == .bytes or lhs_spec == .list)) break :blk lhs;
                const numeric_mark = self.type_mappings.items.len;
                if (try self.isAssignableType(lhs_base, rhs_base)) {
                    const joined = try self.mostGeneral(lhs_base, rhs_base);
                    if (self.env.types.isNumeric(joined)) break :blk joined;
                }
                self.type_mappings.items.len = numeric_mark;
                if (try self.isAssignableType(rhs_base, lhs_base)) {
                    const joined = try self.mostGeneral(rhs_base, lhs_base);
                    if (self.env.types.isNumeric(joined)) break :blk joined;
                }
                self.type_mappings.items.len = numeric_mark;
                if (lhs_base_spec == .type_param or rhs_base_spec == .type_param) break :blk self.env.types.builtins.dyn_type;
                switch (lhs_spec) {
                    .list => |lhs_elem| switch (rhs_spec) {
                        .list => |rhs_elem| {
                            const elem_ty = try self.joinTypes(lhs_elem, rhs_elem);
                            break :blk try self.env.types.listOf(elem_ty);
                        },
                        else => {},
                    },
                    else => {},
                }
                if (lhs_base == self.env.types.builtins.timestamp_type and rhs_base == self.env.types.builtins.duration_type) break :blk lhs_base;
                if (lhs_base == self.env.types.builtins.duration_type and rhs_base == self.env.types.builtins.timestamp_type) break :blk rhs_base;
                if (lhs_base == self.env.types.builtins.duration_type and rhs_base == self.env.types.builtins.duration_type) break :blk lhs_base;
                if (lhs_spec == .dyn or rhs_spec == .dyn or lhs_base_spec == .dyn or rhs_base_spec == .dyn) break :blk self.env.types.builtins.dyn_type;
                if (try self.resolveBinaryOperator(index, binary.op, lhs, rhs)) |resolved| break :blk resolved;
                break :blk Error.InvalidBinaryOperand;
            },
            .subtract, .multiply, .divide, .remainder => blk: {
                if (binary.op == .subtract) {
                    if (lhs_base == self.env.types.builtins.timestamp_type and rhs_base == self.env.types.builtins.timestamp_type) break :blk self.env.types.builtins.duration_type;
                    if (lhs_base == self.env.types.builtins.timestamp_type and rhs_base == self.env.types.builtins.duration_type) break :blk lhs_base;
                    if (lhs_base == self.env.types.builtins.duration_type and rhs_base == self.env.types.builtins.duration_type) break :blk lhs_base;
                }
                if (lhs_base == rhs_base and self.env.types.isNumeric(lhs_base)) break :blk lhs_base;
                const numeric_mark = self.type_mappings.items.len;
                if (try self.isAssignableType(lhs_base, rhs_base)) {
                    const joined = try self.mostGeneral(lhs_base, rhs_base);
                    if (self.env.types.isNumeric(joined)) break :blk joined;
                }
                self.type_mappings.items.len = numeric_mark;
                if (try self.isAssignableType(rhs_base, lhs_base)) {
                    const joined = try self.mostGeneral(rhs_base, lhs_base);
                    if (self.env.types.isNumeric(joined)) break :blk joined;
                }
                self.type_mappings.items.len = numeric_mark;
                if (lhs_base_spec == .type_param or rhs_base_spec == .type_param) break :blk self.env.types.builtins.dyn_type;
                if (lhs_spec == .dyn or rhs_spec == .dyn or lhs_base_spec == .dyn or rhs_base_spec == .dyn) break :blk self.env.types.builtins.dyn_type;
                if (try self.resolveBinaryOperator(index, binary.op, lhs, rhs)) |resolved| break :blk resolved;
                break :blk Error.InvalidBinaryOperand;
            },
            .in_set => switch (rhs_spec) {
                .list => |elem_ty| if (lhs == elem_ty or lhs_base == (self.unwrapWrapperType(elem_ty) orelse elem_ty) or lhs_spec == .dyn or self.env.types.spec(elem_ty) == .dyn or self.env.types.spec(elem_ty) == .type_param)
                    self.env.types.builtins.bool_type
                else if (try self.resolveBinaryOperator(index, binary.op, lhs, rhs)) |resolved|
                    resolved
                else
                    Error.InvalidBinaryOperand,
                .map => |m| if (lhs == m.key or lhs_base == (self.unwrapWrapperType(m.key) orelse m.key) or lhs_spec == .dyn or self.env.types.spec(m.key) == .dyn or self.env.types.spec(m.key) == .type_param)
                    self.env.types.builtins.bool_type
                else if (try self.resolveBinaryOperator(index, binary.op, lhs, rhs)) |resolved|
                    resolved
                else
                    Error.InvalidBinaryOperand,
                .dyn => self.env.types.builtins.bool_type,
                else => if (try self.resolveBinaryOperator(index, binary.op, lhs, rhs)) |resolved|
                    resolved
                else
                    Error.InvalidBinaryOperand,
            },
        };
    }

    fn checkConditional(self: *Checker, conditional: ast.Conditional) Error!types.TypeRef {
        const cond_ty = try self.check(conditional.condition);
        if (!self.isBoolish(cond_ty)) return Error.InvalidConditionalCondition;

        const then_ty = try self.check(conditional.then_expr);
        const else_ty = try self.check(conditional.else_expr);
        return try self.joinTypes(then_ty, else_ty);
    }

    fn checkList(self: *Checker, range: ast.Range) Error!types.TypeRef {
        if (range.len == 0) return self.env.types.listOf(try self.newTypeVar());

        const first_item = self.ast.list_items.items[range.start];
        var elem_ty = try self.checkOptionalLiteralElement(first_item.optional, first_item.value);
        var i: usize = 1;
        while (i < range.len) : (i += 1) {
            const item = self.ast.list_items.items[range.start + i];
            const next_ty = try self.checkOptionalLiteralElement(item.optional, item.value);
            elem_ty = try self.joinTypes(elem_ty, next_ty);
        }
        return self.env.types.listOf(elem_ty);
    }

    fn checkMap(self: *Checker, range: ast.Range) Error!types.TypeRef {
        if (range.len == 0) return self.env.types.mapOf(
            try self.newTypeVar(),
            try self.newTypeVar(),
        );

        const first = self.ast.map_entries.items[range.start];
        var key_ty = try self.check(first.key);
        var val_ty = try self.checkOptionalLiteralElement(first.optional, first.value);
        if (!self.isValidMapKey(key_ty)) return Error.InvalidMapKeyType;

        var i: usize = 1;
        while (i < range.len) : (i += 1) {
            const entry = self.ast.map_entries.items[range.start + i];
            const next_key = try self.check(entry.key);
            const next_value = try self.checkOptionalLiteralElement(entry.optional, entry.value);
            if (!self.isValidMapKey(next_key)) return Error.InvalidMapKeyType;
            key_ty = try self.joinTypes(key_ty, next_key);
            if (!self.isValidMapKey(key_ty)) return Error.InvalidMapKeyType;
            val_ty = try self.joinTypes(val_ty, next_value);
        }
        return self.env.types.mapOf(key_ty, val_ty);
    }

    fn checkIndex(self: *Checker, access: ast.IndexAccess) Error!types.TypeRef {
        const target_ty = try self.check(access.target);
        const index_ty = try self.check(access.index);
        const optional_inner = self.optionalInnerType(target_ty);
        const base_ty = optional_inner orelse target_ty;
        const result_ty = try switch (self.env.types.spec(base_ty)) {
            .list => |elem_ty| if (index_ty == self.env.types.builtins.int_type or self.env.types.spec(index_ty) == .dyn)
                elem_ty
            else
                Error.InvalidIndexOperand,
            .map => |m| if (m.key == self.env.types.builtins.dyn_type or
                index_ty == m.key or
                self.env.types.spec(m.key) == .type_param or
                self.env.types.spec(index_ty) == .dyn)
                m.value
            else
                Error.InvalidIndexOperand,
            .dyn, .type_param => self.env.types.builtins.dyn_type,
            else => Error.InvalidIndexOperand,
        };
        if (access.optional or optional_inner != null) {
            return try self.env.types.optionalOf(result_ty);
        }
        return result_ty;
    }

    fn checkSelect(self: *Checker, index: ast.Index, select: ast.Select) Error!types.TypeRef {
        if (!select.optional and !self.qualifiedExprShadowedByLocal(index)) {
            if (try self.lookupQualifiedExpr(index)) |resolved| {
                return resolved;
            }
        }

        const target_ty = try self.check(select.target);
        const optional_inner = self.optionalInnerType(target_ty);
        const base_ty = optional_inner orelse target_ty;
        const result_ty = try switch (self.env.types.spec(base_ty)) {
            .map => |m| if (m.key == self.env.types.builtins.string_type or self.env.types.spec(m.key) == .dyn or self.env.types.spec(m.key) == .type_param)
                m.value
            else
                Error.InvalidSelectOperand,
            .message => |name| blk: {
                const desc = self.env.lookupMessage(name) orelse break :blk Error.UnknownMessageType;
                const field_name = self.ast.strings.get(select.field);
                const field = desc.lookupField(field_name) orelse break :blk Error.UnknownMessageField;
                break :blk field.ty;
            },
            .host_scalar => |name| blk: {
                const desc = self.env.lookupMessage(name) orelse break :blk self.env.types.builtins.dyn_type;
                const field_name = self.ast.strings.get(select.field);
                const field = desc.lookupField(field_name) orelse break :blk Error.UnknownMessageField;
                break :blk field.ty;
            },
            .dyn, .type_param => self.env.types.builtins.dyn_type,
            else => Error.InvalidSelectOperand,
        };
        if (select.optional or optional_inner != null) {
            return try self.env.types.optionalOf(result_ty);
        }
        return result_ty;
    }

    fn checkCall(self: *Checker, index: ast.Index, call: ast.Call) Error!types.TypeRef {
        const simple_name = self.nameRefText(call.name);
        if (!call.name.absolute and simple_name != null and std.mem.eql(u8, simple_name.?, "has")) {
            return self.checkHasMacro(index, call);
        }
        var joined_storage: std.ArrayListUnmanaged(u8) = .empty;
        defer joined_storage.deinit(self.allocator);
        var joined_small: [256]u8 = undefined;
        const joined_name = try self.joinNameRefInto(call.name, &joined_storage, joined_small[0..]);
        if (!call.name.absolute and std.mem.eql(u8, joined_name, "cel.bind")) {
            return self.checkBindMacro(index, call);
        }
        if (!call.name.absolute and std.mem.eql(u8, joined_name, "cel.block")) {
            return self.checkBlockMacro(index, call);
        }
        if (!call.name.absolute and std.mem.eql(u8, joined_name, "cel.index")) {
            return self.checkBlockIndexCall(index, call);
        }
        if (!call.name.absolute and std.mem.eql(u8, joined_name, "cel.iterVar")) {
            return self.checkIterVarCall(index, call);
        }
        if (self.env.enum_mode == .strong) {
            if (try self.env.lookupEnumScoped(self.allocator, joined_name, call.name.absolute)) |enum_decl| {
                if (call.args.len != 1) return Error.InvalidCall;
                const arg_ty = try self.check(self.ast.expr_ranges.items[call.args.start]);
                const arg_spec = self.env.types.spec(arg_ty);
                if (arg_ty != self.env.types.builtins.int_type and
                    arg_ty != self.env.types.builtins.string_type and
                    arg_spec != .dyn)
                {
                    return Error.InvalidCall;
                }
                self.resolutions[@intFromEnum(index)] = .{ .enum_ctor = enum_decl.ty };
                return enum_decl.ty;
            }
        }

        var args: [8]types.TypeRef = undefined;
        var dynamic = std.ArrayListUnmanaged(types.TypeRef).empty;
        defer dynamic.deinit(self.allocator);

        const arg_types = try self.collectArgTypes(call.args, &args, &dynamic);
        if (try self.resolveStaticOverloadScoped(joined_name, call.name.absolute, false, arg_types)) |resolved| {
            self.resolutions[@intFromEnum(index)] = .{ .custom = .{
                .ref = resolved.ref,
                .receiver_style = false,
            } };
            return resolved.result;
        }
        if (try self.env.findDynamicFunctionScoped(self.allocator, joined_name, call.name.absolute, false, arg_types)) |resolved| {
            self.resolutions[@intFromEnum(index)] = .{ .dynamic = .{
                .ref = resolved.ref,
                .receiver_style = false,
            } };
            return resolved.result;
        }
        return Error.InvalidCall;
    }

    fn checkBindMacro(self: *Checker, index: ast.Index, call: ast.Call) Error!types.TypeRef {
        return check_macro.checkBindMacro(Error, self, index, call);
    }

    fn checkBlockMacro(self: *Checker, index: ast.Index, call: ast.Call) Error!types.TypeRef {
        return check_macro.checkBlockMacro(Error, self, index, call);
    }

    fn checkBlockIndexCall(self: *Checker, index: ast.Index, call: ast.Call) Error!types.TypeRef {
        return check_macro.checkBlockIndexCall(Error, self, index, call);
    }

    fn checkIterVarCall(self: *Checker, index: ast.Index, call: ast.Call) Error!types.TypeRef {
        return check_macro.checkIterVarCall(Error, self, index, call);
    }

    fn checkReceiverCall(self: *Checker, index: ast.Index, call: ast.ReceiverCall) Error!types.TypeRef {
        if (self.receiverTargetIsNamespace(call.target, "cel")) {
            const synthetic = ast.Call{
                .name = .{
                    .absolute = false,
                    .segments = .{ .start = 0, .len = 0 },
                },
                .args = call.args,
            };
            const field_name = self.ast.strings.get(call.name);
            if (std.mem.eql(u8, field_name, "block")) {
                return self.checkBlockMacro(index, synthetic);
            }
            if (std.mem.eql(u8, field_name, "index")) {
                return self.checkBlockIndexCall(index, synthetic);
            }
            if (std.mem.eql(u8, field_name, "iterVar")) {
                return self.checkIterVarCall(index, synthetic);
            }
        }
        if (try self.checkReceiverMacro(index, call)) |macro_ty| {
            return macro_ty;
        }

        var small: [8]types.TypeRef = undefined;
        var dynamic = std.ArrayListUnmanaged(types.TypeRef).empty;
        defer dynamic.deinit(self.allocator);

        if (!self.qualifiedExprShadowedByLocal(call.target)) {
            if (try self.joinQualifiedCallName(call.target, call.name)) |qualified| {
                defer self.allocator.free(qualified.text);
                if (self.env.enum_mode == .strong) {
                    if (try self.env.lookupEnumScoped(self.allocator, qualified.text, qualified.absolute)) |enum_decl| {
                        if (call.args.len != 1) return Error.InvalidCall;
                        const arg_ty = try self.check(self.ast.expr_ranges.items[call.args.start]);
                        const arg_spec = self.env.types.spec(arg_ty);
                        if (arg_ty != self.env.types.builtins.int_type and
                            arg_ty != self.env.types.builtins.string_type and
                            arg_spec != .dyn)
                        {
                            return Error.InvalidCall;
                        }
                        self.resolutions[@intFromEnum(index)] = .{ .enum_ctor = enum_decl.ty };
                        return enum_decl.ty;
                    }
                }
                const qualified_args = try self.collectArgTypes(call.args, &small, &dynamic);
                if (try self.resolveStaticOverloadScoped(qualified.text, qualified.absolute, false, qualified_args)) |resolved| {
                    self.resolutions[@intFromEnum(index)] = .{ .custom = .{
                        .ref = resolved.ref,
                        .receiver_style = false,
                    } };
                    return resolved.result;
                }
                if (try self.env.findDynamicFunctionScoped(self.allocator, qualified.text, qualified.absolute, false, qualified_args)) |resolved| {
                    self.resolutions[@intFromEnum(index)] = .{ .dynamic = .{
                        .ref = resolved.ref,
                        .receiver_style = false,
                    } };
                    return resolved.result;
                }
            }
        }

        dynamic.clearRetainingCapacity();
        try dynamic.append(self.allocator, try self.check(call.target));
        const arg_types = try self.collectArgTypes(call.args, small[1..], &dynamic);

        const field_name = self.ast.strings.get(call.name);
        if (try self.resolveStaticOverload(field_name, true, arg_types)) |resolved| {
            self.resolutions[@intFromEnum(index)] = .{ .custom = .{
                .ref = resolved.ref,
                .receiver_style = true,
            } };
            return resolved.result;
        }
        if (self.env.findDynamicFunction(field_name, true, arg_types)) |resolved| {
            self.resolutions[@intFromEnum(index)] = .{ .dynamic = .{
                .ref = resolved.ref,
                .receiver_style = true,
            } };
            return resolved.result;
        }
        return Error.InvalidCall;
    }

    fn checkHasMacro(self: *Checker, index: ast.Index, call: ast.Call) Error!types.TypeRef {
        return check_macro.checkHasMacro(Error, self, index, call);
    }

    fn checkReceiverMacro(self: *Checker, index: ast.Index, call: ast.ReceiverCall) Error!?types.TypeRef {
        return check_macro.checkReceiverMacro(Error, self, index, call);
    }

    fn receiverTargetIsNamespace(self: *Checker, target: ast.Index, namespace: []const u8) bool {
        return check_macro.receiverTargetIsNamespace(self, target, namespace);
    }

    fn collectArgTypes(
        self: *Checker,
        range: ast.Range,
        small_rest: []types.TypeRef,
        dynamic: *std.ArrayListUnmanaged(types.TypeRef),
    ) Error![]const types.TypeRef {
        if (dynamic.items.len == 0 and range.len <= small_rest.len) {
            for (0..range.len) |i| {
                small_rest[i] = try self.check(self.ast.expr_ranges.items[range.start + i]);
            }
            return small_rest[0..range.len];
        }

        var i: usize = 0;
        while (i < range.len) : (i += 1) {
            try dynamic.append(self.allocator, try self.check(self.ast.expr_ranges.items[range.start + i]));
        }
        return dynamic.items;
    }

    fn resolveStaticOverloadScoped(
        self: *Checker,
        name: []const u8,
        absolute: bool,
        receiver_style: bool,
        params: []const types.TypeRef,
    ) Error!?StaticResolution {
        return check_overload.resolveStaticOverloadScoped(Error, self, name, absolute, receiver_style, params);
    }

    fn resolveStaticOverload(
        self: *Checker,
        name: []const u8,
        receiver_style: bool,
        params: []const types.TypeRef,
    ) Error!?StaticResolution {
        return check_overload.resolveStaticOverload(Error, self, name, receiver_style, params);
    }

    fn instantiateType(
        self: *Checker,
        ty: types.TypeRef,
        instantiations: *InlineList(TypeMapping, 8),
    ) Error!types.TypeRef {
        return check_overload.instantiateType(Error, self, ty, instantiations);
    }

    fn resolveUnaryOperator(
        self: *Checker,
        index: ast.Index,
        op: ast.UnaryOp,
        operand: types.TypeRef,
    ) Error!?types.TypeRef {
        return check_overload.resolveUnaryOperator(self, index, op, operand);
    }

    fn resolveBinaryOperator(
        self: *Checker,
        index: ast.Index,
        op: ast.BinaryOp,
        lhs: types.TypeRef,
        rhs: types.TypeRef,
    ) Error!?types.TypeRef {
        return check_overload.resolveBinaryOperator(self, index, op, lhs, rhs);
    }

    fn checkMessage(self: *Checker, msg: ast.MessageInit) Error!types.TypeRef {
        var name_storage: std.ArrayListUnmanaged(u8) = .empty;
        defer name_storage.deinit(self.allocator);
        var name_small: [256]u8 = undefined;
        const name = try self.joinNameRefInto(msg.name, &name_storage, name_small[0..]);
        const desc = try self.env.lookupMessageScoped(self.allocator, name, msg.name.absolute) orelse return Error.UnknownMessageType;

        for (0..msg.fields.len) |i| {
            const field_init = self.ast.field_inits.items[msg.fields.start + i];
            for (0..i) |j| {
                const prev = self.ast.field_inits.items[msg.fields.start + j];
                if (prev.name == field_init.name) return Error.DuplicateMessageField;
            }
            const field_name = self.ast.strings.get(field_init.name);
            const field = desc.lookupField(field_name) orelse return Error.UnknownMessageField;
            const expr_ty = if (field_init.optional)
                try self.checkOptionalLiteralElement(true, field_init.value)
            else
                try self.check(field_init.value);
            if (!self.isFieldAssignmentValid(field, expr_ty)) {
                return Error.InvalidMessageField;
            }
        }

        return self.env.types.messageOf(desc.name);
    }

    fn checkOptionalLiteralElement(self: *Checker, optional: bool, value_index: ast.Index) Error!types.TypeRef {
        const expr_ty = try self.check(value_index);
        if (!optional) return expr_ty;
        if (self.optionalInnerType(expr_ty)) |inner| return inner;
        return switch (self.env.types.spec(expr_ty)) {
            .dyn, .type_param => self.env.types.builtins.dyn_type,
            else => Error.InvalidOptionalLiteral,
        };
    }

    pub fn optionalInnerType(self: *Checker, ty: types.TypeRef) ?types.TypeRef {
        return typing.optionalInnerType(self, ty);
    }

    pub fn isBoolish(self: *Checker, ref: types.TypeRef) bool {
        return typing.isBoolish(self, ref);
    }

    fn unwrapWrapperType(self: *Checker, ref: types.TypeRef) ?types.TypeRef {
        return typing.unwrapWrapperType(self, ref);
    }

    fn joinTypes(self: *Checker, previous: types.TypeRef, current: types.TypeRef) Error!types.TypeRef {
        return typing.joinTypes(Error, self, previous, current);
    }

    pub fn newTypeVar(self: *Checker) Error!types.TypeRef {
        return typing.newTypeVar(Error, self);
    }

    fn lookupTypeMapping(self: *Checker, param: types.TypeRef) ?types.TypeRef {
        return typing.lookupTypeMapping(self, param);
    }

    fn setTypeMapping(self: *Checker, param: types.TypeRef, replacement: types.TypeRef) Error!void {
        return typing.setTypeMapping(Error, self, param, replacement);
    }

    pub fn substituteType(self: *Checker, ty: types.TypeRef, type_param_to_dyn: bool) Error!types.TypeRef {
        return typing.substituteType(Error, self, ty, type_param_to_dyn);
    }

    fn mostGeneral(self: *Checker, a: types.TypeRef, b: types.TypeRef) Error!types.TypeRef {
        return typing.mostGeneral(Error, self, a, b);
    }

    fn isEqualOrLessSpecific(self: *Checker, a: types.TypeRef, b: types.TypeRef) bool {
        return typing.isEqualOrLessSpecific(self, a, b);
    }

    fn isNullableType(self: *Checker, ty: types.TypeRef) bool {
        return typing.isNullableType(self, ty);
    }

    fn notReferencedIn(self: *Checker, param: types.TypeRef, within: types.TypeRef) bool {
        return typing.notReferencedIn(self, param, within);
    }

    fn bindTypeParam(self: *Checker, param: types.TypeRef, candidate: types.TypeRef) Error!bool {
        return typing.bindTypeParam(Error, self, param, candidate);
    }

    pub fn isAssignableType(self: *Checker, expected: types.TypeRef, actual: types.TypeRef) Error!bool {
        return typing.isAssignableType(Error, self, expected, actual);
    }

    fn isFieldAssignmentValid(self: *Checker, field: *const @import("../env/schema.zig").FieldDecl, expr_ty: types.TypeRef) bool {
        return typing.isFieldAssignmentValid(self, field, expr_ty);
    }

    fn isValidMapKey(self: *Checker, ref: types.TypeRef) bool {
        return typing.isValidMapKey(self, ref);
    }

    pub fn lookupBinding(self: *Checker, name: BindingRef) ?types.TypeRef {
        var i = self.local_bindings.items.len;
        while (i > 0) {
            i -= 1;
            const binding = self.local_bindings.items[i];
            if (bindingRefEql(binding.name, name)) return binding.ty;
        }
        return null;
    }

    pub fn parseU32LiteralArg(self: *Checker, index: ast.Index) Error!u32 {
        return switch (self.ast.node(index).data) {
            .literal_int => |v| blk: {
                if (v < 0 or v > std.math.maxInt(u32)) return Error.InvalidMacro;
                break :blk @intCast(v);
            },
            else => Error.InvalidMacro,
        };
    }

    pub fn extractBindingRef(self: *Checker, index: ast.Index) ?BindingRef {
        if (self.extractSimpleIdent(index)) |id| return .{ .ident = id };
        return self.extractIterVarBinding(index);
    }

    fn extractIterVarBinding(self: *Checker, index: ast.Index) ?BindingRef {
        return switch (self.ast.node(index).data) {
            .call => |call| blk: {
                if (call.name.absolute or call.args.len != 2) break :blk null;
                var joined_storage: std.ArrayListUnmanaged(u8) = .empty;
                defer joined_storage.deinit(self.allocator);
                var joined_small: [256]u8 = undefined;
                const joined = self.joinNameRefInto(call.name, &joined_storage, joined_small[0..]) catch break :blk null;
                if (!std.mem.eql(u8, joined, "cel.iterVar")) break :blk null;
                break :blk self.extractIterVarBindingFromCall(call);
            },
            .receiver_call => |call| blk: {
                if (!self.receiverTargetIsNamespace(call.target, "cel")) break :blk null;
                if (!std.mem.eql(u8, self.ast.strings.get(call.name), "iterVar")) break :blk null;
                break :blk self.extractIterVarBindingFromArgs(call.args);
            },
            else => null,
        };
    }

    pub fn extractIterVarBindingFromCall(self: *Checker, call: ast.Call) ?BindingRef {
        return self.extractIterVarBindingFromArgs(call.args);
    }

    fn extractIterVarBindingFromArgs(self: *Checker, args: ast.Range) ?BindingRef {
        if (args.len != 2) return null;
        const depth = self.parseU32LiteralArg(self.ast.expr_ranges.items[args.start]) catch return null;
        const slot = self.parseU32LiteralArg(self.ast.expr_ranges.items[args.start + 1]) catch return null;
        return .{ .iter_var = .{
            .depth = depth,
            .slot = slot,
        } };
    }

    pub fn extractSimpleIdent(self: *Checker, index: ast.Index) ?strings.StringTable.Id {
        const node = self.ast.node(index);
        return switch (node.data) {
            .ident => |name_ref| blk: {
                if (name_ref.absolute or name_ref.segments.len != 1) break :blk null;
                break :blk self.ast.name_segments.items[name_ref.segments.start];
            },
            else => null,
        };
    }

    fn nameRefText(self: *Checker, name_ref: ast.NameRef) ?[]const u8 {
        _ = name_ref.absolute;
        if (name_ref.segments.len != 1) return null;
        const id = self.ast.name_segments.items[name_ref.segments.start];
        return self.ast.strings.get(id);
    }

    fn lookupQualifiedExpr(self: *Checker, index: ast.Index) Error!?types.TypeRef {
        const qualified = try self.joinQualifiedExpr(index);
        defer if (qualified) |name| self.allocator.free(name.text);
        const name = qualified orelse return null;
        if (try self.env.lookupVarScoped(self.allocator, name.text, name.absolute)) |resolved| {
            return resolved;
        }
        if (try self.env.lookupConstScoped(self.allocator, name.text, name.absolute)) |constant| {
            return constant.ty;
        }
        if (types.isBuiltinTypeDenotation(name.text)) {
            return self.env.types.builtins.type_type;
        }
        if (try self.env.lookupMessageScoped(self.allocator, name.text, name.absolute)) |_| {
            return self.env.types.builtins.type_type;
        }
        return null;
    }

    fn joinQualifiedExpr(self: *Checker, index: ast.Index) Error!?QualifiedName {
        return resolve.joinQualifiedExpr(Error, self, index);
    }

    fn appendQualifiedExpr(
        self: *Checker,
        index: ast.Index,
        buffer: *std.ArrayListUnmanaged(u8),
        absolute: *bool,
    ) Error!bool {
        switch (self.ast.node(index).data) {
            .ident => |name_ref| {
                absolute.* = name_ref.absolute;
                for (0..name_ref.segments.len) |i| {
                    if (buffer.items.len > 0) try buffer.append(self.allocator, '.');
                    const id = self.ast.name_segments.items[name_ref.segments.start + i];
                    try buffer.appendSlice(self.allocator, self.ast.strings.get(id));
                }
                return true;
            },
            .select => |select| {
                if (select.optional) return false;
                if (!try self.appendQualifiedExpr(select.target, buffer, absolute)) return false;
                try buffer.append(self.allocator, '.');
                try buffer.appendSlice(self.allocator, self.ast.strings.get(select.field));
                return true;
            },
            else => return false,
        }
    }

    fn joinQualifiedCallName(self: *Checker, target: ast.Index, field: strings.StringTable.Id) Error!?QualifiedName {
        return resolve.joinQualifiedCallName(Error, self, target, field);
    }

    fn joinNameRef(self: *Checker, name_ref: ast.NameRef) Error![]u8 {
        return resolve.joinNameRef(Error, self, name_ref);
    }

    fn joinNameRefInto(
        self: *Checker,
        name_ref: ast.NameRef,
        dynamic: *std.ArrayListUnmanaged(u8),
        fixed: []u8,
    ) Error![]const u8 {
        return resolve.joinNameRefInto(Error, self, name_ref, dynamic, fixed);
    }

    fn qualifiedExprShadowedByLocal(self: *Checker, index: ast.Index) bool {
        return resolve.qualifiedExprShadowedByLocal(self, index);
    }

    fn isLocalBinding(self: *Checker, id: strings.StringTable.Id) bool {
        return resolve.isLocalBinding(self, id);
    }
};

test "checker rejects unresolved identifiers invalid macros and duplicate message fields" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    _ = try environment.addMessage("Account");
    try environment.addMessageField("Account", "user_id", environment.types.builtins.string_type);

    try std.testing.expectError(
        Error.UndefinedIdentifier,
        compile(std.testing.allocator, &environment, "missing_name"),
    );
    try std.testing.expectError(
        Error.InvalidMacro,
        compile(std.testing.allocator, &environment, "1.all(x, true)"),
    );
    try std.testing.expectError(
        Error.DuplicateMessageField,
        compile(std.testing.allocator, &environment, "Account{user_id: 'a', user_id: 'b'}"),
    );
    try std.testing.expectError(
        Error.InvalidMacro,
        compile(std.testing.allocator, &environment, "has(google.protobuf.Timestamp{}.seconds)"),
    );
}

test "checker infers dyn for heterogeneous literals and conditionals" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var list_program = try compile(std.testing.allocator, &environment, "[1, 'two']");
    defer list_program.deinit();
    switch (environment.types.spec(list_program.result_type)) {
        .list => |elem_ty| try std.testing.expectEqual(environment.types.builtins.dyn_type, elem_ty),
        else => return error.TestUnexpectedResult,
    }

    var map_program = try compile(std.testing.allocator, &environment, "{'a': 1, 'b': 'two'}");
    defer map_program.deinit();
    switch (environment.types.spec(map_program.result_type)) {
        .map => |m| {
            try std.testing.expectEqual(environment.types.builtins.string_type, m.key);
            try std.testing.expectEqual(environment.types.builtins.dyn_type, m.value);
        },
        else => return error.TestUnexpectedResult,
    }

    var conditional_program = try compile(std.testing.allocator, &environment, "true ? 1 : 'two'");
    defer conditional_program.deinit();
    try std.testing.expectEqual(environment.types.builtins.dyn_type, conditional_program.result_type);
}

test "prepareEnvironment installs standard library once" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    try environment.addVarTyped("x", environment.types.builtins.int_type);
    try prepareEnvironment(&environment);
    try prepareEnvironment(&environment);
    try std.testing.expect(environment.hasLibrary(stdlib.standard_library.name));

    var first = try compile(std.testing.allocator, &environment, "x + 1");
    defer first.deinit();
    var second = try compile(std.testing.allocator, &environment, "x + 2");
    defer second.deinit();
}

test "extended env reuses parent declarations and isolates local schema edits" {
    var base = try env.Env.initDefault(std.testing.allocator);
    defer base.deinit();

    const request_ty = try base.addMessage("example.Request");
    try base.addMessageField("example.Request", "id", base.types.builtins.string_type);
    try base.addVarTyped("req", request_ty);

    var child = try base.extend(std.testing.allocator);
    defer child.deinit();
    try child.addVarTyped("enabled", child.types.builtins.bool_type);
    try child.addMessageField("example.Request", "region", child.types.builtins.string_type);

    var child_program = try compile(
        std.testing.allocator,
        &child,
        "req.id == 'a' && req.region == 'us' && enabled",
    );
    defer child_program.deinit();
    try std.testing.expectEqual(child.types.builtins.bool_type, child_program.result_type);

    try std.testing.expectError(
        Error.UnknownMessageField,
        compile(std.testing.allocator, &base, "req.region"),
    );
    try std.testing.expectError(
        Error.UndefinedIdentifier,
        compile(std.testing.allocator, &base, "enabled"),
    );
}

test "checker infers literal types" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const b = environment.types.builtins;
    const cases = [_]struct { expr: []const u8, expected: types.TypeRef }{
        .{ .expr = "42", .expected = b.int_type },
        .{ .expr = "0", .expected = b.int_type },
        .{ .expr = "9223372036854775807", .expected = b.int_type },
        .{ .expr = "42u", .expected = b.uint_type },
        .{ .expr = "0u", .expected = b.uint_type },
        .{ .expr = "3.14", .expected = b.double_type },
        .{ .expr = "0.0", .expected = b.double_type },
        .{ .expr = ".5", .expected = b.double_type },
        .{ .expr = "1e10", .expected = b.double_type },
        .{ .expr = "'hello'", .expected = b.string_type },
        .{ .expr = "''", .expected = b.string_type },
        .{ .expr = "'multi word string'", .expected = b.string_type },
        .{ .expr = "b'abc'", .expected = b.bytes_type },
        .{ .expr = "b''", .expected = b.bytes_type },
        .{ .expr = "true", .expected = b.bool_type },
        .{ .expr = "false", .expected = b.bool_type },
        .{ .expr = "null", .expected = b.null_type },
    };
    for (cases) |case| {
        var program = try compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        try std.testing.expectEqual(case.expected, program.result_type);
    }
}

test "checker infers composite literal types" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    // Homogeneous list -> list(int)
    {
        var program = try compile(std.testing.allocator, &environment, "[1, 2, 3]");
        defer program.deinit();
        switch (environment.types.spec(program.result_type)) {
            .list => |elem_ty| try std.testing.expectEqual(environment.types.builtins.int_type, elem_ty),
            else => return error.TestUnexpectedResult,
        }
    }

    // Map literal -> map(string, int)
    {
        var program = try compile(std.testing.allocator, &environment, "{'a': 1, 'b': 2}");
        defer program.deinit();
        switch (environment.types.spec(program.result_type)) {
            .map => |m| {
                try std.testing.expectEqual(environment.types.builtins.string_type, m.key);
                try std.testing.expectEqual(environment.types.builtins.int_type, m.value);
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "checker infers arithmetic and concatenation types" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const b = environment.types.builtins;
    const cases = [_]struct { expr: []const u8, expected: types.TypeRef }{
        .{ .expr = "1 + 2", .expected = b.int_type },
        .{ .expr = "10 - 3", .expected = b.int_type },
        .{ .expr = "2 * 3", .expected = b.int_type },
        .{ .expr = "7 % 3", .expected = b.int_type },
        .{ .expr = "10 / 2", .expected = b.int_type },
        .{ .expr = "1u + 2u", .expected = b.uint_type },
        .{ .expr = "1.0 + 2.0", .expected = b.double_type },
        .{ .expr = "6.0 / 2.0", .expected = b.double_type },
        .{ .expr = "1.5 - 0.5", .expected = b.double_type },
        .{ .expr = "2.0 * 3.0", .expected = b.double_type },
        .{ .expr = "'hello' + ' world'", .expected = b.string_type },
        .{ .expr = "'' + ''", .expected = b.string_type },
        .{ .expr = "b'ab' + b'cd'", .expected = b.bytes_type },
        .{ .expr = "-1", .expected = b.int_type },
        .{ .expr = "-1.5", .expected = b.double_type },
        .{ .expr = "!true", .expected = b.bool_type },
        .{ .expr = "!false", .expected = b.bool_type },
    };
    for (cases) |case| {
        var program = try compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        try std.testing.expectEqual(case.expected, program.result_type);
    }

    // List concatenation returns list(int)
    {
        var program = try compile(std.testing.allocator, &environment, "[1, 2] + [3, 4]");
        defer program.deinit();
        switch (environment.types.spec(program.result_type)) {
            .list => |elem_ty| try std.testing.expectEqual(b.int_type, elem_ty),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "checker comparison and logical ops return bool" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const cases = [_][]const u8{
        "1 < 2",
        "1 <= 2",
        "1 > 2",
        "1 >= 2",
        "1 == 2",
        "1 != 2",
        "'a' < 'b'",
        "'a' == 'a'",
        "1.0 < 2.0",
        "true == false",
        "true && false",
        "true || false",
        "false && true",
        "false || true",
        "1 in [1, 2, 3]",
        "'a' in {'a': 1, 'b': 2}",
    };
    for (cases) |expr| {
        var program = try compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        try std.testing.expectEqual(environment.types.builtins.bool_type, program.result_type);
    }
}

test "checker ternary type inference" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const b = environment.types.builtins;
    const cases = [_]struct { expr: []const u8, expected: types.TypeRef }{
        .{ .expr = "true ? 1 : 2", .expected = b.int_type },
        .{ .expr = "false ? 1 : 2", .expected = b.int_type },
        .{ .expr = "true ? 'a' : 'b'", .expected = b.string_type },
        .{ .expr = "true ? 1 : 'two'", .expected = b.dyn_type },
        .{ .expr = "true ? true : false", .expected = b.bool_type },
        .{ .expr = "true ? 1.0 : 2.0", .expected = b.double_type },
    };
    for (cases) |case| {
        var program = try compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        try std.testing.expectEqual(case.expected, program.result_type);
    }
}

test "checker select and index type inference" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const b = environment.types.builtins;
    const msg_ty = try environment.addMessage("Foo");
    try environment.addMessageField("Foo", "name", b.string_type);
    try environment.addMessageField("Foo", "count", b.int_type);
    try environment.addVarTyped("foo", msg_ty);
    const map_ty = try environment.types.mapOf(b.string_type, b.int_type);
    try environment.addVarTyped("m", map_ty);
    const list_ty = try environment.types.listOf(b.string_type);
    try environment.addVarTyped("items", list_ty);
    try environment.addVarTyped("d", b.dyn_type);

    const cases = [_]struct { expr: []const u8, expected: types.TypeRef }{
        .{ .expr = "foo.name", .expected = b.string_type },
        .{ .expr = "foo.count", .expected = b.int_type },
        .{ .expr = "m.key", .expected = b.int_type },
        .{ .expr = "m['key']", .expected = b.int_type },
        .{ .expr = "items[0]", .expected = b.string_type },
        .{ .expr = "d[0]", .expected = b.dyn_type },
        .{ .expr = "d.field", .expected = b.dyn_type },
    };
    for (cases) |case| {
        var program = try compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        try std.testing.expectEqual(case.expected, program.result_type);
    }
}

test "checker function and macro return types" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const msg_ty = try environment.addMessage("Msg");
    try environment.addMessageField("Msg", "field", environment.types.builtins.string_type);
    try environment.addVarTyped("m", msg_ty);

    const b = environment.types.builtins;

    // Functions and macros that return bool
    const bool_cases = [_][]const u8{
        "'hello'.contains('lo')",
        "'hello'.contains('')",
        "'hello'.startsWith('he')",
        "'hello'.endsWith('lo')",
        "[1, 2, 3].all(x, x > 0)",
        "[1, 2, 3].exists(x, x == 2)",
        "[1, 2, 3].exists_one(x, x == 2)",
        "has(m.field)",
    };
    for (bool_cases) |expr| {
        var program = try compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        try std.testing.expectEqual(b.bool_type, program.result_type);
    }

    // Functions that return int
    const int_cases = [_][]const u8{
        "'hello'.size()",
        "[1,2].size()",
        "size('test')",
        "size([1])",
    };
    for (int_cases) |expr| {
        var program = try compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        try std.testing.expectEqual(b.int_type, program.result_type);
    }

    // Macros that return list
    const list_cases = [_][]const u8{
        "[1, 2, 3].filter(x, x > 1)",
        "[1, 2, 3].map(x, x * 2)",
    };
    for (list_cases) |expr| {
        var program = try compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        switch (environment.types.spec(program.result_type)) {
            .list => {},
            else => return error.TestUnexpectedResult,
        }
    }
}

test "checker rejects invalid expressions" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const msg_ty = try environment.addMessage("Msg");
    try environment.addMessageField("Msg", "name", environment.types.builtins.string_type);
    try environment.addVarTyped("m", msg_ty);

    const cases = [_]struct { expr: []const u8, expected_error: Error }{
        .{ .expr = "1 + true", .expected_error = Error.InvalidBinaryOperand },
        .{ .expr = "1 + 'x'", .expected_error = Error.InvalidBinaryOperand },
        .{ .expr = "true + false", .expected_error = Error.InvalidBinaryOperand },
        .{ .expr = "-'hello'", .expected_error = Error.InvalidUnaryOperand },
        .{ .expr = "-true", .expected_error = Error.InvalidUnaryOperand },
        .{ .expr = "!42", .expected_error = Error.InvalidUnaryOperand },
        .{ .expr = "NonExistent{}", .expected_error = Error.UnknownMessageType },
        .{ .expr = "m.no_such_field", .expected_error = Error.UnknownMessageField },
        .{ .expr = "1.all(x, true)", .expected_error = Error.InvalidMacro },
        .{ .expr = "'s'.all(x, true)", .expected_error = Error.InvalidMacro },
        .{ .expr = "1 ? 2 : 3", .expected_error = Error.InvalidConditionalCondition },
        .{ .expr = "'s' ? 2 : 3", .expected_error = Error.InvalidConditionalCondition },
        .{ .expr = "{1.0: 'bad'}", .expected_error = Error.InvalidMapKeyType },
        .{ .expr = "{[1]: 'bad'}", .expected_error = Error.InvalidMapKeyType },
    };
    for (cases) |case| {
        try std.testing.expectError(case.expected_error, compile(std.testing.allocator, &environment, case.expr));
    }
}

test "checker unchecked compile type inference" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.dyn_type);

    const b = environment.types.builtins;
    const cases = [_]struct { expr: []const u8, expected: types.TypeRef }{
        .{ .expr = "1 + 2", .expected = b.dyn_type },
        .{ .expr = "1 * 3", .expected = b.dyn_type },
        .{ .expr = "1 < 2", .expected = b.bool_type },
        .{ .expr = "1 == 2", .expected = b.bool_type },
        .{ .expr = "true && false", .expected = b.bool_type },
        .{ .expr = "x.field", .expected = b.dyn_type },
        .{ .expr = "x[0]", .expected = b.dyn_type },
    };
    for (cases) |case| {
        var program = try compileUnchecked(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        try std.testing.expectEqual(case.expected, program.result_type);
    }

    // Unchecked list literal -> list(dyn)
    {
        var program = try compileUnchecked(std.testing.allocator, &environment, "[1, 2]");
        defer program.deinit();
        switch (environment.types.spec(program.result_type)) {
            .list => |elem_ty| try std.testing.expectEqual(b.dyn_type, elem_ty),
            else => return error.TestUnexpectedResult,
        }
    }

    // Unchecked map literal -> map(dyn, dyn)
    {
        var program = try compileUnchecked(std.testing.allocator, &environment, "{'a': 1}");
        defer program.deinit();
        switch (environment.types.spec(program.result_type)) {
            .map => |m| {
                try std.testing.expectEqual(b.dyn_type, m.key);
                try std.testing.expectEqual(b.dyn_type, m.value);
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "checker empty literal types" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    {
        var program = try compile(std.testing.allocator, &environment, "[]");
        defer program.deinit();
        switch (environment.types.spec(program.result_type)) {
            .list => {},
            else => return error.TestUnexpectedResult,
        }
    }
    {
        var program = try compile(std.testing.allocator, &environment, "{}");
        defer program.deinit();
        switch (environment.types.spec(program.result_type)) {
            .map => {},
            else => return error.TestUnexpectedResult,
        }
    }
}

test "checker container scoped name resolution" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.setContainer("my.pkg");
    try environment.addVarTyped("my.pkg.x", environment.types.builtins.int_type);

    var program = try compile(std.testing.allocator, &environment, "x + 1");
    defer program.deinit();
    try std.testing.expectEqual(environment.types.builtins.int_type, program.result_type);
}

test "checker type conversions return expected types" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const b = environment.types.builtins;
    const cases = [_]struct { expr: []const u8, expected: types.TypeRef }{
        .{ .expr = "int(1.5)", .expected = b.int_type },
        .{ .expr = "int('42')", .expected = b.int_type },
        .{ .expr = "uint(42)", .expected = b.uint_type },
        .{ .expr = "double(1)", .expected = b.double_type },
        .{ .expr = "double('1.5')", .expected = b.double_type },
        .{ .expr = "string(42)", .expected = b.string_type },
        .{ .expr = "string(true)", .expected = b.string_type },
        .{ .expr = "string(1.5)", .expected = b.string_type },
        .{ .expr = "bool(true)", .expected = b.bool_type },
        .{ .expr = "bytes('abc')", .expected = b.bytes_type },
    };
    for (cases) |case| {
        var program = try compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        try std.testing.expectEqual(case.expected, program.result_type);
    }
}

test "checker message construction returns message type" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    _ = try environment.addMessage("Msg");
    try environment.addMessageField("Msg", "name", environment.types.builtins.string_type);

    var program = try compile(std.testing.allocator, &environment, "Msg{name: 'hello'}");
    defer program.deinit();
    switch (environment.types.spec(program.result_type)) {
        .message => |name| try std.testing.expect(std.mem.eql(u8, "Msg", name)),
        else => return error.TestUnexpectedResult,
    }
}

test {
    _ = check_macro;
    _ = check_overload;
}
