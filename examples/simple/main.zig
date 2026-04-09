const std = @import("std");
const cel = @import("cel");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var environment = try cel.Env.init(allocator, &.{
        cel.variable("a", cel.IntType),
        cel.variable("name", cel.StringType),
        cel.variable("items", cel.ListType(cel.IntType)),
    });
    defer environment.deinit();

    const source =
        \\a < 10 && name.contains('x') ? size(items) : 0
    ;

    var program = try environment.compile(source);
    defer program.deinit();

    var activation = cel.Activation.init(allocator);
    defer activation.deinit();

    try activation.put("a", .{ .int = 5 });

    var name_value = try cel.value.string(allocator, "x-ray");
    defer name_value.deinit(allocator);
    try activation.put("name", name_value);

    var items: std.ArrayListUnmanaged(cel.value.Value) = .empty;
    defer {
        var temp: cel.value.Value = .{ .list = items };
        temp.deinit(allocator);
    }
    try items.append(allocator, .{ .int = 1 });
    try items.append(allocator, .{ .int = 2 });
    try items.append(allocator, .{ .int = 3 });
    try activation.put("items", .{ .list = items });

    var result = try program.evaluate(allocator, &activation, .{});
    defer result.deinit(allocator);

    std.debug.print("source: {s}\n", .{source});
    switch (result) {
        .int => |value| std.debug.print("result: {d}\n", .{value}),
        else => return error.UnexpectedResultType,
    }
}
