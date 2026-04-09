const std = @import("std");
const cel_env = @import("../env/env.zig");
const value = @import("../env/value.zig");
const compile_mod = @import("../compiler/compile.zig");
const eval_impl = @import("../eval/eval.zig");
const Activation = @import("../eval/activation.zig").Activation;

pub const semver_library = cel_env.Library{
    .name = "cel.lib.ext.semver",
    .install = installSemverLibrary,
};

const semver_vtable = value.HostValueVTable{
    .type_name = "cel.Semver",
    .clone = cloneSemverValue,
    .deinit = deinitSemverValue,
    .eql = eqlSemverValue,
};

const SemverValue = struct {
    raw: []u8,
    version: std.SemanticVersion,
};

fn installSemverLibrary(environment: *cel_env.Env) !void {
    const t = environment.types.builtins;
    const semver_ty = try environment.addHostTypeFromVTable(&semver_vtable);
    _ = try environment.addFunction("semver", false, &.{t.string_type}, semver_ty, evalSemver);
    _ = try environment.addFunction("semver", false, &.{ t.string_type, t.bool_type }, semver_ty, evalSemverNormalized);
    _ = try environment.addFunction("isSemver", false, &.{t.string_type}, t.bool_type, evalIsSemver);
    _ = try environment.addFunction("isSemver", false, &.{ t.string_type, t.bool_type }, t.bool_type, evalIsSemverNormalized);
    _ = try environment.addFunction("major", true, &.{semver_ty}, t.int_type, evalSemverMajor);
    _ = try environment.addFunction("minor", true, &.{semver_ty}, t.int_type, evalSemverMinor);
    _ = try environment.addFunction("patch", true, &.{semver_ty}, t.int_type, evalSemverPatch);
    _ = try environment.addFunction("isGreaterThan", true, &.{ semver_ty, semver_ty }, t.bool_type, evalSemverGreaterThan);
    _ = try environment.addFunction("isLessThan", true, &.{ semver_ty, semver_ty }, t.bool_type, evalSemverLessThan);
    _ = try environment.addFunction("compareTo", true, &.{ semver_ty, semver_ty }, t.int_type, evalSemverCompareTo);
}

fn evalSemver(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    return wrapSemver(allocator, try parseSemver(allocator, args[0].string, false));
}

fn evalSemverNormalized(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 2 or args[0] != .string or args[1] != .bool) return value.RuntimeError.TypeMismatch;
    return wrapSemver(allocator, try parseSemver(allocator, args[0].string, args[1].bool));
}

fn evalIsSemver(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    const parsed = parseSemver(allocator, args[0].string, false) catch return .{ .bool = false };
    allocator.free(parsed.raw);
    return .{ .bool = true };
}

fn evalIsSemverNormalized(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 2 or args[0] != .string or args[1] != .bool) return value.RuntimeError.TypeMismatch;
    const parsed = parseSemver(allocator, args[0].string, args[1].bool) catch return .{ .bool = false };
    allocator.free(parsed.raw);
    return .{ .bool = true };
}

fn evalSemverMajor(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    const semver = try extractSemver(args);
    return .{ .int = @intCast(semver.version.major) };
}

fn evalSemverMinor(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    const semver = try extractSemver(args);
    return .{ .int = @intCast(semver.version.minor) };
}

fn evalSemverPatch(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    const semver = try extractSemver(args);
    return .{ .int = @intCast(semver.version.patch) };
}

fn evalSemverGreaterThan(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    const lhs = try extractSemver(args[0..1]);
    const rhs = try extractSemver(args[1..2]);
    return .{ .bool = lhs.version.order(rhs.version) == .gt };
}

fn evalSemverLessThan(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    const lhs = try extractSemver(args[0..1]);
    const rhs = try extractSemver(args[1..2]);
    return .{ .bool = lhs.version.order(rhs.version) == .lt };
}

fn evalSemverCompareTo(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    const lhs = try extractSemver(args[0..1]);
    const rhs = try extractSemver(args[1..2]);
    return .{ .int = switch (lhs.version.order(rhs.version)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    } };
}

fn parseSemver(allocator: std.mem.Allocator, text: []const u8, normalize: bool) cel_env.EvalError!SemverValue {
    const owned = if (normalize)
        try normalizeSemverText(allocator, text)
    else
        try allocator.dupe(u8, text);
    errdefer allocator.free(owned);
    const version = std.SemanticVersion.parse(owned) catch return value.RuntimeError.TypeMismatch;
    return .{ .raw = owned, .version = version };
}

fn normalizeSemverText(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]u8 {
    const without_v = if (std.mem.startsWith(u8, text, "v")) text[1..] else text;
    var parts_it = std.mem.splitScalar(u8, without_v, '.');
    var parts: [3][]const u8 = .{ "", "", "" };
    var count: usize = 0;
    while (parts_it.next()) |part| {
        if (count == 3) break;
        parts[count] = part;
        count += 1;
    }
    if (count == 0) return allocator.dupe(u8, without_v);
    if (count < 3 and std.mem.indexOfAny(u8, parts[count - 1], "+-") != null) {
        return allocator.dupe(u8, without_v);
    }

    var normalized: std.ArrayListUnmanaged(u8) = .empty;
    errdefer normalized.deinit(allocator);

    for (0..@max(count, 3)) |i| {
        if (i != 0) try normalized.append(allocator, '.');
        const part = if (i < count) parts[i] else "0";
        const trimmed = std.mem.trimStart(u8, part, "0");
        if (trimmed.len == 0 or !std.ascii.isDigit(trimmed[0])) {
            try normalized.append(allocator, '0');
        }
        try normalized.appendSlice(allocator, if (trimmed.len == 0) "" else trimmed);
    }

    return normalized.toOwnedSlice(allocator);
}

fn wrapSemver(allocator: std.mem.Allocator, semver: SemverValue) std.mem.Allocator.Error!value.Value {
    const ptr = try allocator.create(SemverValue);
    ptr.* = semver;
    return value.hostValue(ptr, &semver_vtable);
}

fn extractSemver(args: []const value.Value) value.RuntimeError!*const SemverValue {
    if (args.len != 1 or args[0] != .host or args[0].host.vtable != &semver_vtable) return value.RuntimeError.TypeMismatch;
    return @ptrCast(@alignCast(args[0].host.ptr));
}

fn cloneSemverValue(allocator: std.mem.Allocator, ptr: *const anyopaque) std.mem.Allocator.Error!*anyopaque {
    const typed: *const SemverValue = @ptrCast(@alignCast(ptr));
    const out = try allocator.create(SemverValue);
    errdefer allocator.destroy(out);
    out.* = parseSemver(allocator, typed.raw, false) catch unreachable;
    return out;
}

fn deinitSemverValue(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const typed: *SemverValue = @ptrCast(@alignCast(ptr));
    allocator.free(typed.raw);
    allocator.destroy(typed);
}

fn eqlSemverValue(lhs: *const anyopaque, rhs: *const anyopaque) bool {
    const left: *const SemverValue = @ptrCast(@alignCast(lhs));
    const right: *const SemverValue = @ptrCast(@alignCast(rhs));
    return left.version.order(right.version) == .eq;
}

test "semver library supports validation and comparison" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(semver_library);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_][]const u8{
        "isSemver('v1.0', true)",
        "semver('v01.01', true) == semver('1.1.0')",
        "semver('1.2.3').compareTo(semver('2.0.0')) == -1",
    };
    for (cases) |expr| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.bool);
    }
}

test "semver normalization helper handles prefixes padding and prerelease" {
    const normalized = try normalizeSemverText(std.testing.allocator, "v01.002");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("1.2.0", normalized);

    const prerelease = try normalizeSemverText(std.testing.allocator, "1.2.3-alpha");
    defer std.testing.allocator.free(prerelease);
    try std.testing.expectEqualStrings("1.2.3-alpha", prerelease);
}

test "semver helpers reject invalid versions and compare prereleases" {
    try std.testing.expectError(value.RuntimeError.TypeMismatch, parseSemver(std.testing.allocator, "not-a-semver", false));

    var raw = try value.string(std.testing.allocator, "v1.0");
    defer raw.deinit(std.testing.allocator);
    const loose = try evalIsSemver(std.testing.allocator, &.{raw});
    try std.testing.expect(!loose.bool);
    const normalized = try evalIsSemverNormalized(std.testing.allocator, &.{ raw, .{ .bool = true } });
    try std.testing.expect(normalized.bool);

    var alpha = try wrapSemver(std.testing.allocator, try parseSemver(std.testing.allocator, "1.0.0-alpha", false));
    defer alpha.deinit(std.testing.allocator);
    var release = try wrapSemver(std.testing.allocator, try parseSemver(std.testing.allocator, "1.0.0", false));
    defer release.deinit(std.testing.allocator);
    const comparison = try evalSemverCompareTo(std.testing.allocator, &.{ alpha, release });
    try std.testing.expectEqual(@as(i64, -1), comparison.int);
}
