const cel_env = @import("../env/env.zig");
const std = @import("std");

pub const two_var_comprehensions_library = cel_env.Library{
    .name = "cel.lib.ext.comprev2",
    .install = installTwoVarComprehensionsLibrary,
};

fn installTwoVarComprehensionsLibrary(_: *cel_env.Env) !void {}

const compile_mod = @import("../compiler/compile.zig");
const eval_impl = @import("../eval/eval.zig");
const Activation = @import("../eval/activation.zig").Activation;
const value_mod = @import("../env/value.zig");

test "two-variable comprehensions evaluate transform macros" {
    var environment = try cel_env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(two_var_comprehensions_library);

    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_][]const u8{
        "[10, 20, 30].transformMap(i, v, v * 2) == {0: 20, 1: 40, 2: 60}",
        "[10, 20, 30].transformMap(i, v, i > 0, v * 2) == {1: 40, 2: 60}",
        "{'a': 1, 'b': 2}.transformMap(k, v, v + 10) == {'a': 11, 'b': 12}",
        "['x', 'y'].transformMapEntry(i, v, {v: i}) == {'x': 0, 'y': 1}",
        "{'a': 1}.transformMapEntry(k, v, {k: v * 2}) == {'a': 2}",
        "{'a': 1, 'b': 2}.transformList(k, v, k).size() == 2",
    };
    for (cases) |expr| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.bool);
    }

    var duplicate_program = try compile_mod.compile(std.testing.allocator, &environment, "[1, 2].transformMapEntry(i, v, {'dup': i})");
    defer duplicate_program.deinit();
    try std.testing.expectError(
        value_mod.RuntimeError.DuplicateMapKey,
        eval_impl.evalWithOptions(std.testing.allocator, &duplicate_program, &activation, .{}),
    );
}
