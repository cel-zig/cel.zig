const std = @import("std");
const cel_env = @import("../env/env.zig");
const types = @import("../env/types.zig");
const value = @import("../env/value.zig");

pub const library = cel_env.Library{
    .name = "cel.lib.ext.network",
    .install = installNetworkLibrary,
};

const Family = enum(u8) {
    ipv4 = 4,
    ipv6 = 6,
};

const IPValue = struct {
    family: Family,
    bytes: [16]u8,
};

const CIDRValue = struct {
    family: Family,
    bytes: [16]u8,
    prefix_len: u8,
};

const ip_vtable = value.HostValueVTable{
    .type_name = "net.IP",
    .clone = cloneIPValue,
    .deinit = deinitIPValue,
    .eql = eqlIPValue,
};

const cidr_vtable = value.HostValueVTable{
    .type_name = "net.CIDR",
    .clone = cloneCIDRValue,
    .deinit = deinitCIDRValue,
    .eql = eqlCIDRValue,
};

pub fn installNetworkLibrary(environment: *cel_env.Env) !void {
    const t = environment.types.builtins;
    const ip_ty = try environment.addHostTypeFromVTable(&ip_vtable);
    const cidr_ty = try environment.addHostTypeFromVTable(&cidr_vtable);

    try environment.addConst("net.IP", t.type_type, try value.typeNameValue(environment.allocator, "net.IP"));
    try environment.addConst("net.CIDR", t.type_type, try value.typeNameValue(environment.allocator, "net.CIDR"));

    _ = try environment.addFunction("ip", false, &.{t.string_type}, ip_ty, evalIP);
    _ = try environment.addFunction("cidr", false, &.{t.string_type}, cidr_ty, evalCIDR);

    _ = try environment.addFunction("isIP", false, &.{t.string_type}, t.bool_type, evalIsIP);
    _ = try environment.addFunction("isIP", false, &.{ip_ty}, t.bool_type, evalIsIP);
    _ = try environment.addFunction("isIP", false, &.{cidr_ty}, t.bool_type, evalIsIP);
    _ = try environment.addFunction("isCIDR", false, &.{t.string_type}, t.bool_type, evalIsCIDR);
    _ = try environment.addFunction("isCIDR", false, &.{cidr_ty}, t.bool_type, evalIsCIDR);
    _ = try environment.addFunction("ip.isCanonical", false, &.{t.string_type}, t.bool_type, evalIPIsCanonical);

    _ = try environment.addFunction("string", false, &.{ip_ty}, t.string_type, evalStringIP);
    _ = try environment.addFunction("string", false, &.{cidr_ty}, t.string_type, evalStringCIDR);

    _ = try environment.addFunction("family", true, &.{ip_ty}, t.int_type, evalIPFamily);
    _ = try environment.addFunction("isUnspecified", true, &.{ip_ty}, t.bool_type, evalIPIsUnspecified);
    _ = try environment.addFunction("isLoopback", true, &.{ip_ty}, t.bool_type, evalIPIsLoopback);
    _ = try environment.addFunction("isGlobalUnicast", true, &.{ip_ty}, t.bool_type, evalIPIsGlobalUnicast);
    _ = try environment.addFunction("isLinkLocalMulticast", true, &.{ip_ty}, t.bool_type, evalIPIsLinkLocalMulticast);
    _ = try environment.addFunction("isLinkLocalUnicast", true, &.{ip_ty}, t.bool_type, evalIPIsLinkLocalUnicast);

    _ = try environment.addFunction("containsIP", true, &.{ cidr_ty, ip_ty }, t.bool_type, evalCIDRContainsIP);
    _ = try environment.addFunction("containsIP", true, &.{ cidr_ty, t.string_type }, t.bool_type, evalCIDRContainsIP);
    _ = try environment.addFunction("containsCIDR", true, &.{ cidr_ty, cidr_ty }, t.bool_type, evalCIDRContainsCIDR);
    _ = try environment.addFunction("containsCIDR", true, &.{ cidr_ty, t.string_type }, t.bool_type, evalCIDRContainsCIDR);
    _ = try environment.addFunction("ip", true, &.{cidr_ty}, ip_ty, evalCIDRIP);
    _ = try environment.addFunction("masked", true, &.{cidr_ty}, cidr_ty, evalCIDRMasked);
    _ = try environment.addFunction("prefixLength", true, &.{cidr_ty}, t.int_type, evalCIDRPrefixLength);
}

fn cloneIPValue(allocator: std.mem.Allocator, ptr: *const anyopaque) std.mem.Allocator.Error!*anyopaque {
    const typed: *const IPValue = @ptrCast(@alignCast(ptr));
    const out = try allocator.create(IPValue);
    out.* = typed.*;
    return out;
}

fn deinitIPValue(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const typed: *IPValue = @ptrCast(@alignCast(ptr));
    allocator.destroy(typed);
}

fn eqlIPValue(lhs: *const anyopaque, rhs: *const anyopaque) bool {
    const left: *const IPValue = @ptrCast(@alignCast(lhs));
    const right: *const IPValue = @ptrCast(@alignCast(rhs));
    return std.mem.eql(u8, left.bytes[0..], right.bytes[0..]);
}

fn cloneCIDRValue(allocator: std.mem.Allocator, ptr: *const anyopaque) std.mem.Allocator.Error!*anyopaque {
    const typed: *const CIDRValue = @ptrCast(@alignCast(ptr));
    const out = try allocator.create(CIDRValue);
    out.* = typed.*;
    return out;
}

fn deinitCIDRValue(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const typed: *CIDRValue = @ptrCast(@alignCast(ptr));
    allocator.destroy(typed);
}

fn eqlCIDRValue(lhs: *const anyopaque, rhs: *const anyopaque) bool {
    const left: *const CIDRValue = @ptrCast(@alignCast(lhs));
    const right: *const CIDRValue = @ptrCast(@alignCast(rhs));
    return left.family == right.family and left.prefix_len == right.prefix_len and
        std.mem.eql(u8, left.bytes[0..], right.bytes[0..]);
}

fn evalIP(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    const parsed = try parseIP(args[0].string);
    return wrapIP(allocator, parsed);
}

fn evalCIDR(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    const parsed = try parseCIDR(args[0].string);
    return wrapCIDR(allocator, parsed);
}

fn evalIsIP(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return switch (args[0]) {
        .string => blk: {
            _ = parseIP(args[0].string) catch break :blk .{ .bool = false };
            break :blk .{ .bool = true };
        },
        .host => |host| if (host.vtable == &ip_vtable)
            .{ .bool = true }
        else
            value.RuntimeError.TypeMismatch,
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalIsCIDR(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return switch (args[0]) {
        .string => blk: {
            _ = parseCIDR(args[0].string) catch break :blk .{ .bool = false };
            break :blk .{ .bool = true };
        },
        .host => |host| if (host.vtable == &cidr_vtable)
            .{ .bool = true }
        else
            value.RuntimeError.TypeMismatch,
        else => value.RuntimeError.TypeMismatch,
    };
}

fn evalIPIsCanonical(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    const parsed = try parseIP(args[0].string);
    const canonical = try formatIP(std.heap.page_allocator, parsed);
    defer std.heap.page_allocator.free(canonical);
    return .{ .bool = std.mem.eql(u8, canonical, args[0].string) };
}

fn evalStringIP(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    const ip = try extractIP(args[0]);
    return .{ .string = try formatIP(allocator, ip.*) };
}

fn evalStringCIDR(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    const cidr = try extractCIDR(args[0]);
    return .{ .string = try formatCIDR(allocator, cidr.*) };
}

fn evalIPFamily(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    const ip = try extractUnaryIP(args);
    return .{ .int = @intFromEnum(ip.family) };
}

fn evalIPIsUnspecified(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    const ip = try extractUnaryIP(args);
    return .{ .bool = isIPUnspecified(ip.*) };
}

fn evalIPIsLoopback(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    const ip = try extractUnaryIP(args);
    return .{ .bool = isIPLoopback(ip.*) };
}

fn evalIPIsGlobalUnicast(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    const ip = try extractUnaryIP(args);
    return .{ .bool = isIPGlobalUnicast(ip.*) };
}

fn evalIPIsLinkLocalMulticast(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    const ip = try extractUnaryIP(args);
    return .{ .bool = isIPLinkLocalMulticast(ip.*) };
}

fn evalIPIsLinkLocalUnicast(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    const ip = try extractUnaryIP(args);
    return .{ .bool = isIPLinkLocalUnicast(ip.*) };
}

fn evalCIDRContainsIP(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 2) return value.RuntimeError.TypeMismatch;
    const cidr = try extractCIDR(args[0]);
    const ip = switch (args[1]) {
        .string => try parseIP(args[1].string),
        else => (try extractIP(args[1])).*,
    };
    return .{ .bool = cidrContainsIP(cidr.*, ip) };
}

fn evalCIDRContainsCIDR(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    if (args.len != 2) return value.RuntimeError.TypeMismatch;
    const outer = try extractCIDR(args[0]);
    const inner = switch (args[1]) {
        .string => try parseCIDR(args[1].string),
        else => (try extractCIDR(args[1])).*,
    };
    return .{ .bool = cidrContainsCIDR(outer.*, inner) };
}

fn evalCIDRIP(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    const cidr = try extractUnaryCIDR(args);
    return wrapIP(allocator, .{
        .family = cidr.family,
        .bytes = cidr.bytes,
    });
}

fn evalCIDRMasked(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    const cidr = try extractUnaryCIDR(args);
    return wrapCIDR(allocator, maskCIDR(cidr.*));
}

fn evalCIDRPrefixLength(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    _ = allocator;
    const cidr = try extractUnaryCIDR(args);
    return .{ .int = cidr.prefix_len };
}

fn extractUnaryIP(args: []const value.Value) value.RuntimeError!*const IPValue {
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return extractIP(args[0]);
}

fn extractUnaryCIDR(args: []const value.Value) value.RuntimeError!*const CIDRValue {
    if (args.len != 1) return value.RuntimeError.TypeMismatch;
    return extractCIDR(args[0]);
}

fn extractIP(arg: value.Value) value.RuntimeError!*const IPValue {
    return switch (arg) {
        .host => |host| if (host.vtable == &ip_vtable)
            @ptrCast(@alignCast(host.ptr))
        else
            value.RuntimeError.TypeMismatch,
        else => value.RuntimeError.TypeMismatch,
    };
}

fn extractCIDR(arg: value.Value) value.RuntimeError!*const CIDRValue {
    return switch (arg) {
        .host => |host| if (host.vtable == &cidr_vtable)
            @ptrCast(@alignCast(host.ptr))
        else
            value.RuntimeError.TypeMismatch,
        else => value.RuntimeError.TypeMismatch,
    };
}

fn wrapIP(allocator: std.mem.Allocator, ip: IPValue) std.mem.Allocator.Error!value.Value {
    const ptr = try allocator.create(IPValue);
    ptr.* = ip;
    return value.hostValue(ptr, &ip_vtable);
}

fn wrapCIDR(allocator: std.mem.Allocator, cidr: CIDRValue) std.mem.Allocator.Error!value.Value {
    const ptr = try allocator.create(CIDRValue);
    ptr.* = cidr;
    return value.hostValue(ptr, &cidr_vtable);
}

fn parseIP(text: []const u8) value.RuntimeError!IPValue {
    if (std.mem.indexOfScalar(u8, text, '%') != null) return value.RuntimeError.TypeMismatch;
    if (std.mem.indexOfScalar(u8, text, '/') != null) return value.RuntimeError.TypeMismatch;

    if (std.Io.net.Ip4Address.parse(text, 0)) |ip4| {
        return .{
            .family = .ipv4,
            .bytes = ipv4Mapped(ip4.bytes),
        };
    } else |_| {}

    if (std.mem.indexOf(u8, text, "::ffff:") != null and std.mem.indexOfScalar(u8, text, '.') != null) {
        return value.RuntimeError.TypeMismatch;
    }

    const ip6 = std.Io.net.Ip6Address.parse(text, 0) catch blk: {
        // Zig's IPv6 parser fails on some valid compressed forms like
        // "::ffff:c0a8:1". Expand "::" and retry.
        // Reject ":::" (triple colon) which is always invalid.
        if (std.mem.indexOf(u8, text, ":::") != null) return value.RuntimeError.TypeMismatch;
        if (std.mem.indexOf(u8, text, "::")) |dcolon| {
            var expanded_buf: [64]u8 = undefined;
            const expanded = expandIPv6DoubleColon(text, dcolon, &expanded_buf) orelse
                return value.RuntimeError.TypeMismatch;
            break :blk std.Io.net.Ip6Address.parse(expanded, 0) catch
                return value.RuntimeError.TypeMismatch;
        }
        return value.RuntimeError.TypeMismatch;
    };
    return .{
        .family = .ipv6,
        .bytes = ip6.bytes,
    };
}

fn parseCIDR(text: []const u8) value.RuntimeError!CIDRValue {
    if (std.mem.indexOfScalar(u8, text, '%') != null) return value.RuntimeError.TypeMismatch;
    const slash = std.mem.lastIndexOfScalar(u8, text, '/') orelse return value.RuntimeError.TypeMismatch;
    const ip_text = text[0..slash];
    const prefix_text = text[slash + 1 ..];
    if (prefix_text.len == 0) return value.RuntimeError.TypeMismatch;

    var ip = try parseIP(ip_text);
    const prefix = std.fmt.parseInt(u8, prefix_text, 10) catch return value.RuntimeError.TypeMismatch;
    const max_prefix: u8 = if (ip.family == .ipv4) 32 else 128;
    if (prefix > max_prefix) return value.RuntimeError.TypeMismatch;
    ip.bytes = maskedBytes(ip.bytes, ip.family, prefix);
    return .{
        .family = ip.family,
        .bytes = ip.bytes,
        .prefix_len = prefix,
    };
}

fn formatIP(allocator: std.mem.Allocator, ip: IPValue) std.mem.Allocator.Error![]u8 {
    if (ip.family == .ipv4) {
        const bytes4 = ipv4Tail(ip.bytes);
        return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
            bytes4[0],
            bytes4[1],
            bytes4[2],
            bytes4[3],
        });
    }

    const addr = std.Io.net.Ip6Address{ .bytes = ip.bytes, .port = 0 };
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0..]);
    addr.format(&writer) catch unreachable;
    const rendered = writer.buffered();
    if (std.mem.startsWith(u8, rendered, "[") and std.mem.endsWith(u8, rendered, "]:0")) {
        return allocator.dupe(u8, rendered[1 .. rendered.len - 3]);
    }
    return allocator.dupe(u8, rendered);
}

/// Expand "::" in an IPv6 address to explicit zero groups so that Zig's
/// Ip6Address.parse (which chokes on some valid compressed forms) can handle it.
fn expandIPv6DoubleColon(text: []const u8, dcolon: usize, buf: []u8) ?[]const u8 {
    const before = text[0..dcolon];
    const after = text[dcolon + 2 ..];
    // Count existing groups on each side of "::"
    var before_groups: usize = if (before.len == 0) 0 else 1;
    for (before) |c| {
        if (c == ':') before_groups += 1;
    }
    var after_groups: usize = if (after.len == 0) 0 else 1;
    for (after) |c| {
        if (c == ':') after_groups += 1;
    }
    const missing = 8 -| (before_groups + after_groups);
    if (missing == 0) return null;

    var pos: usize = 0;
    if (before.len > 0) {
        if (pos + before.len + 1 > buf.len) return null;
        @memcpy(buf[pos..][0..before.len], before);
        pos += before.len;
        buf[pos] = ':';
        pos += 1;
    }
    for (0..missing) |i| {
        if (pos + 1 > buf.len) return null;
        buf[pos] = '0';
        pos += 1;
        if (i + 1 < missing or after.len > 0) {
            if (pos + 1 > buf.len) return null;
            buf[pos] = ':';
            pos += 1;
        }
    }
    if (after.len > 0) {
        if (pos + after.len > buf.len) return null;
        @memcpy(buf[pos..][0..after.len], after);
        pos += after.len;
    }
    return buf[0..pos];
}

fn formatCIDR(allocator: std.mem.Allocator, cidr: CIDRValue) std.mem.Allocator.Error![]u8 {
    const ip_text = try formatIP(allocator, .{
        .family = cidr.family,
        .bytes = cidr.bytes,
    });
    defer allocator.free(ip_text);
    return std.fmt.allocPrint(allocator, "{s}/{d}", .{ ip_text, cidr.prefix_len });
}

fn ipv4Mapped(bytes4: [4]u8) [16]u8 {
    var out = [_]u8{0} ** 16;
    out[10] = 0xff;
    out[11] = 0xff;
    @memcpy(out[12..16], bytes4[0..]);
    return out;
}

fn ipv4Tail(bytes: [16]u8) [4]u8 {
    return .{ bytes[12], bytes[13], bytes[14], bytes[15] };
}

fn isMappedIPv4(bytes: [16]u8) bool {
    return std.mem.eql(u8, bytes[0..10], &([_]u8{0} ** 10)) and bytes[10] == 0xff and bytes[11] == 0xff;
}

fn maskedBytes(bytes: [16]u8, family: Family, prefix_len: u8) [16]u8 {
    var out = bytes;
    const bit_len: u8 = if (family == .ipv4) 32 else 128;
    const start: usize = if (family == .ipv4) 12 else 0;
    var remaining = prefix_len;

    if (family == .ipv4 and !isMappedIPv4(out)) return out;
    if (family == .ipv4) {
        @memset(out[0..10], 0);
        out[10] = 0xff;
        out[11] = 0xff;
    }

    for (0..bit_len / 8) |i| {
        const idx = start + i;
        if (remaining >= 8) {
            remaining -= 8;
            continue;
        }
        if (remaining == 0) {
            out[idx] = 0;
            continue;
        }
        const shift: u3 = @intCast(8 - remaining);
        const mask: u8 = @as(u8, 0xff) << shift;
        out[idx] &= mask;
        remaining = 0;
    }
    return out;
}

fn maskCIDR(cidr: CIDRValue) CIDRValue {
    var out = cidr;
    out.bytes = maskedBytes(cidr.bytes, cidr.family, cidr.prefix_len);
    return out;
}

fn cidrContainsIP(cidr: CIDRValue, ip: IPValue) bool {
    switch (cidr.family) {
        .ipv4 => {
            if (ip.family == .ipv6 and !isMappedIPv4(ip.bytes)) return false;
            return std.mem.eql(u8, maskedBytes(ip.bytes, .ipv4, cidr.prefix_len)[12..16], cidr.bytes[12..16]);
        },
        .ipv6 => {
            if (ip.family != .ipv6) return false;
            return std.mem.eql(u8, &maskedBytes(ip.bytes, .ipv6, cidr.prefix_len), &cidr.bytes);
        },
    }
}

fn cidrContainsCIDR(outer: CIDRValue, inner: CIDRValue) bool {
    if (outer.family != inner.family) return false;
    if (outer.prefix_len > inner.prefix_len) return false;
    return switch (outer.family) {
        .ipv4 => std.mem.eql(u8, maskedBytes(inner.bytes, .ipv4, outer.prefix_len)[12..16], outer.bytes[12..16]),
        .ipv6 => std.mem.eql(u8, &maskedBytes(inner.bytes, .ipv6, outer.prefix_len), &outer.bytes),
    };
}

fn isIPUnspecified(ip: IPValue) bool {
    return switch (ip.family) {
        .ipv4 => blk: {
            const tail = ipv4Tail(ip.bytes);
            break :blk std.mem.eql(u8, tail[0..], &[_]u8{ 0, 0, 0, 0 });
        },
        .ipv6 => std.mem.eql(u8, ip.bytes[0..], &([_]u8{0} ** 16)),
    };
}

fn isIPLoopback(ip: IPValue) bool {
    return switch (ip.family) {
        .ipv4 => ipv4Tail(ip.bytes)[0] == 127,
        .ipv6 => std.mem.eql(u8, ip.bytes[0..15], &([_]u8{0} ** 15)) and ip.bytes[15] == 1,
    };
}

fn isIPLinkLocalMulticast(ip: IPValue) bool {
    return switch (ip.family) {
        .ipv4 => ip.bytes[12] == 224 and ip.bytes[13] == 0 and ip.bytes[14] == 0,
        .ipv6 => ip.bytes[0] == 0xff and (ip.bytes[1] & 0x0f) == 0x02,
    };
}

fn isIPLinkLocalUnicast(ip: IPValue) bool {
    return switch (ip.family) {
        .ipv4 => ip.bytes[12] == 169 and ip.bytes[13] == 254,
        .ipv6 => ip.bytes[0] == 0xfe and (ip.bytes[1] & 0xc0) == 0x80,
    };
}

fn isIPGlobalUnicast(ip: IPValue) bool {
    if (isIPUnspecified(ip) or isIPLoopback(ip) or isIPLinkLocalMulticast(ip) or isIPLinkLocalUnicast(ip)) return false;
    return switch (ip.family) {
        .ipv4 => !std.mem.eql(u8, &ipv4Tail(ip.bytes), &[_]u8{ 255, 255, 255, 255 }) and ip.bytes[12] < 224,
        .ipv6 => ip.bytes[0] != 0xff,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const compile_mod = @import("../compiler/compile.zig");
const eval_impl = @import("../eval/eval.zig");
const env_mod = @import("../env/env.zig");
const Activation = @import("../eval/activation.zig").Activation;

fn evalExpectString(environment: *env_mod.Env, activation: *const Activation, expr: []const u8) ![]const u8 {
    var program = try compile_mod.compile(std.testing.allocator, environment, expr);
    defer program.deinit();
    var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, activation, .{});
    defer result.deinit(std.testing.allocator);
    const owned = try std.testing.allocator.dupe(u8, result.string);
    return owned;
}

fn evalExpectBool(environment: *env_mod.Env, activation: *const Activation, expr: []const u8) !bool {
    var program = try compile_mod.compile(std.testing.allocator, environment, expr);
    defer program.deinit();
    var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, activation, .{});
    defer result.deinit(std.testing.allocator);
    return result.bool;
}

fn evalExpectInt(environment: *env_mod.Env, activation: *const Activation, expr: []const u8) !i64 {
    var program = try compile_mod.compile(std.testing.allocator, environment, expr);
    defer program.deinit();
    var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, activation, .{});
    defer result.deinit(std.testing.allocator);
    return result.int;
}

fn evalExpectError(environment: *env_mod.Env, activation: *const Activation, expr: []const u8) !bool {
    var program = compile_mod.compile(std.testing.allocator, environment, expr) catch return true;
    defer program.deinit();
    _ = eval_impl.evalWithOptions(std.testing.allocator, &program, activation, .{}) catch return true;
    return false;
}

fn setupEnv() !env_mod.Env {
    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    errdefer environment.deinit();
    try environment.addLibrary(library);
    return environment;
}

test "ip() parsing and string() roundtrip" {
    var environment = try setupEnv();
    defer environment.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: []const u8 }{
        .{ .expr = "string(ip('1.2.3.4'))", .expected = "1.2.3.4" },
        .{ .expr = "string(ip('0.0.0.0'))", .expected = "0.0.0.0" },
        .{ .expr = "string(ip('255.255.255.255'))", .expected = "255.255.255.255" },
        .{ .expr = "string(ip('127.0.0.1'))", .expected = "127.0.0.1" },
        .{ .expr = "string(ip('10.0.0.1'))", .expected = "10.0.0.1" },
        .{ .expr = "string(ip('192.168.1.1'))", .expected = "192.168.1.1" },
        .{ .expr = "string(ip('::1'))", .expected = "::1" },
        .{ .expr = "string(ip('::'))", .expected = "::" },
        .{ .expr = "string(ip('2001:db8::1'))", .expected = "2001:db8::1" },
        .{ .expr = "string(ip('fe80::1'))", .expected = "fe80::1" },
        .{ .expr = "string(ip('ff02::1'))", .expected = "ff02::1" },
    };
    for (cases) |case| {
        const got = try evalExpectString(&environment, &activation, case.expr);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case.expected, got);
    }
}

test "ip() rejects invalid inputs" {
    var environment = try setupEnv();
    defer environment.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_][]const u8{
        "ip('')",
        "ip('not_an_ip')",
        "ip('999.999.999.999')",
        "ip('1.2.3.4/24')",
        "ip('1.2.3')",
        "ip('fe80::1%eth0')",
        "ip('1.2.3.4.5')",
    };
    for (cases) |expr| {
        const is_err = try evalExpectError(&environment, &activation, expr);
        try std.testing.expect(is_err);
    }
}

test "ip().family() returns 4 or 6" {
    var environment = try setupEnv();
    defer environment.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: i64 }{
        .{ .expr = "ip('1.2.3.4').family()", .expected = 4 },
        .{ .expr = "ip('0.0.0.0').family()", .expected = 4 },
        .{ .expr = "ip('255.255.255.255').family()", .expected = 4 },
        .{ .expr = "ip('::1').family()", .expected = 6 },
        .{ .expr = "ip('::').family()", .expected = 6 },
        .{ .expr = "ip('2001:db8::1').family()", .expected = 6 },
        .{ .expr = "ip('fe80::1').family()", .expected = 6 },
        .{ .expr = "ip('ff02::1').family()", .expected = 6 },
    };
    for (cases) |case| {
        const got = try evalExpectInt(&environment, &activation, case.expr);
        try std.testing.expectEqual(case.expected, got);
    }
}

test "isIP() validates strings and ip values" {
    var environment = try setupEnv();
    defer environment.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        .{ .expr = "isIP('1.2.3.4')", .expected = true },
        .{ .expr = "isIP('::1')", .expected = true },
        .{ .expr = "isIP('not_ip')", .expected = false },
        .{ .expr = "isIP('')", .expected = false },
        .{ .expr = "isIP('1.2.3.4/24')", .expected = false },
        .{ .expr = "isIP(ip('10.0.0.1'))", .expected = true },
        .{ .expr = "isIP('999.0.0.1')", .expected = false },
        .{ .expr = "isIP('2001:db8::1')", .expected = true },
    };
    for (cases) |case| {
        const got = try evalExpectBool(&environment, &activation, case.expr);
        try std.testing.expectEqual(case.expected, got);
    }
}

test "isCIDR() validates strings and cidr values" {
    var environment = try setupEnv();
    defer environment.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        .{ .expr = "isCIDR('10.0.0.0/8')", .expected = true },
        .{ .expr = "isCIDR('2001:db8::/32')", .expected = true },
        .{ .expr = "isCIDR('10.0.0.1')", .expected = false },
        .{ .expr = "isCIDR('not_cidr')", .expected = false },
        .{ .expr = "isCIDR(cidr('192.168.1.0/24'))", .expected = true },
    };
    for (cases) |case| {
        const got = try evalExpectBool(&environment, &activation, case.expr);
        try std.testing.expectEqual(case.expected, got);
    }
}

test "ip.isCanonical() checks canonical form" {
    var environment = try setupEnv();
    defer environment.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        .{ .expr = "ip.isCanonical('1.2.3.4')", .expected = true },
        .{ .expr = "ip.isCanonical('0.0.0.0')", .expected = true },
        .{ .expr = "ip.isCanonical('::1')", .expected = true },
        .{ .expr = "ip.isCanonical('2001:db8::1')", .expected = true },
    };
    for (cases) |case| {
        const got = try evalExpectBool(&environment, &activation, case.expr);
        try std.testing.expectEqual(case.expected, got);
    }
}

test "ip boolean property methods" {
    var environment = try setupEnv();
    defer environment.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        // isUnspecified
        .{ .expr = "ip('0.0.0.0').isUnspecified()", .expected = true },
        .{ .expr = "ip('::').isUnspecified()", .expected = true },
        .{ .expr = "ip('1.2.3.4').isUnspecified()", .expected = false },
        .{ .expr = "ip('::1').isUnspecified()", .expected = false },

        // isLoopback
        .{ .expr = "ip('127.0.0.1').isLoopback()", .expected = true },
        .{ .expr = "ip('127.255.0.1').isLoopback()", .expected = true },
        .{ .expr = "ip('::1').isLoopback()", .expected = true },
        .{ .expr = "ip('1.2.3.4').isLoopback()", .expected = false },
        .{ .expr = "ip('::2').isLoopback()", .expected = false },

        // isLinkLocalMulticast
        .{ .expr = "ip('224.0.0.1').isLinkLocalMulticast()", .expected = true },
        .{ .expr = "ip('224.0.0.251').isLinkLocalMulticast()", .expected = true },
        .{ .expr = "ip('ff02::1').isLinkLocalMulticast()", .expected = true },
        .{ .expr = "ip('1.2.3.4').isLinkLocalMulticast()", .expected = false },
        .{ .expr = "ip('ff01::1').isLinkLocalMulticast()", .expected = false },

        // isLinkLocalUnicast
        .{ .expr = "ip('169.254.0.1').isLinkLocalUnicast()", .expected = true },
        .{ .expr = "ip('169.254.255.255').isLinkLocalUnicast()", .expected = true },
        .{ .expr = "ip('fe80::1').isLinkLocalUnicast()", .expected = true },
        .{ .expr = "ip('1.2.3.4').isLinkLocalUnicast()", .expected = false },
        .{ .expr = "ip('fe40::1').isLinkLocalUnicast()", .expected = false },

        // isGlobalUnicast
        .{ .expr = "ip('8.8.8.8').isGlobalUnicast()", .expected = true },
        .{ .expr = "ip('10.0.0.1').isGlobalUnicast()", .expected = true },
        .{ .expr = "ip('2001:db8::1').isGlobalUnicast()", .expected = true },
        .{ .expr = "ip('0.0.0.0').isGlobalUnicast()", .expected = false },
        .{ .expr = "ip('127.0.0.1').isGlobalUnicast()", .expected = false },
        .{ .expr = "ip('255.255.255.255').isGlobalUnicast()", .expected = false },
        .{ .expr = "ip('224.0.0.1').isGlobalUnicast()", .expected = false },
        .{ .expr = "ip('ff02::1').isGlobalUnicast()", .expected = false },
    };
    for (cases) |case| {
        const got = try evalExpectBool(&environment, &activation, case.expr);
        try std.testing.expectEqual(case.expected, got);
    }
}

test "cidr() parsing and string() roundtrip" {
    var environment = try setupEnv();
    defer environment.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: []const u8 }{
        .{ .expr = "string(cidr('10.0.0.0/8'))", .expected = "10.0.0.0/8" },
        .{ .expr = "string(cidr('192.168.1.0/24'))", .expected = "192.168.1.0/24" },
        .{ .expr = "string(cidr('0.0.0.0/0'))", .expected = "0.0.0.0/0" },
        .{ .expr = "string(cidr('255.255.255.255/32'))", .expected = "255.255.255.255/32" },
        .{ .expr = "string(cidr('172.16.0.0/12'))", .expected = "172.16.0.0/12" },
        .{ .expr = "string(cidr('2001:db8::/32'))", .expected = "2001:db8::/32" },
        .{ .expr = "string(cidr('::/0'))", .expected = "::/0" },
        .{ .expr = "string(cidr('::1/128'))", .expected = "::1/128" },
        .{ .expr = "string(cidr('fe80::/10'))", .expected = "fe80::/10" },
        // masking: host bits get zeroed
        .{ .expr = "string(cidr('10.1.2.3/8'))", .expected = "10.0.0.0/8" },
        .{ .expr = "string(cidr('192.168.1.99/24'))", .expected = "192.168.1.0/24" },
    };
    for (cases) |case| {
        const got = try evalExpectString(&environment, &activation, case.expr);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case.expected, got);
    }
}

test "cidr() rejects invalid inputs" {
    var environment = try setupEnv();
    defer environment.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_][]const u8{
        "cidr('')",
        "cidr('1.2.3.4')",
        "cidr('not_cidr')",
        "cidr('1.2.3.4/')",
        "cidr('1.2.3.4/33')",
        "cidr('::1/129')",
        "cidr('1.2.3.4%-bad/24')",
    };
    for (cases) |expr| {
        const is_err = try evalExpectError(&environment, &activation, expr);
        try std.testing.expect(is_err);
    }
}

test "cidr.containsIP() membership checks" {
    var environment = try setupEnv();
    defer environment.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        // basic containment
        .{ .expr = "cidr('10.0.0.0/8').containsIP(ip('10.0.0.1'))", .expected = true },
        .{ .expr = "cidr('10.0.0.0/8').containsIP(ip('10.255.255.255'))", .expected = true },
        .{ .expr = "cidr('10.0.0.0/8').containsIP(ip('11.0.0.1'))", .expected = false },
        .{ .expr = "cidr('192.168.1.0/24').containsIP(ip('192.168.1.100'))", .expected = true },
        .{ .expr = "cidr('192.168.1.0/24').containsIP(ip('192.168.2.1'))", .expected = false },

        // /32 exact match
        .{ .expr = "cidr('10.0.0.1/32').containsIP(ip('10.0.0.1'))", .expected = true },
        .{ .expr = "cidr('10.0.0.1/32').containsIP(ip('10.0.0.2'))", .expected = false },

        // /0 matches everything in the family
        .{ .expr = "cidr('0.0.0.0/0').containsIP(ip('1.2.3.4'))", .expected = true },
        .{ .expr = "cidr('0.0.0.0/0').containsIP(ip('255.255.255.255'))", .expected = true },

        // string overload
        .{ .expr = "cidr('10.0.0.0/8').containsIP('10.0.0.1')", .expected = true },
        .{ .expr = "cidr('10.0.0.0/8').containsIP('11.0.0.1')", .expected = false },

        // IPv6 containment
        .{ .expr = "cidr('2001:db8::/32').containsIP(ip('2001:db8::1'))", .expected = true },
        .{ .expr = "cidr('2001:db8::/32').containsIP(ip('2001:db9::1'))", .expected = false },
        .{ .expr = "cidr('::/0').containsIP(ip('::1'))", .expected = true },
        .{ .expr = "cidr('::/0').containsIP(ip('ffff::ffff'))", .expected = true },
        .{ .expr = "cidr('::1/128').containsIP(ip('::1'))", .expected = true },
        .{ .expr = "cidr('::1/128').containsIP(ip('::2'))", .expected = false },

        // cross-family should not match
        .{ .expr = "cidr('10.0.0.0/8').containsIP(ip('::1'))", .expected = false },
    };
    for (cases) |case| {
        const got = try evalExpectBool(&environment, &activation, case.expr);
        try std.testing.expectEqual(case.expected, got);
    }
}

test "cidr.containsCIDR() subset checks" {
    var environment = try setupEnv();
    defer environment.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        // self-containment
        .{ .expr = "cidr('10.0.0.0/8').containsCIDR(cidr('10.0.0.0/8'))", .expected = true },

        // narrower subnet is contained
        .{ .expr = "cidr('10.0.0.0/8').containsCIDR(cidr('10.1.0.0/16'))", .expected = true },
        .{ .expr = "cidr('10.0.0.0/8').containsCIDR(cidr('10.1.2.0/24'))", .expected = true },

        // wider subnet is not contained
        .{ .expr = "cidr('10.1.0.0/16').containsCIDR(cidr('10.0.0.0/8'))", .expected = false },

        // disjoint
        .{ .expr = "cidr('10.0.0.0/8').containsCIDR(cidr('11.0.0.0/8'))", .expected = false },

        // /0 contains everything in the family
        .{ .expr = "cidr('0.0.0.0/0').containsCIDR(cidr('10.0.0.0/8'))", .expected = true },
        .{ .expr = "cidr('0.0.0.0/0').containsCIDR(cidr('0.0.0.0/0'))", .expected = true },

        // /32 only contains itself
        .{ .expr = "cidr('10.0.0.1/32').containsCIDR(cidr('10.0.0.1/32'))", .expected = true },

        // string overload
        .{ .expr = "cidr('10.0.0.0/8').containsCIDR('10.1.0.0/16')", .expected = true },
        .{ .expr = "cidr('10.0.0.0/8').containsCIDR('11.0.0.0/8')", .expected = false },

        // IPv6
        .{ .expr = "cidr('2001:db8::/32').containsCIDR(cidr('2001:db8:1::/48'))", .expected = true },
        .{ .expr = "cidr('2001:db8::/32').containsCIDR(cidr('2001:db9::/32'))", .expected = false },
        .{ .expr = "cidr('::/0').containsCIDR(cidr('2001:db8::/32'))", .expected = true },

        // cross-family should not match
        .{ .expr = "cidr('10.0.0.0/8').containsCIDR(cidr('2001:db8::/32'))", .expected = false },
    };
    for (cases) |case| {
        const got = try evalExpectBool(&environment, &activation, case.expr);
        try std.testing.expectEqual(case.expected, got);
    }
}

test "cidr.ip() extracts network address" {
    var environment = try setupEnv();
    defer environment.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: []const u8 }{
        .{ .expr = "string(cidr('10.0.0.0/8').ip())", .expected = "10.0.0.0" },
        .{ .expr = "string(cidr('192.168.1.0/24').ip())", .expected = "192.168.1.0" },
        .{ .expr = "string(cidr('0.0.0.0/0').ip())", .expected = "0.0.0.0" },
        .{ .expr = "string(cidr('255.255.255.255/32').ip())", .expected = "255.255.255.255" },
        // host bits are masked away during parsing
        .{ .expr = "string(cidr('10.1.2.3/8').ip())", .expected = "10.0.0.0" },
        .{ .expr = "string(cidr('2001:db8::1/32').ip())", .expected = "2001:db8::" },
        .{ .expr = "string(cidr('::/0').ip())", .expected = "::" },
        .{ .expr = "string(cidr('::1/128').ip())", .expected = "::1" },
    };
    for (cases) |case| {
        const got = try evalExpectString(&environment, &activation, case.expr);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case.expected, got);
    }
}

test "cidr.prefixLength() returns prefix" {
    var environment = try setupEnv();
    defer environment.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: i64 }{
        .{ .expr = "cidr('10.0.0.0/8').prefixLength()", .expected = 8 },
        .{ .expr = "cidr('192.168.1.0/24').prefixLength()", .expected = 24 },
        .{ .expr = "cidr('0.0.0.0/0').prefixLength()", .expected = 0 },
        .{ .expr = "cidr('10.0.0.1/32').prefixLength()", .expected = 32 },
        .{ .expr = "cidr('172.16.0.0/12').prefixLength()", .expected = 12 },
        .{ .expr = "cidr('2001:db8::/32').prefixLength()", .expected = 32 },
        .{ .expr = "cidr('::/0').prefixLength()", .expected = 0 },
        .{ .expr = "cidr('::1/128').prefixLength()", .expected = 128 },
        .{ .expr = "cidr('fe80::/10').prefixLength()", .expected = 10 },
    };
    for (cases) |case| {
        const got = try evalExpectInt(&environment, &activation, case.expr);
        try std.testing.expectEqual(case.expected, got);
    }
}

test "cidr.masked() zeroes host bits" {
    var environment = try setupEnv();
    defer environment.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    // Note: cidr() already masks on parse, so masked() on a cleanly-parsed
    // CIDR should be idempotent. We verify via string roundtrip.
    const cases = [_]struct { expr: []const u8, expected: []const u8 }{
        .{ .expr = "string(cidr('10.0.0.0/8').masked())", .expected = "10.0.0.0/8" },
        .{ .expr = "string(cidr('192.168.1.0/24').masked())", .expected = "192.168.1.0/24" },
        .{ .expr = "string(cidr('0.0.0.0/0').masked())", .expected = "0.0.0.0/0" },
        .{ .expr = "string(cidr('255.255.255.255/32').masked())", .expected = "255.255.255.255/32" },
        .{ .expr = "string(cidr('2001:db8::/32').masked())", .expected = "2001:db8::/32" },
        .{ .expr = "string(cidr('::/0').masked())", .expected = "::/0" },
        .{ .expr = "string(cidr('::1/128').masked())", .expected = "::1/128" },
        // masked() is idempotent: host bits already zeroed during cidr parse
        .{ .expr = "string(cidr('10.1.2.3/8').masked())", .expected = "10.0.0.0/8" },
    };
    for (cases) |case| {
        const got = try evalExpectString(&environment, &activation, case.expr);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case.expected, got);
    }
}
