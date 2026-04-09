const std = @import("std");
const env = @import("../env/env.zig");
const stdlib = @import("../library/stdlib.zig");

pub const PrepareError = std.mem.Allocator.Error;

pub fn prepareEnvironment(environment: *env.Env) PrepareError!void {
    try ensureStandardLibrary(environment);
}

fn ensureStandardLibrary(environment: *env.Env) std.mem.Allocator.Error!void {
    environment.addLibrary(stdlib.standard_library) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "prepareEnvironment installs stdlib" {
    const allocator = std.testing.allocator;
    var environment = try env.Env.initDefault(allocator);
    defer environment.deinit();

    try prepareEnvironment(&environment);
    try std.testing.expect(environment.hasLibrary("cel.lib.std"));
}

test "prepareEnvironment is idempotent" {
    const allocator = std.testing.allocator;
    var environment = try env.Env.initDefault(allocator);
    defer environment.deinit();

    try prepareEnvironment(&environment);
    const overload_count_after_first = environment.overloads.items.len;

    try prepareEnvironment(&environment);
    const overload_count_after_second = environment.overloads.items.len;

    try std.testing.expectEqual(overload_count_after_first, overload_count_after_second);
}

test "prepareEnvironment makes stdlib functions available" {
    const allocator = std.testing.allocator;
    var environment = try env.Env.initDefault(allocator);
    defer environment.deinit();

    try prepareEnvironment(&environment);

    // After prepare, there should be overloads registered (stdlib adds many).
    try std.testing.expect(environment.overloads.items.len > 0);

    // Spot-check: the "size" function should be among the dynamic functions.
    var found_size = false;
    for (environment.dynamic_functions.items) |func| {
        if (std.mem.eql(u8, func.name, "size")) {
            found_size = true;
            break;
        }
    }
    try std.testing.expect(found_size);
}
