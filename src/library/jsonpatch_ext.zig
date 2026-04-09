const std = @import("std");
const cel_env = @import("../env/env.zig");
const value = @import("../env/value.zig");
const compile_mod = @import("../compiler/compile.zig");
const eval_impl = @import("../eval/eval.zig");
const Activation = @import("../eval/activation.zig").Activation;

pub const jsonpatch_library = cel_env.Library{
    .name = "cel.lib.ext.jsonpatch",
    .install = installJsonPatchLibrary,
};

fn installJsonPatchLibrary(environment: *cel_env.Env) !void {
    const t = environment.types.builtins;
    _ = try environment.addFunction("jsonpatch.escapeKey", false, &.{t.string_type}, t.string_type, evalJsonPatchEscapeKey);
}

fn evalJsonPatchEscapeKey(allocator: std.mem.Allocator, args: []const value.Value) cel_env.EvalError!value.Value {
    if (args.len != 1 or args[0] != .string) return value.RuntimeError.TypeMismatch;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    for (args[0].string) |ch| switch (ch) {
        '~' => try out.appendSlice(allocator, "~0"),
        '/' => try out.appendSlice(allocator, "~1"),
        else => try out.append(allocator, ch),
    };
    return .{ .string = try out.toOwnedSlice(allocator) };
}

test "jsonpatch.escapeKey escapes slash and tilde" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(jsonpatch_library);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    var program = try compile_mod.compile(std.testing.allocator, &environment, "jsonpatch.escapeKey('k8s.io/my~label') == 'k8s.io~1my~0label'");
    defer program.deinit();
    var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.bool);
}
