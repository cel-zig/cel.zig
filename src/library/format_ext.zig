const std = @import("std");
const cel_time = @import("cel_time.zig");
const cel_env = @import("../env/env.zig");
const value = @import("../env/value.zig");
const compile_mod = @import("../compiler/compile.zig");
const eval_impl = @import("../eval/eval.zig");
const Activation = @import("../eval/activation.zig").Activation;

pub const format_library = cel_env.Library{
    .name = "cel.lib.ext.format",
    .install = installFormatLibrary,
};

const format_vtable = value.HostValueVTable{
    .type_name = "cel.Format",
    .clone = cloneFormatValue,
    .deinit = deinitFormatValue,
    .eql = eqlFormatValue,
};

const FormatKind = enum(u8) {
    dns1123_label,
    dns1123_subdomain,
    dns1035_label,
    qualified_name,
    dns1123_label_prefix,
    dns1123_subdomain_prefix,
    dns1035_label_prefix,
    label_value,
    uri,
    uuid,
    byte,
    date,
    datetime,
};

const FormatValue = struct {
    kind: FormatKind,
};

fn installFormatLibrary(environment: *cel_env.Env) !void {
    const t = environment.types.builtins;
    const format_ty = try environment.addHostTypeFromVTable(&format_vtable);
    const list_string = try environment.types.listOf(t.string_type);
    const optional_format = try environment.types.optionalOf(format_ty);
    const optional_string_list = try environment.types.optionalOf(list_string);

    _ = try environment.addFunction("format.named", false, &.{t.string_type}, optional_format, evalFormatNamed);
    _ = try environment.addFunction("validate", true, &.{ format_ty, t.string_type }, optional_string_list, evalFormatValidate);

    inline for ([_]struct { name: []const u8, kind: FormatKind }{
        .{ .name = "format.dns1123Label", .kind = .dns1123_label },
        .{ .name = "format.dns1123Subdomain", .kind = .dns1123_subdomain },
        .{ .name = "format.dns1035Label", .kind = .dns1035_label },
        .{ .name = "format.qualifiedName", .kind = .qualified_name },
        .{ .name = "format.dns1123LabelPrefix", .kind = .dns1123_label_prefix },
        .{ .name = "format.dns1123SubdomainPrefix", .kind = .dns1123_subdomain_prefix },
        .{ .name = "format.dns1035LabelPrefix", .kind = .dns1035_label_prefix },
        .{ .name = "format.labelValue", .kind = .label_value },
        .{ .name = "format.uri", .kind = .uri },
        .{ .name = "format.uuid", .kind = .uuid },
        .{ .name = "format.byte", .kind = .byte },
        .{ .name = "format.date", .kind = .date },
        .{ .name = "format.datetime", .kind = .datetime },
    }) |entry| {
        _ = try environment.addFunction(entry.name, false, &.{}, format_ty, makeFormatFactory(entry.kind));
    }
}

fn makeFormatFactory(comptime kind: FormatKind) cel_env.FunctionImpl {
    return &struct {
        fn f(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
            if (args.len != 0) return value.RuntimeError.TypeMismatch;
            const ptr = try allocator.create(FormatValue);
            ptr.* = .{ .kind = kind };
            return value.hostValue(ptr, &format_vtable);
        }
    }.f;
}

fn evalFormatNamed(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    const kind = formatKindByName(args[0].string) orelse return value.optionalNone();
    const ptr = try allocator.create(FormatValue);
    ptr.* = .{ .kind = kind };
    return value.optionalSome(allocator, value.hostValue(ptr, &format_vtable));
}

fn evalFormatValidate(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 2 or args[1] != .string) return value.RuntimeError.TypeMismatch;
    const fmt = try extractFormat(args[0..1]);
    var messages = try validateFormat(allocator, fmt.kind, args[1].string);
    if (messages.items.len == 0) {
        messages.deinit(allocator);
        return value.optionalNone();
    }
    return value.optionalSome(allocator, .{ .list = messages });
}

fn wrapFormat(allocator: std.mem.Allocator, kind: FormatKind) std.mem.Allocator.Error!value.Value {
    const ptr = try allocator.create(FormatValue);
    ptr.* = .{ .kind = kind };
    return value.hostValue(ptr, &format_vtable);
}

fn extractFormat(args: []const value.Value) value.RuntimeError!*const FormatValue {
    if (args.len != 1 or args[0] != .host or args[0].host.vtable != &format_vtable) return value.RuntimeError.TypeMismatch;
    return @ptrCast(@alignCast(args[0].host.ptr));
}

fn cloneFormatValue(allocator: std.mem.Allocator, ptr: *const anyopaque) std.mem.Allocator.Error!*anyopaque {
    const typed: *const FormatValue = @ptrCast(@alignCast(ptr));
    const out = try allocator.create(FormatValue);
    out.* = typed.*;
    return out;
}

fn deinitFormatValue(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const typed: *FormatValue = @ptrCast(@alignCast(ptr));
    allocator.destroy(typed);
}

fn eqlFormatValue(lhs: *const anyopaque, rhs: *const anyopaque) bool {
    const left: *const FormatValue = @ptrCast(@alignCast(lhs));
    const right: *const FormatValue = @ptrCast(@alignCast(rhs));
    return left.kind == right.kind;
}

fn formatKindByName(name: []const u8) ?FormatKind {
    const entries = [_]struct { name: []const u8, kind: FormatKind }{
        .{ .name = "dns1123Label", .kind = .dns1123_label },
        .{ .name = "dns1123Subdomain", .kind = .dns1123_subdomain },
        .{ .name = "dns1035Label", .kind = .dns1035_label },
        .{ .name = "qualifiedName", .kind = .qualified_name },
        .{ .name = "dns1123LabelPrefix", .kind = .dns1123_label_prefix },
        .{ .name = "dns1123SubdomainPrefix", .kind = .dns1123_subdomain_prefix },
        .{ .name = "dns1035LabelPrefix", .kind = .dns1035_label_prefix },
        .{ .name = "labelValue", .kind = .label_value },
        .{ .name = "uri", .kind = .uri },
        .{ .name = "uuid", .kind = .uuid },
        .{ .name = "byte", .kind = .byte },
        .{ .name = "date", .kind = .date },
        .{ .name = "datetime", .kind = .datetime },
    };
    for (entries) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.kind;
    }
    return null;
}

fn validateFormat(allocator: std.mem.Allocator, kind: FormatKind, text: []const u8) !std.ArrayListUnmanaged(value.Value) {
    var out: std.ArrayListUnmanaged(value.Value) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }

    const addError = struct {
        fn f(list: *std.ArrayListUnmanaged(value.Value), alloc: std.mem.Allocator, message: []const u8) !void {
            try list.append(alloc, try value.string(alloc, message));
        }
    }.f;

    switch (kind) {
        .dns1123_label => if (!isDns1123Label(text)) try addError(&out, allocator, "must be a DNS-1123 label"),
        .dns1123_subdomain => if (!isDns1123Subdomain(text)) try addError(&out, allocator, "must be a DNS-1123 subdomain"),
        .dns1035_label => if (!isDns1035Label(text)) try addError(&out, allocator, "must be a DNS-1035 label"),
        .qualified_name => if (!isQualifiedName(text)) try addError(&out, allocator, "must be a qualified name"),
        .dns1123_label_prefix => if (!isDns1123LabelPrefix(text)) try addError(&out, allocator, "must be a DNS-1123 label prefix"),
        .dns1123_subdomain_prefix => if (!isDns1123SubdomainPrefix(text)) try addError(&out, allocator, "must be a DNS-1123 subdomain prefix"),
        .dns1035_label_prefix => if (!isDns1035LabelPrefix(text)) try addError(&out, allocator, "must be a DNS-1035 label prefix"),
        .label_value => if (!isLabelValue(text)) try addError(&out, allocator, "must be a valid label value"),
        .uri => if (!isUri(text)) try addError(&out, allocator, "invalid URI"),
        .uuid => if (!isUuid(text)) try addError(&out, allocator, "does not match the UUID format"),
        .byte => if (!isBase64(text)) try addError(&out, allocator, "invalid base64"),
        .date => if (!isDate(text)) try addError(&out, allocator, "invalid date"),
        .datetime => if (!isDateTime(text)) try addError(&out, allocator, "invalid datetime"),
    }
    return out;
}

fn isDns1123Label(text: []const u8) bool {
    if (text.len == 0 or text.len > 63) return false;
    if (!isLowerAlnum(text[0]) or !isLowerAlnum(text[text.len - 1])) return false;
    for (text) |ch| {
        if (!isLowerAlnum(ch) and ch != '-') return false;
    }
    return true;
}

fn isDns1123Subdomain(text: []const u8) bool {
    if (text.len == 0 or text.len > 253) return false;
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |part| {
        if (!isDns1123Label(part)) return false;
    }
    return true;
}

fn isDns1035Label(text: []const u8) bool {
    if (text.len == 0 or text.len > 63) return false;
    if (!isLowerAlpha(text[0]) or !isLowerAlnum(text[text.len - 1])) return false;
    for (text[1..]) |ch| {
        if (!isLowerAlnum(ch) and ch != '-') return false;
    }
    return true;
}

fn isDns1123LabelPrefix(text: []const u8) bool {
    if (text.len == 0) return false;
    const trimmed = std.mem.trimEnd(u8, text, "-");
    return trimmed.len != 0 and isDns1123Label(trimmed);
}

fn isDns1123SubdomainPrefix(text: []const u8) bool {
    if (text.len == 0) return false;
    const trimmed = std.mem.trimEnd(u8, text, "-.");
    return trimmed.len != 0 and isDns1123Subdomain(trimmed);
}

fn isDns1035LabelPrefix(text: []const u8) bool {
    if (text.len == 0) return false;
    const trimmed = std.mem.trimEnd(u8, text, "-");
    return trimmed.len != 0 and isDns1035Label(trimmed);
}

fn isQualifiedName(text: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, text, '/');
    if (slash) |idx| {
        if (!isDns1123Subdomain(text[0..idx])) return false;
        return isLabelName(text[idx + 1 ..]);
    }
    return isLabelName(text);
}

fn isLabelValue(text: []const u8) bool {
    if (text.len == 0) return true;
    return isLabelName(text);
}

fn isLabelName(text: []const u8) bool {
    if (text.len == 0 or text.len > 63) return false;
    if (!isAsciiAlnum(text[0]) or !isAsciiAlnum(text[text.len - 1])) return false;
    for (text) |ch| {
        if (!isAsciiAlnum(ch) and ch != '-' and ch != '_' and ch != '.') return false;
    }
    return true;
}

fn isUri(text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.mem.startsWith(u8, text, "/") and !std.mem.startsWith(u8, text, "//")) return true;
    const parsed = std.Uri.parse(text) catch return false;
    if (parsed.scheme.len == 0) {
        return std.mem.startsWith(u8, text, "/") and !std.mem.startsWith(u8, text, "//");
    }
    return true;
}

fn isUuid(text: []const u8) bool {
    if (text.len != 36) return false;
    const dash_positions = [_]usize{ 8, 13, 18, 23 };
    for (dash_positions) |idx| {
        if (text[idx] != '-') return false;
    }
    for (text, 0..) |ch, idx| {
        if (idx == 8 or idx == 13 or idx == 18 or idx == 23) continue;
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

fn isBase64(text: []const u8) bool {
    const len = std.base64.standard.Decoder.calcSizeForSlice(text) catch return false;
    const buf = std.heap.page_allocator.alloc(u8, len) catch return false;
    defer std.heap.page_allocator.free(buf);
    std.base64.standard.Decoder.decode(buf, text) catch return false;
    return true;
}

fn isDate(text: []const u8) bool {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return false;
    const year = std.fmt.parseInt(i32, text[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return false;
    if (month == 0 or month > 12 or day == 0) return false;
    return day <= daysInMonth(year, month);
}

fn isDateTime(text: []const u8) bool {
    _ = cel_time.parseTimestamp(text) catch return false;
    return true;
}

fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
}

fn isLowerAlpha(ch: u8) bool {
    return ch >= 'a' and ch <= 'z';
}

fn isLowerAlnum(ch: u8) bool {
    return isLowerAlpha(ch) or std.ascii.isDigit(ch);
}

fn isAsciiAlnum(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch);
}

test "format library supports validation" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(@import("stdlib.zig").standard_library);
    try environment.addLibrary(format_library);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_][]const u8{
        "!format.dns1123Label().validate('my-name').hasValue()",
        "format.named('uuid').hasValue()",
        "format.named('dns1123Label').value().validate('UPPER').hasValue()",
    };
    for (cases) |expr| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.bool);
    }
}

test "format named lookup returns optional some or none" {
    var known_name = try value.string(std.testing.allocator, "date");
    defer known_name.deinit(std.testing.allocator);
    var known = try evalFormatNamed(std.testing.allocator, &.{known_name});
    defer known.deinit(std.testing.allocator);
    try std.testing.expect(known == .optional);
    try std.testing.expect(known.optional.value != null);

    var unknown_name = try value.string(std.testing.allocator, "missing");
    defer unknown_name.deinit(std.testing.allocator);
    var unknown = try evalFormatNamed(std.testing.allocator, &.{unknown_name});
    defer unknown.deinit(std.testing.allocator);
    try std.testing.expect(unknown == .optional);
    try std.testing.expect(unknown.optional.value == null);
    try std.testing.expect(formatKindByName("dns1123Label") != null);
    try std.testing.expect(formatKindByName("missing") == null);
}

test "format validation covers leap dates uri paths and base64" {
    var leap_date = try validateFormat(std.testing.allocator, .date, "2024-02-29");
    defer {
        for (leap_date.items) |*item| item.deinit(std.testing.allocator);
        leap_date.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 0), leap_date.items.len);

    var invalid_date = try validateFormat(std.testing.allocator, .date, "2023-02-29");
    defer {
        for (invalid_date.items) |*item| item.deinit(std.testing.allocator);
        invalid_date.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), invalid_date.items.len);
    try std.testing.expectEqualStrings("invalid date", invalid_date.items[0].string);

    var relative_uri = try validateFormat(std.testing.allocator, .uri, "/namespaces/default");
    defer {
        for (relative_uri.items) |*item| item.deinit(std.testing.allocator);
        relative_uri.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 0), relative_uri.items.len);

    var protocol_relative = try validateFormat(std.testing.allocator, .uri, "//example.com");
    defer {
        for (protocol_relative.items) |*item| item.deinit(std.testing.allocator);
        protocol_relative.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), protocol_relative.items.len);
    try std.testing.expectEqualStrings("invalid URI", protocol_relative.items[0].string);

    var invalid_base64 = try validateFormat(std.testing.allocator, .byte, "%");
    defer {
        for (invalid_base64.items) |*item| item.deinit(std.testing.allocator);
        invalid_base64.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), invalid_base64.items.len);
    try std.testing.expectEqualStrings("invalid base64", invalid_base64.items[0].string);
}
