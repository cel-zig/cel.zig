const std = @import("std");
const cel_env = @import("../env/env.zig");
const value = @import("../env/value.zig");
const compile_mod = @import("../compiler/compile.zig");
const eval_impl = @import("../eval/eval.zig");
const Activation = @import("../eval/activation.zig").Activation;

pub const hash_library = cel_env.Library{
    .name = "cel.lib.ext.hash",
    .install = installHashLibrary,
};

fn installHashLibrary(environment: *cel_env.Env) !void {
    const t = environment.types.builtins;
    _ = try environment.addFunction("hash.fnv64a", false, &.{t.string_type}, t.bytes_type, evalHashFnv64a);
    _ = try environment.addFunction("hash.sha256", false, &.{t.string_type}, t.bytes_type, evalHashSha256);
    _ = try environment.addFunction("hash.md5", false, &.{t.string_type}, t.bytes_type, evalHashMd5);
}

fn evalHashFnv64a(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, std.hash.Fnv1a_64.hash(args[0].string), .big);
    return value.bytesValue(allocator, buf[0..]);
}

fn evalHashSha256(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(args[0].string, &digest, .{});
    return value.bytesValue(allocator, digest[0..]);
}

fn evalHashMd5(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(args[0].string, &digest, .{});
    return value.bytesValue(allocator, digest[0..]);
}

test "hash library matches known digests" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(@import("stdlib.zig").standard_library);
    try environment.addLibrary(hash_library);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_][]const u8{
        "base64.encode(hash.fnv64a('hello')) == 'pDDYRoCqvQs='",
        "base64.encode(hash.sha256('hello')) == 'LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ='",
        "base64.encode(hash.md5('hello')) == 'XUFAKrxLKna5cZ2REBfFkg=='",
    };
    for (cases) |expr| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.bool);
    }
}

test "hash library rejects non-string inputs" {
    try std.testing.expectError(value.RuntimeError.TypeMismatch, evalHashFnv64a(std.testing.allocator, &.{.{ .int = 1 }}));
    try std.testing.expectError(value.RuntimeError.TypeMismatch, evalHashSha256(std.testing.allocator, &.{.{ .bool = true }}));
    try std.testing.expectError(value.RuntimeError.TypeMismatch, evalHashMd5(std.testing.allocator, &.{.{ .null = {} }}));
}
