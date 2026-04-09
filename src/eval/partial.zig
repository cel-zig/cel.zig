const std = @import("std");

pub const Qualifier = union(enum) {
    wildcard,
    string: []u8,
    int: i64,
    uint: u64,
    double: f64,
    bool: bool,

    pub fn clone(self: Qualifier, allocator: std.mem.Allocator) !Qualifier {
        return switch (self) {
            .wildcard, .int, .uint, .double, .bool => self,
            .string => |text| .{ .string = try allocator.dupe(u8, text) },
        };
    }

    pub fn deinit(self: *Qualifier, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |text| allocator.free(text),
            else => {},
        }
    }

    pub fn eql(a: Qualifier, b: Qualifier) bool {
        const tag_a = std.meta.activeTag(a);
        const tag_b = std.meta.activeTag(b);
        if (tag_a != tag_b) return false;
        return switch (a) {
            .wildcard => true,
            .string => |text| std.mem.eql(u8, text, b.string),
            .int => |v| v == b.int,
            .uint => |v| v == b.uint,
            .double => |v| v == b.double,
            .bool => |v| v == b.bool,
        };
    }

    pub fn matchesPattern(actual: Qualifier, pattern: Qualifier) bool {
        if (pattern == .wildcard) return true;
        return switch (actual) {
            .int => |left| switch (pattern) {
                .int => left == pattern.int,
                .uint => if (left < 0) false else @as(u64, @intCast(left)) == pattern.uint,
                .double => numericEqual(@as(f64, @floatFromInt(left)), pattern.double),
                else => false,
            },
            .uint => |left| switch (pattern) {
                .int => if (pattern.int < 0) false else left == @as(u64, @intCast(pattern.int)),
                .uint => left == pattern.uint,
                .double => numericEqual(@as(f64, @floatFromInt(left)), pattern.double),
                else => false,
            },
            .double => |left| switch (pattern) {
                .int => numericEqual(left, @as(f64, @floatFromInt(pattern.int))),
                .uint => numericEqual(left, @as(f64, @floatFromInt(pattern.uint))),
                .double => numericEqual(left, pattern.double),
                else => false,
            },
            else => actual.eql(pattern),
        };
    }
};

fn numericEqual(lhs: f64, rhs: f64) bool {
    return std.math.isFinite(lhs) and std.math.isFinite(rhs) and lhs == rhs;
}

pub const AttributePattern = struct {
    variable: []u8,
    qualifiers: std.ArrayListUnmanaged(Qualifier) = .empty,

    pub fn init(allocator: std.mem.Allocator, variable: []const u8) !AttributePattern {
        return .{ .variable = try allocator.dupe(u8, variable) };
    }

    pub fn deinit(self: *AttributePattern, allocator: std.mem.Allocator) void {
        allocator.free(self.variable);
        for (self.qualifiers.items) |*qualifier| qualifier.deinit(allocator);
        self.qualifiers.deinit(allocator);
    }

    pub fn clone(self: *const AttributePattern, allocator: std.mem.Allocator) !AttributePattern {
        var out = try init(allocator, self.variable);
        errdefer out.deinit(allocator);
        try out.qualifiers.ensureTotalCapacity(allocator, self.qualifiers.items.len);
        for (self.qualifiers.items) |qualifier| {
            out.qualifiers.appendAssumeCapacity(try qualifier.clone(allocator));
        }
        return out;
    }

    pub fn qualString(self: *AttributePattern, allocator: std.mem.Allocator, value: []const u8) !void {
        try self.qualifiers.append(allocator, .{ .string = try allocator.dupe(u8, value) });
    }

    pub fn qualInt(self: *AttributePattern, allocator: std.mem.Allocator, value: i64) !void {
        try self.qualifiers.append(allocator, .{ .int = value });
    }

    pub fn qualUint(self: *AttributePattern, allocator: std.mem.Allocator, value: u64) !void {
        try self.qualifiers.append(allocator, .{ .uint = value });
    }

    pub fn qualBool(self: *AttributePattern, allocator: std.mem.Allocator, value: bool) !void {
        try self.qualifiers.append(allocator, .{ .bool = value });
    }

    pub fn wildcard(self: *AttributePattern, allocator: std.mem.Allocator) !void {
        try self.qualifiers.append(allocator, .wildcard);
    }

    pub fn overlapMatch(self: *const AttributePattern, trail: *const AttributeTrail) ?usize {
        if (!std.mem.eql(u8, self.variable, trail.variable)) return null;
        const shared = @min(self.qualifiers.items.len, trail.qualifiers.items.len);
        for (0..shared) |i| {
            if (!trail.qualifiers.items[i].matchesPattern(self.qualifiers.items[i])) return null;
        }
        return shared;
    }
};

pub const AttributeTrail = struct {
    variable: []u8,
    qualifiers: std.ArrayListUnmanaged(Qualifier) = .empty,

    pub fn init(allocator: std.mem.Allocator, variable: []const u8) !AttributeTrail {
        return .{ .variable = try allocator.dupe(u8, variable) };
    }

    pub fn deinit(self: *AttributeTrail, allocator: std.mem.Allocator) void {
        allocator.free(self.variable);
        for (self.qualifiers.items) |*qualifier| qualifier.deinit(allocator);
        self.qualifiers.deinit(allocator);
    }

    pub fn clone(self: *const AttributeTrail, allocator: std.mem.Allocator) !AttributeTrail {
        var out = try init(allocator, self.variable);
        errdefer out.deinit(allocator);
        try out.qualifiers.ensureTotalCapacity(allocator, self.qualifiers.items.len);
        for (self.qualifiers.items) |qualifier| {
            out.qualifiers.appendAssumeCapacity(try qualifier.clone(allocator));
        }
        return out;
    }

    pub fn append(self: *AttributeTrail, allocator: std.mem.Allocator, qualifier: Qualifier) !void {
        try self.qualifiers.append(allocator, try qualifier.clone(allocator));
    }

    pub fn eql(a: *const AttributeTrail, b: *const AttributeTrail) bool {
        if (!std.mem.eql(u8, a.variable, b.variable)) return false;
        if (a.qualifiers.items.len != b.qualifiers.items.len) return false;
        for (a.qualifiers.items, b.qualifiers.items) |lhs, rhs| {
            if (!lhs.eql(rhs)) return false;
        }
        return true;
    }
};

pub const UnknownCause = struct {
    expr_id: i64,
    trail: AttributeTrail,
};

pub const UnknownSet = struct {
    causes: std.ArrayListUnmanaged(UnknownCause) = .empty,

    pub fn deinit(self: *UnknownSet, allocator: std.mem.Allocator) void {
        for (self.causes.items) |*cause| cause.trail.deinit(allocator);
        self.causes.deinit(allocator);
    }

    pub fn clone(self: *const UnknownSet, allocator: std.mem.Allocator) !UnknownSet {
        var out: UnknownSet = .{};
        errdefer out.deinit(allocator);
        try out.causes.ensureTotalCapacity(allocator, self.causes.items.len);
        for (self.causes.items) |cause| {
            out.causes.appendAssumeCapacity(.{
                .expr_id = cause.expr_id,
                .trail = try cause.trail.clone(allocator),
            });
        }
        return out;
    }

    pub fn add(self: *UnknownSet, allocator: std.mem.Allocator, expr_id: i64, trail: AttributeTrail) !void {
        for (self.causes.items) |existing| {
            if (existing.expr_id == expr_id and existing.trail.eql(&trail)) {
                var temp = trail;
                temp.deinit(allocator);
                return;
            }
        }
        try self.causes.append(allocator, .{
            .expr_id = expr_id,
            .trail = trail,
        });
    }

    pub fn merge(self: *UnknownSet, allocator: std.mem.Allocator, other: *const UnknownSet) !void {
        for (other.causes.items) |cause| {
            try self.add(allocator, cause.expr_id, try cause.trail.clone(allocator));
        }
    }

    pub fn eql(a: *const UnknownSet, b: *const UnknownSet) bool {
        if (a.causes.items.len != b.causes.items.len) return false;
        for (a.causes.items) |lhs| {
            var found = false;
            for (b.causes.items) |rhs| {
                if (lhs.expr_id == rhs.expr_id and lhs.trail.eql(&rhs.trail)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }
};

pub fn singletonUnknown(
    allocator: std.mem.Allocator,
    expr_id: i64,
    variable: []const u8,
    qualifiers: []const Qualifier,
) !UnknownSet {
    var trail = try AttributeTrail.init(allocator, variable);
    errdefer trail.deinit(allocator);
    for (qualifiers) |qualifier| {
        try trail.append(allocator, qualifier);
    }
    var set: UnknownSet = .{};
    try set.add(allocator, expr_id, trail);
    return set;
}

test "unknown sets merge and dedupe" {
    var set = try singletonUnknown(std.testing.allocator, 1, "x", &.{});
    defer set.deinit(std.testing.allocator);

    var other = try singletonUnknown(std.testing.allocator, 1, "x", &.{});
    defer other.deinit(std.testing.allocator);
    try set.merge(std.testing.allocator, &other);

    try std.testing.expectEqual(@as(usize, 1), set.causes.items.len);
}

test "attribute pattern overlap handles prefix and numeric qualifiers" {
    var pattern = try AttributePattern.init(std.testing.allocator, "a");
    defer pattern.deinit(std.testing.allocator);
    try pattern.qualString(std.testing.allocator, "b");
    try pattern.qualInt(std.testing.allocator, 1);

    var trail = try AttributeTrail.init(std.testing.allocator, "a");
    defer trail.deinit(std.testing.allocator);
    var field: Qualifier = .{ .string = try std.testing.allocator.dupe(u8, "b") };
    defer field.deinit(std.testing.allocator);
    try trail.append(std.testing.allocator, field);
    try trail.append(std.testing.allocator, .{ .double = 1.0 });

    try std.testing.expectEqual(@as(?usize, 2), pattern.overlapMatch(&trail));
}

test "UnknownSet creation and basic operations" {
    var set = try singletonUnknown(std.testing.allocator, 1, "x", &.{});
    defer set.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), set.causes.items.len);
    try std.testing.expectEqual(@as(i64, 1), set.causes.items[0].expr_id);
    try std.testing.expectEqualStrings("x", set.causes.items[0].trail.variable);
}

test "UnknownSet merge combines distinct causes" {
    var set_a = try singletonUnknown(std.testing.allocator, 1, "x", &.{});
    defer set_a.deinit(std.testing.allocator);

    var set_b = try singletonUnknown(std.testing.allocator, 2, "y", &.{});
    defer set_b.deinit(std.testing.allocator);

    try set_a.merge(std.testing.allocator, &set_b);
    try std.testing.expectEqual(@as(usize, 2), set_a.causes.items.len);
}

test "UnknownSet eql checks content equality" {
    var set_a = try singletonUnknown(std.testing.allocator, 1, "x", &.{});
    defer set_a.deinit(std.testing.allocator);

    var set_b = try singletonUnknown(std.testing.allocator, 1, "x", &.{});
    defer set_b.deinit(std.testing.allocator);

    try std.testing.expect(set_a.eql(&set_b));

    var set_c = try singletonUnknown(std.testing.allocator, 2, "y", &.{});
    defer set_c.deinit(std.testing.allocator);

    try std.testing.expect(!set_a.eql(&set_c));
}

test "UnknownSet clone produces independent copy" {
    var original = try singletonUnknown(std.testing.allocator, 1, "x", &.{});
    defer original.deinit(std.testing.allocator);

    var cloned = try original.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expect(original.eql(&cloned));
    try std.testing.expectEqual(@as(usize, 1), cloned.causes.items.len);
}

test "AttributePattern with qualifiers matches trail" {
    var pattern = try AttributePattern.init(std.testing.allocator, "req");
    defer pattern.deinit(std.testing.allocator);
    try pattern.qualString(std.testing.allocator, "auth");
    try pattern.wildcard(std.testing.allocator);

    // Trail that matches the pattern
    var trail = try AttributeTrail.init(std.testing.allocator, "req");
    defer trail.deinit(std.testing.allocator);
    var q1: Qualifier = .{ .string = try std.testing.allocator.dupe(u8, "auth") };
    defer q1.deinit(std.testing.allocator);
    try trail.append(std.testing.allocator, q1);
    try trail.append(std.testing.allocator, .{ .int = 42 });

    try std.testing.expectEqual(@as(?usize, 2), pattern.overlapMatch(&trail));
}

test "AttributePattern no match on different variable" {
    var pattern = try AttributePattern.init(std.testing.allocator, "req");
    defer pattern.deinit(std.testing.allocator);

    var trail = try AttributeTrail.init(std.testing.allocator, "other");
    defer trail.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?usize, null), pattern.overlapMatch(&trail));
}

test "AttributeTrail eql and clone" {
    var trail_a = try AttributeTrail.init(std.testing.allocator, "x");
    defer trail_a.deinit(std.testing.allocator);
    try trail_a.append(std.testing.allocator, .{ .int = 1 });

    var trail_b = try trail_a.clone(std.testing.allocator);
    defer trail_b.deinit(std.testing.allocator);

    try std.testing.expect(trail_a.eql(&trail_b));

    // Different trail
    var trail_c = try AttributeTrail.init(std.testing.allocator, "x");
    defer trail_c.deinit(std.testing.allocator);
    try trail_c.append(std.testing.allocator, .{ .int = 2 });

    try std.testing.expect(!trail_a.eql(&trail_c));
}

test "Qualifier matchesPattern" {
    const cases = [_]struct {
        qualifier: Qualifier,
        pattern: Qualifier,
        expected: bool,
    }{
        // wildcard matches everything
        .{ .qualifier = .{ .int = 42 }, .pattern = .wildcard, .expected = true },
        .{ .qualifier = .{ .uint = 10 }, .pattern = .wildcard, .expected = true },
        .{ .qualifier = .{ .double = 3.14 }, .pattern = .wildcard, .expected = true },
        // cross-numeric: int matches uint
        .{ .qualifier = .{ .int = 5 }, .pattern = .{ .uint = 5 }, .expected = true },
        // cross-numeric: uint matches int
        .{ .qualifier = .{ .uint = 5 }, .pattern = .{ .int = 5 }, .expected = true },
        // cross-numeric: int matches double
        .{ .qualifier = .{ .int = 5 }, .pattern = .{ .double = 5.0 }, .expected = true },
        // negative int does not match uint
        .{ .qualifier = .{ .int = -1 }, .pattern = .{ .uint = 1 }, .expected = false },
        // exact int match
        .{ .qualifier = .{ .int = 7 }, .pattern = .{ .int = 7 }, .expected = true },
        // int mismatch
        .{ .qualifier = .{ .int = 7 }, .pattern = .{ .int = 8 }, .expected = false },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, case.qualifier.matchesPattern(case.pattern));
    }
}

test "singletonUnknown with qualifiers" {
    var set = try singletonUnknown(std.testing.allocator, 3, "request", &.{.{ .string = @constCast("auth") }});
    defer set.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), set.causes.items.len);
    try std.testing.expectEqual(@as(usize, 1), set.causes.items[0].trail.qualifiers.items.len);
    try std.testing.expectEqualStrings("auth", set.causes.items[0].trail.qualifiers.items[0].string);
}
