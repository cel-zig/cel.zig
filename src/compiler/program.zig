const std = @import("std");
const ast = @import("../parse/ast.zig");
const env = @import("../env/env.zig");
const eval_mod = @import("../eval/eval.zig");
const activation_mod = @import("../eval/activation.zig");
const strings = @import("../parse/string_table.zig");
const types = @import("../env/types.zig");
const value = @import("../env/value.zig");

pub const MacroCall = enum {
    has,
    bind,
    block,
    all,
    exists,
    exists_one,
    opt_map,
    opt_flat_map,
    map,
    map_filter,
    sort_by,
    filter,
    transform_list,
    transform_list_filter,
    transform_map,
    transform_map_filter,
    transform_map_entry,
    transform_map_entry_filter,
};

pub const BindingRef = union(enum) {
    ident: strings.StringTable.Id,
    iter_var: struct {
        depth: u32,
        slot: u32,
    },
    block_index: struct {
        depth: u32,
        index: u32,
    },
};

pub const CallResolution = union(enum) {
    none,
    macro: MacroCall,
    enum_ctor: types.TypeRef,
    iter_var: struct {
        depth: u32,
        slot: u32,
    },
    block_index: struct {
        depth: u32,
        index: u32,
    },
    custom: struct {
        ref: env.ResolutionRef,
        receiver_style: bool,
    },
    dynamic: struct {
        ref: env.ResolutionRef,
        receiver_style: bool,
    },
};

pub const Program = struct {
    env: *const env.Env,
    ast: ast.Ast,
    analysis_allocator: std.mem.Allocator,
    call_resolution: std.ArrayListUnmanaged(CallResolution) = .empty,
    operator_resolution: std.ArrayListUnmanaged(?env.ResolutionRef) = .empty,
    result_type: types.TypeRef,
    /// Precompiled data for dynamic function calls, indexed by AST node.
    /// Populated by the precompileArguments optimizer pass. null means no
    /// precompiled data for that node.
    prepared: std.ArrayListUnmanaged(?env.PreparedContext) = .empty,

    pub fn deinit(self: *Program) void {
        for (self.prepared.items) |maybe| {
            if (maybe) |ctx| ctx.destroy(self.analysis_allocator, ctx.ptr);
        }
        self.prepared.deinit(self.analysis_allocator);
        self.ast.deinit();
        self.call_resolution.deinit(self.analysis_allocator);
        self.operator_resolution.deinit(self.analysis_allocator);
    }

    pub fn outputType(self: *const Program, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return formatTypeRef(allocator, self.env.types, self.result_type);
    }

    fn formatTypeRef(allocator: std.mem.Allocator, provider: *const types.TypeProvider, ref: types.TypeRef) std.mem.Allocator.Error![]u8 {
        const spec = provider.spec(ref);
        return switch (spec) {
            .dyn => allocator.dupe(u8, "dyn"),
            .null_type => allocator.dupe(u8, "null_type"),
            .bool => allocator.dupe(u8, "bool"),
            .int => allocator.dupe(u8, "int"),
            .uint => allocator.dupe(u8, "uint"),
            .double => allocator.dupe(u8, "double"),
            .string => allocator.dupe(u8, "string"),
            .bytes => allocator.dupe(u8, "bytes"),
            .type_type => allocator.dupe(u8, "type"),
            .list => |elem| {
                const inner = try formatTypeRef(allocator, provider, elem);
                defer allocator.free(inner);
                return std.fmt.allocPrint(allocator, "list({s})", .{inner});
            },
            .map => |m| {
                const key = try formatTypeRef(allocator, provider, m.key);
                defer allocator.free(key);
                const val = try formatTypeRef(allocator, provider, m.value);
                defer allocator.free(val);
                return std.fmt.allocPrint(allocator, "map({s}, {s})", .{ key, val });
            },
            .wrapper => |inner| {
                const wrapped = try formatTypeRef(allocator, provider, inner);
                defer allocator.free(wrapped);
                return std.fmt.allocPrint(allocator, "wrapper({s})", .{wrapped});
            },
            .message => |name| allocator.dupe(u8, name),
            .enum_type => |name| allocator.dupe(u8, name),
            .host_scalar => |name| allocator.dupe(u8, name),
            .abstract => |a| allocator.dupe(u8, a.name),
            .type_param => |name| allocator.dupe(u8, name),
        };
    }

    pub fn evaluate(
        self: *const Program,
        allocator: std.mem.Allocator,
        context: anytype,
        options: eval_mod.EvalOptions,
    ) env.EvalError!value.Value {
        const Context = @TypeOf(context);
        if (Context == *const activation_mod.Activation or Context == *activation_mod.Activation) {
            return eval_mod.evalWithOptions(allocator, self, context, options);
        } else {
            const fields = @typeInfo(Context).@"struct".fields;
            var activation = activation_mod.Activation.init(allocator);
            defer activation.deinit();
            inline for (fields) |field| {
                const val = @field(context, field.name);
                try putFieldValue(&activation, allocator, field.name, field.type, val);
            }
            return eval_mod.evalWithOptions(allocator, self, &activation, options);
        }
    }

    fn putFieldValue(
        activation: *activation_mod.Activation,
        allocator: std.mem.Allocator,
        name: []const u8,
        comptime T: type,
        val: T,
    ) !void {
        switch (@typeInfo(T)) {
            .int, .comptime_int => try activation.put(name, .{ .int = @intCast(val) }),
            .float, .comptime_float => try activation.put(name, .{ .double = @floatCast(val) }),
            .bool => try activation.put(name, .{ .bool = val }),
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    try activation.putString(name, val);
                } else if (ptr_info.size == .one and @typeInfo(ptr_info.child) == .array) {
                    const child_info = @typeInfo(ptr_info.child).array;
                    if (child_info.child == u8) {
                        try activation.putString(name, val);
                    } else {
                        @compileError("unsupported field type for CEL context: " ++ @typeName(T));
                    }
                } else {
                    @compileError("unsupported field type for CEL context: " ++ @typeName(T));
                }
            },
            .@"enum" => try activation.put(name, .{ .int = @intFromEnum(val) }),
            .optional => {
                if (val) |v| {
                    try putFieldValue(activation, allocator, name, @TypeOf(v), v);
                } else {
                    try activation.put(name, .null);
                }
            },
            else => @compileError("unsupported field type for CEL context: " ++ @typeName(T)),
        }
    }
};

pub fn bindingRefEql(a: BindingRef, b: BindingRef) bool {
    const tag_a = std.meta.activeTag(a);
    const tag_b = std.meta.activeTag(b);
    if (tag_a != tag_b) return false;

    return switch (a) {
        .ident => a.ident == b.ident,
        .iter_var => a.iter_var.depth == b.iter_var.depth and a.iter_var.slot == b.iter_var.slot,
        .block_index => a.block_index.depth == b.block_index.depth and a.block_index.index == b.block_index.index,
    };
}

pub fn bindingMatchesIdent(binding: BindingRef, id: strings.StringTable.Id) bool {
    return switch (binding) {
        .ident => |binding_id| binding_id == id,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "bindingRefEql - same tag same values" {
    const cases = [_]struct { a: BindingRef, b: BindingRef, expected: bool }{
        .{ .a = .{ .ident = @enumFromInt(1) }, .b = .{ .ident = @enumFromInt(1) }, .expected = true },
        .{ .a = .{ .ident = @enumFromInt(1) }, .b = .{ .ident = @enumFromInt(2) }, .expected = false },
        .{ .a = .{ .iter_var = .{ .depth = 0, .slot = 0 } }, .b = .{ .iter_var = .{ .depth = 0, .slot = 0 } }, .expected = true },
        .{ .a = .{ .iter_var = .{ .depth = 0, .slot = 0 } }, .b = .{ .iter_var = .{ .depth = 1, .slot = 0 } }, .expected = false },
        .{ .a = .{ .iter_var = .{ .depth = 0, .slot = 0 } }, .b = .{ .iter_var = .{ .depth = 0, .slot = 1 } }, .expected = false },
        .{ .a = .{ .block_index = .{ .depth = 3, .index = 7 } }, .b = .{ .block_index = .{ .depth = 3, .index = 7 } }, .expected = true },
        .{ .a = .{ .block_index = .{ .depth = 3, .index = 7 } }, .b = .{ .block_index = .{ .depth = 3, .index = 8 } }, .expected = false },
    };

    for (cases) |c| {
        try std.testing.expectEqual(c.expected, bindingRefEql(c.a, c.b));
    }
}

test "bindingRefEql - different tags always false" {
    const cases = [_]struct { a: BindingRef, b: BindingRef }{
        .{ .a = .{ .ident = @enumFromInt(0) }, .b = .{ .iter_var = .{ .depth = 0, .slot = 0 } } },
        .{ .a = .{ .ident = @enumFromInt(0) }, .b = .{ .block_index = .{ .depth = 0, .index = 0 } } },
        .{ .a = .{ .iter_var = .{ .depth = 0, .slot = 0 } }, .b = .{ .block_index = .{ .depth = 0, .index = 0 } } },
    };

    for (cases) |c| {
        try std.testing.expectEqual(false, bindingRefEql(c.a, c.b));
    }
}

test "bindingMatchesIdent - ident variant matches" {
    const id_a: strings.StringTable.Id = @enumFromInt(5);
    const id_b: strings.StringTable.Id = @enumFromInt(6);

    const cases = [_]struct { binding: BindingRef, id: strings.StringTable.Id, expected: bool }{
        .{ .binding = .{ .ident = id_a }, .id = id_a, .expected = true },
        .{ .binding = .{ .ident = id_a }, .id = id_b, .expected = false },
        .{ .binding = .{ .iter_var = .{ .depth = 0, .slot = 0 } }, .id = id_a, .expected = false },
        .{ .binding = .{ .block_index = .{ .depth = 0, .index = 0 } }, .id = id_a, .expected = false },
    };

    for (cases) |c| {
        try std.testing.expectEqual(c.expected, bindingMatchesIdent(c.binding, c.id));
    }
}

test "CallResolution variants are distinct tags" {
    const variants = [_]CallResolution{
        .none,
        .{ .macro = .has },
        .{ .iter_var = .{ .depth = 0, .slot = 0 } },
        .{ .block_index = .{ .depth = 0, .index = 0 } },
    };

    for (variants, 0..) |a, i| {
        for (variants, 0..) |b, j| {
            const same = std.meta.activeTag(a) == std.meta.activeTag(b);
            try std.testing.expectEqual(i == j, same);
        }
    }
}

test "MacroCall enum has expected members" {
    // Verify the enum can be exhaustively switched over with all expected variants.
    const expected_names = [_][]const u8{
        "has",          "bind",           "block",               "all",
        "exists",       "exists_one",     "opt_map",             "opt_flat_map",
        "map",          "map_filter",     "sort_by",             "filter",
        "transform_list", "transform_list_filter", "transform_map", "transform_map_filter",
        "transform_map_entry", "transform_map_entry_filter",
    };

    inline for (expected_names) |name| {
        _ = @field(MacroCall, name);
    }
    // Count: the enum should have exactly this many members.
    const info = @typeInfo(MacroCall);
    try std.testing.expectEqual(expected_names.len, info.@"enum".fields.len);
}

test "Program.deinit does not leak on empty program" {
    const allocator = std.testing.allocator;
    var environment = try env.Env.initDefault(allocator);
    defer environment.deinit();

    var prog = Program{
        .env = &environment,
        .ast = .{
            .allocator = allocator,
        },
        .analysis_allocator = allocator,
        .result_type = environment.types.builtins.dyn_type,
    };
    prog.deinit();
    // If we reach here without a leak, the test passes (testing.allocator checks leaks).
}
