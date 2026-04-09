const std = @import("std");
const cel = @import("cel");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var environment = try cel.Env.init(allocator, &.{
        cel.variable("count", cel.IntType),
        cel.variable("items", cel.ListType(cel.IntType)),
    });
    defer environment.deinit();

    const source =
        \\count > 1 ? items.map(x, x * count) : []
    ;

    const parsed = try cel.parseExpr(allocator, source);
    var program = try cel.compileParsed(allocator, &environment, parsed);
    defer program.deinit();

    var activation = cel.Activation.init(allocator);
    defer activation.deinit();
    try activation.put("count", .{ .int = 3 });

    var items: std.ArrayListUnmanaged(cel.value.Value) = .empty;
    defer {
        var temp: cel.value.Value = .{ .list = items };
        temp.deinit(allocator);
    }
    try items.append(allocator, .{ .int = 1 });
    try items.append(allocator, .{ .int = 2 });
    try items.append(allocator, .{ .int = 3 });
    try activation.put("items", .{ .list = items });

    var scratch = cel.EvalScratch.init(allocator);
    defer scratch.deinit();

    var result = try cel.evaluateWithScratch(&scratch, &program, &activation);
    defer result.deinit(allocator);

    std.debug.print("source: {s}\n", .{source});
    const type_name = try program.outputType(allocator);
    defer allocator.free(type_name);
    std.debug.print("result_type: {s}\n", .{type_name});
    switch (result) {
        .list => |list| {
            std.debug.print("values:", .{});
            for (list.items) |item| {
                std.debug.print(" {d}", .{item.int});
            }
            std.debug.print("\n", .{});
        },
        else => return error.UnexpectedResultType,
    }
}
