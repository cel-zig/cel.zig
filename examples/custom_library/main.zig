const std = @import("std");
const cel = @import("cel");

// ---------------------------------------------------------------------------
// Custom library: string utilities
//
// Adds two functions to CEL:
//   str.reverse(string) -> string       reverses a string
//   str.repeat(string, int) -> string   repeats a string N times
// ---------------------------------------------------------------------------

const string_utils_library = cel.Library{
    .name = "example.string_utils",
    .install = installStringUtils,
};

fn installStringUtils(environment: *cel.Env) !void {
    const t = environment.types.builtins;

    // str.reverse("hello") => "olleh"
    _ = try environment.addFunction(
        "str.reverse",
        false,
        &.{t.string_type},
        t.string_type,
        evalStrReverse,
    );

    // str.repeat("ab", 3) => "ababab"
    _ = try environment.addFunction(
        "str.repeat",
        false,
        &.{ t.string_type, t.int_type },
        t.string_type,
        evalStrRepeat,
    );
}

fn evalStrReverse(allocator: std.mem.Allocator, args: []const cel.Value) !cel.Value {
    if (args.len != 1 or args[0] != .string) return error.TypeMismatch;
    const input = args[0].string;

    const out = try allocator.alloc(u8, input.len);
    for (input, 0..) |ch, i| {
        out[input.len - 1 - i] = ch;
    }
    return .{ .string = out };
}

fn evalStrRepeat(allocator: std.mem.Allocator, args: []const cel.Value) !cel.Value {
    if (args.len != 2 or args[0] != .string or args[1] != .int) return error.TypeMismatch;
    const input = args[0].string;
    const count = args[1].int;

    if (count < 0) return error.Overflow;
    const n: usize = @intCast(count);

    const out = try allocator.alloc(u8, input.len * n);
    for (0..n) |i| {
        @memcpy(out[i * input.len ..][0..input.len], input);
    }
    return .{ .string = out };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var environment = try cel.Env.init(allocator, &.{
        cel.withLibrary(string_utils_library),
        cel.variable("name", cel.StringType),
    });
    defer environment.deinit();

    // Compile expressions that use our custom functions
    const cases = [_]struct { source: []const u8 }{
        .{ .source = "str.reverse(name)" },
        .{ .source = "str.repeat(name, 3)" },
        .{ .source = "str.reverse(str.repeat('ab', 2))" },
    };

    var activation = cel.Activation.init(allocator);
    defer activation.deinit();
    try activation.putString("name", "hello");

    for (cases) |case| {
        var program = try environment.compile(case.source);
        defer program.deinit();

        var result = try program.evaluate(allocator, &activation, .{});
        defer result.deinit(allocator);

        std.debug.print("{s}  =>  {s}\n", .{ case.source, result.string });
    }
}
