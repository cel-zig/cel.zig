const std = @import("std");
const cel = @import("cel");

const GoResult = struct {
    kind: []const u8,
    bool: ?bool = null,
    int: ?i64 = null,
    uint: ?u64 = null,
    @"error": ?[]const u8 = null,
};

test "cel-go differential corpus" {
    const cases = [_][]const u8{
        "1 + 2 * 3 == 7",
        "[1, 2, 3].map(x, x * 2)[1] == 4",
        "[1, 2, 3].exists_one(x, x == 2)",
        "{'a': 1}.a == 1",
        "size([1, 2, 3]) == 3",
        "'hello'.startsWith('he') && 'hello'.contains('ell') && 'hello'.endsWith('lo')",
        "timestamp('1970-01-01T00:00:10Z') - timestamp('1970-01-01T00:00:00Z') == duration('10s')",
    };

    var environment = try cel.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    var activation = cel.Activation.init(std.testing.allocator);
    defer activation.deinit();

    for (cases) |expr| {
        var program = try cel.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();

        var local = try cel.evaluate(std.testing.allocator, &program, &activation, .{});
        defer local.deinit(std.testing.allocator);

        const go = try runCelGo(expr);
        defer std.testing.allocator.free(go.kind);
        if (go.@"error") |err_text| {
            defer std.testing.allocator.free(err_text);
            std.debug.print("cel-go differential error for `{s}`: {s}\n", .{ expr, err_text });
            return error.TestExpectedEqual;
        }

        switch (local) {
            .bool => |v| {
                try std.testing.expectEqualStrings("bool", go.kind);
                try std.testing.expectEqual(v, go.bool.?);
            },
            .int => |v| {
                try std.testing.expectEqualStrings("int", go.kind);
                try std.testing.expectEqual(v, go.int.?);
            },
            .uint => |v| {
                try std.testing.expectEqualStrings("uint", go.kind);
                try std.testing.expectEqual(v, go.uint.?);
            },
            else => {
                std.debug.print("unsupported local differential result for `{s}`\n", .{expr});
                return error.TestExpectedEqual;
            },
        }
    }
}

fn runCelGo(expr: []const u8) !GoResult {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const repo_root = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(repo_root);
    const tool_dir = try std.fs.path.join(allocator, &.{ repo_root, "tools", "differential" });
    defer allocator.free(tool_dir);

    const run = try std.process.run(allocator, io, .{
        .argv = &.{ "go", "run", ".", expr },
        .cwd = .{ .path = tool_dir },
        .stdout_limit = std.Io.Limit.limited(16 * 1024),
        .stderr_limit = std.Io.Limit.limited(16 * 1024),
    });
    defer allocator.free(run.stdout);
    defer allocator.free(run.stderr);

    switch (run.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("cel-go differential command failed: {s}\n", .{run.stderr});
            return error.TestExpectedEqual;
        },
        else => {
            std.debug.print("cel-go differential command failed: {s}\n", .{run.stderr});
            return error.TestExpectedEqual;
        },
    }

    var parsed = try std.json.parseFromSlice(GoResult, allocator, run.stdout, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    return .{
        .kind = try allocator.dupe(u8, parsed.value.kind),
        .bool = parsed.value.bool,
        .int = parsed.value.int,
        .uint = parsed.value.uint,
        .@"error" = if (parsed.value.@"error") |text| try allocator.dupe(u8, text) else null,
    };
}
