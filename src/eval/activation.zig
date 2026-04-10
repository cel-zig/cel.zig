const std = @import("std");
const partial = @import("partial.zig");
const value = @import("../env/value.zig");

pub const Activation = struct {
    allocator: std.mem.Allocator,
    vars: std.StringHashMapUnmanaged(value.Value) = .empty,
    unknown_patterns: std.ArrayListUnmanaged(partial.AttributePattern) = .empty,

    pub fn init(allocator: std.mem.Allocator) Activation {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Activation) void {
        self.clearRetainingCapacity();
        self.vars.deinit(self.allocator);
        self.unknown_patterns.deinit(self.allocator);
    }

    pub fn clearRetainingCapacity(self: *Activation) void {
        var it = self.vars.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.vars.clearRetainingCapacity();
        for (self.unknown_patterns.items) |*pattern| pattern.deinit(self.allocator);
        self.unknown_patterns.clearRetainingCapacity();
    }

    pub fn put(self: *Activation, name: []const u8, val: value.Value) !void {
        const owned_val = try val.clone(self.allocator);
        // putOwned consumes owned_val on both success and failure, so no
        // errdefer needed here.
        try self.putOwned(name, owned_val);
    }

    /// Takes ownership of `val`. On any error path the caller's value is
    /// deinit'd before returning, so callers (including putString/putBytes)
    /// don't need their own errdefer when they pass freshly-allocated values.
    pub fn putOwned(self: *Activation, name: []const u8, val: value.Value) !void {
        var owned = val;
        errdefer owned.deinit(self.allocator);

        if (self.vars.getPtr(name)) |existing| {
            existing.deinit(self.allocator);
            existing.* = owned;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.vars.put(self.allocator, owned_name, owned);
    }

    pub fn putString(self: *Activation, name: []const u8, text: []const u8) !void {
        return self.putOwned(name, .{ .string = try self.allocator.dupe(u8, text) });
    }

    pub fn putBytes(self: *Activation, name: []const u8, data: []const u8) !void {
        return self.putOwned(name, .{ .bytes = try self.allocator.dupe(u8, data) });
    }

    pub fn get(self: *const Activation, name: []const u8) ?value.Value {
        return self.vars.get(name);
    }

    pub fn addUnknownPattern(self: *Activation, pattern: *const partial.AttributePattern) !void {
        try self.unknown_patterns.append(self.allocator, try pattern.clone(self.allocator));
    }

    pub fn addUnknownVariable(self: *Activation, name: []const u8) !void {
        var pattern = try partial.AttributePattern.init(self.allocator, name);
        errdefer pattern.deinit(self.allocator);
        try self.unknown_patterns.append(self.allocator, pattern);
    }
};

test "init and deinit on empty activation" {
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();
    try std.testing.expect(activation.get("anything") == null);
}

test "put and get a value" {
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    try activation.put("x", .{ .int = 42 });
    const got = activation.get("x");
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(i64, 42), got.?.int);
}

test "putOwned with string" {
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const owned = try std.testing.allocator.dupe(u8, "hello");
    try activation.putOwned("greeting", .{ .string = owned });
    try std.testing.expectEqualStrings("hello", activation.get("greeting").?.string);
}

test "putString and putBytes helpers" {
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    try activation.putString("name", "alice");
    try std.testing.expectEqualStrings("alice", activation.get("name").?.string);

    try activation.putBytes("data", "\x01\x02\x03");
    try std.testing.expectEqualStrings("\x01\x02\x03", activation.get("data").?.bytes);
}

test "clearRetainingCapacity and reuse" {
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    try activation.putString("a", "first");
    try activation.put("b", .{ .int = 1 });

    activation.clearRetainingCapacity();
    try std.testing.expect(activation.get("a") == null);
    try std.testing.expect(activation.get("b") == null);

    // Reuse after clear
    try activation.putString("a", "second");
    try std.testing.expectEqualStrings("second", activation.get("a").?.string);
}

test "multiple variables" {
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    try activation.put("x", .{ .int = 1 });
    try activation.put("y", .{ .int = 2 });
    try activation.put("z", .{ .bool = true });

    try std.testing.expectEqual(@as(i64, 1), activation.get("x").?.int);
    try std.testing.expectEqual(@as(i64, 2), activation.get("y").?.int);
    try std.testing.expectEqual(true, activation.get("z").?.bool);
}

test "overwrite existing variable" {
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    try activation.put("x", .{ .int = 1 });
    try std.testing.expectEqual(@as(i64, 1), activation.get("x").?.int);

    try activation.put("x", .{ .int = 99 });
    try std.testing.expectEqual(@as(i64, 99), activation.get("x").?.int);
}

test "get nonexistent variable returns null" {
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    try activation.put("x", .{ .int = 1 });
    try std.testing.expect(activation.get("y") == null);
    try std.testing.expect(activation.get("") == null);
    try std.testing.expect(activation.get("xyz") == null);
}

test "unknown patterns: add and check" {
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    try activation.addUnknownVariable("request");
    try std.testing.expectEqual(@as(usize, 1), activation.unknown_patterns.items.len);
    try std.testing.expectEqualStrings("request", activation.unknown_patterns.items[0].variable);

    var pattern = try partial.AttributePattern.init(std.testing.allocator, "response");
    defer pattern.deinit(std.testing.allocator);
    try pattern.qualString(std.testing.allocator, "body");
    try activation.addUnknownPattern(&pattern);
    try std.testing.expectEqual(@as(usize, 2), activation.unknown_patterns.items.len);
    try std.testing.expectEqualStrings("response", activation.unknown_patterns.items[1].variable);
    try std.testing.expectEqual(@as(usize, 1), activation.unknown_patterns.items[1].qualifiers.items.len);
}

test "clearRetainingCapacity also clears unknown patterns" {
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    try activation.addUnknownVariable("x");
    try activation.addUnknownVariable("y");
    try std.testing.expectEqual(@as(usize, 2), activation.unknown_patterns.items.len);

    activation.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), activation.unknown_patterns.items.len);
}

test "putOwned overwrites existing string value without leak" {
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    try activation.putString("key", "first");
    try activation.putString("key", "second");
    try std.testing.expectEqualStrings("second", activation.get("key").?.string);
}

test "putOwned cleans up val when name dupe fails" {
    // Allow only the original putString's dupe to succeed; the second
    // allocation (owned_name inside putOwned) must fail. The duped value
    // bytes from the outer putString must not leak — testing.allocator
    // detects leaks at deinit.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var activation = Activation.init(failing.allocator());
    defer activation.deinit();

    try std.testing.expectError(error.OutOfMemory, activation.putString("k", "v"));
    try std.testing.expect(activation.get("k") == null);
}

test "putOwned cleans up val when vars.put fails" {
    // First two allocations (value dupe + name dupe) succeed; the
    // hashmap's internal allocation fails. Both the duped string and
    // the duped name must be freed.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    var activation = Activation.init(failing.allocator());
    defer activation.deinit();

    try std.testing.expectError(error.OutOfMemory, activation.putString("k", "v"));
    try std.testing.expect(activation.get("k") == null);
}
