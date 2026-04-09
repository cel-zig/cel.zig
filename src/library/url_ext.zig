const std = @import("std");
const cel_env = @import("../env/env.zig");
const value = @import("../env/value.zig");
const compile_mod = @import("../compiler/compile.zig");
const eval_impl = @import("../eval/eval.zig");
const Activation = @import("../eval/activation.zig").Activation;

pub const urls_library = cel_env.Library{
    .name = "cel.lib.ext.urls",
    .install = installUrlsLibrary,
};

const url_vtable = value.HostValueVTable{
    .type_name = "cel.URL",
    .clone = cloneUrlValue,
    .deinit = deinitUrlValue,
    .eql = eqlUrlValue,
};

const UrlValue = struct {
    raw: []u8,
    uri: std.Uri,
};

fn installUrlsLibrary(environment: *cel_env.Env) !void {
    const t = environment.types.builtins;
    const url_ty = try environment.addHostTypeFromVTable(&url_vtable);
    const list_string = try environment.types.listOf(t.string_type);
    const query_ty = try environment.types.mapOf(t.string_type, list_string);
    _ = try environment.addFunction("url", false, &.{t.string_type}, url_ty, evalUrl);
    _ = try environment.addFunction("isURL", false, &.{t.string_type}, t.bool_type, evalIsUrl);
    _ = try environment.addFunction("getScheme", true, &.{url_ty}, t.string_type, evalUrlGetScheme);
    _ = try environment.addFunction("getHost", true, &.{url_ty}, t.string_type, evalUrlGetHost);
    _ = try environment.addFunction("getHostname", true, &.{url_ty}, t.string_type, evalUrlGetHostname);
    _ = try environment.addFunction("getPort", true, &.{url_ty}, t.string_type, evalUrlGetPort);
    _ = try environment.addFunction("getEscapedPath", true, &.{url_ty}, t.string_type, evalUrlGetEscapedPath);
    _ = try environment.addFunction("getQuery", true, &.{url_ty}, query_ty, evalUrlGetQuery);
}

fn evalUrl(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    return wrapUrl(allocator, try parseUrlText(allocator, args[0].string));
}

fn evalIsUrl(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    const parsed = parseUrlText(allocator, args[0].string) catch return .{ .bool = false };
    allocator.free(parsed.raw);
    return .{ .bool = true };
}

fn evalUrlGetScheme(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    const url = try extractUrl(args);
    return value.string(allocator, url.uri.scheme);
}

fn evalUrlGetHost(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    const url = try extractUrl(args);
    if (url.uri.host) |component| {
        if (url.uri.port) |port| {
            return .{ .string = try std.fmt.allocPrint(allocator, "{f}:{d}", .{
                std.fmt.alt(component, .formatRaw),
                port,
            }) };
        }
        return .{ .string = try std.fmt.allocPrint(allocator, "{f}", .{std.fmt.alt(component, .formatRaw)}) };
    }
    return value.string(allocator, "");
}

fn evalUrlGetHostname(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    const url = try extractUrl(args);
    if (url.uri.host) |component| {
        var host = try std.fmt.allocPrint(allocator, "{f}", .{std.fmt.alt(component, .formatRaw)});
        if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
            const stripped = try allocator.dupe(u8, host[1 .. host.len - 1]);
            allocator.free(host);
            host = stripped;
        }
        return .{ .string = host };
    }
    return value.string(allocator, "");
}

fn evalUrlGetPort(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    const url = try extractUrl(args);
    if (url.uri.port) |port| return .{ .string = try std.fmt.allocPrint(allocator, "{d}", .{port}) };
    return value.string(allocator, "");
}

fn evalUrlGetEscapedPath(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    const url = try extractUrl(args);
    if (url.uri.path.isEmpty()) return value.string(allocator, "");
    const raw_path = try std.fmt.allocPrint(allocator, "{f}", .{std.fmt.alt(url.uri.path, .formatRaw)});
    defer allocator.free(raw_path);
    return .{ .string = try std.fmt.allocPrint(allocator, "{f}", .{std.fmt.alt(std.Uri.Component{ .raw = raw_path }, .formatPath)}) };
}

fn evalUrlGetQuery(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    const url = try extractUrl(args);
    var out: std.ArrayListUnmanaged(value.MapEntry) = .empty;
    errdefer {
        for (out.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        out.deinit(allocator);
    }

    const query_component = url.uri.query orelse return .{ .map = out };
    const query_text = try std.fmt.allocPrint(allocator, "{f}", .{std.fmt.alt(query_component, .formatRaw)});
    defer allocator.free(query_text);

    var it = std.mem.splitScalar(u8, query_text, '&');
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        const eq_idx = std.mem.indexOfScalar(u8, segment, '=') orelse segment.len;
        const key_text = segment[0..eq_idx];
        const raw_value = if (eq_idx < segment.len) segment[eq_idx + 1 ..] else "";
        const key = try plusToSpace(allocator, key_text);
        errdefer allocator.free(key);
        const val_text = try plusToSpace(allocator, raw_value);
        errdefer allocator.free(val_text);

        var found = false;
        for (out.items) |*entry| {
            if (entry.key == .string and std.mem.eql(u8, entry.key.string, key)) {
                try entry.value.list.append(allocator, .{ .string = val_text });
                found = true;
                allocator.free(key);
                break;
            }
        }
        if (!found) {
            var list: std.ArrayListUnmanaged(value.Value) = .empty;
            errdefer {
                for (list.items) |*item| item.deinit(allocator);
                list.deinit(allocator);
            }
            try list.append(allocator, .{ .string = val_text });
            try out.append(allocator, .{
                .key = .{ .string = key },
                .value = .{ .list = list },
            });
        }
    }

    return .{ .map = out };
}

pub fn parseUrlText(allocator: std.mem.Allocator, text: []const u8) cel_env.EvalError!UrlValue {
    if (text.len == 0) return value.RuntimeError.TypeMismatch;
    const raw = try allocator.dupe(u8, text);
    errdefer allocator.free(raw);
    if (std.mem.startsWith(u8, raw, "/") and !std.mem.startsWith(u8, raw, "//")) {
        var path_end = raw.len;
        var fragment: ?std.Uri.Component = null;
        if (std.mem.indexOfScalar(u8, raw, '#')) |fragment_idx| {
            fragment = .{ .raw = raw[fragment_idx + 1 ..] };
            path_end = fragment_idx;
        }

        var query: ?std.Uri.Component = null;
        if (std.mem.indexOfScalar(u8, raw[0..path_end], '?')) |query_idx| {
            query = .{ .raw = raw[query_idx + 1 .. path_end] };
            path_end = query_idx;
        }

        return .{ .raw = raw, .uri = .{
            .scheme = "",
            .path = .{ .raw = raw[0..path_end] },
            .query = query,
            .fragment = fragment,
        } };
    }
    const uri = std.Uri.parse(raw) catch return value.RuntimeError.TypeMismatch;
    if (uri.scheme.len == 0) {
        if (!std.mem.startsWith(u8, raw, "/") or std.mem.startsWith(u8, raw, "//")) return value.RuntimeError.TypeMismatch;
    }
    return .{ .raw = raw, .uri = uri };
}

fn wrapUrl(allocator: std.mem.Allocator, url: UrlValue) std.mem.Allocator.Error!value.Value {
    const ptr = try allocator.create(UrlValue);
    ptr.* = url;
    return value.hostValue(ptr, &url_vtable);
}

fn extractUrl(args: []const value.Value) value.RuntimeError!*const UrlValue {
    if (args.len != 1 or args[0] != .host or args[0].host.vtable != &url_vtable) return value.RuntimeError.TypeMismatch;
    return @ptrCast(@alignCast(args[0].host.ptr));
}

fn cloneUrlValue(allocator: std.mem.Allocator, ptr: *const anyopaque) std.mem.Allocator.Error!*anyopaque {
    const typed: *const UrlValue = @ptrCast(@alignCast(ptr));
    const out = try allocator.create(UrlValue);
    errdefer allocator.destroy(out);
    out.* = parseUrlText(allocator, typed.raw) catch unreachable;
    return out;
}

fn deinitUrlValue(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const typed: *UrlValue = @ptrCast(@alignCast(ptr));
    allocator.free(typed.raw);
    allocator.destroy(typed);
}

fn eqlUrlValue(lhs: *const anyopaque, rhs: *const anyopaque) bool {
    const left: *const UrlValue = @ptrCast(@alignCast(lhs));
    const right: *const UrlValue = @ptrCast(@alignCast(rhs));
    return std.mem.eql(u8, left.raw, right.raw);
}

fn plusToSpace(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, text);
    for (out) |*ch| {
        if (ch.* == '+') ch.* = ' ';
    }
    return out;
}

test "urls library exposes parsed components" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(urls_library);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_][]const u8{
        "isURL('https://example.com/path?k=a&k=b')",
        "url('https://[::1]:80/path?k=a&k=b').getHost() == '[::1]:80'",
        "url('https://[::1]:80/path?k=a&k=b').getHostname() == '::1'",
        "url('https://[::1]:80/path?k=a&k=b').getPort() == '80'",
        "url('https://example.com/path with spaces/').getEscapedPath() == '/path%20with%20spaces/'",
        "url('https://example.com/path?k=a&k=b').getQuery()['k'] == ['a', 'b']",
    };
    for (cases) |expr| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.bool);
    }
}

test "url parsing accepts absolute paths and rejects protocol-relative text" {
    const parsed = try parseUrlText(std.testing.allocator, "/apis/v1/widgets");
    defer std.testing.allocator.free(parsed.raw);
    try std.testing.expectEqual(@as(usize, 0), parsed.uri.scheme.len);
    try std.testing.expectError(value.RuntimeError.TypeMismatch, parseUrlText(std.testing.allocator, "//example.com"));
}

test "url helpers decode queries and expose empty hosts" {
    var path_only = try wrapUrl(std.testing.allocator, try parseUrlText(std.testing.allocator, "/namespaces/default"));
    defer path_only.deinit(std.testing.allocator);
    var host = try evalUrlGetHost(std.testing.allocator, &.{path_only});
    defer host.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", host.string);

    var wrapped = try wrapUrl(std.testing.allocator, try parseUrlText(std.testing.allocator, "https://example.com/search?q=a+b&empty&k=1&k=2"));
    defer wrapped.deinit(std.testing.allocator);
    var query = try evalUrlGetQuery(std.testing.allocator, &.{wrapped});
    defer query.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), query.map.items.len);

    var saw_q = false;
    var saw_empty = false;
    var saw_k = false;
    for (query.map.items) |entry| {
        if (std.mem.eql(u8, entry.key.string, "q")) {
            saw_q = true;
            try std.testing.expectEqual(@as(usize, 1), entry.value.list.items.len);
            try std.testing.expectEqualStrings("a b", entry.value.list.items[0].string);
        } else if (std.mem.eql(u8, entry.key.string, "empty")) {
            saw_empty = true;
            try std.testing.expectEqual(@as(usize, 1), entry.value.list.items.len);
            try std.testing.expectEqualStrings("", entry.value.list.items[0].string);
        } else if (std.mem.eql(u8, entry.key.string, "k")) {
            saw_k = true;
            try std.testing.expectEqual(@as(usize, 2), entry.value.list.items.len);
            try std.testing.expectEqualStrings("1", entry.value.list.items[0].string);
            try std.testing.expectEqualStrings("2", entry.value.list.items[1].string);
        }
    }

    try std.testing.expect(saw_q);
    try std.testing.expect(saw_empty);
    try std.testing.expect(saw_k);
}
