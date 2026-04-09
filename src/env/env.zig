const std = @import("std");
const ast = @import("../parse/ast.zig");
const checker = @import("../checker/check.zig");
const schema = @import("schema.zig");
const types = @import("types.zig");
const value = @import("value.zig");

pub const EvalError = std.mem.Allocator.Error || value.RuntimeError || error{
    UndefinedVariable,
    CostBudgetExceeded,
    DeadlineExceeded,
};

pub const FunctionImpl = *const fn (
    allocator: std.mem.Allocator,
    args: []const value.Value,
) EvalError!value.Value;

pub const Overload = struct {
    name: []const u8,
    receiver_style: bool,
    params: []types.TypeRef,
    result: types.TypeRef,
    implementation: FunctionImpl,
};

pub const DynamicMatcher = *const fn (
    environment: *const Env,
    params: []const types.TypeRef,
) ?types.TypeRef;

pub const DynamicFunction = struct {
    name: []const u8,
    receiver_style: bool,
    match: DynamicMatcher,
    implementation: FunctionImpl,
};

pub const ResolutionRef = struct {
    depth: u32,
    index: u32,
};

pub const DynamicResolution = struct {
    ref: ResolutionRef,
    result: types.TypeRef,
};

pub const EnumMode = enum {
    legacy,
    strong,
};

pub const EnumValueDecl = types.EnumValueDecl;
pub const EnumDecl = types.EnumDecl;

pub const Constant = struct {
    ty: types.TypeRef,
    value: value.Value,
};

pub const LibraryInstaller = *const fn (environment: *Env) anyerror!void;

pub const Library = struct {
    name: []const u8,
    install: LibraryInstaller,
};

pub const EnvOption = union(enum) {
    variable: struct {
        name: []const u8,
        type: types.Type,
    },
    constant: struct {
        name: []const u8,
        type: types.Type,
        value: value.Value,
    },
    library: Library,
    container: []const u8,
    enum_mode: EnumMode,
    object: struct {
        name: []const u8,
        fields: []const types.ObjectField,
    },
    custom_types: *types.TypeProvider,
};

pub const Env = struct {
    allocator: std.mem.Allocator,
    types: *types.TypeProvider,
    owns_types: bool = false,
    parent: ?*const Env = null,
    enum_mode: EnumMode = .legacy,
    container: ?[]u8 = null,
    variables: std.StringHashMapUnmanaged(types.TypeRef) = .empty,
    constants: std.StringHashMapUnmanaged(Constant) = .empty,
    overloads: std.ArrayListUnmanaged(Overload) = .empty,
    dynamic_functions: std.ArrayListUnmanaged(DynamicFunction) = .empty,
    libraries: std.StringHashMapUnmanaged(void) = .empty,

    pub fn initDefault(allocator: std.mem.Allocator) !Env {
        return init(allocator, &.{});
    }

    pub fn init(allocator: std.mem.Allocator, options: []const EnvOption) !Env {
        // Check for a custom type provider
        var custom_provider: ?*types.TypeProvider = null;
        for (options) |opt| {
            switch (opt) {
                .custom_types => |tp| {
                    custom_provider = tp;
                    break;
                },
                else => {},
            }
        }

        var provider: *types.TypeProvider = undefined;
        var owns_types: bool = undefined;
        if (custom_provider) |cp| {
            provider = cp;
            owns_types = false;
        } else {
            provider = try allocator.create(types.TypeProvider);
            provider.* = try types.TypeProvider.init(allocator);
            owns_types = true;
        }
        errdefer if (owns_types) {
            provider.deinit();
            allocator.destroy(provider);
        };

        var environment: Env = .{
            .allocator = allocator,
            .types = provider,
            .owns_types = owns_types,
        };
        errdefer environment.deinit();

        if (owns_types) {
            try registerWellKnownTypes(&environment);
        }

        for (options) |opt| {
            switch (opt) {
                .object => |obj| _ = try environment.types.defineMessage(obj.name, obj.fields),
                .variable => |v| {
                    const resolved = try v.type.resolve(environment.types);
                    try environment.addVarTyped(v.name, resolved);
                },
                .constant => |c| {
                    const resolved = try c.type.resolve(environment.types);
                    try environment.addConst(c.name, resolved, c.value);
                },
                .library => |lib| try environment.addLibrary(lib),
                .container => |scope| try environment.setContainer(scope),
                .enum_mode => |mode| environment.setEnumMode(mode),
                .custom_types => {},
            }
        }

        return environment;
    }

    pub fn initWithProvider(allocator: std.mem.Allocator, provider: *types.TypeProvider) Env {
        return .{
            .allocator = allocator,
            .types = provider,
            .owns_types = false,
        };
    }

    pub fn extend(self: *const Env, allocator: std.mem.Allocator) !Env {
        const child_types = try allocator.create(types.TypeProvider);
        child_types.* = self.types.extend(allocator);

        return .{
            .allocator = allocator,
            .types = child_types,
            .owns_types = true,
            .parent = self,
            .enum_mode = self.enum_mode,
            .container = if (self.container) |container| try allocator.dupe(u8, container) else null,
        };
    }

    pub fn deinit(self: *Env) void {
        if (self.container) |container| {
            self.allocator.free(container);
        }
        var vars_it = self.variables.iterator();
        while (vars_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.variables.deinit(self.allocator);
        var consts_it = self.constants.iterator();
        while (consts_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.value.deinit(self.allocator);
        }
        self.constants.deinit(self.allocator);

        for (self.overloads.items) |overload| {
            self.allocator.free(overload.name);
            self.allocator.free(overload.params);
        }
        self.overloads.deinit(self.allocator);
        for (self.dynamic_functions.items) |fn_decl| {
            self.allocator.free(fn_decl.name);
        }
        self.dynamic_functions.deinit(self.allocator);
        var libs_it = self.libraries.iterator();
        while (libs_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.libraries.deinit(self.allocator);
        if (self.owns_types) {
            self.types.deinit();
            self.allocator.destroy(self.types);
        }
    }

    pub fn setEnumMode(self: *Env, mode: EnumMode) void {
        self.enum_mode = mode;
    }

    pub fn setContainer(self: *Env, scope: ?[]const u8) !void {
        if (self.container) |existing| {
            self.allocator.free(existing);
            self.container = null;
        }
        if (scope) |name| {
            self.container = try self.allocator.dupe(u8, name);
        }
    }

    pub fn addHostType(self: *Env, name: []const u8) !types.TypeRef {
        return self.types.hostScalarOf(name);
    }

    pub fn addHostTypeFromVTable(self: *Env, vtable: *const value.HostValueVTable) !types.TypeRef {
        return self.addHostType(vtable.type_name);
    }

    pub fn addEnum(self: *Env, name: []const u8) !types.TypeRef {
        const enum_ty = try self.types.addEnum(name);
        if (self.enum_mode == .strong) {
            // Only add the const if we haven't already (avoid double-add on idempotent calls)
            if (self.lookupConst(name) == null) {
                try self.addConst(name, self.types.builtins.type_type, try value.typeNameValue(self.allocator, name));
            }
        }
        return enum_ty;
    }

    pub fn addEnumValue(self: *Env, enum_name: []const u8, member_name: []const u8, raw_value: i32) !void {
        const enum_ty = try self.addEnum(enum_name);
        const idx = self.types.enum_index.get(enum_name) orelse unreachable;
        try self.types.enums.items[idx].addValue(member_name, raw_value);

        const full_name = self.types.enums.items[idx].lookupValueName(member_name).?.full_name;
        if (self.enum_mode == .strong) {
            try self.addConst(full_name, enum_ty, try value.enumValue(self.allocator, enum_name, raw_value));
        } else {
            try self.addConst(full_name, self.types.builtins.int_type, .{ .int = raw_value });
        }
    }

    pub fn addVar(self: *Env, name: []const u8, typ: types.Type) !void {
        const resolved = try typ.resolve(self.types);
        return self.addVarTyped(name, resolved);
    }

    pub fn addVarTyped(self: *Env, name: []const u8, ty: types.TypeRef) !void {
        const gop = try self.variables.getOrPut(self.allocator, name);
        if (gop.found_existing) {
            gop.value_ptr.* = ty;
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, name);
            gop.value_ptr.* = ty;
        }
    }

    pub fn lookupVar(self: *const Env, name: []const u8) ?types.TypeRef {
        return self.variables.get(name) orelse if (self.parent) |parent| parent.lookupVar(name) else null;
    }

    pub fn addConst(self: *Env, name: []const u8, ty: types.TypeRef, constant: value.Value) !void {
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        errdefer {
            var temp = constant;
            temp.deinit(self.allocator);
        }
        try self.constants.put(self.allocator, owned, .{
            .ty = ty,
            .value = constant,
        });
    }

    pub fn lookupConst(self: *const Env, name: []const u8) ?Constant {
        return self.constants.get(name) orelse if (self.parent) |parent| parent.lookupConst(name) else null;
    }

    pub fn lookupEnum(self: *const Env, name: []const u8) ?*const EnumDecl {
        return self.types.lookupEnum(name);
    }

    pub fn lookupVarScoped(
        self: *const Env,
        allocator: std.mem.Allocator,
        name: []const u8,
        absolute: bool,
    ) !?types.TypeRef {
        var candidate_storage: std.ArrayListUnmanaged(u8) = .empty;
        defer candidate_storage.deinit(allocator);
        var small_buffer: [256]u8 = undefined;

        if (!absolute and self.container != null and self.container.?.len != 0) {
            var prefix_len = self.container.?.len;
            while (true) {
                const candidate = try buildScopedName(
                    allocator,
                    &candidate_storage,
                    small_buffer[0..],
                    self.container.?[0..prefix_len],
                    name,
                );
                if (self.lookupVar(candidate)) |resolved| return resolved;

                prefix_len = std.mem.lastIndexOfScalar(u8, self.container.?[0..prefix_len], '.') orelse break;
            }
        }
        return self.lookupVar(name);
    }

    pub fn lookupConstScoped(
        self: *const Env,
        allocator: std.mem.Allocator,
        name: []const u8,
        absolute: bool,
    ) !?Constant {
        var candidate_storage: std.ArrayListUnmanaged(u8) = .empty;
        defer candidate_storage.deinit(allocator);
        var small_buffer: [256]u8 = undefined;

        if (!absolute and self.container != null and self.container.?.len != 0) {
            var prefix_len = self.container.?.len;
            while (true) {
                const candidate = try buildScopedName(
                    allocator,
                    &candidate_storage,
                    small_buffer[0..],
                    self.container.?[0..prefix_len],
                    name,
                );
                if (self.lookupConst(candidate)) |resolved| return resolved;

                prefix_len = std.mem.lastIndexOfScalar(u8, self.container.?[0..prefix_len], '.') orelse break;
            }
        }
        return self.lookupConst(name);
    }

    pub fn lookupEnumScoped(
        self: *const Env,
        allocator: std.mem.Allocator,
        name: []const u8,
        absolute: bool,
    ) !?*const EnumDecl {
        var candidate_storage: std.ArrayListUnmanaged(u8) = .empty;
        defer candidate_storage.deinit(allocator);
        var small_buffer: [256]u8 = undefined;

        if (!absolute and self.container != null and self.container.?.len != 0) {
            var prefix_len = self.container.?.len;
            while (true) {
                const candidate = try buildScopedName(
                    allocator,
                    &candidate_storage,
                    small_buffer[0..],
                    self.container.?[0..prefix_len],
                    name,
                );
                if (self.lookupEnum(candidate)) |resolved| return resolved;

                prefix_len = std.mem.lastIndexOfScalar(u8, self.container.?[0..prefix_len], '.') orelse break;
            }
        }
        return self.lookupEnum(name);
    }

    pub fn addFunction(
        self: *Env,
        name: []const u8,
        receiver_style: bool,
        params: []const types.TypeRef,
        result: types.TypeRef,
        implementation: FunctionImpl,
    ) !u32 {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_params = try self.allocator.dupe(types.TypeRef, params);
        errdefer self.allocator.free(owned_params);

        const idx: u32 = @intCast(self.overloads.items.len);
        try self.overloads.append(self.allocator, .{
            .name = owned_name,
            .receiver_style = receiver_style,
            .params = owned_params,
            .result = result,
            .implementation = implementation,
        });
        return idx;
    }

    pub fn addDynamicFunction(
        self: *Env,
        name: []const u8,
        receiver_style: bool,
        matcher: DynamicMatcher,
        implementation: FunctionImpl,
    ) !u32 {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        const idx: u32 = @intCast(self.dynamic_functions.items.len);
        try self.dynamic_functions.append(self.allocator, .{
            .name = owned_name,
            .receiver_style = receiver_style,
            .match = matcher,
            .implementation = implementation,
        });
        return idx;
    }

    pub fn addLibrary(self: *Env, library: Library) !void {
        if (self.libraries.contains(library.name)) return;
        if (self.parent) |parent| {
            if (parent.hasLibrary(library.name)) return;
        }
        const owned_name = try self.allocator.dupe(u8, library.name);
        errdefer self.allocator.free(owned_name);
        try self.libraries.put(self.allocator, owned_name, {});
        errdefer _ = self.libraries.remove(owned_name);
        try library.install(self);
    }

    pub fn hasLibrary(self: *const Env, name: []const u8) bool {
        return self.libraries.contains(name) or if (self.parent) |parent| parent.hasLibrary(name) else false;
    }

    pub fn addUnaryOperator(
        self: *Env,
        op: ast.UnaryOp,
        operand: types.TypeRef,
        result: types.TypeRef,
        implementation: FunctionImpl,
    ) !u32 {
        return self.addFunction(unaryOperatorName(op), false, &.{operand}, result, implementation);
    }

    pub fn addBinaryOperator(
        self: *Env,
        op: ast.BinaryOp,
        lhs: types.TypeRef,
        rhs: types.TypeRef,
        result: types.TypeRef,
        implementation: FunctionImpl,
    ) !u32 {
        return self.addFunction(binaryOperatorName(op), false, &.{ lhs, rhs }, result, implementation);
    }

    pub fn findOverload(
        self: *const Env,
        name: []const u8,
        receiver_style: bool,
        params: []const types.TypeRef,
    ) ?ResolutionRef {
        for (self.overloads.items, 0..) |overload, i| {
            if (overload.receiver_style != receiver_style) continue;
            if (!std.mem.eql(u8, overload.name, name)) continue;
            if (!std.mem.eql(types.TypeRef, overload.params, params)) continue;
            return .{
                .depth = 0,
                .index = @intCast(i),
            };
        }
        if (self.parent) |parent| {
            const resolved = parent.findOverload(name, receiver_style, params) orelse return null;
            return .{
                .depth = resolved.depth + 1,
                .index = resolved.index,
            };
        }
        return null;
    }

    pub fn findDynamicFunction(
        self: *const Env,
        name: []const u8,
        receiver_style: bool,
        params: []const types.TypeRef,
    ) ?DynamicResolution {
        return self.findDynamicFunctionIn(self, 0, name, receiver_style, params);
    }

    fn findDynamicFunctionIn(
        self: *const Env,
        query_env: *const Env,
        depth: u32,
        name: []const u8,
        receiver_style: bool,
        params: []const types.TypeRef,
    ) ?DynamicResolution {
        for (self.dynamic_functions.items, 0..) |fn_decl, i| {
            if (fn_decl.receiver_style != receiver_style) continue;
            if (!std.mem.eql(u8, fn_decl.name, name)) continue;
            const result = fn_decl.match(query_env, params) orelse continue;
            return .{
                .ref = .{
                    .depth = depth,
                    .index = @intCast(i),
                },
                .result = result,
            };
        }
        const parent = self.parent orelse return null;
        return parent.findDynamicFunctionIn(query_env, depth + 1, name, receiver_style, params);
    }

    pub fn findOverloadScoped(
        self: *const Env,
        allocator: std.mem.Allocator,
        name: []const u8,
        absolute: bool,
        receiver_style: bool,
        params: []const types.TypeRef,
    ) !?ResolutionRef {
        var candidate_storage: std.ArrayListUnmanaged(u8) = .empty;
        defer candidate_storage.deinit(allocator);
        var small_buffer: [256]u8 = undefined;

        if (!absolute and self.container != null and self.container.?.len != 0) {
            var prefix_len = self.container.?.len;
            while (true) {
                const candidate = try buildScopedName(
                    allocator,
                    &candidate_storage,
                    small_buffer[0..],
                    self.container.?[0..prefix_len],
                    name,
                );
                if (self.findOverload(candidate, receiver_style, params)) |resolved| return resolved;

                prefix_len = std.mem.lastIndexOfScalar(u8, self.container.?[0..prefix_len], '.') orelse break;
            }
        }
        return self.findOverload(name, receiver_style, params);
    }

    pub fn findDynamicFunctionScoped(
        self: *const Env,
        allocator: std.mem.Allocator,
        name: []const u8,
        absolute: bool,
        receiver_style: bool,
        params: []const types.TypeRef,
    ) !?DynamicResolution {
        var candidate_storage: std.ArrayListUnmanaged(u8) = .empty;
        defer candidate_storage.deinit(allocator);
        var small_buffer: [256]u8 = undefined;

        if (!absolute and self.container != null and self.container.?.len != 0) {
            var prefix_len = self.container.?.len;
            while (true) {
                const candidate = try buildScopedName(
                    allocator,
                    &candidate_storage,
                    small_buffer[0..],
                    self.container.?[0..prefix_len],
                    name,
                );
                if (self.findDynamicFunction(candidate, receiver_style, params)) |resolved| return resolved;

                prefix_len = std.mem.lastIndexOfScalar(u8, self.container.?[0..prefix_len], '.') orelse break;
            }
        }
        return self.findDynamicFunction(name, receiver_style, params);
    }

    pub fn addMessage(self: *Env, name: []const u8) !types.TypeRef {
        return self.types.addMessage(name);
    }

    pub fn addMessageWithKind(self: *Env, name: []const u8, kind: schema.MessageKind) !types.TypeRef {
        return self.types.addMessageWithKind(name, kind);
    }

    pub fn addMessageField(self: *Env, message_name: []const u8, field_name: []const u8, ty: types.TypeRef) !void {
        return self.types.addMessageField(message_name, field_name, ty);
    }

    pub fn addProtobufField(
        self: *Env,
        message_name: []const u8,
        field_name: []const u8,
        number: u32,
        ty: types.TypeRef,
        encoding: schema.FieldEncoding,
    ) !void {
        return self.types.addProtobufField(message_name, field_name, number, ty, encoding);
    }

    pub fn addProtobufFieldWithPresence(
        self: *Env,
        message_name: []const u8,
        field_name: []const u8,
        number: u32,
        ty: types.TypeRef,
        encoding: schema.FieldEncoding,
        presence: schema.FieldPresence,
    ) !void {
        return self.types.addProtobufFieldWithPresence(message_name, field_name, number, ty, encoding, presence);
    }

    pub fn addProtobufFieldWithOptions(
        self: *Env,
        message_name: []const u8,
        field_name: []const u8,
        number: u32,
        ty: types.TypeRef,
        encoding: schema.FieldEncoding,
        presence: schema.FieldPresence,
        default_value: ?schema.FieldDefault,
    ) !void {
        return self.types.addProtobufFieldWithOptions(message_name, field_name, number, ty, encoding, presence, default_value);
    }

    pub fn lookupMessage(self: *const Env, name: []const u8) ?*const schema.MessageDecl {
        return self.types.lookupMessage(name);
    }

    pub fn lookupMessageScoped(
        self: *const Env,
        allocator: std.mem.Allocator,
        name: []const u8,
        absolute: bool,
    ) !?*const schema.MessageDecl {
        var candidate_storage: std.ArrayListUnmanaged(u8) = .empty;
        defer candidate_storage.deinit(allocator);
        var small_buffer: [256]u8 = undefined;

        if (!absolute and self.container != null and self.container.?.len != 0) {
            var prefix_len = self.container.?.len;
            while (true) {
                const candidate = try buildScopedName(
                    allocator,
                    &candidate_storage,
                    small_buffer[0..],
                    self.container.?[0..prefix_len],
                    name,
                );
                if (self.lookupMessage(candidate)) |resolved| return resolved;

                prefix_len = std.mem.lastIndexOfScalar(u8, self.container.?[0..prefix_len], '.') orelse break;
            }
        }
        return self.lookupMessage(name);
    }

    pub fn overloadAt(self: *const Env, ref: ResolutionRef) *const Overload {
        return &self.envAtDepth(ref.depth).overloads.items[ref.index];
    }

    pub fn dynamicFunctionAt(self: *const Env, ref: ResolutionRef) *const DynamicFunction {
        return &self.envAtDepth(ref.depth).dynamic_functions.items[ref.index];
    }

    fn envAtDepth(self: *const Env, depth: u32) *const Env {
        var current = self;
        var remaining = depth;
        while (remaining != 0) : (remaining -= 1) {
            current = current.parent orelse unreachable;
        }
        return current;
    }

    pub fn compile(self: *Env, source: []const u8) checker.Error!checker.Program {
        return checker.compile(self.allocator, self, source);
    }
};

pub fn unaryOperatorName(op: ast.UnaryOp) []const u8 {
    return switch (op) {
        .logical_not => "@op_not",
        .negate => "@op_negate",
    };
}

pub fn binaryOperatorName(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .logical_or => "@op_logical_or",
        .logical_and => "@op_logical_and",
        .less => "@op_less",
        .less_equal => "@op_less_equal",
        .greater => "@op_greater",
        .greater_equal => "@op_greater_equal",
        .equal => "@op_equal",
        .not_equal => "@op_not_equal",
        .in_set => "@op_in",
        .add => "@op_add",
        .subtract => "@op_subtract",
        .multiply => "@op_multiply",
        .divide => "@op_divide",
        .remainder => "@op_remainder",
    };
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

fn registerWellKnownTypes(environment: *Env) !void {
    const t = environment.types.builtins;

    _ = try environment.addMessageWithKind("google.protobuf.Timestamp", .timestamp);
    try environment.addProtobufField("google.protobuf.Timestamp", "seconds", 1, t.int_type, .{
        .singular = .{ .scalar = .int64 },
    });
    try environment.addProtobufField("google.protobuf.Timestamp", "nanos", 2, t.int_type, .{
        .singular = .{ .scalar = .int32 },
    });

    _ = try environment.addMessageWithKind("google.protobuf.Duration", .duration);
    try environment.addProtobufField("google.protobuf.Duration", "seconds", 1, t.int_type, .{
        .singular = .{ .scalar = .int64 },
    });
    try environment.addProtobufField("google.protobuf.Duration", "nanos", 2, t.int_type, .{
        .singular = .{ .scalar = .int32 },
    });

    try registerWrapperType(environment, "google.protobuf.BoolValue", .bool_wrapper, t.bool_type, .bool);
    try registerWrapperType(environment, "google.protobuf.BytesValue", .bytes_wrapper, t.bytes_type, .bytes);
    try registerWrapperType(environment, "google.protobuf.DoubleValue", .double_wrapper, t.double_type, .double);
    try registerWrapperType(environment, "google.protobuf.FloatValue", .float_wrapper, t.double_type, .float);
    try registerWrapperType(environment, "google.protobuf.Int32Value", .int32_wrapper, t.int_type, .int32);
    try registerWrapperType(environment, "google.protobuf.Int64Value", .int64_wrapper, t.int_type, .int64);
    try registerWrapperType(environment, "google.protobuf.StringValue", .string_wrapper, t.string_type, .string);
    try registerWrapperType(environment, "google.protobuf.UInt32Value", .uint32_wrapper, t.uint_type, .uint32);
    try registerWrapperType(environment, "google.protobuf.UInt64Value", .uint64_wrapper, t.uint_type, .uint64);

    _ = try environment.addMessageWithKind("google.protobuf.Any", .any);
    try environment.addProtobufField("google.protobuf.Any", "type_url", 1, t.string_type, .{
        .singular = .{ .scalar = .string },
    });
    try environment.addProtobufField("google.protobuf.Any", "value", 2, t.bytes_type, .{
        .singular = .{ .scalar = .bytes },
    });

    const dyn_list = try environment.types.listOf(t.dyn_type);
    const dyn_map = try environment.types.mapOf(t.string_type, t.dyn_type);
    const string_list = try environment.types.listOf(t.string_type);

    _ = try environment.addMessageWithKind("google.protobuf.ListValue", .list_value);
    try environment.addProtobufField("google.protobuf.ListValue", "values", 1, dyn_list, .{
        .repeated = .{
            .element = .{ .message = "google.protobuf.Value" },
        },
    });

    _ = try environment.addMessageWithKind("google.protobuf.Struct", .struct_value);
    try environment.addProtobufField("google.protobuf.Struct", "fields", 1, dyn_map, .{
        .map = .{
            .key = .string,
            .value = .{ .message = "google.protobuf.Value" },
        },
    });

    _ = try environment.addMessageWithKind("google.protobuf.Value", .value);
    try environment.addProtobufField("google.protobuf.Value", "null_value", 1, t.int_type, .{
        .singular = .{ .scalar = .enum_value },
    });
    try environment.addProtobufField("google.protobuf.Value", "number_value", 2, t.double_type, .{
        .singular = .{ .scalar = .double },
    });
    try environment.addProtobufField("google.protobuf.Value", "string_value", 3, t.string_type, .{
        .singular = .{ .scalar = .string },
    });
    try environment.addProtobufField("google.protobuf.Value", "bool_value", 4, t.bool_type, .{
        .singular = .{ .scalar = .bool },
    });
    try environment.addProtobufField("google.protobuf.Value", "struct_value", 5, dyn_map, .{
        .singular = .{ .message = "google.protobuf.Struct" },
    });
    try environment.addProtobufField("google.protobuf.Value", "list_value", 6, dyn_list, .{
        .singular = .{ .message = "google.protobuf.ListValue" },
    });

    _ = try environment.addMessageWithKind("google.protobuf.Empty", .plain);

    _ = try environment.addMessageWithKind("google.protobuf.FieldMask", .plain);
    try environment.addProtobufField("google.protobuf.FieldMask", "paths", 1, string_list, .{
        .repeated = .{
            .element = .{ .scalar = .string },
        },
    });

    try environment.addConst("google.protobuf.NullValue.NULL_VALUE", t.int_type, .{ .int = 0 });
}

fn registerWrapperType(
    environment: *Env,
    name: []const u8,
    kind: schema.MessageKind,
    ty: types.TypeRef,
    scalar: schema.ProtoScalarKind,
) !void {
    _ = try environment.addMessageWithKind(name, kind);
    try environment.addProtobufField(name, "value", 1, ty, .{
        .singular = .{ .scalar = scalar },
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn stubImpl(_: std.mem.Allocator, _: []const value.Value) EvalError!value.Value {
    return .{ .int = 0 };
}

fn stubDynamicMatcher(_: *const Env, params: []const types.TypeRef) ?types.TypeRef {
    _ = params;
    return null;
}

fn matchingDynamicMatcher(environment: *const Env, _: []const types.TypeRef) ?types.TypeRef {
    return environment.types.builtins.bool_type;
}

test "init and deinit no leaks" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    // After init, well-known types should be registered.
    try std.testing.expect(env.lookupMessage("google.protobuf.Timestamp") != null);
    try std.testing.expect(env.lookupMessage("google.protobuf.Duration") != null);
}

test "addVar and lookupVar" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    try env.addVarTyped("x", env.types.builtins.int_type);
    const result = env.lookupVar("x");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(env.types.builtins.int_type, result.?);
}

test "lookupVar returns null for missing" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    try std.testing.expect(env.lookupVar("missing") == null);
}

test "addVar duplicate name overwrites" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    try env.addVarTyped("x", env.types.builtins.int_type);
    try env.addVarTyped("x", env.types.builtins.string_type);
    const result = env.lookupVar("x").?;
    try std.testing.expectEqual(env.types.builtins.string_type, result);
}

test "addConst and lookupConst" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    try env.addConst("PI", env.types.builtins.double_type, .{ .double = 3.14 });
    const c = env.lookupConst("PI");
    try std.testing.expect(c != null);
    try std.testing.expectEqual(@as(f64, 3.14), c.?.value.double);
    try std.testing.expectEqual(env.types.builtins.double_type, c.?.ty);
}

test "lookupConst returns null for missing" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    try std.testing.expect(env.lookupConst("missing") == null);
}

test "addMessage and lookupMessage" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    _ = try env.addMessage("example.Foo");
    const msg = env.lookupMessage("example.Foo");
    try std.testing.expect(msg != null);
    try std.testing.expectEqualStrings("example.Foo", msg.?.name);
}

test "addMessage idempotent" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    const ty1 = try env.addMessage("example.Foo");
    const ty2 = try env.addMessage("example.Foo");
    try std.testing.expectEqual(ty1, ty2);
}

test "addMessageField and lookupField on message" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    _ = try env.addMessage("example.Foo");
    try env.addMessageField("example.Foo", "bar", env.types.builtins.string_type);

    const msg = env.lookupMessage("example.Foo").?;
    const field = msg.lookupField("bar");
    try std.testing.expect(field != null);
    try std.testing.expectEqualStrings("bar", field.?.name);
}

test "addMessageField auto-creates message if missing" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    try env.addMessageField("example.Auto", "field1", env.types.builtins.int_type);
    try std.testing.expect(env.lookupMessage("example.Auto") != null);
}

test "addEnum and lookupEnum" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    _ = try env.addEnum("example.Status");
    const e = env.lookupEnum("example.Status");
    try std.testing.expect(e != null);
    try std.testing.expectEqualStrings("example.Status", e.?.name);
}

test "addEnumValue stores values" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    try env.addEnumValue("example.Color", "RED", 0);
    try env.addEnumValue("example.Color", "GREEN", 1);
    try env.addEnumValue("example.Color", "BLUE", 2);

    const e = env.lookupEnum("example.Color").?;
    try std.testing.expect(e.lookupValueName("RED") != null);
    try std.testing.expect(e.lookupValueName("GREEN") != null);
    try std.testing.expect(e.lookupValueName("BLUE") != null);
    try std.testing.expect(e.lookupValueName("YELLOW") == null);

    try std.testing.expectEqual(@as(i32, 0), e.lookupValueName("RED").?.value);
    try std.testing.expectEqual(@as(i32, 2), e.lookupValueNumber(2).?.value);
}

test "addFunction and findOverload" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    _ = try env.addFunction(
        "size",
        true,
        &.{env.types.builtins.string_type},
        env.types.builtins.int_type,
        stubImpl,
    );

    const ref = env.findOverload("size", true, &.{env.types.builtins.string_type});
    try std.testing.expect(ref != null);
    try std.testing.expectEqual(@as(u32, 0), ref.?.depth);

    // Wrong receiver style.
    try std.testing.expect(env.findOverload("size", false, &.{env.types.builtins.string_type}) == null);

    // Wrong name.
    try std.testing.expect(env.findOverload("length", true, &.{env.types.builtins.string_type}) == null);

    // Wrong params.
    try std.testing.expect(env.findOverload("size", true, &.{env.types.builtins.int_type}) == null);
}

test "addDynamicFunction and findDynamicFunction" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    _ = try env.addDynamicFunction("dyn_fn", false, matchingDynamicMatcher, stubImpl);

    const result = env.findDynamicFunction("dyn_fn", false, &.{});
    try std.testing.expect(result != null);
    try std.testing.expectEqual(env.types.builtins.bool_type, result.?.result);
}

test "addDynamicFunction non-matching returns null" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    _ = try env.addDynamicFunction("dyn_fn", false, stubDynamicMatcher, stubImpl);

    const result = env.findDynamicFunction("dyn_fn", false, &.{});
    try std.testing.expect(result == null);
}

test "setContainer and scoped var lookup" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    try env.addVarTyped("com.example.x", env.types.builtins.int_type);
    try env.setContainer("com.example");

    const result = try env.lookupVarScoped(std.testing.allocator, "x", false);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(env.types.builtins.int_type, result.?);
}

test "lookupVarScoped falls back to unscoped" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    try env.addVarTyped("global_x", env.types.builtins.int_type);
    try env.setContainer("com.example");

    const result = try env.lookupVarScoped(std.testing.allocator, "global_x", false);
    try std.testing.expect(result != null);
}

test "lookupVarScoped absolute skips container" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    try env.addVarTyped("com.example.x", env.types.builtins.int_type);
    try env.setContainer("com.example");

    // Absolute lookup should not prepend the container.
    const result = try env.lookupVarScoped(std.testing.allocator, "x", true);
    try std.testing.expect(result == null);
}

test "lookupMessageScoped with container" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    _ = try env.addMessage("com.example.MyMessage");
    try env.setContainer("com.example");

    const result = try env.lookupMessageScoped(std.testing.allocator, "MyMessage", false);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("com.example.MyMessage", result.?.name);
}

test "lookupEnumScoped with container" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    _ = try env.addEnum("com.example.Status");
    try env.setContainer("com.example");

    const result = try env.lookupEnumScoped(std.testing.allocator, "Status", false);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("com.example.Status", result.?.name);
}

fn testLibraryInstaller(environment: *Env) anyerror!void {
    try environment.addVarTyped("lib_var", environment.types.builtins.bool_type);
}

test "addLibrary and hasLibrary" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    const lib = Library{ .name = "test_lib", .install = testLibraryInstaller };
    try env.addLibrary(lib);

    try std.testing.expect(env.hasLibrary("test_lib"));
    try std.testing.expect(!env.hasLibrary("other_lib"));

    // Verify the installer ran.
    try std.testing.expect(env.lookupVar("lib_var") != null);
}

test "addLibrary double install is idempotent" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    const lib = Library{ .name = "test_lib", .install = testLibraryInstaller };
    try env.addLibrary(lib);
    try env.addLibrary(lib); // Should not error or re-install.

    try std.testing.expect(env.hasLibrary("test_lib"));
}

test "extend creates child env" {
    var parent = try Env.initDefault(std.testing.allocator);
    defer parent.deinit();

    var child = try parent.extend(std.testing.allocator);
    defer child.deinit();

    try std.testing.expect(child.parent != null);
}

test "child inherits parent vars" {
    var parent = try Env.initDefault(std.testing.allocator);
    defer parent.deinit();

    try parent.addVarTyped("x", parent.types.builtins.int_type);

    var child = try parent.extend(std.testing.allocator);
    defer child.deinit();

    const result = child.lookupVar("x");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(parent.types.builtins.int_type, result.?);
}

test "child local vars do not leak to parent" {
    var parent = try Env.initDefault(std.testing.allocator);
    defer parent.deinit();

    var child = try parent.extend(std.testing.allocator);
    defer child.deinit();

    try child.addVarTyped("child_only", child.types.builtins.string_type);

    try std.testing.expect(child.lookupVar("child_only") != null);
    try std.testing.expect(parent.lookupVar("child_only") == null);
}

test "child can shadow parent vars" {
    var parent = try Env.initDefault(std.testing.allocator);
    defer parent.deinit();

    try parent.addVarTyped("x", parent.types.builtins.int_type);

    var child = try parent.extend(std.testing.allocator);
    defer child.deinit();

    try child.addVarTyped("x", child.types.builtins.string_type);

    // Child sees the shadow.
    try std.testing.expectEqual(child.types.builtins.string_type, child.lookupVar("x").?);
    // Parent is unchanged.
    try std.testing.expectEqual(parent.types.builtins.int_type, parent.lookupVar("x").?);
}

test "child inherits parent consts" {
    var parent = try Env.initDefault(std.testing.allocator);
    defer parent.deinit();

    try parent.addConst("C", parent.types.builtins.int_type, .{ .int = 42 });

    var child = try parent.extend(std.testing.allocator);
    defer child.deinit();

    const c = child.lookupConst("C");
    try std.testing.expect(c != null);
    try std.testing.expectEqual(@as(i64, 42), c.?.value.int);
}

test "parent message and child local field additions" {
    var parent = try Env.initDefault(std.testing.allocator);
    defer parent.deinit();

    _ = try parent.addMessage("example.Msg");
    try parent.addMessageField("example.Msg", "parent_field", parent.types.builtins.int_type);

    var child = try parent.extend(std.testing.allocator);
    defer child.deinit();

    // Child should be able to see parent message via lookupMessage.
    const msg = child.lookupMessage("example.Msg");
    try std.testing.expect(msg != null);

    // Adding a field in child creates a local clone.
    try child.addMessageField("example.Msg", "child_field", child.types.builtins.string_type);
    const child_msg = child.lookupMessage("example.Msg").?;
    try std.testing.expect(child_msg.lookupField("parent_field") != null);
    try std.testing.expect(child_msg.lookupField("child_field") != null);
}

test "overloadAt with ResolutionRef across parent chain" {
    var parent = try Env.initDefault(std.testing.allocator);
    defer parent.deinit();

    const idx = try parent.addFunction(
        "add",
        false,
        &.{ parent.types.builtins.int_type, parent.types.builtins.int_type },
        parent.types.builtins.int_type,
        stubImpl,
    );

    var child = try parent.extend(std.testing.allocator);
    defer child.deinit();

    // Find overload from child; should resolve at depth 1.
    const ref = child.findOverload(
        "add",
        false,
        &.{ child.types.builtins.int_type, child.types.builtins.int_type },
    );
    try std.testing.expect(ref != null);
    try std.testing.expectEqual(@as(u32, 1), ref.?.depth);
    try std.testing.expectEqual(idx, ref.?.index);

    // overloadAt should resolve correctly.
    const overload = child.overloadAt(ref.?);
    try std.testing.expectEqualStrings("add", overload.name);
}

test "enum_mode legacy creates int constants" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    env.setEnumMode(.legacy);
    try env.addEnumValue("example.Color", "RED", 0);

    const c = env.lookupConst("example.Color.RED");
    try std.testing.expect(c != null);
    try std.testing.expectEqual(env.types.builtins.int_type, c.?.ty);
    try std.testing.expectEqual(@as(i64, 0), c.?.value.int);
}

test "enum_mode strong creates typed enum constants" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    env.setEnumMode(.strong);
    try env.addEnumValue("example.Color", "RED", 0);

    // The type name itself is registered as a const.
    const type_const = env.lookupConst("example.Color");
    try std.testing.expect(type_const != null);
    try std.testing.expectEqual(env.types.builtins.type_type, type_const.?.ty);

    // The value is an enum_value, not an int.
    const val_const = env.lookupConst("example.Color.RED");
    try std.testing.expect(val_const != null);
    try std.testing.expectEqual(@as(i32, 0), val_const.?.value.enum_value.value);
}

test "setContainer replaces previous container" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    try env.setContainer("com.a");
    try env.addVarTyped("com.a.x", env.types.builtins.int_type);

    const r1 = try env.lookupVarScoped(std.testing.allocator, "x", false);
    try std.testing.expect(r1 != null);

    try env.setContainer("com.b");
    // Now "x" should not resolve via container "com.b".
    try env.addVarTyped("com.b.y", env.types.builtins.int_type);
    const r2 = try env.lookupVarScoped(std.testing.allocator, "y", false);
    try std.testing.expect(r2 != null);
    // "x" unscoped still works.
    const r3 = try env.lookupVarScoped(std.testing.allocator, "x", false);
    try std.testing.expect(r3 == null);
}

test "setContainer to null clears container" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    try env.setContainer("com.example");
    try env.setContainer(null);

    try env.addVarTyped("com.example.x", env.types.builtins.int_type);
    // Without container, scoped lookup for bare "x" should not find it.
    const result = try env.lookupVarScoped(std.testing.allocator, "x", false);
    try std.testing.expect(result == null);
}

test "child env inherits container" {
    var parent = try Env.initDefault(std.testing.allocator);
    defer parent.deinit();

    try parent.setContainer("com.example");
    try parent.addVarTyped("com.example.x", parent.types.builtins.int_type);

    var child = try parent.extend(std.testing.allocator);
    defer child.deinit();

    // Child should inherit container.
    try std.testing.expect(child.container != null);
    try std.testing.expectEqualStrings("com.example", child.container.?);

    const result = try child.lookupVarScoped(std.testing.allocator, "x", false);
    try std.testing.expect(result != null);
}

test "hasLibrary checks parent" {
    var parent = try Env.initDefault(std.testing.allocator);
    defer parent.deinit();

    const lib = Library{ .name = "parent_lib", .install = testLibraryInstaller };
    try parent.addLibrary(lib);

    var child = try parent.extend(std.testing.allocator);
    defer child.deinit();

    try std.testing.expect(child.hasLibrary("parent_lib"));
}

test "addLibrary in child skips if parent has it" {
    var parent = try Env.initDefault(std.testing.allocator);
    defer parent.deinit();

    const lib = Library{ .name = "shared_lib", .install = testLibraryInstaller };
    try parent.addLibrary(lib);

    var child = try parent.extend(std.testing.allocator);
    defer child.deinit();

    // Should not re-install.
    try child.addLibrary(lib);
    try std.testing.expect(child.hasLibrary("shared_lib"));
}

test "findOverloadScoped with container" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    _ = try env.addFunction(
        "com.example.myFunc",
        false,
        &.{env.types.builtins.int_type},
        env.types.builtins.bool_type,
        stubImpl,
    );
    try env.setContainer("com.example");

    const ref = try env.findOverloadScoped(
        std.testing.allocator,
        "myFunc",
        false,
        false,
        &.{env.types.builtins.int_type},
    );
    try std.testing.expect(ref != null);
}

test "lookupConstScoped with container" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    try env.addConst("com.example.MAX", env.types.builtins.int_type, .{ .int = 100 });
    try env.setContainer("com.example");

    const result = try env.lookupConstScoped(std.testing.allocator, "MAX", false);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 100), result.?.value.int);
}

test "well-known types have correct fields" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();

    // Timestamp has seconds and nanos.
    const ts = env.lookupMessage("google.protobuf.Timestamp").?;
    try std.testing.expect(ts.lookupField("seconds") != null);
    try std.testing.expect(ts.lookupField("nanos") != null);
    try std.testing.expectEqual(schema.MessageKind.timestamp, ts.kind);

    // Duration has seconds and nanos.
    const dur = env.lookupMessage("google.protobuf.Duration").?;
    try std.testing.expect(dur.lookupField("seconds") != null);
    try std.testing.expect(dur.lookupField("nanos") != null);
    try std.testing.expectEqual(schema.MessageKind.duration, dur.kind);

    // BoolValue wrapper.
    const bv = env.lookupMessage("google.protobuf.BoolValue").?;
    try std.testing.expect(bv.lookupField("value") != null);
    try std.testing.expectEqual(schema.MessageKind.bool_wrapper, bv.kind);
}

test "child inherits parent enum" {
    var parent = try Env.initDefault(std.testing.allocator);
    defer parent.deinit();

    try parent.addEnumValue("example.Dir", "NORTH", 0);
    try parent.addEnumValue("example.Dir", "SOUTH", 1);

    var child = try parent.extend(std.testing.allocator);
    defer child.deinit();

    const e = child.lookupEnum("example.Dir");
    try std.testing.expect(e != null);
    try std.testing.expect(e.?.lookupValueName("NORTH") != null);
}

test "dynamicFunctionAt resolves across parent chain" {
    var parent = try Env.initDefault(std.testing.allocator);
    defer parent.deinit();

    _ = try parent.addDynamicFunction("dyn", false, matchingDynamicMatcher, stubImpl);

    var child = try parent.extend(std.testing.allocator);
    defer child.deinit();

    const result = child.findDynamicFunction("dyn", false, &.{});
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 1), result.?.ref.depth);

    const func = child.dynamicFunctionAt(result.?.ref);
    try std.testing.expectEqualStrings("dyn", func.name);
}
