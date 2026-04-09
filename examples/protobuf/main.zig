const std = @import("std");
const cel = @import("cel");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var environment = try cel.Env.initDefault(allocator);
    defer environment.deinit();

    _ = try environment.addMessage("example.Counter");
    try environment.addProtobufFieldWithPresence(
        "example.Counter",
        "count",
        1,
        environment.types.builtins.int_type,
        .{ .singular = .{ .scalar = .int64 } },
        .explicit,
    );
    try environment.addVarTyped("msg", try environment.types.messageOf("example.Counter"));

    const encoded = [_]u8{ 0x08, 0x7b };
    var decoded = try cel.library.protobuf.decodeMessage(allocator, &environment, "example.Counter", &encoded);
    defer decoded.deinit(allocator);

    var activation = cel.Activation.init(allocator);
    defer activation.deinit();
    try activation.put("msg", decoded);

    const source =
        \\has(msg.count) && msg.count == 123
    ;

    var program = try environment.compile(source);
    defer program.deinit();

    var result = try program.evaluate(allocator, &activation, .{});
    defer result.deinit(allocator);

    std.debug.print("source: {s}\n", .{source});
    std.debug.print("result: {any}\n", .{result.bool});
}
