const builtin = @import("builtin");
const std = @import("std");
const activation_mod = @import("activation.zig");
const ast = @import("../parse/ast.zig");
const cel_time = @import("../library/cel_time.zig");
const compiler_program = @import("../compiler/program.zig");
const checker = @import("../checker/check.zig");
pub const decorator_mod = @import("decorator.zig");
const env = @import("../env/env.zig");
const InlineList = @import("../util/inline_list.zig").InlineList;
const partial = @import("partial.zig");
const protobuf = @import("../library/protobuf.zig");
const scratch_mod = @import("scratch.zig");
const stdlib = @import("../library/stdlib.zig");
const strings = @import("../parse/string_table.zig");
const types = @import("../env/types.zig");
const value = @import("../env/value.zig");

pub const Decorator = decorator_mod.Decorator;
pub const NodeCounter = decorator_mod.NodeCounter;
pub const TraceCollector = decorator_mod.TraceCollector;

pub const Activation = activation_mod.Activation;

const LocalBinding = scratch_mod.LocalBinding;

pub const EvalState = scratch_mod.EvalState;
pub const EvalScratch = scratch_mod.EvalScratch;
pub const TrackedResult = scratch_mod.TrackedResult;

pub const EvalOptions = struct {
    budget: ?u64 = null,
    deadline_ns: ?u64 = null,
    exhaustive: bool = false,
    decorators: []const Decorator = &.{},
};

fn monotonicNowNs() u64 {
    const clock_id: std.c.clockid_t = switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => .UPTIME_RAW,
        else => .MONOTONIC,
    };
    var ts: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(clock_id, &ts);
    std.debug.assert(rc == 0);
    return (@as(u64, @intCast(ts.sec)) * std.time.ns_per_s) + @as(u64, @intCast(ts.nsec));
}

pub fn eval(
    allocator: std.mem.Allocator,
    program: *const compiler_program.Program,
    activation: *const Activation,
) env.EvalError!value.Value {
    return evalWithOptions(allocator, program, activation, .{});
}

pub fn evalWithOptions(
    allocator: std.mem.Allocator,
    program: *const compiler_program.Program,
    activation: *const Activation,
    options: EvalOptions,
) env.EvalError!value.Value {
    var evaluator = Evaluator{
        .allocator = allocator,
        .binding_storage_allocator = allocator,
        .program = program,
        .activation = activation,
        .state = null,
        .cost_budget = options.budget,
        .exhaustive = options.exhaustive,
        .decorators = options.decorators,
        .deadline = if (options.deadline_ns) |ns| monotonicNowNs() +| ns else null,
    };
    defer evaluator.deinit();
    return evaluator.evalNode(program.ast.root.?);
}

// Convenience wrappers for backward compat — delegate to evalWithOptions
pub fn evalWithBudget(allocator: std.mem.Allocator, program: *const compiler_program.Program, activation: *const Activation, budget: u64) env.EvalError!value.Value {
    return evalWithOptions(allocator, program, activation, .{ .budget = budget });
}

pub fn evalWithDeadline(allocator: std.mem.Allocator, program: *const compiler_program.Program, activation: *const Activation, timeout_ns: u64) env.EvalError!value.Value {
    return evalWithOptions(allocator, program, activation, .{ .deadline_ns = timeout_ns });
}

pub fn evalExhaustive(allocator: std.mem.Allocator, program: *const compiler_program.Program, activation: *const Activation) env.EvalError!value.Value {
    return evalWithOptions(allocator, program, activation, .{ .exhaustive = true });
}

pub fn evalWithDecorators(allocator: std.mem.Allocator, program: *const compiler_program.Program, activation: *const Activation, decorators: []const Decorator) env.EvalError!value.Value {
    return evalWithOptions(allocator, program, activation, .{ .decorators = decorators });
}

pub fn evalWithScratch(
    scratch: *EvalScratch,
    program: *const compiler_program.Program,
    activation: *const Activation,
) env.EvalError!value.Value {
    scratch.prepareBindings(true);
    var evaluator = Evaluator{
        .allocator = scratch.transientAllocator(),
        .program = program,
        .activation = activation,
        .state = null,
        .binding_storage_allocator = scratch.allocator,
        .local_bindings = scratch.local_bindings,
        .borrowed_bindings = true,
    };
    defer {
        evaluator.deinit();
        scratch.local_bindings = evaluator.local_bindings;
    }
    var result = try evaluator.evalNode(program.ast.root.?);
    defer result.deinit(scratch.transientAllocator());
    return try result.clone(scratch.allocator);
}

pub fn evalBorrowedWithScratch(
    scratch: *EvalScratch,
    program: *const compiler_program.Program,
    activation: *const Activation,
) env.EvalError!value.Value {
    scratch.prepareBindings(true);
    var evaluator = Evaluator{
        .allocator = scratch.transientAllocator(),
        .program = program,
        .activation = activation,
        .state = null,
        .binding_storage_allocator = scratch.allocator,
        .local_bindings = scratch.local_bindings,
        .borrowed_bindings = true,
    };
    defer {
        evaluator.deinit();
        scratch.local_bindings = evaluator.local_bindings;
    }
    return evaluator.evalNode(program.ast.root.?);
}

pub fn evalTracked(
    allocator: std.mem.Allocator,
    program: *const compiler_program.Program,
    activation: *const Activation,
) env.EvalError!TrackedResult {
    var state = try EvalState.init(allocator, program.ast.nodes.items.len);
    errdefer state.deinit();

    var evaluator = Evaluator{
        .allocator = allocator,
        .binding_storage_allocator = allocator,
        .program = program,
        .activation = activation,
        .state = &state,
    };
    defer evaluator.deinit();

    return .{
        .value = try evaluator.evalNode(program.ast.root.?),
        .state = state,
    };
}

pub fn evalTrackedWithScratch(
    scratch: *EvalScratch,
    program: *const compiler_program.Program,
    activation: *const Activation,
) env.EvalError!TrackedResult {
    scratch.prepareBindings(false);
    var state = try scratch.prepareTracked(program.ast.nodes.items.len);
    var evaluator = Evaluator{
        .allocator = scratch.allocator,
        .program = program,
        .activation = activation,
        .state = &state,
        .binding_storage_allocator = scratch.allocator,
        .local_bindings = scratch.local_bindings,
        .borrowed_bindings = true,
    };
    errdefer state.deinit();
    defer {
        evaluator.deinit();
        scratch.local_bindings = evaluator.local_bindings;
    }

    return .{
        .value = try evaluator.evalNode(program.ast.root.?),
        .state = state,
    };
}

const Evaluator = struct {
    allocator: std.mem.Allocator,
    binding_storage_allocator: std.mem.Allocator,
    program: *const checker.Program,
    activation: *const Activation,
    state: ?*EvalState,
    local_bindings: std.ArrayListUnmanaged(LocalBinding) = .empty,
    borrowed_bindings: bool = false,
    block_depth: u32 = 0,
    cost_budget: ?u64 = null,
    cost_spent: u64 = 0,
    decorators: []const Decorator = &.{},
    deadline: ?u64 = null,
    node_counter: u64 = 0,
    exhaustive: bool = false,

    const CapturedAttribute = struct {
        absolute: bool,
        root_name: []u8,
        root_expr_id: i64,
        qualifiers: std.ArrayListUnmanaged(partial.Qualifier) = .empty,
        qualifier_expr_ids: std.ArrayListUnmanaged(i64) = .empty,

        fn deinit(self: *CapturedAttribute, allocator: std.mem.Allocator) void {
            allocator.free(self.root_name);
            for (self.qualifiers.items) |*qualifier| qualifier.deinit(allocator);
            self.qualifiers.deinit(allocator);
            self.qualifier_expr_ids.deinit(allocator);
        }
    };

    const CapturedAttributeResult = union(enum) {
        not_attribute,
        attribute: CapturedAttribute,
        unknown: value.Value,

        fn deinit(self: *CapturedAttributeResult, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .attribute => |*attribute| attribute.deinit(allocator),
                .unknown => |*unknown| unknown.deinit(allocator),
                .not_attribute => {},
            }
        }
    };

    const LogicOutcome = union(enum) {
        bool: bool,
        unknown: value.Value,
        err: env.EvalError,

        fn deinit(self: *LogicOutcome, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .unknown => |*unknown| unknown.deinit(allocator),
                else => {},
            }
        }
    };

    fn deinit(self: *Evaluator) void {
        for (self.local_bindings.items) |*binding| {
            binding.val.deinit(self.allocator);
        }
        if (self.borrowed_bindings) {
            self.local_bindings.clearRetainingCapacity();
            return;
        }
        self.local_bindings.deinit(self.binding_storage_allocator);
    }

    fn evalNode(self: *Evaluator, index: ast.Index) env.EvalError!value.Value {
        if (self.cost_budget) |budget| {
            if (self.cost_spent >= budget) return error.CostBudgetExceeded;
        }
        self.cost_spent +|= 1;
        if (self.deadline) |dl| {
            if (self.node_counter & 63 == 0) {
                if (monotonicNowNs() >= dl) return error.DeadlineExceeded;
            }
            self.node_counter +%= 1;
        }
        // before_eval hooks: allow short-circuiting
        for (self.decorators) |d| {
            if (d.before_eval) |hook| {
                if (hook(d.context, index)) |intercepted| {
                    for (self.decorators) |d2| {
                        if (d2.after_eval) |after| after(d2.context, index, intercepted);
                    }
                    return intercepted;
                }
            }
        }
        const node = self.program.ast.node(index);
        const out: value.Value = try switch (node.data) {
            .literal_int => |v| value.Value{ .int = v },
            .literal_uint => |v| value.Value{ .uint = v },
            .literal_double => |v| value.Value{ .double = v },
            .literal_bool => |v| value.Value{ .bool = v },
            .literal_null => value.Value{ .null = {} },
            .literal_string => |id| try value.string(self.allocator, self.program.ast.strings.get(id)),
            .literal_bytes => |id| try value.bytesValue(self.allocator, self.program.ast.strings.get(id)),
            .ident => |name_ref| self.evalIdent(index, name_ref),
            .unary => |u| self.evalUnary(index, u),
            .binary => |b| self.evalBinary(index, b),
            .conditional => |c| self.evalConditional(c),
            .list => |range| self.evalList(range),
            .map => |range| self.evalMap(range),
            .index => |access| self.evalIndex(index, access),
            .select => |select| self.evalSelect(index, select),
            .call => |call| self.evalCall(index, call.args, null),
            .receiver_call => |call| self.evalCall(index, call.args, call.target),
            .message => |msg| self.evalMessage(msg),
        };
        // after_eval hooks
        for (self.decorators) |d| {
            if (d.after_eval) |hook| hook(d.context, index, out);
        }
        try self.captureValue(index, out);
        return out;
    }

    fn captureValue(self: *Evaluator, index: ast.Index, out: value.Value) !void {
        const state = self.state orelse return;
        try state.capture(index, out);
    }

    fn evalIdent(self: *Evaluator, index: ast.Index, name_ref: ast.NameRef) env.EvalError!value.Value {
        if (!name_ref.absolute and name_ref.segments.len == 1) {
            const id = self.program.ast.name_segments.items[name_ref.segments.start];
            var i = self.local_bindings.items.len;
            while (i > 0) {
                i -= 1;
                const binding = self.local_bindings.items[i];
                if (bindingMatchesIdent(binding.name, id)) return binding.val.clone(self.allocator);
            }
        }
        if (try self.maybeUnknownForAttribute(index)) |unknown| return unknown;
        var joined_storage: std.ArrayListUnmanaged(u8) = .empty;
        defer joined_storage.deinit(self.allocator);
        var joined_small: [256]u8 = undefined;
        const joined = try self.joinNameRefInto(name_ref, &joined_storage, joined_small[0..]);
        if (try self.lookupActivationScoped(joined, name_ref.absolute)) |found| {
            return found.clone(self.allocator);
        }
        if (try self.program.env.lookupConstScoped(self.allocator, joined, name_ref.absolute)) |constant| {
            return constant.value.clone(self.allocator);
        }
        if (types.isBuiltinTypeDenotation(joined) or (try self.program.env.lookupMessageScoped(self.allocator, joined, name_ref.absolute)) != null) {
            return value.typeNameValue(self.allocator, joined);
        }
        return error.UndefinedVariable;
    }

    fn evalUnary(self: *Evaluator, index: ast.Index, unary: ast.Unary) env.EvalError!value.Value {
        if (self.program.operator_resolution.items[@intFromEnum(index)]) |overload_ref| {
            var operand = try self.evalNode(unary.expr);
            if (operand == .unknown) return operand;
            defer operand.deinit(self.allocator);
            const args = [_]value.Value{operand};
            return self.program.env.overloadAt(overload_ref).implementation(self.allocator, &args);
        }

        var operand = try self.evalNode(unary.expr);
        if (operand == .unknown) return operand;
        defer operand.deinit(self.allocator);

        return switch (unary.op) {
            .logical_not => switch (operand) {
                .bool => |v| .{ .bool = !v },
                else => value.RuntimeError.TypeMismatch,
            },
            .negate => switch (operand) {
                .int => |v| .{ .int = std.math.negate(v) catch return value.RuntimeError.Overflow },
                .double => |v| .{ .double = -v },
                else => value.RuntimeError.TypeMismatch,
            },
        };
    }

    fn evalBinary(self: *Evaluator, index: ast.Index, binary: ast.Binary) env.EvalError!value.Value {
        if (binary.op == .logical_and or binary.op == .logical_or) {
            return self.evalLogical(binary);
        }

        var lhs = try self.evalNode(binary.left);
        errdefer lhs.deinit(self.allocator);
        var rhs = self.evalNode(binary.right) catch |err| return err;
        errdefer rhs.deinit(self.allocator);

        if (lhs == .unknown or rhs == .unknown) {
            const out = try mergeUnknownValues(self.allocator, &.{ lhs, rhs });
            lhs.deinit(self.allocator);
            rhs.deinit(self.allocator);
            return out;
        }

        if (self.program.operator_resolution.items[@intFromEnum(index)]) |overload_ref| {
            const args = [_]value.Value{ lhs, rhs };
            const out = self.program.env.overloadAt(overload_ref).implementation(self.allocator, &args);
            lhs.deinit(self.allocator);
            rhs.deinit(self.allocator);
            return out;
        }

        const out = switch (binary.op) {
            .equal => value.Value{ .bool = try equalValues(lhs, rhs) },
            .not_equal => value.Value{ .bool = !(try equalValues(lhs, rhs)) },
            .less => value.Value{ .bool = try compareValues(lhs, rhs, .lt) },
            .less_equal => value.Value{ .bool = try compareValues(lhs, rhs, .lte) },
            .greater => value.Value{ .bool = try compareValues(lhs, rhs, .gt) },
            .greater_equal => value.Value{ .bool = try compareValues(lhs, rhs, .gte) },
            .add => try addValues(self.allocator, lhs, rhs),
            .subtract => try subValues(lhs, rhs),
            .multiply => try mulValues(lhs, rhs),
            .divide => try divValues(lhs, rhs),
            .remainder => try remValues(lhs, rhs),
            .in_set => value.Value{ .bool = try inValues(lhs, rhs) },
            .logical_and, .logical_or => unreachable,
        };
        lhs.deinit(self.allocator);
        rhs.deinit(self.allocator);
        return out;
    }

    fn evalLogical(self: *Evaluator, binary: ast.Binary) env.EvalError!value.Value {
        var lhs = self.evalLogicOutcome(binary.left);
        defer lhs.deinit(self.allocator);

        if (!self.exhaustive and lhs == .bool) {
            if (binary.op == .logical_and and !lhs.bool) return .{ .bool = false };
            if (binary.op == .logical_or and lhs.bool) return .{ .bool = true };
        }

        var rhs = self.evalLogicOutcome(binary.right);
        defer rhs.deinit(self.allocator);

        return switch (binary.op) {
            .logical_and => self.combineLogicalAnd(lhs, rhs),
            .logical_or => self.combineLogicalOr(lhs, rhs),
            else => unreachable,
        };
    }

    fn evalConditional(self: *Evaluator, conditional: ast.Conditional) env.EvalError!value.Value {
        var cond = try self.evalNode(conditional.condition);
        if (cond == .unknown) return cond;
        defer cond.deinit(self.allocator);
        if (self.exhaustive) {
            return switch (cond) {
                .bool => |v| {
                    if (v) {
                        const then_val = try self.evalNode(conditional.then_expr);
                        // Evaluate else branch for exhaustiveness, discard result.
                        var else_val = self.evalNode(conditional.else_expr) catch {
                            return then_val;
                        };
                        else_val.deinit(self.allocator);
                        return then_val;
                    } else {
                        const else_val = try self.evalNode(conditional.else_expr);
                        // Evaluate then branch for exhaustiveness, discard result.
                        var then_val = self.evalNode(conditional.then_expr) catch {
                            return else_val;
                        };
                        then_val.deinit(self.allocator);
                        return else_val;
                    }
                },
                else => value.RuntimeError.TypeMismatch,
            };
        }
        return switch (cond) {
            .bool => |v| if (v) self.evalNode(conditional.then_expr) else self.evalNode(conditional.else_expr),
            else => value.RuntimeError.TypeMismatch,
        };
    }

    fn evalList(self: *Evaluator, range: ast.Range) env.EvalError!value.Value {
        var out: std.ArrayListUnmanaged(value.Value) = .empty;
        var unknowns: partial.UnknownSet = .{};
        var saw_unknown = false;
        errdefer {
            for (out.items) |*item| item.deinit(self.allocator);
            out.deinit(self.allocator);
            unknowns.deinit(self.allocator);
        }
        try out.ensureTotalCapacity(self.allocator, range.len);
        for (0..range.len) |i| {
            const item = self.program.ast.list_items.items[range.start + i];
            if (item.optional) {
                var opt = try self.evalNode(item.value);
                defer opt.deinit(self.allocator);
                if (opt == .unknown) {
                    try unknowns.merge(self.allocator, &opt.unknown);
                    saw_unknown = true;
                    continue;
                }
                switch (opt) {
                    .optional => |optional| if (optional.value) |ptr| {
                        out.appendAssumeCapacity(try ptr.*.clone(self.allocator));
                    },
                    else => return value.RuntimeError.TypeMismatch,
                }
                continue;
            }
            var item_value = try self.evalNode(item.value);
            if (item_value == .unknown) {
                defer item_value.deinit(self.allocator);
                try unknowns.merge(self.allocator, &item_value.unknown);
                saw_unknown = true;
                continue;
            }
            out.appendAssumeCapacity(item_value);
        }
        if (saw_unknown) {
            for (out.items) |*item| item.deinit(self.allocator);
            out.deinit(self.allocator);
            return value.unknownFromSet(unknowns);
        }
        unknowns.deinit(self.allocator);
        return .{ .list = out };
    }

    fn evalMap(self: *Evaluator, range: ast.Range) env.EvalError!value.Value {
        var out: std.ArrayListUnmanaged(value.MapEntry) = .empty;
        var unknowns: partial.UnknownSet = .{};
        var saw_unknown = false;
        errdefer {
            for (out.items) |*entry| {
                entry.key.deinit(self.allocator);
                entry.value.deinit(self.allocator);
            }
            out.deinit(self.allocator);
            unknowns.deinit(self.allocator);
        }
        try out.ensureTotalCapacity(self.allocator, range.len);
        for (0..range.len) |i| {
            const entry = self.program.ast.map_entries.items[range.start + i];
            var key = try self.evalNode(entry.key);
            var key_owned = true;
            errdefer if (key_owned) key.deinit(self.allocator);
            if (key == .unknown) {
                defer key.deinit(self.allocator);
                try unknowns.merge(self.allocator, &key.unknown);
                saw_unknown = true;
                continue;
            }
            var val = if (entry.optional) blk: {
                var opt = try self.evalNode(entry.value);
                defer opt.deinit(self.allocator);
                if (opt == .unknown) {
                    try unknowns.merge(self.allocator, &opt.unknown);
                    saw_unknown = true;
                    key.deinit(self.allocator);
                    key_owned = false;
                    continue;
                }
                switch (opt) {
                    .optional => |optional| {
                        if (optional.value == null) {
                            key.deinit(self.allocator);
                            key_owned = false;
                            continue;
                        }
                        break :blk try optional.value.?.*.clone(self.allocator);
                    },
                    else => return value.RuntimeError.TypeMismatch,
                }
            } else try self.evalNode(entry.value);
            var val_owned = true;
            errdefer if (val_owned) val.deinit(self.allocator);
            if (val == .unknown) {
                defer val.deinit(self.allocator);
                try unknowns.merge(self.allocator, &val.unknown);
                saw_unknown = true;
                key.deinit(self.allocator);
                key_owned = false;
                continue;
            }
            if (!isValidMapKeyValue(key)) return value.RuntimeError.TypeMismatch;
            for (out.items) |existing| {
                if (try equalValues(existing.key, key)) return value.RuntimeError.DuplicateMapKey;
            }
            out.appendAssumeCapacity(.{
                .key = key,
                .value = val,
            });
            key_owned = false;
            val_owned = false;
        }
        if (saw_unknown) {
            for (out.items) |*entry| {
                entry.key.deinit(self.allocator);
                entry.value.deinit(self.allocator);
            }
            out.deinit(self.allocator);
            return value.unknownFromSet(unknowns);
        }
        unknowns.deinit(self.allocator);
        return .{ .map = out };
    }

    fn evalIndex(self: *Evaluator, index: ast.Index, access: ast.IndexAccess) env.EvalError!value.Value {
        if (try self.maybeUnknownForAttribute(index)) |unknown| return unknown;
        var resolved_target = try self.resolveAccessTarget(access.target);
        defer resolved_target.deinit(self.allocator);
        if (resolved_target.unknown) |unknown| return unknown;
        var idx = try self.evalNode(access.index);
        if (idx == .unknown) return idx;
        defer idx.deinit(self.allocator);
        const optional_result = access.optional or resolved_target.optional_chain;
        if (!resolved_target.present) {
            return if (optional_result) value.optionalNone() else value.RuntimeError.InvalidIndex;
        }
        const maybe = try self.lookupIndexValue(resolved_target.value.?, idx, optional_result);
        if (optional_result) {
            if (maybe) |found| return value.optionalSome(self.allocator, found);
            return value.optionalNone();
        }
        return maybe orelse value.RuntimeError.InvalidIndex;
    }

    fn evalSelect(self: *Evaluator, index: ast.Index, select: ast.Select) env.EvalError!value.Value {
        if (try self.maybeUnknownForAttribute(index)) |unknown| return unknown;
        if (!select.optional and !self.qualifiedExprShadowedByLocal(select.target)) {
            if (try self.lookupQualifiedValue(.{ .select = select })) |resolved| {
                return resolved;
            }
        }

        var resolved_target = try self.resolveAccessTarget(select.target);
        defer resolved_target.deinit(self.allocator);
        if (resolved_target.unknown) |unknown| return unknown;
        const field_name = self.program.ast.strings.get(select.field);
        const optional_result = select.optional or resolved_target.optional_chain;
        if (!resolved_target.present) {
            return if (optional_result) value.optionalNone() else value.RuntimeError.NoSuchField;
        }
        const maybe = try self.lookupSelectValue(
            resolved_target.value.?,
            field_name,
            if (optional_result) .optional else .normal,
        );
        if (optional_result) {
            if (maybe) |found| return value.optionalSome(self.allocator, found);
            return value.optionalNone();
        }
        return maybe orelse value.RuntimeError.NoSuchField;
    }

    fn evalCall(
        self: *Evaluator,
        node_index: ast.Index,
        args_range: ast.Range,
        maybe_target: ?ast.Index,
    ) env.EvalError!value.Value {
        const resolution = self.program.call_resolution.items[@intFromEnum(node_index)];
        switch (resolution) {
            .macro => |macro_call| return self.evalMacro(macro_call, args_range, maybe_target),
            .iter_var => |resolved| return self.evalSyntheticBinding(.{ .iter_var = .{
                .depth = resolved.depth,
                .slot = resolved.slot,
            } }),
            .block_index => |resolved| return self.evalSyntheticBinding(.{ .block_index = .{
                .depth = resolved.depth,
                .index = resolved.index,
            } }),
            else => {},
        }

        var args = InlineList(value.Value, 8).init(self.allocator);
        defer {
            for (args.itemsMut()) |*arg| arg.deinit(self.allocator);
            args.deinit();
        }

        const include_target = switch (resolution) {
            .custom => |resolved| resolved.receiver_style,
            .dynamic => |resolved| resolved.receiver_style,
            .enum_ctor => false,
            .none, .macro, .iter_var, .block_index => maybe_target != null,
        };
        const total_len = args_range.len + @as(u32, if (include_target) 1 else 0);
        try args.ensureTotalCapacity(total_len);
        if (include_target and maybe_target != null) {
            const target = maybe_target.?;
            try args.append(try self.evalNode(target));
        }
        for (0..args_range.len) |i| {
            try args.append(try self.evalNode(self.program.ast.expr_ranges.items[args_range.start + i]));
        }

        if (argsContainUnknown(args.items())) {
            return try mergeUnknownValues(self.allocator, args.items());
        }

        return switch (resolution) {
            .none => value.RuntimeError.NoMatchingOverload,
            .enum_ctor => |enum_ty| try self.evalEnumConstructor(enum_ty, args.items()),
            .custom => |resolved| self.program.env.overloadAt(resolved.ref).implementation(self.allocator, args.items()),
            .dynamic => |resolved| self.program.env.dynamicFunctionAt(resolved.ref).implementation(self.allocator, args.items()),
            .macro => unreachable,
            .iter_var => unreachable,
            .block_index => unreachable,
        };
    }

    fn evalEnumConstructor(self: *Evaluator, enum_ty: types.TypeRef, args: []const value.Value) env.EvalError!value.Value {
        if (args.len != 1) return value.RuntimeError.NoMatchingOverload;
        const enum_name = switch (self.program.env.types.spec(enum_ty)) {
            .enum_type => |name| name,
            else => return value.RuntimeError.TypeMismatch,
        };
        const enum_decl = self.program.env.lookupEnum(enum_name) orelse return value.RuntimeError.NoMatchingOverload;

        return switch (args[0]) {
            .int => |raw| blk: {
                if (raw < std.math.minInt(i32) or raw > std.math.maxInt(i32)) return value.RuntimeError.Overflow;
                break :blk try value.enumValue(self.allocator, enum_name, @intCast(raw));
            },
            .string => |member_name| blk: {
                const member = enum_decl.lookupValueName(member_name) orelse return value.RuntimeError.TypeMismatch;
                break :blk try value.enumValue(self.allocator, enum_name, member.value);
            },
            else => value.RuntimeError.TypeMismatch,
        };
    }

    fn evalMacro(
        self: *Evaluator,
        macro_call: checker.MacroCall,
        args_range: ast.Range,
        maybe_target: ?ast.Index,
    ) env.EvalError!value.Value {
        switch (macro_call) {
            .has => return self.evalHasMacro(args_range),
            .bind => return self.evalBindMacro(args_range),
            .block => return self.evalBlockMacro(args_range),
            .all, .exists, .exists_one, .opt_map, .opt_flat_map, .filter, .map, .map_filter, .sort_by, .transform_list, .transform_list_filter, .transform_map, .transform_map_filter, .transform_map_entry, .transform_map_entry_filter => {
                const target = maybe_target orelse return value.RuntimeError.NoMatchingOverload;
                return self.evalReceiverMacro(macro_call, target, args_range);
            },
        }
    }

    fn evalHasMacro(self: *Evaluator, args_range: ast.Range) env.EvalError!value.Value {
        const arg_index = self.program.ast.expr_ranges.items[args_range.start];
        switch (self.program.ast.node(arg_index).data) {
            .select, .index => {},
            else => return value.RuntimeError.NoMatchingOverload,
        }
        return self.evalPresenceValue(arg_index);
    }

    fn evalBindMacro(self: *Evaluator, args_range: ast.Range) env.EvalError!value.Value {
        if (args_range.len != 3) return value.RuntimeError.NoMatchingOverload;
        const binding_id = self.extractBindingRef(self.program.ast.expr_ranges.items[args_range.start]) orelse {
            return value.RuntimeError.NoMatchingOverload;
        };
        const binding_expr = self.program.ast.expr_ranges.items[args_range.start + 1];
        const body_expr = self.program.ast.expr_ranges.items[args_range.start + 2];
        const binding_value = try self.evalNode(binding_expr);
        return self.withBinding(binding_id, binding_value, body_expr);
    }

    fn evalBlockMacro(self: *Evaluator, args_range: ast.Range) env.EvalError!value.Value {
        if (args_range.len != 2) return value.RuntimeError.NoMatchingOverload;
        const bindings_index = self.program.ast.expr_ranges.items[args_range.start];
        const body_index = self.program.ast.expr_ranges.items[args_range.start + 1];
        const bindings_range = switch (self.program.ast.node(bindings_index).data) {
            .list => |range| range,
            else => return value.RuntimeError.NoMatchingOverload,
        };

        const depth = self.block_depth;
        self.block_depth += 1;
        defer self.block_depth -= 1;

        const mark = self.local_bindings.items.len;
        defer {
            while (self.local_bindings.items.len > mark) {
                var binding = self.local_bindings.pop().?;
                binding.val.deinit(self.allocator);
            }
        }

        for (0..bindings_range.len) |i| {
            const item = self.program.ast.list_items.items[bindings_range.start + i];
            const value_out = try self.evalNode(item.value);
            try self.local_bindings.append(self.binding_storage_allocator, .{
                .name = .{ .block_index = .{
                    .depth = depth,
                    .index = @intCast(i),
                } },
                .val = value_out,
            });
        }

        return self.evalNode(body_index);
    }

    fn evalReceiverMacro(
        self: *Evaluator,
        macro_call: checker.MacroCall,
        target_index: ast.Index,
        args_range: ast.Range,
    ) env.EvalError!value.Value {
        var target = try self.evalNode(target_index);
        if (target == .unknown) return target;
        defer target.deinit(self.allocator);

        const first_binding_id = self.extractBindingRef(self.program.ast.expr_ranges.items[args_range.start]) orelse {
            return value.RuntimeError.NoMatchingOverload;
        };
        const second_binding_id = if (args_range.len >= 3 and (macro_call == .all or
            macro_call == .exists or
            macro_call == .exists_one or
            macro_call == .transform_list or
            macro_call == .transform_list_filter or
            macro_call == .transform_map or
            macro_call == .transform_map_filter or
            macro_call == .transform_map_entry or
            macro_call == .transform_map_entry_filter))
            self.extractBindingRef(self.program.ast.expr_ranges.items[args_range.start + 1]) orelse return value.RuntimeError.NoMatchingOverload
        else
            null;

        if (macro_call == .opt_map or macro_call == .opt_flat_map) {
            if (target != .optional) return value.RuntimeError.NoMatchingOverload;
            const inner_ptr = target.optional.value orelse return value.optionalNone();
            const expr_index = self.program.ast.expr_ranges.items[args_range.start + 1];
            if (macro_call == .opt_map) {
                const mapped = try self.withBinding(first_binding_id, try inner_ptr.*.clone(self.allocator), expr_index);
                if (mapped == .unknown) return mapped;
                return value.optionalSome(self.allocator, mapped);
            }
            return self.withBinding(first_binding_id, try inner_ptr.*.clone(self.allocator), expr_index);
        }

        return switch (target) {
            .list => |items| switch (macro_call) {
                .all => if (second_binding_id) |second_id|
                    try self.evalAllList2(first_binding_id, second_id, items.items, self.program.ast.expr_ranges.items[args_range.start + 2])
                else
                    try self.evalAllList(first_binding_id, items.items, self.program.ast.expr_ranges.items[args_range.start + 1]),
                .exists => if (second_binding_id) |second_id|
                    try self.evalExistsList2(first_binding_id, second_id, items.items, self.program.ast.expr_ranges.items[args_range.start + 2])
                else
                    try self.evalExistsList(first_binding_id, items.items, self.program.ast.expr_ranges.items[args_range.start + 1]),
                .exists_one => if (second_binding_id) |second_id|
                    try self.evalExistsOneList2(first_binding_id, second_id, items.items, self.program.ast.expr_ranges.items[args_range.start + 2])
                else
                    try self.evalExistsOneList(first_binding_id, items.items, self.program.ast.expr_ranges.items[args_range.start + 1]),
                .filter => try self.evalFilterList(first_binding_id, items.items, self.program.ast.expr_ranges.items[args_range.start + 1]),
                .map => try self.evalMapList(first_binding_id, items.items, null, self.program.ast.expr_ranges.items[args_range.start + 1]),
                .map_filter => try self.evalMapList(
                    first_binding_id,
                    items.items,
                    self.program.ast.expr_ranges.items[args_range.start + 1],
                    self.program.ast.expr_ranges.items[args_range.start + 2],
                ),
                .sort_by => try self.evalSortByList(
                    first_binding_id,
                    items.items,
                    self.program.ast.expr_ranges.items[args_range.start + 1],
                ),
                .transform_list => try self.evalTransformList2(
                    first_binding_id,
                    second_binding_id.?,
                    items.items,
                    null,
                    self.program.ast.expr_ranges.items[args_range.start + 2],
                ),
                .transform_list_filter => try self.evalTransformList2(
                    first_binding_id,
                    second_binding_id.?,
                    items.items,
                    self.program.ast.expr_ranges.items[args_range.start + 2],
                    self.program.ast.expr_ranges.items[args_range.start + 3],
                ),
                .transform_map => try self.evalTransformMapList2(
                    first_binding_id,
                    second_binding_id.?,
                    items.items,
                    null,
                    self.program.ast.expr_ranges.items[args_range.start + 2],
                ),
                .transform_map_filter => try self.evalTransformMapList2(
                    first_binding_id,
                    second_binding_id.?,
                    items.items,
                    self.program.ast.expr_ranges.items[args_range.start + 2],
                    self.program.ast.expr_ranges.items[args_range.start + 3],
                ),
                .transform_map_entry => try self.evalTransformMapEntryList2(
                    first_binding_id,
                    second_binding_id.?,
                    items.items,
                    null,
                    self.program.ast.expr_ranges.items[args_range.start + 2],
                ),
                .transform_map_entry_filter => try self.evalTransformMapEntryList2(
                    first_binding_id,
                    second_binding_id.?,
                    items.items,
                    self.program.ast.expr_ranges.items[args_range.start + 2],
                    self.program.ast.expr_ranges.items[args_range.start + 3],
                ),
                .opt_map, .opt_flat_map => value.RuntimeError.NoMatchingOverload,
                .block => unreachable,
                .bind => unreachable,
                .has => unreachable,
            },
            .map => |entries| switch (macro_call) {
                .all => if (second_binding_id) |second_id|
                    try self.evalAllMap2(first_binding_id, second_id, entries.items, self.program.ast.expr_ranges.items[args_range.start + 2])
                else
                    try self.evalAllMap(first_binding_id, entries.items, self.program.ast.expr_ranges.items[args_range.start + 1]),
                .exists => if (second_binding_id) |second_id|
                    try self.evalExistsMap2(first_binding_id, second_id, entries.items, self.program.ast.expr_ranges.items[args_range.start + 2])
                else
                    try self.evalExistsMap(first_binding_id, entries.items, self.program.ast.expr_ranges.items[args_range.start + 1]),
                .exists_one => if (second_binding_id) |second_id|
                    try self.evalExistsOneMap2(first_binding_id, second_id, entries.items, self.program.ast.expr_ranges.items[args_range.start + 2])
                else
                    try self.evalExistsOneMap(first_binding_id, entries.items, self.program.ast.expr_ranges.items[args_range.start + 1]),
                .filter => try self.evalFilterMap(first_binding_id, entries.items, self.program.ast.expr_ranges.items[args_range.start + 1]),
                .map => try self.evalMapMap(first_binding_id, entries.items, null, self.program.ast.expr_ranges.items[args_range.start + 1]),
                .map_filter => try self.evalMapMap(
                    first_binding_id,
                    entries.items,
                    self.program.ast.expr_ranges.items[args_range.start + 1],
                    self.program.ast.expr_ranges.items[args_range.start + 2],
                ),
                .transform_list => try self.evalTransformListMap2(
                    first_binding_id,
                    second_binding_id.?,
                    entries.items,
                    null,
                    self.program.ast.expr_ranges.items[args_range.start + 2],
                ),
                .transform_list_filter => try self.evalTransformListMap2(
                    first_binding_id,
                    second_binding_id.?,
                    entries.items,
                    self.program.ast.expr_ranges.items[args_range.start + 2],
                    self.program.ast.expr_ranges.items[args_range.start + 3],
                ),
                .transform_map => try self.evalTransformMap2(
                    first_binding_id,
                    second_binding_id.?,
                    entries.items,
                    null,
                    self.program.ast.expr_ranges.items[args_range.start + 2],
                ),
                .transform_map_filter => try self.evalTransformMap2(
                    first_binding_id,
                    second_binding_id.?,
                    entries.items,
                    self.program.ast.expr_ranges.items[args_range.start + 2],
                    self.program.ast.expr_ranges.items[args_range.start + 3],
                ),
                .transform_map_entry => try self.evalTransformMapEntryMap2(
                    first_binding_id,
                    second_binding_id.?,
                    entries.items,
                    null,
                    self.program.ast.expr_ranges.items[args_range.start + 2],
                ),
                .transform_map_entry_filter => try self.evalTransformMapEntryMap2(
                    first_binding_id,
                    second_binding_id.?,
                    entries.items,
                    self.program.ast.expr_ranges.items[args_range.start + 2],
                    self.program.ast.expr_ranges.items[args_range.start + 3],
                ),
                .sort_by, .opt_map, .opt_flat_map => value.RuntimeError.NoMatchingOverload,
                .block => unreachable,
                .bind => unreachable,
                .has => unreachable,
            },
            else => value.RuntimeError.NoMatchingOverload,
        };
    }

    fn withBinding(
        self: *Evaluator,
        binding_id: checker.BindingRef,
        bound_value: value.Value,
        expr_index: ast.Index,
    ) env.EvalError!value.Value {
        try self.local_bindings.append(self.binding_storage_allocator, .{
            .name = binding_id,
            .val = bound_value,
        });
        defer {
            var binding = self.local_bindings.pop().?;
            binding.val.deinit(self.allocator);
        }
        return self.evalNode(expr_index);
    }

    fn withBindings(
        self: *Evaluator,
        first_binding_id: checker.BindingRef,
        first_value: value.Value,
        second_binding_id: checker.BindingRef,
        second_value: value.Value,
        expr_index: ast.Index,
    ) env.EvalError!value.Value {
        try self.local_bindings.append(self.binding_storage_allocator, .{
            .name = first_binding_id,
            .val = first_value,
        });
        defer {
            var binding = self.local_bindings.pop().?;
            binding.val.deinit(self.allocator);
        }
        try self.local_bindings.append(self.binding_storage_allocator, .{
            .name = second_binding_id,
            .val = second_value,
        });
        defer {
            var binding = self.local_bindings.pop().?;
            binding.val.deinit(self.allocator);
        }
        return self.evalNode(expr_index);
    }

    fn evalPredicateOutcome(
        self: *Evaluator,
        binding_id: checker.BindingRef,
        bound_value: value.Value,
        expr_index: ast.Index,
    ) LogicOutcome {
        var result = self.withBinding(binding_id, bound_value, expr_index) catch |err| return .{ .err = err };
        switch (result) {
            .bool => |boolean| {
                result.deinit(self.allocator);
                return .{ .bool = boolean };
            },
            .unknown => return .{ .unknown = result },
            else => {
                result.deinit(self.allocator);
                return .{ .err = value.RuntimeError.TypeMismatch };
            },
        }
    }

    fn evalPredicateOutcome2(
        self: *Evaluator,
        first_binding_id: checker.BindingRef,
        first_value: value.Value,
        second_binding_id: checker.BindingRef,
        second_value: value.Value,
        expr_index: ast.Index,
    ) LogicOutcome {
        var result = self.withBindings(first_binding_id, first_value, second_binding_id, second_value, expr_index) catch |err| return .{ .err = err };
        switch (result) {
            .bool => |boolean| {
                result.deinit(self.allocator);
                return .{ .bool = boolean };
            },
            .unknown => return .{ .unknown = result },
            else => {
                result.deinit(self.allocator);
                return .{ .err = value.RuntimeError.TypeMismatch };
            },
        }
    }

    fn evalAllList(self: *Evaluator, binding_id: checker.BindingRef, items: []const value.Value, expr_index: ast.Index) env.EvalError!value.Value {
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        var first_err: ?env.EvalError = null;
        for (items) |item| {
            var outcome = self.evalPredicateOutcome(binding_id, try item.clone(self.allocator), expr_index);
            defer outcome.deinit(self.allocator);
            switch (outcome) {
                .bool => |pred| if (!pred) return .{ .bool = false },
                .unknown => try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown),
                .err => |err| {
                    if (first_err == null) first_err = err;
                },
            }
        }
        if (pending_unknown) |unknown| return try unknown.clone(self.allocator);
        if (first_err) |err| return err;
        return .{ .bool = true };
    }

    fn evalExistsList(self: *Evaluator, binding_id: checker.BindingRef, items: []const value.Value, expr_index: ast.Index) env.EvalError!value.Value {
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        var first_err: ?env.EvalError = null;
        for (items) |item| {
            var outcome = self.evalPredicateOutcome(binding_id, try item.clone(self.allocator), expr_index);
            defer outcome.deinit(self.allocator);
            switch (outcome) {
                .bool => |pred| if (pred) return .{ .bool = true },
                .unknown => try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown),
                .err => |err| {
                    if (first_err == null) first_err = err;
                },
            }
        }
        if (pending_unknown) |unknown| return try unknown.clone(self.allocator);
        if (first_err) |err| return err;
        return .{ .bool = false };
    }

    fn evalExistsOneList(self: *Evaluator, binding_id: checker.BindingRef, items: []const value.Value, expr_index: ast.Index) env.EvalError!value.Value {
        var matches: usize = 0;
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        var first_err: ?env.EvalError = null;
        for (items) |item| {
            var outcome = self.evalPredicateOutcome(binding_id, try item.clone(self.allocator), expr_index);
            defer outcome.deinit(self.allocator);
            switch (outcome) {
                .bool => |pred| {
                    if (pred) matches += 1;
                },
                .unknown => try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown),
                .err => |err| {
                    if (first_err == null) first_err = err;
                },
            }
        }
        if (pending_unknown) |unknown| return try unknown.clone(self.allocator);
        if (first_err) |err| return err;
        return .{ .bool = matches == 1 };
    }

    fn evalFilterList(self: *Evaluator, binding_id: checker.BindingRef, items: []const value.Value, expr_index: ast.Index) env.EvalError!value.Value {
        var out: std.ArrayListUnmanaged(value.Value) = .empty;
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        errdefer {
            for (out.items) |*item| item.deinit(self.allocator);
            out.deinit(self.allocator);
        }
        try out.ensureTotalCapacity(self.allocator, items.len);
        for (items) |item| {
            var outcome = self.evalPredicateOutcome(binding_id, try item.clone(self.allocator), expr_index);
            defer outcome.deinit(self.allocator);
            switch (outcome) {
                .bool => |pred| if (pred) try out.append(self.allocator, try item.clone(self.allocator)),
                .unknown => try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown),
                .err => |err| return err,
            }
        }
        if (pending_unknown) |unknown| {
            for (out.items) |*item| item.deinit(self.allocator);
            out.deinit(self.allocator);
            return try unknown.clone(self.allocator);
        }
        return .{ .list = out };
    }

    fn evalMapList(
        self: *Evaluator,
        binding_id: checker.BindingRef,
        items: []const value.Value,
        maybe_predicate: ?ast.Index,
        transform_expr: ast.Index,
    ) env.EvalError!value.Value {
        var out: std.ArrayListUnmanaged(value.Value) = .empty;
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        errdefer {
            for (out.items) |*item| item.deinit(self.allocator);
            out.deinit(self.allocator);
        }
        try out.ensureTotalCapacity(self.allocator, items.len);
        for (items) |item| {
            if (maybe_predicate) |predicate_expr| {
                var outcome = self.evalPredicateOutcome(binding_id, try item.clone(self.allocator), predicate_expr);
                defer outcome.deinit(self.allocator);
                switch (outcome) {
                    .bool => |pred| if (!pred) continue,
                    .unknown => {
                        try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown);
                        continue;
                    },
                    .err => |err| return err,
                }
            }
            var transformed = try self.withBinding(binding_id, try item.clone(self.allocator), transform_expr);
            if (transformed == .unknown) {
                defer transformed.deinit(self.allocator);
                try mergePendingUnknown(self.allocator, &pending_unknown, transformed);
                continue;
            }
            try out.append(self.allocator, transformed);
        }
        if (pending_unknown) |unknown| {
            for (out.items) |*item| item.deinit(self.allocator);
            out.deinit(self.allocator);
            return try unknown.clone(self.allocator);
        }
        return .{ .list = out };
    }

    fn evalSortByList(
        self: *Evaluator,
        binding_id: checker.BindingRef,
        items: []const value.Value,
        key_expr: ast.Index,
    ) env.EvalError!value.Value {
        const SortPair = struct {
            key: value.Value,
            item: value.Value,
        };

        var pairs: std.ArrayListUnmanaged(SortPair) = .empty;
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        errdefer {
            for (pairs.items) |*pair| {
                pair.key.deinit(self.allocator);
                pair.item.deinit(self.allocator);
            }
            pairs.deinit(self.allocator);
        }

        try pairs.ensureTotalCapacity(self.allocator, items.len);
        for (items) |item| {
            var key = try self.withBinding(binding_id, try item.clone(self.allocator), key_expr);
            if (key == .unknown) {
                defer key.deinit(self.allocator);
                try mergePendingUnknown(self.allocator, &pending_unknown, key);
                continue;
            }
            try pairs.append(self.allocator, .{
                .key = key,
                .item = try item.clone(self.allocator),
            });
        }
        if (pending_unknown) |unknown| return try unknown.clone(self.allocator);

        try validateSortablePairs(pairs.items);
        std.mem.sortUnstable(SortPair, pairs.items, {}, struct {
            fn lessThan(_: void, lhs: SortPair, rhs: SortPair) bool {
                return sortableValueLessThan(lhs.key, rhs.key);
            }
        }.lessThan);

        var out: std.ArrayListUnmanaged(value.Value) = .empty;
        errdefer {
            for (out.items) |*item| item.deinit(self.allocator);
            out.deinit(self.allocator);
        }
        try out.ensureTotalCapacity(self.allocator, pairs.items.len);
        for (pairs.items) |*pair| {
            out.appendAssumeCapacity(pair.item);
            pair.item = .null;
            pair.key.deinit(self.allocator);
            pair.key = .null;
        }
        pairs.deinit(self.allocator);
        return .{ .list = out };
    }

    fn evalAllMap(self: *Evaluator, binding_id: checker.BindingRef, entries: []const value.MapEntry, expr_index: ast.Index) env.EvalError!value.Value {
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        var first_err: ?env.EvalError = null;
        for (entries) |entry| {
            var outcome = self.evalPredicateOutcome(binding_id, try entry.key.clone(self.allocator), expr_index);
            defer outcome.deinit(self.allocator);
            switch (outcome) {
                .bool => |pred| if (!pred) return .{ .bool = false },
                .unknown => try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown),
                .err => |err| {
                    if (first_err == null) first_err = err;
                },
            }
        }
        if (pending_unknown) |unknown| return try unknown.clone(self.allocator);
        if (first_err) |err| return err;
        return .{ .bool = true };
    }

    fn evalExistsMap(self: *Evaluator, binding_id: checker.BindingRef, entries: []const value.MapEntry, expr_index: ast.Index) env.EvalError!value.Value {
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        var first_err: ?env.EvalError = null;
        for (entries) |entry| {
            var outcome = self.evalPredicateOutcome(binding_id, try entry.key.clone(self.allocator), expr_index);
            defer outcome.deinit(self.allocator);
            switch (outcome) {
                .bool => |pred| if (pred) return .{ .bool = true },
                .unknown => try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown),
                .err => |err| {
                    if (first_err == null) first_err = err;
                },
            }
        }
        if (pending_unknown) |unknown| return try unknown.clone(self.allocator);
        if (first_err) |err| return err;
        return .{ .bool = false };
    }

    fn evalExistsOneMap(self: *Evaluator, binding_id: checker.BindingRef, entries: []const value.MapEntry, expr_index: ast.Index) env.EvalError!value.Value {
        var matches: usize = 0;
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        var first_err: ?env.EvalError = null;
        for (entries) |entry| {
            var outcome = self.evalPredicateOutcome(binding_id, try entry.key.clone(self.allocator), expr_index);
            defer outcome.deinit(self.allocator);
            switch (outcome) {
                .bool => |pred| {
                    if (pred) matches += 1;
                },
                .unknown => try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown),
                .err => |err| {
                    if (first_err == null) first_err = err;
                },
            }
        }
        if (pending_unknown) |unknown| return try unknown.clone(self.allocator);
        if (first_err) |err| return err;
        return .{ .bool = matches == 1 };
    }

    fn evalFilterMap(self: *Evaluator, binding_id: checker.BindingRef, entries: []const value.MapEntry, expr_index: ast.Index) env.EvalError!value.Value {
        var out: std.ArrayListUnmanaged(value.Value) = .empty;
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        errdefer {
            for (out.items) |*item| item.deinit(self.allocator);
            out.deinit(self.allocator);
        }
        try out.ensureTotalCapacity(self.allocator, entries.len);
        for (entries) |entry| {
            var outcome = self.evalPredicateOutcome(binding_id, try entry.key.clone(self.allocator), expr_index);
            defer outcome.deinit(self.allocator);
            switch (outcome) {
                .bool => |pred| if (pred) try out.append(self.allocator, try entry.key.clone(self.allocator)),
                .unknown => try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown),
                .err => |err| return err,
            }
        }
        if (pending_unknown) |unknown| {
            for (out.items) |*item| item.deinit(self.allocator);
            out.deinit(self.allocator);
            return try unknown.clone(self.allocator);
        }
        return .{ .list = out };
    }

    fn evalMapMap(
        self: *Evaluator,
        binding_id: checker.BindingRef,
        entries: []const value.MapEntry,
        maybe_predicate: ?ast.Index,
        transform_expr: ast.Index,
    ) env.EvalError!value.Value {
        var out: std.ArrayListUnmanaged(value.Value) = .empty;
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        errdefer {
            for (out.items) |*item| item.deinit(self.allocator);
            out.deinit(self.allocator);
        }
        try out.ensureTotalCapacity(self.allocator, entries.len);
        for (entries) |entry| {
            if (maybe_predicate) |predicate_expr| {
                var outcome = self.evalPredicateOutcome(binding_id, try entry.key.clone(self.allocator), predicate_expr);
                defer outcome.deinit(self.allocator);
                switch (outcome) {
                    .bool => |pred| if (!pred) continue,
                    .unknown => {
                        try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown);
                        continue;
                    },
                    .err => |err| return err,
                }
            }
            var transformed = try self.withBinding(binding_id, try entry.key.clone(self.allocator), transform_expr);
            if (transformed == .unknown) {
                defer transformed.deinit(self.allocator);
                try mergePendingUnknown(self.allocator, &pending_unknown, transformed);
                continue;
            }
            try out.append(self.allocator, transformed);
        }
        if (pending_unknown) |unknown| {
            for (out.items) |*item| item.deinit(self.allocator);
            out.deinit(self.allocator);
            return try unknown.clone(self.allocator);
        }
        return .{ .list = out };
    }

    fn evalAllList2(
        self: *Evaluator,
        index_binding_id: checker.BindingRef,
        value_binding_id: checker.BindingRef,
        items: []const value.Value,
        expr_index: ast.Index,
    ) env.EvalError!value.Value {
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        var first_err: ?env.EvalError = null;
        for (items, 0..) |item, i| {
            var outcome = self.evalPredicateOutcome2(
                index_binding_id,
                .{ .int = @intCast(i) },
                value_binding_id,
                try item.clone(self.allocator),
                expr_index,
            );
            defer outcome.deinit(self.allocator);
            switch (outcome) {
                .bool => |pred| if (!pred) return .{ .bool = false },
                .unknown => try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown),
                .err => |err| {
                    if (first_err == null) first_err = err;
                },
            }
        }
        if (pending_unknown) |unknown| return try unknown.clone(self.allocator);
        if (first_err) |err| return err;
        return .{ .bool = true };
    }

    fn evalExistsList2(
        self: *Evaluator,
        index_binding_id: checker.BindingRef,
        value_binding_id: checker.BindingRef,
        items: []const value.Value,
        expr_index: ast.Index,
    ) env.EvalError!value.Value {
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        var first_err: ?env.EvalError = null;
        for (items, 0..) |item, i| {
            var outcome = self.evalPredicateOutcome2(
                index_binding_id,
                .{ .int = @intCast(i) },
                value_binding_id,
                try item.clone(self.allocator),
                expr_index,
            );
            defer outcome.deinit(self.allocator);
            switch (outcome) {
                .bool => |pred| if (pred) return .{ .bool = true },
                .unknown => try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown),
                .err => |err| {
                    if (first_err == null) first_err = err;
                },
            }
        }
        if (pending_unknown) |unknown| return try unknown.clone(self.allocator);
        if (first_err) |err| return err;
        return .{ .bool = false };
    }

    fn evalExistsOneList2(
        self: *Evaluator,
        index_binding_id: checker.BindingRef,
        value_binding_id: checker.BindingRef,
        items: []const value.Value,
        expr_index: ast.Index,
    ) env.EvalError!value.Value {
        var matches: usize = 0;
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        var first_err: ?env.EvalError = null;
        for (items, 0..) |item, i| {
            var outcome = self.evalPredicateOutcome2(
                index_binding_id,
                .{ .int = @intCast(i) },
                value_binding_id,
                try item.clone(self.allocator),
                expr_index,
            );
            defer outcome.deinit(self.allocator);
            switch (outcome) {
                .bool => |pred| {
                    if (pred) matches += 1;
                },
                .unknown => try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown),
                .err => |err| {
                    if (first_err == null) first_err = err;
                },
            }
        }
        if (pending_unknown) |unknown| return try unknown.clone(self.allocator);
        if (first_err) |err| return err;
        return .{ .bool = matches == 1 };
    }

    fn evalTransformList2(
        self: *Evaluator,
        index_binding_id: checker.BindingRef,
        value_binding_id: checker.BindingRef,
        items: []const value.Value,
        maybe_predicate: ?ast.Index,
        transform_expr: ast.Index,
    ) env.EvalError!value.Value {
        var out: std.ArrayListUnmanaged(value.Value) = .empty;
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        errdefer {
            for (out.items) |*item| item.deinit(self.allocator);
            out.deinit(self.allocator);
        }
        try out.ensureTotalCapacity(self.allocator, items.len);
        for (items, 0..) |item, i| {
            if (maybe_predicate) |predicate_expr| {
                var outcome = self.evalPredicateOutcome2(
                    index_binding_id,
                    .{ .int = @intCast(i) },
                    value_binding_id,
                    try item.clone(self.allocator),
                    predicate_expr,
                );
                defer outcome.deinit(self.allocator);
                switch (outcome) {
                    .bool => |pred| if (!pred) continue,
                    .unknown => {
                        try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown);
                        continue;
                    },
                    .err => |err| return err,
                }
            }
            var transformed = try self.withBindings(
                index_binding_id,
                .{ .int = @intCast(i) },
                value_binding_id,
                try item.clone(self.allocator),
                transform_expr,
            );
            if (transformed == .unknown) {
                defer transformed.deinit(self.allocator);
                try mergePendingUnknown(self.allocator, &pending_unknown, transformed);
                continue;
            }
            try out.append(self.allocator, transformed);
        }
        if (pending_unknown) |unknown| {
            for (out.items) |*item| item.deinit(self.allocator);
            out.deinit(self.allocator);
            return try unknown.clone(self.allocator);
        }
        return .{ .list = out };
    }

    fn evalTransformMapList2(
        self: *Evaluator,
        index_binding_id: checker.BindingRef,
        value_binding_id: checker.BindingRef,
        items: []const value.Value,
        maybe_predicate: ?ast.Index,
        transform_expr: ast.Index,
    ) env.EvalError!value.Value {
        var out: std.ArrayListUnmanaged(value.MapEntry) = .empty;
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        errdefer {
            for (out.items) |*item| {
                item.key.deinit(self.allocator);
                item.value.deinit(self.allocator);
            }
            out.deinit(self.allocator);
        }
        try out.ensureTotalCapacity(self.allocator, items.len);
        for (items, 0..) |item, i| {
            if (maybe_predicate) |predicate_expr| {
                var outcome = self.evalPredicateOutcome2(
                    index_binding_id,
                    .{ .int = @intCast(i) },
                    value_binding_id,
                    try item.clone(self.allocator),
                    predicate_expr,
                );
                defer outcome.deinit(self.allocator);
                switch (outcome) {
                    .bool => |pred| if (!pred) continue,
                    .unknown => {
                        try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown);
                        continue;
                    },
                    .err => |err| return err,
                }
            }
            const transformed = try self.withBindings(
                index_binding_id,
                .{ .int = @intCast(i) },
                value_binding_id,
                try item.clone(self.allocator),
                transform_expr,
            );
            if (transformed == .unknown) {
                defer {
                    var unknown = transformed;
                    unknown.deinit(self.allocator);
                }
                try mergePendingUnknown(self.allocator, &pending_unknown, transformed);
                continue;
            }
            try out.append(self.allocator, .{
                .key = .{ .int = @intCast(i) },
                .value = transformed,
            });
        }
        if (pending_unknown) |unknown| {
            for (out.items) |*item| {
                item.key.deinit(self.allocator);
                item.value.deinit(self.allocator);
            }
            out.deinit(self.allocator);
            return try unknown.clone(self.allocator);
        }
        return .{ .map = out };
    }

    fn evalAllMap2(
        self: *Evaluator,
        key_binding_id: checker.BindingRef,
        value_binding_id: checker.BindingRef,
        entries: []const value.MapEntry,
        expr_index: ast.Index,
    ) env.EvalError!value.Value {
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        var first_err: ?env.EvalError = null;
        for (entries) |entry| {
            var outcome = self.evalPredicateOutcome2(
                key_binding_id,
                try entry.key.clone(self.allocator),
                value_binding_id,
                try entry.value.clone(self.allocator),
                expr_index,
            );
            defer outcome.deinit(self.allocator);
            switch (outcome) {
                .bool => |pred| if (!pred) return .{ .bool = false },
                .unknown => try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown),
                .err => |err| {
                    if (first_err == null) first_err = err;
                },
            }
        }
        if (pending_unknown) |unknown| return try unknown.clone(self.allocator);
        if (first_err) |err| return err;
        return .{ .bool = true };
    }

    fn evalExistsMap2(
        self: *Evaluator,
        key_binding_id: checker.BindingRef,
        value_binding_id: checker.BindingRef,
        entries: []const value.MapEntry,
        expr_index: ast.Index,
    ) env.EvalError!value.Value {
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        var first_err: ?env.EvalError = null;
        for (entries) |entry| {
            var outcome = self.evalPredicateOutcome2(
                key_binding_id,
                try entry.key.clone(self.allocator),
                value_binding_id,
                try entry.value.clone(self.allocator),
                expr_index,
            );
            defer outcome.deinit(self.allocator);
            switch (outcome) {
                .bool => |pred| if (pred) return .{ .bool = true },
                .unknown => try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown),
                .err => |err| {
                    if (first_err == null) first_err = err;
                },
            }
        }
        if (pending_unknown) |unknown| return try unknown.clone(self.allocator);
        if (first_err) |err| return err;
        return .{ .bool = false };
    }

    fn evalExistsOneMap2(
        self: *Evaluator,
        key_binding_id: checker.BindingRef,
        value_binding_id: checker.BindingRef,
        entries: []const value.MapEntry,
        expr_index: ast.Index,
    ) env.EvalError!value.Value {
        var matches: usize = 0;
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        var first_err: ?env.EvalError = null;
        for (entries) |entry| {
            var outcome = self.evalPredicateOutcome2(
                key_binding_id,
                try entry.key.clone(self.allocator),
                value_binding_id,
                try entry.value.clone(self.allocator),
                expr_index,
            );
            defer outcome.deinit(self.allocator);
            switch (outcome) {
                .bool => |pred| {
                    if (pred) matches += 1;
                },
                .unknown => try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown),
                .err => |err| {
                    if (first_err == null) first_err = err;
                },
            }
        }
        if (pending_unknown) |unknown| return try unknown.clone(self.allocator);
        if (first_err) |err| return err;
        return .{ .bool = matches == 1 };
    }

    fn evalTransformMap2(
        self: *Evaluator,
        key_binding_id: checker.BindingRef,
        value_binding_id: checker.BindingRef,
        entries: []const value.MapEntry,
        maybe_predicate: ?ast.Index,
        transform_expr: ast.Index,
    ) env.EvalError!value.Value {
        var out: std.ArrayListUnmanaged(value.MapEntry) = .empty;
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        errdefer {
            for (out.items) |*item| {
                item.key.deinit(self.allocator);
                item.value.deinit(self.allocator);
            }
            out.deinit(self.allocator);
        }
        try out.ensureTotalCapacity(self.allocator, entries.len);
        for (entries) |entry| {
            if (maybe_predicate) |predicate_expr| {
                var outcome = self.evalPredicateOutcome2(
                    key_binding_id,
                    try entry.key.clone(self.allocator),
                    value_binding_id,
                    try entry.value.clone(self.allocator),
                    predicate_expr,
                );
                defer outcome.deinit(self.allocator);
                switch (outcome) {
                    .bool => |pred| if (!pred) continue,
                    .unknown => {
                        try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown);
                        continue;
                    },
                    .err => |err| return err,
                }
            }
            var transformed = try self.evalTransformMapValue(
                key_binding_id,
                value_binding_id,
                entry,
                transform_expr,
            );
            if (transformed.value == .unknown) {
                defer transformed.key.deinit(self.allocator);
                defer transformed.value.deinit(self.allocator);
                try mergePendingUnknown(self.allocator, &pending_unknown, transformed.value);
                continue;
            }
            out.appendAssumeCapacity(transformed);
        }
        if (pending_unknown) |unknown| {
            for (out.items) |*item| {
                item.key.deinit(self.allocator);
                item.value.deinit(self.allocator);
            }
            out.deinit(self.allocator);
            return try unknown.clone(self.allocator);
        }
        return .{ .map = out };
    }

    fn evalTransformListMap2(
        self: *Evaluator,
        key_binding_id: checker.BindingRef,
        value_binding_id: checker.BindingRef,
        entries: []const value.MapEntry,
        maybe_predicate: ?ast.Index,
        transform_expr: ast.Index,
    ) env.EvalError!value.Value {
        var out: std.ArrayListUnmanaged(value.Value) = .empty;
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        errdefer {
            for (out.items) |*item| item.deinit(self.allocator);
            out.deinit(self.allocator);
        }
        try out.ensureTotalCapacity(self.allocator, entries.len);
        for (entries) |entry| {
            if (maybe_predicate) |predicate_expr| {
                var outcome = self.evalPredicateOutcome2(
                    key_binding_id,
                    try entry.key.clone(self.allocator),
                    value_binding_id,
                    try entry.value.clone(self.allocator),
                    predicate_expr,
                );
                defer outcome.deinit(self.allocator);
                switch (outcome) {
                    .bool => |pred| if (!pred) continue,
                    .unknown => {
                        try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown);
                        continue;
                    },
                    .err => |err| return err,
                }
            }
            var transformed = try self.withBindings(
                key_binding_id,
                try entry.key.clone(self.allocator),
                value_binding_id,
                try entry.value.clone(self.allocator),
                transform_expr,
            );
            if (transformed == .unknown) {
                defer transformed.deinit(self.allocator);
                try mergePendingUnknown(self.allocator, &pending_unknown, transformed);
                continue;
            }
            try out.append(self.allocator, transformed);
        }
        if (pending_unknown) |unknown| {
            for (out.items) |*item| item.deinit(self.allocator);
            out.deinit(self.allocator);
            return try unknown.clone(self.allocator);
        }
        return .{ .list = out };
    }

    fn evalTransformMapValue(
        self: *Evaluator,
        key_binding_id: checker.BindingRef,
        value_binding_id: checker.BindingRef,
        entry: value.MapEntry,
        transform_expr: ast.Index,
    ) env.EvalError!value.MapEntry {
        const out_key = try entry.key.clone(self.allocator);
        errdefer {
            var key = out_key;
            key.deinit(self.allocator);
        }
        const out_value = try self.withBindings(
            key_binding_id,
            try entry.key.clone(self.allocator),
            value_binding_id,
            try entry.value.clone(self.allocator),
            transform_expr,
        );
        errdefer {
            var value_out = out_value;
            value_out.deinit(self.allocator);
        }
        return .{
            .key = out_key,
            .value = out_value,
        };
    }

    fn evalTransformMapEntryList2(
        self: *Evaluator,
        index_binding_id: checker.BindingRef,
        value_binding_id: checker.BindingRef,
        items: []const value.Value,
        maybe_predicate: ?ast.Index,
        transform_expr: ast.Index,
    ) env.EvalError!value.Value {
        var out: std.ArrayListUnmanaged(value.MapEntry) = .empty;
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        errdefer {
            for (out.items) |*item| {
                item.key.deinit(self.allocator);
                item.value.deinit(self.allocator);
            }
            out.deinit(self.allocator);
        }

        try out.ensureTotalCapacity(self.allocator, items.len);
        for (items, 0..) |item, i| {
            if (maybe_predicate) |predicate_expr| {
                var outcome = self.evalPredicateOutcome2(
                    index_binding_id,
                    .{ .int = @intCast(i) },
                    value_binding_id,
                    try item.clone(self.allocator),
                    predicate_expr,
                );
                defer outcome.deinit(self.allocator);
                switch (outcome) {
                    .bool => |pred| if (!pred) continue,
                    .unknown => {
                        try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown);
                        continue;
                    },
                    .err => |err| return err,
                }
            }

            var transformed = try self.withBindings(
                index_binding_id,
                .{ .int = @intCast(i) },
                value_binding_id,
                try item.clone(self.allocator),
                transform_expr,
            );
            defer transformed.deinit(self.allocator);
            if (transformed == .unknown) {
                try mergePendingUnknown(self.allocator, &pending_unknown, transformed);
                continue;
            }

            const entry = try cloneSingleMapEntry(self.allocator, transformed);
            errdefer {
                var owned = entry;
                owned.key.deinit(self.allocator);
                owned.value.deinit(self.allocator);
            }
            try appendUniqueMapEntry(self.allocator, &out, entry);
        }

        if (pending_unknown) |unknown| {
            for (out.items) |*item| {
                item.key.deinit(self.allocator);
                item.value.deinit(self.allocator);
            }
            out.deinit(self.allocator);
            return try unknown.clone(self.allocator);
        }
        return .{ .map = out };
    }

    fn evalTransformMapEntryMap2(
        self: *Evaluator,
        key_binding_id: checker.BindingRef,
        value_binding_id: checker.BindingRef,
        entries: []const value.MapEntry,
        maybe_predicate: ?ast.Index,
        transform_expr: ast.Index,
    ) env.EvalError!value.Value {
        var out: std.ArrayListUnmanaged(value.MapEntry) = .empty;
        var pending_unknown: ?value.Value = null;
        defer if (pending_unknown) |*unknown| unknown.deinit(self.allocator);
        errdefer {
            for (out.items) |*item| {
                item.key.deinit(self.allocator);
                item.value.deinit(self.allocator);
            }
            out.deinit(self.allocator);
        }

        try out.ensureTotalCapacity(self.allocator, entries.len);
        for (entries) |entry| {
            if (maybe_predicate) |predicate_expr| {
                var outcome = self.evalPredicateOutcome2(
                    key_binding_id,
                    try entry.key.clone(self.allocator),
                    value_binding_id,
                    try entry.value.clone(self.allocator),
                    predicate_expr,
                );
                defer outcome.deinit(self.allocator);
                switch (outcome) {
                    .bool => |pred| if (!pred) continue,
                    .unknown => {
                        try mergePendingUnknown(self.allocator, &pending_unknown, outcome.unknown);
                        continue;
                    },
                    .err => |err| return err,
                }
            }

            var transformed = try self.withBindings(
                key_binding_id,
                try entry.key.clone(self.allocator),
                value_binding_id,
                try entry.value.clone(self.allocator),
                transform_expr,
            );
            defer transformed.deinit(self.allocator);
            if (transformed == .unknown) {
                try mergePendingUnknown(self.allocator, &pending_unknown, transformed);
                continue;
            }

            const transformed_entry = try cloneSingleMapEntry(self.allocator, transformed);
            errdefer {
                var owned = transformed_entry;
                owned.key.deinit(self.allocator);
                owned.value.deinit(self.allocator);
            }
            try appendUniqueMapEntry(self.allocator, &out, transformed_entry);
        }

        if (pending_unknown) |unknown| {
            for (out.items) |*item| {
                item.key.deinit(self.allocator);
                item.value.deinit(self.allocator);
            }
            out.deinit(self.allocator);
            return try unknown.clone(self.allocator);
        }
        return .{ .map = out };
    }

    fn evalMessage(self: *Evaluator, msg: ast.MessageInit) env.EvalError!value.Value {
        var joined_storage: std.ArrayListUnmanaged(u8) = .empty;
        defer joined_storage.deinit(self.allocator);
        var joined_small: [256]u8 = undefined;
        const joined = try self.joinNameRefInto(msg.name, &joined_storage, joined_small[0..]);
        const desc = try self.program.env.lookupMessageScoped(self.allocator, joined, msg.name.absolute) orelse return value.RuntimeError.NoSuchField;
        var inits: std.ArrayListUnmanaged(protobuf.MessageFieldInit) = .empty;
        var unknowns: partial.UnknownSet = .{};
        var saw_unknown = false;
        errdefer {
            for (inits.items) |*init| init.value.deinit(self.allocator);
            inits.deinit(self.allocator);
            unknowns.deinit(self.allocator);
        }
        try inits.ensureTotalCapacity(self.allocator, msg.fields.len);
        for (0..msg.fields.len) |i| {
            const init_field = self.program.ast.field_inits.items[msg.fields.start + i];
            const field_name = self.program.ast.strings.get(init_field.name);
            const field = desc.lookupField(field_name) orelse return value.RuntimeError.NoSuchField;
            for (inits.items) |existing| {
                if (std.mem.eql(u8, existing.field.name, field_name)) return value.RuntimeError.DuplicateMessageField;
            }
            var raw = if (init_field.optional) blk: {
                var opt = try self.evalNode(init_field.value);
                defer opt.deinit(self.allocator);
                if (opt == .unknown) {
                    try unknowns.merge(self.allocator, &opt.unknown);
                    saw_unknown = true;
                    continue;
                }
                switch (opt) {
                    .optional => |optional| {
                        if (optional.value == null) continue;
                        break :blk try optional.value.?.*.clone(self.allocator);
                    },
                    else => return value.RuntimeError.TypeMismatch,
                }
            } else try self.evalNode(init_field.value);
            var raw_owned = true;
            errdefer if (raw_owned) raw.deinit(self.allocator);
            if (raw == .unknown) {
                defer raw.deinit(self.allocator);
                try unknowns.merge(self.allocator, &raw.unknown);
                saw_unknown = true;
                continue;
            }
            const coerced = try protobuf.coerceFieldValue(self.allocator, self.program.env, field, raw);
            raw.deinit(self.allocator);
            raw_owned = false;
            const out_value = coerced orelse continue;
            inits.appendAssumeCapacity(.{
                .field = field,
                .value = out_value,
            });
        }
        const out = try protobuf.buildMessageLiteral(self.allocator, self.program.env, desc, inits.items);
        for (inits.items) |*init| init.value.deinit(self.allocator);
        inits.deinit(self.allocator);
        if (saw_unknown) {
            var temp = out;
            temp.deinit(self.allocator);
            return value.unknownFromSet(unknowns);
        }
        unknowns.deinit(self.allocator);
        return out;
    }

    const ResolvedAccessTarget = struct {
        optional_chain: bool,
        present: bool,
        unknown: ?value.Value = null,
        value: ?value.Value = null,

        fn deinit(self: *ResolvedAccessTarget, allocator: std.mem.Allocator) void {
            if (self.unknown) |*unknown| {
                unknown.deinit(allocator);
                self.unknown = null;
            }
            if (self.value) |*val| {
                val.deinit(allocator);
                self.value = null;
            }
        }
    };

    fn resolveAccessTarget(self: *Evaluator, index: ast.Index) env.EvalError!ResolvedAccessTarget {
        var evaluated = try self.evalNode(index);
        if (evaluated == .unknown) {
            return .{
                .optional_chain = false,
                .present = false,
                .unknown = evaluated,
            };
        }
        if (evaluated == .optional) {
            defer evaluated.deinit(self.allocator);
            const inner = evaluated.optional.value orelse return .{
                .optional_chain = true,
                .present = false,
            };
            return .{
                .optional_chain = true,
                .present = true,
                .value = try inner.*.clone(self.allocator),
            };
        }
        return .{
            .optional_chain = false,
            .present = true,
            .value = evaluated,
        };
    }

    const SelectLookupMode = enum {
        normal,
        optional,
        presence,
    };

    fn lookupSelectValue(
        self: *Evaluator,
        target: value.Value,
        field_name: []const u8,
        mode: SelectLookupMode,
    ) env.EvalError!?value.Value {
        return switch (target) {
            .map => |entries| blk: {
                for (entries.items) |entry| {
                    switch (entry.key) {
                        .string => |s| if (std.mem.eql(u8, s, field_name)) break :blk try entry.value.clone(self.allocator),
                        else => {},
                    }
                }
                break :blk null;
            },
            .message => |msg| blk: {
                const desc = self.program.env.lookupMessage(msg.name) orelse return value.RuntimeError.NoSuchField;
                const field = desc.lookupField(field_name) orelse return value.RuntimeError.NoSuchField;
                for (msg.fields.items) |entry| {
                    if (std.mem.eql(u8, entry.name, field_name)) {
                        switch (mode) {
                            .normal => break :blk try entry.value.clone(self.allocator),
                            .optional => {
                                if (!fieldHasLogicalPresence(field, entry.value)) break :blk null;
                                break :blk try entry.value.clone(self.allocator);
                            },
                            .presence => {
                                if (!fieldHasLogicalPresence(field, entry.value)) break :blk null;
                                break :blk .null;
                            },
                        }
                    }
                }
                switch (mode) {
                    .presence => break :blk null,
                    .optional => break :blk null,
                    .normal => break :blk try protobuf.defaultFieldValue(self.allocator, self.program.env, field),
                }
            },
            .host => |host| {
                if (host.vtable.getField) |getter| {
                    const result = getter(self.allocator, host.ptr, field_name) catch return value.RuntimeError.NoSuchField;
                    if (result) |val| return val;
                    return switch (mode) {
                        .presence => null,
                        .optional => null,
                        .normal => value.RuntimeError.NoSuchField,
                    };
                }
                return value.RuntimeError.NoSuchField;
            },
            else => value.RuntimeError.NoSuchField,
        };
    }

    fn lookupIndexValue(
        self: *Evaluator,
        target: value.Value,
        idx: value.Value,
        presence_sensitive: bool,
    ) env.EvalError!?value.Value {
        return switch (target) {
            .list => |items| switch (idx) {
                .int => |i| {
                    if (i < 0 or @as(usize, @intCast(i)) >= items.items.len) {
                        return if (presence_sensitive) null else value.RuntimeError.InvalidIndex;
                    }
                    return try items.items[@intCast(i)].clone(self.allocator);
                },
                .uint => |u| {
                    if (u >= items.items.len) return if (presence_sensitive) null else value.RuntimeError.InvalidIndex;
                    return try items.items[@intCast(u)].clone(self.allocator);
                },
                .double => |d| {
                    if (!std.math.isFinite(d) or @trunc(d) != d) return value.RuntimeError.InvalidIndex;
                    if (d < 0 or d >= @as(f64, @floatFromInt(items.items.len))) {
                        return if (presence_sensitive) null else value.RuntimeError.InvalidIndex;
                    }
                    const i: usize = @as(usize, @intFromFloat(d));
                    return try items.items[i].clone(self.allocator);
                },
                else => value.RuntimeError.InvalidIndex,
            },
            .map => |entries| blk: {
                if (!isValidMapLookupValue(idx)) return value.RuntimeError.TypeMismatch;
                for (entries.items) |entry| {
                    if (try equalValues(entry.key, idx)) break :blk try entry.value.clone(self.allocator);
                }
                if (presence_sensitive) break :blk null;
                return value.RuntimeError.NoSuchField;
            },
            else => value.RuntimeError.InvalidIndex,
        };
    }

    fn evalPresenceValue(self: *Evaluator, index: ast.Index) env.EvalError!value.Value {
        return switch (self.program.ast.node(index).data) {
            .select => |select| blk: {
                if (try self.maybeUnknownForAttribute(index)) |unknown| break :blk unknown;
                var resolved_target = try self.resolveAccessTarget(select.target);
                defer resolved_target.deinit(self.allocator);
                if (resolved_target.unknown) |unknown| break :blk unknown;
                if (!resolved_target.present) break :blk .{ .bool = false };
                var maybe = try self.lookupSelectValue(
                    resolved_target.value.?,
                    self.program.ast.strings.get(select.field),
                    .presence,
                );
                defer if (maybe) |*found| found.deinit(self.allocator);
                break :blk .{ .bool = maybe != null };
            },
            .index => |access| blk: {
                if (try self.maybeUnknownForAttribute(index)) |unknown| break :blk unknown;
                var resolved_target = try self.resolveAccessTarget(access.target);
                defer resolved_target.deinit(self.allocator);
                if (resolved_target.unknown) |unknown| break :blk unknown;
                if (!resolved_target.present) break :blk .{ .bool = false };
                var idx = try self.evalNode(access.index);
                if (idx == .unknown) break :blk idx;
                defer idx.deinit(self.allocator);
                var maybe = try self.lookupIndexValue(resolved_target.value.?, idx, true);
                defer if (maybe) |*found| found.deinit(self.allocator);
                break :blk .{ .bool = maybe != null };
            },
            else => blk: {
                var evaluated = try self.evalNode(index);
                if (evaluated == .unknown) break :blk evaluated;
                defer evaluated.deinit(self.allocator);
                break :blk switch (evaluated) {
                    .optional => |optional| .{ .bool = optional.value != null },
                    else => .{ .bool = true },
                };
            },
        };
    }

    fn evalSyntheticBinding(self: *Evaluator, binding_ref: checker.BindingRef) env.EvalError!value.Value {
        var i = self.local_bindings.items.len;
        while (i > 0) {
            i -= 1;
            const binding = self.local_bindings.items[i];
            if (checker.bindingRefEql(binding.name, binding_ref)) {
                return binding.val.clone(self.allocator);
            }
        }
        return value.RuntimeError.NoMatchingOverload;
    }

    fn parseU32LiteralArg(self: *Evaluator, index: ast.Index) ?u32 {
        return switch (self.program.ast.node(index).data) {
            .literal_int => |v| blk: {
                if (v < 0 or v > std.math.maxInt(u32)) break :blk null;
                break :blk @intCast(v);
            },
            else => null,
        };
    }

    fn extractBindingRef(self: *Evaluator, index: ast.Index) ?checker.BindingRef {
        if (self.extractSimpleIdent(index)) |id| return .{ .ident = id };
        return self.extractIterVarBinding(index);
    }

    fn extractIterVarBinding(self: *Evaluator, index: ast.Index) ?checker.BindingRef {
        return switch (self.program.ast.node(index).data) {
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
                const target_id = self.extractSimpleIdent(call.target) orelse break :blk null;
                if (!std.mem.eql(u8, self.program.ast.strings.get(target_id), "cel")) break :blk null;
                if (!std.mem.eql(u8, self.program.ast.strings.get(call.name), "iterVar")) break :blk null;
                break :blk self.extractIterVarBindingFromArgs(call.args);
            },
            else => null,
        };
    }

    fn extractIterVarBindingFromCall(self: *Evaluator, call: ast.Call) ?checker.BindingRef {
        return self.extractIterVarBindingFromArgs(call.args);
    }

    fn extractIterVarBindingFromArgs(self: *Evaluator, args: ast.Range) ?checker.BindingRef {
        if (args.len != 2) return null;
        const depth = self.parseU32LiteralArg(self.program.ast.expr_ranges.items[args.start]) orelse return null;
        const slot = self.parseU32LiteralArg(self.program.ast.expr_ranges.items[args.start + 1]) orelse return null;
        return .{ .iter_var = .{
            .depth = depth,
            .slot = slot,
        } };
    }

    fn extractSimpleIdent(self: *Evaluator, index: ast.Index) ?strings.StringTable.Id {
        return switch (self.program.ast.node(index).data) {
            .ident => |name_ref| blk: {
                if (name_ref.absolute or name_ref.segments.len != 1) break :blk null;
                break :blk self.program.ast.name_segments.items[name_ref.segments.start];
            },
            else => null,
        };
    }

    const QualifiedName = struct {
        absolute: bool,
        text: []u8,
    };

    fn lookupQualifiedValue(self: *Evaluator, node: ast.Data) env.EvalError!?value.Value {
        const qualified = switch (node) {
            .select => |select| try self.joinQualifiedSelect(select),
            else => null,
        } orelse return null;
        defer self.allocator.free(qualified.text);
        if (try self.lookupActivationScoped(qualified.text, qualified.absolute)) |resolved| {
            return try resolved.clone(self.allocator);
        }
        if (try self.program.env.lookupConstScoped(self.allocator, qualified.text, qualified.absolute)) |constant| {
            return try constant.value.clone(self.allocator);
        }
        if (types.isBuiltinTypeDenotation(qualified.text) or (try self.program.env.lookupMessageScoped(self.allocator, qualified.text, qualified.absolute)) != null) {
            return try value.typeNameValue(self.allocator, qualified.text);
        }
        return null;
    }

    fn joinQualifiedSelect(self: *Evaluator, select: ast.Select) env.EvalError!?QualifiedName {
        if (select.optional) return null;
        var qualified = try self.joinQualifiedExpr(select.target) orelse return null;
        errdefer self.allocator.free(qualified.text);
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        defer buffer.deinit(self.allocator);
        try buffer.appendSlice(self.allocator, qualified.text);
        try buffer.append(self.allocator, '.');
        try buffer.appendSlice(self.allocator, self.program.ast.strings.get(select.field));
        self.allocator.free(qualified.text);
        qualified.text = try buffer.toOwnedSlice(self.allocator);
        return qualified;
    }

    fn joinQualifiedExpr(self: *Evaluator, index: ast.Index) env.EvalError!?QualifiedName {
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buffer.deinit(self.allocator);
        var absolute = false;
        if (!try self.appendQualifiedExpr(index, &buffer, &absolute)) return null;
        return .{
            .absolute = absolute,
            .text = try buffer.toOwnedSlice(self.allocator),
        };
    }

    fn appendQualifiedExpr(
        self: *Evaluator,
        index: ast.Index,
        buffer: *std.ArrayListUnmanaged(u8),
        absolute: *bool,
    ) env.EvalError!bool {
        switch (self.program.ast.node(index).data) {
            .ident => |name_ref| {
                absolute.* = name_ref.absolute;
                for (0..name_ref.segments.len) |i| {
                    if (buffer.items.len > 0) try buffer.append(self.allocator, '.');
                    const id = self.program.ast.name_segments.items[name_ref.segments.start + i];
                    try buffer.appendSlice(self.allocator, self.program.ast.strings.get(id));
                }
                return true;
            },
            .select => |select| {
                if (select.optional) return false;
                if (!try self.appendQualifiedExpr(select.target, buffer, absolute)) return false;
                try buffer.append(self.allocator, '.');
                try buffer.appendSlice(self.allocator, self.program.ast.strings.get(select.field));
                return true;
            },
            else => return false,
        }
    }

    fn joinNameRef(self: *Evaluator, name_ref: ast.NameRef) env.EvalError![]u8 {
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        defer buffer.deinit(self.allocator);
        const joined = try self.joinNameRefInto(name_ref, &buffer, &.{});
        return try self.allocator.dupe(u8, joined);
    }

    fn joinNameRefInto(
        self: *Evaluator,
        name_ref: ast.NameRef,
        dynamic: *std.ArrayListUnmanaged(u8),
        fixed: []u8,
    ) env.EvalError![]const u8 {
        const needed = joinedNameRefLen(&self.program.ast, name_ref);
        const out = if (needed <= fixed.len)
            fixed[0..needed]
        else blk: {
            try dynamic.resize(self.allocator, needed);
            break :blk dynamic.items[0..needed];
        };
        writeJoinedNameRef(&self.program.ast, name_ref, out);
        return out;
    }

    fn qualifiedExprShadowedByLocal(self: *Evaluator, index: ast.Index) bool {
        return switch (self.program.ast.node(index).data) {
            .ident => |name_ref| blk: {
                if (name_ref.absolute or name_ref.segments.len != 1) break :blk false;
                break :blk self.isLocalBinding(self.program.ast.name_segments.items[name_ref.segments.start]);
            },
            .select => |select| self.qualifiedExprShadowedByLocal(select.target),
            else => false,
        };
    }

    fn isLocalBinding(self: *Evaluator, id: strings.StringTable.Id) bool {
        var i = self.local_bindings.items.len;
        while (i > 0) {
            i -= 1;
            if (bindingMatchesIdent(self.local_bindings.items[i].name, id)) return true;
        }
        return false;
    }

    fn lookupActivationScoped(self: *Evaluator, name: []const u8, absolute: bool) env.EvalError!?value.Value {
        if (!absolute and self.program.env.container != null and self.program.env.container.?.len != 0) {
            var candidate_storage: std.ArrayListUnmanaged(u8) = .empty;
            defer candidate_storage.deinit(self.allocator);
            var small_buffer: [256]u8 = undefined;
            var prefix_len = self.program.env.container.?.len;
            while (true) {
                const candidate = try buildScopedName(
                    self.allocator,
                    &candidate_storage,
                    small_buffer[0..],
                    self.program.env.container.?[0..prefix_len],
                    name,
                );
                if (self.activation.get(candidate)) |resolved| return resolved;
                prefix_len = std.mem.lastIndexOfScalar(u8, self.program.env.container.?[0..prefix_len], '.') orelse break;
            }
        }
        return self.activation.get(name);
    }

    fn maybeUnknownForAttribute(self: *Evaluator, index: ast.Index) env.EvalError!?value.Value {
        if (self.activation.unknown_patterns.items.len == 0) return null;

        var capture = try self.captureAttribute(index);
        defer capture.deinit(self.allocator);

        switch (capture) {
            .not_attribute => return null,
            .unknown => |unknown| return try unknown.clone(self.allocator),
            .attribute => |*attribute| {
                var unknowns: partial.UnknownSet = .{};
                errdefer unknowns.deinit(self.allocator);
                var matched = false;

                if (try self.collectUnknownMatches(&unknowns, attribute, attribute.root_name)) matched = true;
                if (!attribute.absolute and self.program.env.container != null and self.program.env.container.?.len != 0) {
                    var candidate_storage: std.ArrayListUnmanaged(u8) = .empty;
                    defer candidate_storage.deinit(self.allocator);
                    var small_buffer: [256]u8 = undefined;
                    var prefix_len = self.program.env.container.?.len;
                    while (true) {
                        const candidate = try buildScopedName(
                            self.allocator,
                            &candidate_storage,
                            small_buffer[0..],
                            self.program.env.container.?[0..prefix_len],
                            attribute.root_name,
                        );
                        if (try self.collectUnknownMatches(&unknowns, attribute, candidate)) matched = true;
                        prefix_len = std.mem.lastIndexOfScalar(u8, self.program.env.container.?[0..prefix_len], '.') orelse break;
                    }
                }

                if (!matched) {
                    unknowns.deinit(self.allocator);
                    return null;
                }
                return value.unknownFromSet(unknowns);
            },
        }
    }

    fn collectUnknownMatches(
        self: *Evaluator,
        unknowns: *partial.UnknownSet,
        attribute: *const CapturedAttribute,
        candidate: []const u8,
    ) env.EvalError!bool {
        if (self.activation.get(candidate) == null and self.program.env.lookupVar(candidate) == null) {
            return false;
        }

        var matched = false;
        for (self.activation.unknown_patterns.items) |pattern| {
            if (!std.mem.eql(u8, pattern.variable, candidate)) continue;
            const shared = sharedQualifierCount(attribute.qualifiers.items, pattern.qualifiers.items) orelse continue;

            var trail = try partial.AttributeTrail.init(self.allocator, candidate);
            errdefer trail.deinit(self.allocator);
            for (0..shared) |i| {
                try trail.append(self.allocator, attribute.qualifiers.items[i]);
            }

            const expr_id = if (shared == 0)
                attribute.root_expr_id
            else
                attribute.qualifier_expr_ids.items[shared - 1];
            try unknowns.add(self.allocator, expr_id, trail);
            matched = true;
        }
        return matched;
    }

    fn captureAttribute(self: *Evaluator, index: ast.Index) env.EvalError!CapturedAttributeResult {
        return switch (self.program.ast.node(index).data) {
            .ident => |name_ref| blk: {
                if (!name_ref.absolute and name_ref.segments.len == 1) {
                    const id = self.program.ast.name_segments.items[name_ref.segments.start];
                    if (self.isLocalBinding(id)) break :blk .not_attribute;
                }
                break :blk .{ .attribute = .{
                    .absolute = name_ref.absolute,
                    .root_name = try self.joinNameRef(name_ref),
                    .root_expr_id = @intFromEnum(index),
                } };
            },
            .select => |select| blk: {
                var target = try self.captureAttribute(select.target);
                switch (target) {
                    .attribute => |*attribute| {
                        try attribute.qualifiers.append(self.allocator, .{
                            .string = try self.allocator.dupe(u8, self.program.ast.strings.get(select.field)),
                        });
                        try attribute.qualifier_expr_ids.append(self.allocator, @intFromEnum(index));
                    },
                    else => {},
                }
                break :blk target;
            },
            .index => |access| blk: {
                var target = try self.captureAttribute(access.target);
                switch (target) {
                    .attribute => |*attribute| {
                        var idx = try self.evalNode(access.index);
                        defer idx.deinit(self.allocator);
                        if (idx == .unknown) {
                            break :blk .{ .unknown = try idx.clone(self.allocator) };
                        }
                        const qualifier = qualifierFromValue(self.allocator, idx) orelse break :blk .not_attribute;
                        try attribute.qualifiers.append(self.allocator, qualifier);
                        try attribute.qualifier_expr_ids.append(self.allocator, @intFromEnum(index));
                    },
                    else => {},
                }
                break :blk target;
            },
            else => .not_attribute,
        };
    }

    fn evalLogicOutcome(self: *Evaluator, index: ast.Index) LogicOutcome {
        var result = self.evalNode(index) catch |err| return .{ .err = err };
        switch (result) {
            .bool => |boolean| {
                result.deinit(self.allocator);
                return .{ .bool = boolean };
            },
            .unknown => return .{ .unknown = result },
            else => {
                result.deinit(self.allocator);
                return .{ .err = value.RuntimeError.TypeMismatch };
            },
        }
    }

    fn combineLogicalAnd(self: *Evaluator, lhs: LogicOutcome, rhs: LogicOutcome) env.EvalError!value.Value {
        if ((lhs == .bool and !lhs.bool) or (rhs == .bool and !rhs.bool)) return .{ .bool = false };
        if (lhs == .unknown or rhs == .unknown) return mergeUnknownOutcomes(self.allocator, &.{ lhs, rhs });
        if (lhs == .bool and rhs == .bool) return .{ .bool = true };
        if (lhs == .err) return lhs.err;
        return rhs.err;
    }

    fn combineLogicalOr(self: *Evaluator, lhs: LogicOutcome, rhs: LogicOutcome) env.EvalError!value.Value {
        if ((lhs == .bool and lhs.bool) or (rhs == .bool and rhs.bool)) return .{ .bool = true };
        if (lhs == .unknown or rhs == .unknown) return mergeUnknownOutcomes(self.allocator, &.{ lhs, rhs });
        if (lhs == .bool and rhs == .bool) return .{ .bool = false };
        if (lhs == .err) return lhs.err;
        return rhs.err;
    }
};

fn bindingMatchesIdent(binding: checker.BindingRef, id: strings.StringTable.Id) bool {
    return switch (binding) {
        .ident => |binding_id| binding_id == id,
        else => false,
    };
}

fn sharedQualifierCount(actual: []const partial.Qualifier, pattern: []const partial.Qualifier) ?usize {
    const shared = @min(actual.len, pattern.len);
    for (0..shared) |i| {
        if (!actual[i].matchesPattern(pattern[i])) return null;
    }
    return shared;
}

fn fieldHasLogicalPresence(field: *const @import("../env/schema.zig").FieldDecl, candidate: value.Value) bool {
    return switch (field.encoding) {
        .repeated => switch (candidate) {
            .list => |items| items.items.len != 0,
            else => true,
        },
        .map => switch (candidate) {
            .map => |entries| entries.items.len != 0,
            else => true,
        },
        .singular => |raw| switch (raw) {
            .message => true,
            .scalar => |scalar| if (field.presence == .explicit) true else !fieldScalarEqualsDefault(field, scalar, candidate),
        },
    };
}

fn fieldScalarEqualsDefault(
    field: *const @import("../env/schema.zig").FieldDecl,
    scalar: @import("../env/schema.zig").ProtoScalarKind,
    candidate: value.Value,
) bool {
    if (field.default_value) |default_value| {
        return switch (default_value) {
            .bool => |v| candidate == .bool and candidate.bool == v,
            .int => |v| switch (candidate) {
                .int => candidate.int == v,
                .enum_value => |enum_value| enum_value.value == v,
                else => false,
            },
            .uint => |v| candidate == .uint and candidate.uint == v,
            .double => |v| candidate == .double and candidate.double == v,
            .string => |text| candidate == .string and std.mem.eql(u8, candidate.string, text),
            .bytes => |data| candidate == .bytes and std.mem.eql(u8, candidate.bytes, data),
        };
    }

    return switch (scalar) {
        .bool => candidate == .bool and !candidate.bool,
        .int32, .int64, .sint32, .sint64, .sfixed32, .sfixed64 => candidate == .int and candidate.int == 0,
        .enum_value => switch (candidate) {
            .int => candidate.int == 0,
            .enum_value => |enum_value| enum_value.value == 0,
            else => false,
        },
        .uint32, .uint64, .fixed32, .fixed64 => candidate == .uint and candidate.uint == 0,
        .float, .double => candidate == .double and candidate.double == 0,
        .string => candidate == .string and candidate.string.len == 0,
        .bytes => candidate == .bytes and candidate.bytes.len == 0,
    };
}

fn qualifierFromValue(allocator: std.mem.Allocator, v: value.Value) ?partial.Qualifier {
    return switch (v) {
        .string => .{ .string = allocator.dupe(u8, v.string) catch return null },
        .int => .{ .int = v.int },
        .uint => .{ .uint = v.uint },
        .double => if (std.math.isFinite(v.double) and @trunc(v.double) == v.double) .{ .double = v.double } else null,
        .bool => .{ .bool = v.bool },
        else => null,
    };
}

fn argsContainUnknown(args: []const value.Value) bool {
    for (args) |arg| {
        if (arg == .unknown) return true;
    }
    return false;
}

fn mergeUnknownValues(allocator: std.mem.Allocator, vals: []const value.Value) std.mem.Allocator.Error!value.Value {
    var unknowns: partial.UnknownSet = .{};
    errdefer unknowns.deinit(allocator);
    for (vals) |val| {
        if (val == .unknown) try unknowns.merge(allocator, &val.unknown);
    }
    return value.unknownFromSet(unknowns);
}

fn mergeUnknownOutcomes(allocator: std.mem.Allocator, outcomes: []const Evaluator.LogicOutcome) std.mem.Allocator.Error!value.Value {
    var unknowns: partial.UnknownSet = .{};
    errdefer unknowns.deinit(allocator);
    for (outcomes) |outcome| {
        if (outcome == .unknown) try unknowns.merge(allocator, &outcome.unknown.unknown);
    }
    return value.unknownFromSet(unknowns);
}

fn mergePendingUnknown(
    allocator: std.mem.Allocator,
    pending: *?value.Value,
    next: value.Value,
) std.mem.Allocator.Error!void {
    if (next != .unknown) return;
    if (pending.*) |*existing| {
        try existing.unknown.merge(allocator, &next.unknown);
        return;
    }
    pending.* = try next.clone(allocator);
}

fn buildScopedName(
    allocator: std.mem.Allocator,
    dynamic: *std.ArrayListUnmanaged(u8),
    fixed: []u8,
    prefix: []const u8,
    name: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const needed = prefix.len + 1 + name.len;
    if (needed <= fixed.len) {
        @memcpy(fixed[0..prefix.len], prefix);
        fixed[prefix.len] = '.';
        @memcpy(fixed[prefix.len + 1 .. needed], name);
        return fixed[0..needed];
    }

    try dynamic.resize(allocator, needed);
    @memcpy(dynamic.items[0..prefix.len], prefix);
    dynamic.items[prefix.len] = '.';
    @memcpy(dynamic.items[prefix.len + 1 .. needed], name);
    return dynamic.items[0..needed];
}

fn joinedNameRefLen(tree: *const ast.Ast, name_ref: ast.NameRef) usize {
    var total: usize = 0;
    for (0..name_ref.segments.len) |i| {
        if (i > 0) total += 1;
        const id = tree.name_segments.items[name_ref.segments.start + i];
        total += tree.strings.get(id).len;
    }
    return total;
}

fn writeJoinedNameRef(tree: *const ast.Ast, name_ref: ast.NameRef, out: []u8) void {
    var cursor: usize = 0;
    for (0..name_ref.segments.len) |i| {
        if (i > 0) {
            out[cursor] = '.';
            cursor += 1;
        }
        const id = tree.name_segments.items[name_ref.segments.start + i];
        const segment = tree.strings.get(id);
        @memcpy(out[cursor .. cursor + segment.len], segment);
        cursor += segment.len;
    }
    std.debug.assert(cursor == out.len);
}

const CompareOp = enum { lt, lte, gt, gte };

fn compareValues(lhs: value.Value, rhs: value.Value, op: CompareOp) value.RuntimeError!bool {
    if (isNumericValue(lhs) and isNumericValue(rhs)) {
        return compareNumericValues(lhs, rhs, op);
    }
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return value.RuntimeError.TypeMismatch;
    return switch (lhs) {
        .int => compareOrd(i64, lhs.int, rhs.int, op),
        .uint => compareOrd(u64, lhs.uint, rhs.uint, op),
        .double => compareOrd(f64, lhs.double, rhs.double, op),
        .bool => compareOrd(bool, lhs.bool, rhs.bool, op),
        .string => compareSlice(lhs.string, rhs.string, op),
        .bytes => compareSlice(lhs.bytes, rhs.bytes, op),
        .timestamp => compareTimestamp(lhs.timestamp, rhs.timestamp, op),
        .duration => compareDuration(lhs.duration, rhs.duration, op),
        .unknown => value.RuntimeError.TypeMismatch,
        else => value.RuntimeError.TypeMismatch,
    };
}

fn compareOrd(comptime T: type, lhs: T, rhs: T, op: CompareOp) bool {
    if (comptime T == bool) {
        const lhs_num: u1 = @intFromBool(lhs);
        const rhs_num: u1 = @intFromBool(rhs);
        return switch (op) {
            .lt => lhs_num < rhs_num,
            .lte => lhs_num <= rhs_num,
            .gt => lhs_num > rhs_num,
            .gte => lhs_num >= rhs_num,
        };
    }
    return switch (op) {
        .lt => lhs < rhs,
        .lte => lhs <= rhs,
        .gt => lhs > rhs,
        .gte => lhs >= rhs,
    };
}

fn compareSlice(lhs: []const u8, rhs: []const u8, op: CompareOp) bool {
    const cmp = std.mem.order(u8, lhs, rhs);
    return switch (op) {
        .lt => cmp == .lt,
        .lte => cmp != .gt,
        .gt => cmp == .gt,
        .gte => cmp != .lt,
    };
}

fn cloneSingleMapEntry(allocator: std.mem.Allocator, transformed: value.Value) env.EvalError!value.MapEntry {
    if (transformed != .map or transformed.map.items.len != 1) return value.RuntimeError.TypeMismatch;
    const entry = transformed.map.items[0];
    return .{
        .key = try entry.key.clone(allocator),
        .value = try entry.value.clone(allocator),
    };
}

fn appendUniqueMapEntry(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(value.MapEntry),
    entry: value.MapEntry,
) env.EvalError!void {
    for (out.items) |existing| {
        if (try equalValues(existing.key, entry.key)) return value.RuntimeError.DuplicateMapKey;
    }
    try out.append(allocator, entry);
}

fn validateSortablePairs(pairs: anytype) env.EvalError!void {
    if (pairs.len == 0) return;
    const first_tag = std.meta.activeTag(pairs[0].key);
    if (!sortableTagSupported(pairs[0].key)) return value.RuntimeError.TypeMismatch;
    if (pairs[0].key == .double and std.math.isNan(pairs[0].key.double)) return value.RuntimeError.TypeMismatch;
    for (pairs[1..]) |pair| {
        if (std.meta.activeTag(pair.key) != first_tag) return value.RuntimeError.TypeMismatch;
        if (!sortableTagSupported(pair.key)) return value.RuntimeError.TypeMismatch;
        if (pair.key == .double and std.math.isNan(pair.key.double)) return value.RuntimeError.TypeMismatch;
    }
}

fn sortableTagSupported(v: value.Value) bool {
    return switch (v) {
        .int, .uint, .double, .bool, .string, .bytes, .timestamp, .duration => true,
        else => false,
    };
}

fn sortableValueLessThan(lhs: value.Value, rhs: value.Value) bool {
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

fn equalValues(lhs: value.Value, rhs: value.Value) value.RuntimeError!bool {
    if (isNumericValue(lhs) and isNumericValue(rhs)) {
        return equalNumericValues(lhs, rhs);
    }
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .int => lhs.int == rhs.int,
        .uint => lhs.uint == rhs.uint,
        .double => !std.math.isNan(lhs.double) and !std.math.isNan(rhs.double) and lhs.double == rhs.double,
        .bool => lhs.bool == rhs.bool,
        .string => std.mem.eql(u8, lhs.string, rhs.string),
        .bytes => std.mem.eql(u8, lhs.bytes, rhs.bytes),
        .timestamp => lhs.timestamp.seconds == rhs.timestamp.seconds and lhs.timestamp.nanos == rhs.timestamp.nanos,
        .duration => lhs.duration.seconds == rhs.duration.seconds and lhs.duration.nanos == rhs.duration.nanos,
        .enum_value => lhs.enum_value.value == rhs.enum_value.value and
            std.mem.eql(u8, lhs.enum_value.type_name, rhs.enum_value.type_name),
        .host => |host| host.vtable == rhs.host.vtable and host.vtable.eql(host.ptr, rhs.host.ptr),
        .null => true,
        .unknown => lhs.unknown.eql(&rhs.unknown),
        .optional => |opt| blk: {
            if (opt.value == null) break :blk rhs.optional.value == null;
            if (rhs.optional.value == null) break :blk false;
            break :blk try equalValues(opt.value.?.*, rhs.optional.value.?.*);
        },
        .type_name => std.mem.eql(u8, lhs.type_name, rhs.type_name),
        .list => |items| blk: {
            if (items.items.len != rhs.list.items.len) break :blk false;
            for (items.items, rhs.list.items) |left_item, right_item| {
                if (!(try equalValues(left_item, right_item))) break :blk false;
            }
            break :blk true;
        },
        .map => |entries| blk: {
            if (entries.items.len != rhs.map.items.len) break :blk false;
            for (entries.items) |left_entry| {
                var found = false;
                for (rhs.map.items) |right_entry| {
                    if (!(try equalValues(left_entry.key, right_entry.key))) continue;
                    if (!(try equalValues(left_entry.value, right_entry.value))) break :blk false;
                    found = true;
                    break;
                }
                if (!found) break :blk false;
            }
            break :blk true;
        },
        .message => |msg| blk: {
            if (!std.mem.eql(u8, msg.name, rhs.message.name)) break :blk false;
            if (msg.fields.items.len != rhs.message.fields.items.len) break :blk false;
            for (msg.fields.items) |left_field| {
                var found = false;
                for (rhs.message.fields.items) |right_field| {
                    if (!std.mem.eql(u8, left_field.name, right_field.name)) continue;
                    if (!(try equalValues(left_field.value, right_field.value))) break :blk false;
                    found = true;
                    break;
                }
                if (!found) break :blk false;
            }
            break :blk true;
        },
    };
}

fn isNumericValue(v: value.Value) bool {
    return switch (v) {
        .int, .uint, .double => true,
        else => false,
    };
}

fn isValidMapKeyValue(v: value.Value) bool {
    return switch (v) {
        .int, .uint, .bool, .string => true,
        else => false,
    };
}

fn isValidMapLookupValue(v: value.Value) bool {
    return switch (v) {
        .int, .uint, .double, .bool, .string => true,
        else => false,
    };
}

fn equalNumericValues(lhs: value.Value, rhs: value.Value) bool {
    return switch (lhs) {
        .int => |left| switch (rhs) {
            .int => left == rhs.int,
            .uint => if (left < 0) false else @as(u64, @intCast(left)) == rhs.uint,
            .double => equalIntAndDouble(left, rhs.double),
            else => unreachable,
        },
        .uint => |left| switch (rhs) {
            .int => if (rhs.int < 0) false else left == @as(u64, @intCast(rhs.int)),
            .uint => left == rhs.uint,
            .double => equalUintAndDouble(left, rhs.double),
            else => unreachable,
        },
        .double => |left| switch (rhs) {
            .int => equalIntAndDouble(rhs.int, left),
            .uint => equalUintAndDouble(rhs.uint, left),
            .double => !std.math.isNan(left) and !std.math.isNan(rhs.double) and left == rhs.double,
            else => unreachable,
        },
        else => unreachable,
    };
}

fn compareNumericValues(lhs: value.Value, rhs: value.Value, op: CompareOp) value.RuntimeError!bool {
    return switch (lhs) {
        .int => |left| switch (rhs) {
            .int => compareOrd(i64, left, rhs.int, op),
            .uint => compareIntAndUint(left, rhs.uint, op),
            .double => compareFloatLike(@as(f64, @floatFromInt(left)), rhs.double, op),
            else => unreachable,
        },
        .uint => |left| switch (rhs) {
            .int => compareUintAndInt(left, rhs.int, op),
            .uint => compareOrd(u64, left, rhs.uint, op),
            .double => compareFloatLike(@as(f64, @floatFromInt(left)), rhs.double, op),
            else => unreachable,
        },
        .double => |left| switch (rhs) {
            .int => compareFloatLike(left, @as(f64, @floatFromInt(rhs.int)), op),
            .uint => compareFloatLike(left, @as(f64, @floatFromInt(rhs.uint)), op),
            .double => compareFloatLike(left, rhs.double, op),
            else => unreachable,
        },
        else => unreachable,
    };
}

fn compareIntAndUint(lhs: i64, rhs: u64, op: CompareOp) bool {
    if (lhs < 0) {
        return switch (op) {
            .lt, .lte => true,
            .gt, .gte => false,
        };
    }
    return compareOrd(u64, @intCast(lhs), rhs, op);
}

fn compareUintAndInt(lhs: u64, rhs: i64, op: CompareOp) bool {
    if (rhs < 0) {
        return switch (op) {
            .lt, .lte => false,
            .gt, .gte => true,
        };
    }
    return compareOrd(u64, lhs, @intCast(rhs), op);
}

fn compareFloatLike(lhs: f64, rhs: f64, op: CompareOp) bool {
    if (std.math.isNan(lhs) or std.math.isNan(rhs)) return false;
    return compareOrd(f64, lhs, rhs, op);
}

fn equalIntAndDouble(lhs: i64, rhs: f64) bool {
    if (!std.math.isFinite(rhs)) return false;
    if (@trunc(rhs) != rhs) return false;
    if (rhs < -0x1p63 or rhs >= 0x1p63) return false;
    const converted: i64 = @as(i64, @intFromFloat(rhs));
    return @as(f64, @floatFromInt(converted)) == rhs and lhs == converted;
}

fn equalUintAndDouble(lhs: u64, rhs: f64) bool {
    if (!std.math.isFinite(rhs) or rhs < 0) return false;
    if (@trunc(rhs) != rhs) return false;
    if (rhs >= 0x1p64) return false;
    const converted: u64 = @as(u64, @intFromFloat(rhs));
    return @as(f64, @floatFromInt(converted)) == rhs and lhs == converted;
}

fn addValues(allocator: std.mem.Allocator, lhs: value.Value, rhs: value.Value) env.EvalError!value.Value {
    if (lhs == .timestamp and rhs == .duration) {
        return .{ .timestamp = cel_time.addDurationToTimestamp(lhs.timestamp, rhs.duration) catch return value.RuntimeError.Overflow };
    }
    if (lhs == .duration and rhs == .timestamp) {
        return .{ .timestamp = cel_time.addDurationToTimestamp(rhs.timestamp, lhs.duration) catch return value.RuntimeError.Overflow };
    }
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return value.RuntimeError.TypeMismatch;
    return switch (lhs) {
        .int => .{ .int = std.math.add(i64, lhs.int, rhs.int) catch return value.RuntimeError.Overflow },
        .uint => .{ .uint = std.math.add(u64, lhs.uint, rhs.uint) catch return value.RuntimeError.Overflow },
        .double => .{ .double = lhs.double + rhs.double },
        .duration => .{ .duration = cel_time.addDurations(lhs.duration, rhs.duration) catch return value.RuntimeError.Overflow },
        .string => blk: {
            const out = try allocator.alloc(u8, lhs.string.len + rhs.string.len);
            @memcpy(out[0..lhs.string.len], lhs.string);
            @memcpy(out[lhs.string.len..], rhs.string);
            break :blk .{ .string = out };
        },
        .bytes => blk: {
            const out = try allocator.alloc(u8, lhs.bytes.len + rhs.bytes.len);
            @memcpy(out[0..lhs.bytes.len], lhs.bytes);
            @memcpy(out[lhs.bytes.len..], rhs.bytes);
            break :blk .{ .bytes = out };
        },
        .list => blk: {
            var out: std.ArrayListUnmanaged(value.Value) = .empty;
            errdefer {
                for (out.items) |*item| item.deinit(allocator);
                out.deinit(allocator);
            }
            try out.ensureTotalCapacity(allocator, lhs.list.items.len + rhs.list.items.len);
            for (lhs.list.items) |item| out.appendAssumeCapacity(try item.clone(allocator));
            for (rhs.list.items) |item| out.appendAssumeCapacity(try item.clone(allocator));
            break :blk .{ .list = out };
        },
        .unknown => value.RuntimeError.TypeMismatch,
        else => value.RuntimeError.TypeMismatch,
    };
}

fn subValues(lhs: value.Value, rhs: value.Value) value.RuntimeError!value.Value {
    if (lhs == .timestamp and rhs == .duration) {
        return .{ .timestamp = cel_time.subDurationFromTimestamp(lhs.timestamp, rhs.duration) catch return value.RuntimeError.Overflow };
    }
    if (lhs == .timestamp and rhs == .timestamp) {
        return .{ .duration = cel_time.diffTimestamps(lhs.timestamp, rhs.timestamp) catch return value.RuntimeError.Overflow };
    }
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return value.RuntimeError.TypeMismatch;
    return switch (lhs) {
        .int => .{ .int = std.math.sub(i64, lhs.int, rhs.int) catch return value.RuntimeError.Overflow },
        .uint => .{ .uint = std.math.sub(u64, lhs.uint, rhs.uint) catch return value.RuntimeError.Overflow },
        .double => .{ .double = lhs.double - rhs.double },
        .duration => .{ .duration = cel_time.subDurations(lhs.duration, rhs.duration) catch return value.RuntimeError.Overflow },
        .unknown => value.RuntimeError.TypeMismatch,
        else => value.RuntimeError.TypeMismatch,
    };
}

fn mulValues(lhs: value.Value, rhs: value.Value) value.RuntimeError!value.Value {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return value.RuntimeError.TypeMismatch;
    return switch (lhs) {
        .int => .{ .int = std.math.mul(i64, lhs.int, rhs.int) catch return value.RuntimeError.Overflow },
        .uint => .{ .uint = std.math.mul(u64, lhs.uint, rhs.uint) catch return value.RuntimeError.Overflow },
        .double => .{ .double = lhs.double * rhs.double },
        .unknown => value.RuntimeError.TypeMismatch,
        else => value.RuntimeError.TypeMismatch,
    };
}

fn divValues(lhs: value.Value, rhs: value.Value) value.RuntimeError!value.Value {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return value.RuntimeError.TypeMismatch;
    return switch (lhs) {
        .int => {
            if (rhs.int == 0) return value.RuntimeError.DivisionByZero;
            if (lhs.int == std.math.minInt(i64) and rhs.int == -1) return value.RuntimeError.Overflow;
            return .{ .int = @divTrunc(lhs.int, rhs.int) };
        },
        .uint => {
            if (rhs.uint == 0) return value.RuntimeError.DivisionByZero;
            return .{ .uint = @divTrunc(lhs.uint, rhs.uint) };
        },
        .double => .{ .double = lhs.double / rhs.double },
        .unknown => value.RuntimeError.TypeMismatch,
        else => value.RuntimeError.TypeMismatch,
    };
}

fn remValues(lhs: value.Value, rhs: value.Value) value.RuntimeError!value.Value {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return value.RuntimeError.TypeMismatch;
    return switch (lhs) {
        .int => {
            if (rhs.int == 0) return value.RuntimeError.DivisionByZero;
            if (lhs.int == std.math.minInt(i64) and rhs.int == -1) return .{ .int = 0 };
            return .{ .int = @rem(lhs.int, rhs.int) };
        },
        .uint => {
            if (rhs.uint == 0) return value.RuntimeError.DivisionByZero;
            return .{ .uint = @rem(lhs.uint, rhs.uint) };
        },
        .unknown => value.RuntimeError.TypeMismatch,
        else => value.RuntimeError.TypeMismatch,
    };
}

fn inValues(lhs: value.Value, rhs: value.Value) value.RuntimeError!bool {
    return switch (rhs) {
        .list => |items| blk: {
            for (items.items) |item| if (try equalValues(item, lhs)) break :blk true;
            break :blk false;
        },
        .map => |entries| blk: {
            for (entries.items) |entry| if (try equalValues(entry.key, lhs)) break :blk true;
            break :blk false;
        },
        else => value.RuntimeError.TypeMismatch,
    };
}

fn compareTimestamp(lhs: cel_time.Timestamp, rhs: cel_time.Timestamp, op: CompareOp) bool {
    if (lhs.seconds == rhs.seconds) {
        return compareOrd(u32, lhs.nanos, rhs.nanos, op);
    }
    return compareOrd(i64, lhs.seconds, rhs.seconds, op);
}

fn compareDuration(lhs: cel_time.Duration, rhs: cel_time.Duration, op: CompareOp) bool {
    if (lhs.seconds == rhs.seconds) {
        return compareOrd(i32, lhs.nanos, rhs.nanos, op);
    }
    return compareOrd(i64, lhs.seconds, rhs.seconds, op);
}

test "compile and eval core expressions" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("a", environment.types.builtins.int_type);
    try environment.addVarTyped("name", environment.types.builtins.string_type);
    try environment.addVarTyped("items", try environment.types.listOf(environment.types.builtins.int_type));

    var program = try checker.compile(
        std.testing.allocator,
        &environment,
        "a < 10 && name.contains('x') ? size(items) : 0",
    );
    defer program.deinit();
    try std.testing.expectEqual(environment.types.builtins.int_type, program.result_type);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.put("a", .{ .int = 5 });
    var name_value = try value.string(std.testing.allocator, "x-ray");
    defer name_value.deinit(std.testing.allocator);
    try activation.put("name", name_value);

    var list: std.ArrayListUnmanaged(value.Value) = .empty;
    defer {
        var temp: value.Value = .{ .list = list };
        temp.deinit(std.testing.allocator);
    }
    try list.append(std.testing.allocator, .{ .int = 1 });
    try list.append(std.testing.allocator, .{ .int = 2 });
    try list.append(std.testing.allocator, .{ .int = 3 });
    try activation.put("items", .{ .list = list });

    var result = try eval(std.testing.allocator, &program, &activation);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 3), result.int);
}

test "activation owned puts and clear support request reuse" {
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    try activation.putString("name", "first");
    try std.testing.expectEqualStrings("first", activation.get("name").?.string);

    const replacement = try std.testing.allocator.dupe(u8, "second");
    try activation.putOwned("name", .{ .string = replacement });
    try std.testing.expectEqualStrings("second", activation.get("name").?.string);

    try activation.putBytes("payload", "abc");
    try std.testing.expectEqualStrings("abc", activation.get("payload").?.bytes);

    activation.clearRetainingCapacity();
    try std.testing.expect(activation.get("name") == null);
    try std.testing.expect(activation.get("payload") == null);
}

test "logical operators short circuit and absorb errors per CEL semantics" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const cases = [_]struct {
        expr: []const u8,
        want_bool: ?bool,
        want_err: ?anyerror,
    }{
        .{ .expr = "false && (1 / 0 > 0)", .want_bool = false, .want_err = null },
        .{ .expr = "true || (1 / 0 > 0)", .want_bool = true, .want_err = null },
        .{ .expr = "(1 / 0 > 0) && false", .want_bool = false, .want_err = null },
        .{ .expr = "(1 / 0 > 0) || true", .want_bool = true, .want_err = null },
        .{ .expr = "true && (1 / 0 > 0)", .want_bool = null, .want_err = value.RuntimeError.DivisionByZero },
        .{ .expr = "false || (1 / 0 > 0)", .want_bool = null, .want_err = value.RuntimeError.DivisionByZero },
    };

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        if (case.want_bool) |expected| {
            var result = try eval(std.testing.allocator, &program, &activation);
            defer result.deinit(std.testing.allocator);
            try std.testing.expectEqual(expected, result.bool);
        } else {
            try std.testing.expectError(case.want_err.?, eval(std.testing.allocator, &program, &activation));
        }
    }
}

test "map select index and membership" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const map_ty = try environment.types.mapOf(
        environment.types.builtins.string_type,
        environment.types.builtins.int_type,
    );
    try environment.addVarTyped("m", map_ty);

    var program = try checker.compile(
        std.testing.allocator,
        &environment,
        "m.foo == m['foo'] && 'foo' in m",
    );
    defer program.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    var entries: std.ArrayListUnmanaged(value.MapEntry) = .empty;
    defer {
        var temp: value.Value = .{ .map = entries };
        temp.deinit(std.testing.allocator);
    }
    try entries.append(std.testing.allocator, .{
        .key = try value.string(std.testing.allocator, "foo"),
        .value = .{ .int = 42 },
    });
    try activation.put("m", .{ .map = entries });

    var result = try eval(std.testing.allocator, &program, &activation);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.bool);
}

test "custom functions work through env overloads" {
    const Custom = struct {
        fn twice(allocator: std.mem.Allocator, args: []const value.Value) env.EvalError!value.Value {
            _ = allocator;
            if (args.len != 1 or args[0] != .int) return value.RuntimeError.NoMatchingOverload;
            return .{ .int = args[0].int * 2 };
        }
    };

    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    _ = try environment.addFunction(
        "twice",
        false,
        &.{environment.types.builtins.int_type},
        environment.types.builtins.int_type,
        Custom.twice,
    );

    var program = try checker.compile(std.testing.allocator, &environment, "twice(21)");
    defer program.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var result = try eval(std.testing.allocator, &program, &activation);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 42), result.int);
}

test "extended env inherits parent libraries and overloads without copying them" {
    const Custom = struct {
        fn twice(allocator: std.mem.Allocator, args: []const value.Value) env.EvalError!value.Value {
            _ = allocator;
            if (args.len != 1 or args[0] != .int) return value.RuntimeError.NoMatchingOverload;
            return .{ .int = args[0].int * 2 };
        }
    };

    var base = try env.Env.initDefault(std.testing.allocator);
    defer base.deinit();
    try checker.prepareEnvironment(&base);
    _ = try base.addFunction(
        "acme.twice",
        false,
        &.{base.types.builtins.int_type},
        base.types.builtins.int_type,
        Custom.twice,
    );

    var child = try base.extend(std.testing.allocator);
    defer child.deinit();
    try std.testing.expectEqual(@as(usize, 0), child.overloads.items.len);
    try std.testing.expectEqual(@as(usize, 0), child.dynamic_functions.items.len);
    try child.addVarTyped("x", child.types.builtins.int_type);

    var program = try checker.compile(
        std.testing.allocator,
        &child,
        "size([1, 2, 3]) == 3 && acme.twice(x) == 6",
    );
    defer program.deinit();

    try std.testing.expect(child.hasLibrary(stdlib.standard_library.name));
    try std.testing.expectEqual(@as(usize, 0), child.overloads.items.len);
    try std.testing.expectEqual(@as(usize, 0), child.dynamic_functions.items.len);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.put("x", .{ .int = 3 });

    var result = try eval(std.testing.allocator, &program, &activation);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.bool);
}

test "container scoped names and absolute names resolve" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.setContainer("acme.auth.v1");
    try environment.addVarTyped("acme.auth.v1.user_id", environment.types.builtins.string_type);
    try environment.addVarTyped("acme.auth.enabled", environment.types.builtins.bool_type);

    var program = try checker.compile(
        std.testing.allocator,
        &environment,
        "user_id == .acme.auth.v1.user_id && enabled",
    );
    defer program.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    var user_id = try value.string(std.testing.allocator, "pokemon");
    defer user_id.deinit(std.testing.allocator);
    try activation.put("acme.auth.v1.user_id", user_id);
    try activation.put("acme.auth.enabled", .{ .bool = true });

    var result = try eval(std.testing.allocator, &program, &activation);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.bool);
}

test "qualified globals do not override local comprehension bindings" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped(
        "x.ok",
        environment.types.builtins.bool_type,
    );

    var program = try checker.compile(
        std.testing.allocator,
        &environment,
        "[{'ok': false}].all(x, !x.ok)",
    );
    defer program.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.put("x.ok", .{ .bool = true });

    var result = try eval(std.testing.allocator, &program, &activation);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.bool);
}

test "qualified function names resolve through scoped lookup" {
    const Custom = struct {
        fn twice(allocator: std.mem.Allocator, args: []const value.Value) env.EvalError!value.Value {
            _ = allocator;
            if (args.len != 1 or args[0] != .int) return value.RuntimeError.NoMatchingOverload;
            return .{ .int = args[0].int * 2 };
        }
    };

    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.setContainer("acme");
    _ = try environment.addFunction(
        "acme.math.twice",
        false,
        &.{environment.types.builtins.int_type},
        environment.types.builtins.int_type,
        Custom.twice,
    );

    var program = try checker.compile(std.testing.allocator, &environment, "math.twice(21) == .acme.math.twice(21)");
    defer program.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var result = try eval(std.testing.allocator, &program, &activation);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.bool);
}

test "overload dispatch prefers exact overloads, fresh generics, and receiver style" {
    const Custom = struct {
        fn staticPick(allocator: std.mem.Allocator, args: []const value.Value) env.EvalError!value.Value {
            _ = args;
            return value.string(allocator, "static-int");
        }

        fn dynamicPick(allocator: std.mem.Allocator, args: []const value.Value) env.EvalError!value.Value {
            _ = args;
            return value.string(allocator, "dynamic");
        }

        fn identity(allocator: std.mem.Allocator, args: []const value.Value) env.EvalError!value.Value {
            return args[0].clone(allocator);
        }

        fn receiverMark(allocator: std.mem.Allocator, args: []const value.Value) env.EvalError!value.Value {
            if (args.len != 1 or args[0] != .string) return value.RuntimeError.NoMatchingOverload;
            return .{ .string = try std.fmt.allocPrint(allocator, "recv:{s}", .{args[0].string}) };
        }

        fn globalMark(allocator: std.mem.Allocator, args: []const value.Value) env.EvalError!value.Value {
            if (args.len != 1 or args[0] != .int) return value.RuntimeError.NoMatchingOverload;
            return .{ .string = try std.fmt.allocPrint(allocator, "free:{d}", .{args[0].int}) };
        }

        fn matchAnySingle(environment: *const env.Env, params: []const types.TypeRef) ?types.TypeRef {
            if (params.len != 1) return null;
            return environment.types.builtins.string_type;
        }
    };

    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const any_param = try environment.types.typeParamOf("A");

    _ = try environment.addFunction(
        "pick",
        false,
        &.{environment.types.builtins.int_type},
        environment.types.builtins.string_type,
        Custom.staticPick,
    );
    _ = try environment.addDynamicFunction("pick", false, Custom.matchAnySingle, Custom.dynamicPick);
    _ = try environment.addFunction("id", false, &.{any_param}, any_param, Custom.identity);
    _ = try environment.addFunction(
        "mark",
        true,
        &.{environment.types.builtins.string_type},
        environment.types.builtins.string_type,
        Custom.receiverMark,
    );
    _ = try environment.addFunction(
        "mark",
        false,
        &.{environment.types.builtins.int_type},
        environment.types.builtins.string_type,
        Custom.globalMark,
    );

    var program = try checker.compile(
        std.testing.allocator,
        &environment,
        "pick(1) == 'static-int' && pick('x') == 'dynamic' && id(1) == 1 && id('x') == 'x' && 'go'.mark() == 'recv:go' && mark(7) == 'free:7'",
    );
    defer program.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var result = try eval(std.testing.allocator, &program, &activation);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.bool);

    try std.testing.expectError(
        checker.Error.InvalidCall,
        checker.compile(std.testing.allocator, &environment, "mark('x')"),
    );
    try std.testing.expectError(
        checker.Error.InvalidCall,
        checker.compile(std.testing.allocator, &environment, "1.mark()"),
    );
}

test "message literals and field selection use descriptor layer" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const account_ty = try environment.addMessage("Account");
    try environment.addMessageField("Account", "user_id", environment.types.builtins.string_type);
    try environment.addMessageField("Account", "enabled", environment.types.builtins.bool_type);

    var program = try checker.compile(
        std.testing.allocator,
        &environment,
        "Account{user_id: 'Pokemon'}.user_id == 'Pokemon' && !Account{}.enabled",
    );
    defer program.deinit();
    try std.testing.expectEqual(environment.types.builtins.bool_type, program.result_type);
    _ = account_ty;

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var result = try eval(std.testing.allocator, &program, &activation);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.bool);
}

test "protobuf field presence distinguishes optional access from implicit defaults" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    _ = try environment.addMessage("example.Presence");
    try environment.addProtobufField("example.Presence", "count", 1, environment.types.builtins.int_type, .{
        .singular = .{ .scalar = .int64 },
    });
    _ = try environment.addMessage("example.Container");
    try environment.addProtobufField("example.Container", "wrapped", 1, environment.types.builtins.int_type, .{
        .singular = .{ .message = "google.protobuf.Int32Value" },
    });

    var program = try checker.compile(
        std.testing.allocator,
        &environment,
        "example.Presence{}.count == 0 && example.Presence{}.?count.orValue(7) == 7 && example.Container{}.?wrapped.orValue(7) == 7",
    );
    defer program.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var result = try eval(std.testing.allocator, &program, &activation);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.bool);
}

test "comprehension macros work on lists and shadow outer bindings" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.string_type);

    var program = try checker.compile(
        std.testing.allocator,
        &environment,
        "[1, 2, 3].all(x, x > 0) && [1, 2, 3].exists_one(x, x == 2) && [1, 2, 3, 4].filter(x, x % 2 == 0).size() == 2 && [1, 2, 3].map(x, x * 2)[1] == 4",
    );
    defer program.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    var outer_x = try value.string(std.testing.allocator, "outer");
    defer outer_x.deinit(std.testing.allocator);
    try activation.put("x", outer_x);

    var result = try eval(std.testing.allocator, &program, &activation);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.bool);
}

test "map macros and has macro work" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const map_ty = try environment.types.mapOf(
        environment.types.builtins.string_type,
        environment.types.builtins.int_type,
    );
    try environment.addVarTyped("m", map_ty);
    _ = try environment.addMessage("Account");
    try environment.addMessageField("Account", "user_id", environment.types.builtins.string_type);

    var program = try checker.compile(
        std.testing.allocator,
        &environment,
        "has(m.foo) && m.filter(k, k == 'foo').size() == 1 && m.map(k, k)[0] == 'foo' && has(Account{user_id: 'u'}.user_id) && !has(Account{}.user_id)",
    );
    defer program.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    var entries: std.ArrayListUnmanaged(value.MapEntry) = .empty;
    defer {
        var temp: value.Value = .{ .map = entries };
        temp.deinit(std.testing.allocator);
    }
    try entries.append(std.testing.allocator, .{
        .key = try value.string(std.testing.allocator, "foo"),
        .value = .{ .int = 1 },
    });
    try activation.put("m", .{ .map = entries });

    var result = try eval(std.testing.allocator, &program, &activation);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.bool);
}

test "duplicate map keys fail at evaluation" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var program = try checker.compile(
        std.testing.allocator,
        &environment,
        "{'x': 1, 'x': 2}",
    );
    defer program.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    try std.testing.expectError(
        value.RuntimeError.DuplicateMapKey,
        eval(std.testing.allocator, &program, &activation),
    );
}

test "optionals support chaining and literal elision" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.setContainer("cel.expr.conformance.proto2");

    var program = try checker.compile(
        std.testing.allocator,
        &environment,
        "[?{}.?c, ?optional.of(42), ?optional.none()].size() == 1 && optional.of({'c': {'index': 'goodbye'}}).c['index'].orValue('default') == 'goodbye' && {?'nested': optional.none(), 'present': true}.present",
    );
    defer program.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var result = try eval(std.testing.allocator, &program, &activation);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.bool);
}

test "partial activation produces path-sensitive unknowns" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("request", environment.types.builtins.dyn_type);

    var program = try checker.compile(
        std.testing.allocator,
        &environment,
        "request.auth.claims['role'] == 'admin'",
    );
    defer program.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    var pattern = try partial.AttributePattern.init(std.testing.allocator, "request");
    defer pattern.deinit(std.testing.allocator);
    try pattern.qualString(std.testing.allocator, "auth");
    try pattern.qualString(std.testing.allocator, "claims");
    try pattern.qualString(std.testing.allocator, "role");
    try activation.addUnknownPattern(&pattern);

    var result = try eval(std.testing.allocator, &program, &activation);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .unknown);
    try std.testing.expectEqual(@as(usize, 1), result.unknown.causes.items.len);
    const cause = result.unknown.causes.items[0];
    try std.testing.expect(std.mem.eql(u8, cause.trail.variable, "request"));
    try std.testing.expectEqual(@as(usize, 3), cause.trail.qualifiers.items.len);
    try std.testing.expect(cause.trail.qualifiers.items[0] == .string);
    try std.testing.expect(std.mem.eql(u8, cause.trail.qualifiers.items[0].string, "auth"));
    try std.testing.expect(cause.trail.qualifiers.items[1] == .string);
    try std.testing.expect(std.mem.eql(u8, cause.trail.qualifiers.items[1].string, "claims"));
    try std.testing.expect(cause.trail.qualifiers.items[2] == .string);
    try std.testing.expect(std.mem.eql(u8, cause.trail.qualifiers.items[2].string, "role"));
}

test "unknowns obey CEL short-circuit and error precedence" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("x", environment.types.builtins.int_type);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.addUnknownVariable("x");

    const cases = [_]struct {
        expr: []const u8,
        want_bool: ?bool,
        want_unknown: bool,
        want_err: ?anyerror,
    }{
        .{ .expr = "false && x == 1", .want_bool = false, .want_unknown = false, .want_err = null },
        .{ .expr = "true && x == 1", .want_bool = null, .want_unknown = true, .want_err = null },
        .{ .expr = "((1 / 0) > 0) && x == 1", .want_bool = null, .want_unknown = true, .want_err = null },
        .{ .expr = "(1 / 0) + x", .want_bool = null, .want_unknown = false, .want_err = value.RuntimeError.DivisionByZero },
    };

    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        if (case.want_err) |expected_err| {
            try std.testing.expectError(expected_err, eval(std.testing.allocator, &program, &activation));
            continue;
        }

        var result = try eval(std.testing.allocator, &program, &activation);
        defer result.deinit(std.testing.allocator);
        if (case.want_bool) |expected_bool| {
            try std.testing.expect(result == .bool);
            try std.testing.expectEqual(expected_bool, result.bool);
        } else if (case.want_unknown) {
            try std.testing.expect(result == .unknown);
            try std.testing.expectEqual(@as(usize, 1), result.unknown.causes.items.len);
            try std.testing.expect(std.mem.eql(u8, result.unknown.causes.items[0].trail.variable, "x"));
        } else {
            unreachable;
        }
    }
}

test "has macro propagates unknown presence" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("request", environment.types.builtins.dyn_type);

    var program = try checker.compile(
        std.testing.allocator,
        &environment,
        "has(request.auth)",
    );
    defer program.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    var pattern = try partial.AttributePattern.init(std.testing.allocator, "request");
    defer pattern.deinit(std.testing.allocator);
    try pattern.qualString(std.testing.allocator, "auth");
    try activation.addUnknownPattern(&pattern);

    var result = try eval(std.testing.allocator, &program, &activation);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .unknown);
}

test "host-defined primitives participate in native operators and type checking" {
    const Money = struct {
        cents: i64,
    };

    const Helpers = struct {
        fn asConst(ptr: *const anyopaque) *const Money {
            return @ptrCast(@alignCast(ptr));
        }

        fn asMut(ptr: *anyopaque) *Money {
            return @ptrCast(@alignCast(ptr));
        }

        fn fromValue(val: value.Value) *const Money {
            return asConst(val.host.ptr);
        }

        fn makeValue(allocator: std.mem.Allocator, cents: i64) !value.Value {
            const ptr = try allocator.create(Money);
            ptr.* = .{ .cents = cents };
            return value.hostValue(ptr, &@This().money_vtable);
        }

        fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) std.mem.Allocator.Error!*anyopaque {
            const out = try allocator.create(Money);
            out.* = asConst(ptr).*;
            return out;
        }

        fn deinit(allocator: std.mem.Allocator, ptr: *anyopaque) void {
            allocator.destroy(asMut(ptr));
        }

        fn eql(lhs: *const anyopaque, rhs: *const anyopaque) bool {
            return asConst(lhs).cents == asConst(rhs).cents;
        }

        fn negate(allocator: std.mem.Allocator, args: []const value.Value) env.EvalError!value.Value {
            return makeValue(allocator, -fromValue(args[0]).cents);
        }

        fn add(allocator: std.mem.Allocator, args: []const value.Value) env.EvalError!value.Value {
            return makeValue(allocator, fromValue(args[0]).cents + fromValue(args[1]).cents);
        }

        fn greater(allocator: std.mem.Allocator, args: []const value.Value) env.EvalError!value.Value {
            _ = allocator;
            return .{ .bool = fromValue(args[0]).cents > fromValue(args[1]).cents };
        }

        fn stringify(allocator: std.mem.Allocator, args: []const value.Value) env.EvalError!value.Value {
            const money = fromValue(args[0]).cents;
            const abs_value: i64 = if (money < 0) -money else money;
            const text = try std.fmt.allocPrint(allocator, "{s}{d}.{d:0>2} USD", .{
                if (money < 0) "-" else "",
                @divTrunc(abs_value, 100),
                @as(u8, @intCast(@mod(abs_value, 100))),
            });
            return .{ .string = text };
        }

        const money_vtable = value.HostValueVTable{
            .type_name = "example.Money",
            .clone = clone,
            .deinit = deinit,
            .eql = eql,
        };
    };

    const money_vtable = Helpers.money_vtable;

    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const money_ty = try environment.addHostTypeFromVTable(&money_vtable);
    try environment.addVarTyped("price", money_ty);
    try environment.addVarTyped("tax", money_ty);
    try environment.addVarTyped("limit", money_ty);
    try environment.addVarTyped("discount", money_ty);

    _ = try environment.addUnaryOperator(.negate, money_ty, money_ty, Helpers.negate);
    _ = try environment.addBinaryOperator(.add, money_ty, money_ty, money_ty, Helpers.add);
    _ = try environment.addBinaryOperator(.greater, money_ty, money_ty, environment.types.builtins.bool_type, Helpers.greater);
    _ = try environment.addFunction("string", false, &.{money_ty}, environment.types.builtins.string_type, Helpers.stringify);

    var typed_program = try checker.compile(std.testing.allocator, &environment, "price + tax");
    defer typed_program.deinit();
    try std.testing.expectEqual(money_ty, typed_program.result_type);

    var program = try checker.compile(
        std.testing.allocator,
        &environment,
        "-discount + price > limit && string(price + tax) == '12.50 USD' && price != tax",
    );
    defer program.deinit();
    try std.testing.expectEqual(environment.types.builtins.bool_type, program.result_type);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var price = try Helpers.makeValue(std.testing.allocator, 1_000);
    defer price.deinit(std.testing.allocator);
    try activation.put("price", price);

    var tax = try Helpers.makeValue(std.testing.allocator, 250);
    defer tax.deinit(std.testing.allocator);
    try activation.put("tax", tax);

    var limit = try Helpers.makeValue(std.testing.allocator, 700);
    defer limit.deinit(std.testing.allocator);
    try activation.put("limit", limit);

    var discount = try Helpers.makeValue(std.testing.allocator, 200);
    defer discount.deinit(std.testing.allocator);
    try activation.put("discount", discount);

    var compare_program = try checker.compile(std.testing.allocator, &environment, "-discount + price > limit");
    defer compare_program.deinit();
    var compare_result = try eval(std.testing.allocator, &compare_program, &activation);
    defer compare_result.deinit(std.testing.allocator);
    try std.testing.expect(compare_result.bool);

    var string_program = try checker.compile(std.testing.allocator, &environment, "string(price + tax)");
    defer string_program.deinit();
    var string_result = try eval(std.testing.allocator, &string_program, &activation);
    defer string_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("12.50 USD", string_result.string);

    var neq_program = try checker.compile(std.testing.allocator, &environment, "price != tax");
    defer neq_program.deinit();
    var neq_result = try eval(std.testing.allocator, &neq_program, &activation);
    defer neq_result.deinit(std.testing.allocator);
    try std.testing.expect(neq_result.bool);

    var result = try eval(std.testing.allocator, &program, &activation);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.bool);
}

test "eval runtime errors" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected_error: anyerror }{
        .{ .expr = "1 / 0", .expected_error = value.RuntimeError.DivisionByZero },
        .{ .expr = "10 % 0", .expected_error = value.RuntimeError.DivisionByZero },
        .{ .expr = "1u / 0u", .expected_error = value.RuntimeError.DivisionByZero },
        .{ .expr = "9223372036854775807 + 1", .expected_error = value.RuntimeError.Overflow },
        .{ .expr = "-9223372036854775807 - 2", .expected_error = value.RuntimeError.Overflow },
        .{ .expr = "9223372036854775807 * 2", .expected_error = value.RuntimeError.Overflow },
        .{ .expr = "[1, 2, 3][5]", .expected_error = value.RuntimeError.InvalidIndex },
        .{ .expr = "[1, 2, 3][-1]", .expected_error = value.RuntimeError.InvalidIndex },
        .{ .expr = "{'a': 1}['missing']", .expected_error = value.RuntimeError.NoSuchField },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        try std.testing.expectError(case.expected_error, eval(std.testing.allocator, &program, &activation));
    }
}

test "eval string concatenation" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: []const u8 }{
        .{ .expr = "'hello' + ' ' + 'world'", .expected = "hello world" },
        .{ .expr = "'' + ''", .expected = "" },
        .{ .expr = "'a' + 'b' + 'c'", .expected = "abc" },
        .{ .expr = "'' + 'nonempty'", .expected = "nonempty" },
        .{ .expr = "'prefix' + ''", .expected = "prefix" },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval(std.testing.allocator, &program, &activation);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected, result.string);
    }
}

test "eval list concatenation" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var program = try checker.compile(std.testing.allocator, &environment, "[1, 2] + [3, 4]");
    defer program.deinit();
    var result = try eval(std.testing.allocator, &program, &activation);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .list);
    try std.testing.expectEqual(@as(usize, 4), result.list.items.len);
    try std.testing.expectEqual(@as(i64, 1), result.list.items[0].int);
    try std.testing.expectEqual(@as(i64, 4), result.list.items[3].int);
}

test "eval integer arithmetic" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: i64 }{
        .{ .expr = "1 + 2", .expected = 3 },
        .{ .expr = "10 - 3", .expected = 7 },
        .{ .expr = "4 * 5", .expected = 20 },
        .{ .expr = "10 / 3", .expected = 3 },
        .{ .expr = "10 % 3", .expected = 1 },
        .{ .expr = "-(5)", .expected = -5 },
        .{ .expr = "-(-3)", .expected = 3 },
        .{ .expr = "0 + 0", .expected = 0 },
        .{ .expr = "100 - 100", .expected = 0 },
        .{ .expr = "size([size([1,2]), size([3,4,5])])", .expected = 2 },
        .{ .expr = "((((1 + 2) * 3) - 4) / 5)", .expected = 1 },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval(std.testing.allocator, &program, &activation);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.int);
    }
}

test "eval boolean short-circuit" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        .{ .expr = "true || (1/0 > 0)", .expected = true },
        .{ .expr = "false && (1/0 > 0)", .expected = false },
        .{ .expr = "true || false", .expected = true },
        .{ .expr = "false || true", .expected = true },
        .{ .expr = "true && true", .expected = true },
        .{ .expr = "false && false", .expected = false },
        .{ .expr = "false || false", .expected = false },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval(std.testing.allocator, &program, &activation);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.bool);
    }
}

test "eval ternary conditional" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: i64 }{
        .{ .expr = "true ? 1 : 2", .expected = 1 },
        .{ .expr = "false ? 1 : 2", .expected = 2 },
        .{ .expr = "(1 < 2) ? 10 : 20", .expected = 10 },
        .{ .expr = "(1 > 2) ? 10 : 20", .expected = 20 },
        .{ .expr = "true ? (true ? 1 : 2) : 3", .expected = 1 },
        .{ .expr = "false ? 1 : (false ? 2 : 3)", .expected = 3 },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval(std.testing.allocator, &program, &activation);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.int);
    }
}

test "eval has() macro on maps and messages" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    _ = try environment.addMessage("Msg");
    try environment.addMessageField("Msg", "field", environment.types.builtins.string_type);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        .{ .expr = "has({'a': 1}.a)", .expected = true },
        .{ .expr = "has({'a': 1}.b)", .expected = false },
        .{ .expr = "has({'x': 1, 'y': 2}.x)", .expected = true },
        .{ .expr = "has({'x': 1, 'y': 2}.z)", .expected = false },
        .{ .expr = "has(Msg{field: 'x'}.field)", .expected = true },
        .{ .expr = "has(Msg{}.field)", .expected = false },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval(std.testing.allocator, &program, &activation);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.bool);
    }
}

test "eval quantifier macros on lists" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        // all
        .{ .expr = "[1, 2, 3].all(x, x > 0)", .expected = true },
        .{ .expr = "[1, -1, 3].all(x, x > 0)", .expected = false },
        .{ .expr = "[].all(x, x > 0)", .expected = true },
        .{ .expr = "[5].all(x, x == 5)", .expected = true },
        // exists
        .{ .expr = "[1, 2, 3].exists(x, x == 2)", .expected = true },
        .{ .expr = "[1, 2, 3].exists(x, x == 5)", .expected = false },
        .{ .expr = "[].exists(x, x > 0)", .expected = false },
        // exists_one
        .{ .expr = "[1, 2, 3].exists_one(x, x == 2)", .expected = true },
        .{ .expr = "[1, 2, 2, 3].exists_one(x, x == 2)", .expected = false },
        .{ .expr = "[1, 2, 3].exists_one(x, x == 5)", .expected = false },
        .{ .expr = "[1].exists_one(x, x == 1)", .expected = true },
        // macros on maps
        .{ .expr = "{'a': 1, 'b': 2}.exists(k, k == 'a')", .expected = true },
        .{ .expr = "{'a': 1, 'b': 2}.exists(k, k == 'c')", .expected = false },
        .{ .expr = "{'ab': 1, 'ac': 2}.all(k, k.startsWith('a'))", .expected = true },
        .{ .expr = "{'ab': 1, 'bc': 2}.all(k, k.startsWith('a'))", .expected = false },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval(std.testing.allocator, &program, &activation);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.bool);
    }
}

test "eval filter and map macros on lists" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    // filter
    {
        var program = try checker.compile(std.testing.allocator, &environment, "[1, 2, 3, 4, 5].filter(x, x > 3)");
        defer program.deinit();
        var result = try eval(std.testing.allocator, &program, &activation);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result == .list);
        try std.testing.expectEqual(@as(usize, 2), result.list.items.len);
        try std.testing.expectEqual(@as(i64, 4), result.list.items[0].int);
        try std.testing.expectEqual(@as(i64, 5), result.list.items[1].int);
    }

    // map
    {
        var program = try checker.compile(std.testing.allocator, &environment, "[1, 2, 3].map(x, x * 10)");
        defer program.deinit();
        var result = try eval(std.testing.allocator, &program, &activation);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result == .list);
        try std.testing.expectEqual(@as(usize, 3), result.list.items.len);
        try std.testing.expectEqual(@as(i64, 10), result.list.items[0].int);
        try std.testing.expectEqual(@as(i64, 20), result.list.items[1].int);
        try std.testing.expectEqual(@as(i64, 30), result.list.items[2].int);
    }
}

test "eval optional chaining with .?" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: i64 }{
        .{ .expr = "{}.?c.orValue(42)", .expected = 42 },
        .{ .expr = "{'c': 10}.?c.orValue(42)", .expected = 10 },
        .{ .expr = "{'c': 0}.?c.orValue(99)", .expected = 0 },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval(std.testing.allocator, &program, &activation);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.int);
    }
}

test "type coercion functions" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct {
        expr: []const u8,
        check: enum { int_val, uint_val, double_val, string_val, bool_val },
        expected_int: i64 = 0,
        expected_uint: u64 = 0,
        expected_double: f64 = 0.0,
        expected_string: []const u8 = "",
        expected_bool: bool = false,
    }{
        .{ .expr = "int(2.5)", .check = .int_val, .expected_int = 2 },
        .{ .expr = "int('42')", .check = .int_val, .expected_int = 42 },
        .{ .expr = "uint(42)", .check = .uint_val, .expected_uint = 42 },
        .{ .expr = "double(10)", .check = .double_val, .expected_double = 10.0 },
        .{ .expr = "string(123)", .check = .string_val, .expected_string = "123" },
        .{ .expr = "string(true)", .check = .string_val, .expected_string = "true" },
    };

    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval(std.testing.allocator, &program, &activation);
        defer result.deinit(std.testing.allocator);
        switch (case.check) {
            .int_val => try std.testing.expectEqual(case.expected_int, result.int),
            .uint_val => try std.testing.expectEqual(case.expected_uint, result.uint),
            .double_val => try std.testing.expectEqual(case.expected_double, result.double),
            .string_val => try std.testing.expectEqualStrings(case.expected_string, result.string),
            .bool_val => try std.testing.expectEqual(case.expected_bool, result.bool),
        }
    }
}

test "size() on string, list, map, bytes" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addVarTyped("b", environment.types.builtins.bytes_type);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.putBytes("b", "abc");

    const cases = [_]struct { expr: []const u8, expected: i64 }{
        .{ .expr = "size('hello')", .expected = 5 },
        .{ .expr = "size('')", .expected = 0 },
        .{ .expr = "size([1, 2, 3])", .expected = 3 },
        .{ .expr = "size([])", .expected = 0 },
        .{ .expr = "size({'a': 1, 'b': 2})", .expected = 2 },
        .{ .expr = "size({})", .expected = 0 },
        .{ .expr = "size(b)", .expected = 3 },
    };

    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval(std.testing.allocator, &program, &activation);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.int);
    }
}

test "contains, startsWith, endsWith on strings" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        .{ .expr = "'hello world'.contains('world')", .expected = true },
        .{ .expr = "'hello world'.contains('xyz')", .expected = false },
        .{ .expr = "'hello'.startsWith('hel')", .expected = true },
        .{ .expr = "'hello'.startsWith('xyz')", .expected = false },
        .{ .expr = "'hello'.endsWith('llo')", .expected = true },
        .{ .expr = "'hello'.endsWith('xyz')", .expected = false },
        .{ .expr = "''.contains('')", .expected = true },
        .{ .expr = "'hello'.startsWith('')", .expected = true },
        .{ .expr = "'hello'.endsWith('')", .expected = true },
    };

    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval(std.testing.allocator, &program, &activation);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.bool);
    }
}

test "eval matches() regex" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        .{ .expr = "'hello'.matches('hello')", .expected = true },
        .{ .expr = "'hello'.matches('x')", .expected = false },
        .{ .expr = "'hello'.matches('h.*o')", .expected = true },
        .{ .expr = "'hello'.matches('hel.*')", .expected = true },
        .{ .expr = "'hello'.matches('.*llo')", .expected = true },
        .{ .expr = "'hello'.matches('world')", .expected = false },
        .{ .expr = "''.matches('')", .expected = true },
        .{ .expr = "'abc'.matches('a.c')", .expected = true },
        .{ .expr = "'abc'.matches('a.d')", .expected = false },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval(std.testing.allocator, &program, &activation);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.bool);
    }
}

test "eval boolean expressions on various types" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        // deeply nested arithmetic
        .{ .expr = "((((1 + 2) * 3) - 4) / 5) == 1", .expected = true },
        // empty list/map operations
        .{ .expr = "size([]) == 0", .expected = true },
        .{ .expr = "size({}) == 0", .expected = true },
        .{ .expr = "[] + [1] == [1]", .expected = true },
        .{ .expr = "[].all(x, x > 0)", .expected = true },
        .{ .expr = "[].exists(x, x > 0)", .expected = false },
        // unary
        .{ .expr = "!false", .expected = true },
        .{ .expr = "!true", .expected = false },
        .{ .expr = "!!true", .expected = true },
        // null equality
        .{ .expr = "null == null", .expected = true },
        .{ .expr = "null != null", .expected = false },
        // timestamp/duration comparisons
        .{ .expr = "duration('1h') > duration('30m')", .expected = true },
        .{ .expr = "timestamp('2023-01-02T00:00:00Z') > timestamp('2023-01-01T00:00:00Z')", .expected = true },
        .{ .expr = "timestamp('2023-01-01T00:00:00Z') + duration('24h') == timestamp('2023-01-02T00:00:00Z')", .expected = true },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval(std.testing.allocator, &program, &activation);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.bool);
    }
}

test "eval comparison and membership operators" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        // int comparisons
        .{ .expr = "1 < 2", .expected = true },
        .{ .expr = "2 < 1", .expected = false },
        .{ .expr = "2 <= 2", .expected = true },
        .{ .expr = "3 > 2", .expected = true },
        .{ .expr = "3 >= 3", .expected = true },
        .{ .expr = "1 == 1", .expected = true },
        .{ .expr = "1 != 2", .expected = true },
        .{ .expr = "1 == 2", .expected = false },
        .{ .expr = "1 != 1", .expected = false },
        // string comparisons
        .{ .expr = "'a' < 'b'", .expected = true },
        .{ .expr = "'abc' == 'abc'", .expected = true },
        .{ .expr = "'abc' != 'def'", .expected = true },
        // double comparisons
        .{ .expr = "1.0 < 2.0", .expected = true },
        .{ .expr = "1.0 == 1.0", .expected = true },
        // bool comparisons
        .{ .expr = "true == true", .expected = true },
        .{ .expr = "true != false", .expected = true },
        .{ .expr = "false == false", .expected = true },
        // in operator
        .{ .expr = "2 in [1, 2, 3]", .expected = true },
        .{ .expr = "5 in [1, 2, 3]", .expected = false },
        .{ .expr = "'a' in {'a': 1}", .expected = true },
        .{ .expr = "'z' in {'a': 1}", .expected = false },
        .{ .expr = "1 in []", .expected = false },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval(std.testing.allocator, &program, &activation);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.bool);
    }
}

test "evalWithScratch reuses scratch across evaluations" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var program = try checker.compile(std.testing.allocator, &environment, "1 + 2");
    defer program.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var scratch = EvalScratch.init(std.testing.allocator);
    defer scratch.deinit();

    // First evaluation
    {
        var result = try evalWithScratch(&scratch, &program, &activation);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(i64, 3), result.int);
    }

    // Second evaluation with same scratch
    {
        var result = try evalWithScratch(&scratch, &program, &activation);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(i64, 3), result.int);
    }
}

test "exhaustive eval returns same results as normal eval" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const bt = environment.types.builtins;
    try environment.addVarTyped("x", bt.int_type);
    try environment.addVarTyped("y", bt.int_type);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.put("x", .{ .int = 10 });
    try activation.put("y", .{ .int = 20 });

    const cases = [_]struct { expr: []const u8, expected_int: ?i64 = null, expected_bool: ?bool = null }{
        .{ .expr = "1 + 2", .expected_int = 3 },
        .{ .expr = "true || false", .expected_bool = true },
        .{ .expr = "false && true", .expected_bool = false },
        .{ .expr = "true ? 1 : 2", .expected_int = 1 },
        .{ .expr = "false ? 1 : 2", .expected_int = 2 },
        .{ .expr = "x + y", .expected_int = 30 },
        .{ .expr = "x > 5", .expected_bool = true },
        .{ .expr = "true && true", .expected_bool = true },
        .{ .expr = "false || false", .expected_bool = false },
        .{ .expr = "true || true", .expected_bool = true },
        .{ .expr = "false && false", .expected_bool = false },
        .{ .expr = "true ? x : y", .expected_int = 10 },
        .{ .expr = "false ? x : y", .expected_int = 20 },
        .{ .expr = "1 + 2 + 3", .expected_int = 6 },
        .{ .expr = "x == 10", .expected_bool = true },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var normal = try eval(std.testing.allocator, &program, &activation);
        defer normal.deinit(std.testing.allocator);

        var exhaustive_result = try evalWithOptions(std.testing.allocator, &program, &activation, .{
            .exhaustive = true,
        });
        defer exhaustive_result.deinit(std.testing.allocator);

        if (case.expected_int) |expected| {
            try std.testing.expectEqual(expected, normal.int);
            try std.testing.expectEqual(expected, exhaustive_result.int);
        }
        if (case.expected_bool) |expected| {
            try std.testing.expectEqual(expected, normal.bool);
            try std.testing.expectEqual(expected, exhaustive_result.bool);
        }
    }
}

test "exhaustive eval evaluates both branches of logical or when left is true" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const bt = environment.types.builtins;
    try environment.addVarTyped("x", bt.int_type);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.put("x", .{ .int = 5 });

    var program = try checker.compile(std.testing.allocator, &environment, "true || x > 0");
    defer program.deinit();

    var result = try evalWithOptions(std.testing.allocator, &program, &activation, .{
        .exhaustive = true,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(true, result.bool);
}

test "exhaustive eval evaluates both branches of logical and when left is false" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const bt = environment.types.builtins;
    try environment.addVarTyped("x", bt.int_type);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.put("x", .{ .int = 5 });

    var program = try checker.compile(std.testing.allocator, &environment, "false && x > 0");
    defer program.deinit();

    var result = try evalWithOptions(std.testing.allocator, &program, &activation, .{
        .exhaustive = true,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(false, result.bool);
}

test "exhaustive eval evaluates both branches of ternary" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const bt = environment.types.builtins;
    try environment.addVarTyped("x", bt.int_type);
    try environment.addVarTyped("y", bt.int_type);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.put("x", .{ .int = 10 });
    try activation.put("y", .{ .int = 20 });

    {
        var program = try checker.compile(std.testing.allocator, &environment, "true ? x : y");
        defer program.deinit();

        var result = try evalWithOptions(std.testing.allocator, &program, &activation, .{
            .exhaustive = true,
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(i64, 10), result.int);
    }

    {
        var program = try checker.compile(std.testing.allocator, &environment, "false ? x : y");
        defer program.deinit();

        var result = try evalWithOptions(std.testing.allocator, &program, &activation, .{
            .exhaustive = true,
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(i64, 20), result.int);
    }
}

test "exhaustive eval still produces correct result with chained logical ops" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const bt = environment.types.builtins;
    try environment.addVarTyped("a", bt.bool_type);
    try environment.addVarTyped("bv", bt.bool_type);
    try environment.addVarTyped("c", bt.bool_type);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    try activation.put("a", .{ .bool = true });
    try activation.put("bv", .{ .bool = false });
    try activation.put("c", .{ .bool = true });

    const cases = [_]struct { expr: []const u8, expected: bool }{
        .{ .expr = "a || bv || c", .expected = true },
        .{ .expr = "a && bv && c", .expected = false },
        .{ .expr = "a || bv && c", .expected = true },
        .{ .expr = "(a || bv) && c", .expected = true },
        .{ .expr = "a && (bv || c)", .expected = true },
        .{ .expr = "!bv || a", .expected = true },
        .{ .expr = "bv && a", .expected = false },
    };
    for (cases) |case| {
        var program = try checker.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();

        var result = try evalWithOptions(std.testing.allocator, &program, &activation, .{
            .exhaustive = true,
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.bool);
    }
}

test "eval options compose" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var program = try checker.compile(std.testing.allocator, &environment, "true || false");
    defer program.deinit();

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var counter = NodeCounter{};
    var tracer = TraceCollector.init(std.testing.allocator);
    defer tracer.deinit();

    const decorators = [_]Decorator{ counter.decorator(), tracer.decorator() };
    var result = try evalWithOptions(std.testing.allocator, &program, &activation, .{
        .budget = 8,
        .deadline_ns = std.time.ns_per_s,
        .exhaustive = true,
        .decorators = &decorators,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result == .bool);
    try std.testing.expect(result.bool);
    try std.testing.expectEqual(@as(u64, 3), counter.count);
    try std.testing.expectEqual(@as(usize, 3), tracer.entries.items.len);
}

test "host type adapter with field access via getField vtable" {
    const Point = struct { x: i64, y: i64 };

    const PointHelpers = struct {
        fn asConst(ptr: *const anyopaque) *const Point {
            return @ptrCast(@alignCast(ptr));
        }
        fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) std.mem.Allocator.Error!*anyopaque {
            const out = try allocator.create(Point);
            out.* = asConst(ptr).*;
            return out;
        }
        fn deinit_fn(allocator: std.mem.Allocator, ptr: *anyopaque) void {
            const p: *Point = @ptrCast(@alignCast(ptr));
            allocator.destroy(p);
        }
        fn eql(lhs: *const anyopaque, rhs: *const anyopaque) bool {
            const a = asConst(lhs);
            const b = asConst(rhs);
            return a.x == b.x and a.y == b.y;
        }
        fn getField(_: std.mem.Allocator, ptr: *const anyopaque, field: []const u8) value.RuntimeError!?value.Value {
            const p = asConst(ptr);
            if (std.mem.eql(u8, field, "x")) return .{ .int = p.x };
            if (std.mem.eql(u8, field, "y")) return .{ .int = p.y };
            return null;
        }

        const vtable = value.HostValueVTable{
            .type_name = "test.Point",
            .clone = clone,
            .deinit = deinit_fn,
            .eql = eql,
            .getField = getField,
        };
    };

    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    const point_ty = try environment.addHostTypeFromVTable(&PointHelpers.vtable);
    try environment.addVarTyped("p", point_ty);

    // Register fields for type checking
    try environment.addMessageField("test.Point", "x", environment.types.builtins.int_type);
    try environment.addMessageField("test.Point", "y", environment.types.builtins.int_type);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const ptr = try std.testing.allocator.create(Point);
    ptr.* = .{ .x = 10, .y = 20 };
    try activation.put("p", value.hostValue(ptr, &PointHelpers.vtable));
    std.testing.allocator.destroy(ptr);

    // Field access works
    {
        var program = try checker.compile(std.testing.allocator, &environment, "p.x + p.y");
        defer program.deinit();
        var result = try eval(std.testing.allocator, &program, &activation);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(i64, 30), result.int);
    }
    // Comparison using fields
    {
        var program = try checker.compile(std.testing.allocator, &environment, "p.x < p.y");
        defer program.deinit();
        var result = try eval(std.testing.allocator, &program, &activation);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(true, result.bool);
    }
}
