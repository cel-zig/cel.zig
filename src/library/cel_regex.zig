const std = @import("std");
const cel_env = @import("../env/env.zig");
const value_mod = @import("../env/value.zig");

pub const Error = std.mem.Allocator.Error || error{
    InvalidPattern,
};

const Index = enum(u32) { _ };

const Range = struct {
    start: u32,
    len: u32,
};

const Repeat = struct {
    child: Index,
    min: usize,
    max: ?usize,
};

const Node = union(enum) {
    empty,
    literal: u21,
    any,
    concat: Range,
    alt: Range,
    repeat: Repeat,
};

const Pattern = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    ranges: std.ArrayListUnmanaged(Index) = .empty,
    root: Index,

    fn deinit(self: *Pattern) void {
        self.nodes.deinit(self.allocator);
        self.ranges.deinit(self.allocator);
    }

    fn addNode(self: *Pattern, node: Node) !Index {
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, node);
        return @enumFromInt(idx);
    }

    fn appendRange(self: *Pattern, values: []const Index) !Range {
        const start: u32 = @intCast(self.ranges.items.len);
        try self.ranges.appendSlice(self.allocator, values);
        return .{
            .start = start,
            .len = @intCast(values.len),
        };
    }
};

pub fn matches(allocator: std.mem.Allocator, text: []const u8, pattern_text: []const u8) Error!bool {
    var compiled = try compilePattern(allocator, pattern_text);
    defer compiled.deinit();

    const text_runes = try decodeUtf8(allocator, text);
    defer allocator.free(text_runes);

    return try matcherMatches(allocator, &compiled, text_runes);
}

fn compilePattern(allocator: std.mem.Allocator, pattern_text: []const u8) Error!Pattern {
    const pattern_runes = try decodeUtf8(allocator, pattern_text);
    defer allocator.free(pattern_runes);

    var parser = Parser{
        .allocator = allocator,
        .pattern = pattern_runes,
    };
    return parser.parse();
}

// ---------------------------------------------------------------------------
// Compile-time precompile interface for the matches() builtin.
//
// Allows the optimizer to compile a literal regex pattern once at program
// creation time. The compiled Pattern is stored on the Program as an
// opaque artifact and reused on every eval call, skipping re-parsing.
// ---------------------------------------------------------------------------

/// Called at compile time. args[0] is the receiver text (typically
/// runtime data, so usually null). args[1] is the pattern -- if it's
/// a string literal we compile it once and cache the result.
pub fn prepareMatches(allocator: std.mem.Allocator, args: []const ?value_mod.Value) anyerror!*anyopaque {
    if (args.len != 2) return error.Skip;
    const pattern_val = args[1] orelse return error.Skip;
    if (pattern_val != .string) return error.Skip;
    const compiled = try compilePattern(allocator, pattern_val.string);
    const ptr = try allocator.create(Pattern);
    ptr.* = compiled;
    return @ptrCast(ptr);
}

/// Called at eval time when a precompiled pattern exists. Skips
/// pattern re-parsing and runs the matcher directly.
pub fn evalMatchesPrepared(
    allocator: std.mem.Allocator,
    ctx: *anyopaque,
    args: []const value_mod.Value,
) cel_env.EvalError!value_mod.Value {
    const pattern: *const Pattern = @ptrCast(@alignCast(ctx));
    if (args.len < 1 or args[0] != .string) return value_mod.RuntimeError.TypeMismatch;
    const text_runes = decodeUtf8(allocator, args[0].string) catch return error.OutOfMemory;
    defer allocator.free(text_runes);
    const result = matcherMatches(allocator, pattern, text_runes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return value_mod.RuntimeError.TypeMismatch,
    };
    return .{ .bool = result };
}

/// Called once when the Program is deinit'd.
pub fn destroyMatchesPattern(allocator: std.mem.Allocator, ctx: *anyopaque) void {
    const pattern: *Pattern = @ptrCast(@alignCast(ctx));
    pattern.deinit();
    allocator.destroy(pattern);
}

pub const matches_precompile = cel_env.Precompile{
    .prepare = prepareMatches,
    .eval = evalMatchesPrepared,
    .destroy = destroyMatchesPattern,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    pattern: []const u21,
    pos: usize = 0,
    scratch: std.ArrayListUnmanaged(Index) = .empty,

    fn parse(self: *Parser) Error!Pattern {
        var compiled = Pattern{
            .allocator = self.allocator,
            .root = undefined,
        };
        errdefer compiled.deinit();
        defer self.scratch.deinit(self.allocator);

        compiled.root = try self.parseAlternation(&compiled);
        if (self.pos != self.pattern.len) return Error.InvalidPattern;
        return compiled;
    }

    fn parseAlternation(self: *Parser, compiled: *Pattern) Error!Index {
        var parts: std.ArrayListUnmanaged(Index) = .empty;
        defer parts.deinit(self.allocator);

        try parts.append(self.allocator, try self.parseConcat(compiled));
        while (self.pos < self.pattern.len and self.pattern[self.pos] == '|') {
            self.pos += 1;
            try parts.append(self.allocator, try self.parseConcat(compiled));
        }

        if (parts.items.len == 1) return parts.items[0];
        const range = try compiled.appendRange(parts.items);
        return compiled.addNode(.{ .alt = range });
    }

    fn parseConcat(self: *Parser, compiled: *Pattern) Error!Index {
        var parts: std.ArrayListUnmanaged(Index) = .empty;
        defer parts.deinit(self.allocator);

        while (self.pos < self.pattern.len) {
            const rune = self.pattern[self.pos];
            if (rune == ')' or rune == '|') break;
            try parts.append(self.allocator, try self.parseQuantified(compiled));
        }

        if (parts.items.len == 0) return compiled.addNode(.empty);
        if (parts.items.len == 1) return parts.items[0];
        const range = try compiled.appendRange(parts.items);
        return compiled.addNode(.{ .concat = range });
    }

    fn parseQuantified(self: *Parser, compiled: *Pattern) Error!Index {
        const atom = try self.parseAtom(compiled);
        if (self.pos >= self.pattern.len) return atom;

        return switch (self.pattern[self.pos]) {
            '*' => blk: {
                self.pos += 1;
                break :blk compiled.addNode(.{ .repeat = .{
                    .child = atom,
                    .min = 0,
                    .max = null,
                } });
            },
            '+' => blk: {
                self.pos += 1;
                break :blk compiled.addNode(.{ .repeat = .{
                    .child = atom,
                    .min = 1,
                    .max = null,
                } });
            },
            '?' => blk: {
                self.pos += 1;
                break :blk compiled.addNode(.{ .repeat = .{
                    .child = atom,
                    .min = 0,
                    .max = 1,
                } });
            },
            '{' => blk: {
                self.pos += 1;
                const min = try self.parseCount();
                var max: ?usize = min;
                if (self.pos >= self.pattern.len) return Error.InvalidPattern;
                if (self.pattern[self.pos] == ',') {
                    self.pos += 1;
                    if (self.pos >= self.pattern.len) return Error.InvalidPattern;
                    if (self.pattern[self.pos] == '}') {
                        max = null;
                    } else {
                        max = try self.parseCount();
                    }
                }
                if (self.pos >= self.pattern.len or self.pattern[self.pos] != '}') return Error.InvalidPattern;
                self.pos += 1;
                if (max) |upper| if (upper < min) return Error.InvalidPattern;
                break :blk compiled.addNode(.{ .repeat = .{
                    .child = atom,
                    .min = min,
                    .max = max,
                } });
            },
            else => atom,
        };
    }

    fn parseAtom(self: *Parser, compiled: *Pattern) Error!Index {
        if (self.pos >= self.pattern.len) return Error.InvalidPattern;
        const rune = self.pattern[self.pos];
        switch (rune) {
            '(' => {
                self.pos += 1;
                const expr = try self.parseAlternation(compiled);
                if (self.pos >= self.pattern.len or self.pattern[self.pos] != ')') return Error.InvalidPattern;
                self.pos += 1;
                return expr;
            },
            ')' => return Error.InvalidPattern,
            '.' => {
                self.pos += 1;
                return compiled.addNode(.any);
            },
            '\\' => {
                self.pos += 1;
                if (self.pos >= self.pattern.len) return Error.InvalidPattern;
                const escaped = self.pattern[self.pos];
                self.pos += 1;
                return compiled.addNode(.{ .literal = escaped });
            },
            else => {
                self.pos += 1;
                return compiled.addNode(.{ .literal = rune });
            },
        }
    }

    fn parseCount(self: *Parser) Error!usize {
        if (self.pos >= self.pattern.len or !isAsciiDigit(self.pattern[self.pos])) return Error.InvalidPattern;
        var count: usize = 0;
        while (self.pos < self.pattern.len and isAsciiDigit(self.pattern[self.pos])) : (self.pos += 1) {
            const digit: usize = @intCast(self.pattern[self.pos] - '0');
            count = std.math.add(usize, std.math.mul(usize, count, 10) catch return Error.InvalidPattern, digit) catch return Error.InvalidPattern;
        }
        return count;
    }
};

fn matcherMatches(allocator: std.mem.Allocator, compiled: *const Pattern, text: []const u21) Error!bool {
    var end_positions: std.ArrayListUnmanaged(usize) = .empty;
    defer end_positions.deinit(allocator);

    var start: usize = 0;
    while (start <= text.len) : (start += 1) {
        end_positions.clearRetainingCapacity();
        try matchInto(allocator, compiled, compiled.root, text, start, &end_positions);
        if (end_positions.items.len != 0) return true;
    }
    return false;
}

fn matchInto(
    allocator: std.mem.Allocator,
    compiled: *const Pattern,
    node_index: Index,
    text: []const u21,
    start: usize,
    out: *std.ArrayListUnmanaged(usize),
) Error!void {
    switch (compiled.nodes.items[@intFromEnum(node_index)]) {
        .empty => try appendUnique(allocator, out, start),
        .literal => |rune| {
            if (start < text.len and text[start] == rune) {
                try appendUnique(allocator, out, start + 1);
            }
        },
        .any => {
            if (start < text.len) try appendUnique(allocator, out, start + 1);
        },
        .concat => |range| {
            var current: std.ArrayListUnmanaged(usize) = .empty;
            defer current.deinit(allocator);
            var next: std.ArrayListUnmanaged(usize) = .empty;
            defer next.deinit(allocator);

            try appendUnique(allocator, &current, start);
            for (0..range.len) |i| {
                next.clearRetainingCapacity();
                const child = compiled.ranges.items[range.start + i];
                for (current.items) |pos| {
                    try matchInto(allocator, compiled, child, text, pos, &next);
                }
                current.clearRetainingCapacity();
                for (next.items) |pos| {
                    try appendUnique(allocator, &current, pos);
                }
                if (current.items.len == 0) break;
            }
            for (current.items) |pos| {
                try appendUnique(allocator, out, pos);
            }
        },
        .alt => |range| {
            for (0..range.len) |i| {
                try matchInto(allocator, compiled, compiled.ranges.items[range.start + i], text, start, out);
            }
        },
        .repeat => |rep| try matchRepeat(allocator, compiled, rep, text, start, out),
    }
}

fn matchRepeat(
    allocator: std.mem.Allocator,
    compiled: *const Pattern,
    rep: Repeat,
    text: []const u21,
    start: usize,
    out: *std.ArrayListUnmanaged(usize),
) Error!void {
    var frontier: std.ArrayListUnmanaged(usize) = .empty;
    defer frontier.deinit(allocator);
    var next: std.ArrayListUnmanaged(usize) = .empty;
    defer next.deinit(allocator);

    try appendUnique(allocator, &frontier, start);
    var count: usize = 0;
    while (true) {
        if (count >= rep.min) {
            for (frontier.items) |pos| {
                try appendUnique(allocator, out, pos);
            }
        }
        if (rep.max) |max| {
            if (count >= max) break;
        }

        next.clearRetainingCapacity();
        var any_progress = false;
        for (frontier.items) |pos| {
            var child_positions: std.ArrayListUnmanaged(usize) = .empty;
            defer child_positions.deinit(allocator);
            try matchInto(allocator, compiled, rep.child, text, pos, &child_positions);
            for (child_positions.items) |child_pos| {
                if (child_pos != pos) any_progress = true;
                try appendUnique(allocator, &next, child_pos);
            }
        }
        if (next.items.len == 0 or !any_progress) break;

        frontier.clearRetainingCapacity();
        for (next.items) |pos| {
            try appendUnique(allocator, &frontier, pos);
        }
        count += 1;
    }
}

fn appendUnique(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(usize), val: usize) !void {
    for (list.items) |existing| {
        if (existing == val) return;
    }
    try list.append(allocator, val);
}

fn decodeUtf8(allocator: std.mem.Allocator, text: []const u8) Error![]u21 {
    var out: std.ArrayListUnmanaged(u21) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[index]) catch return Error.InvalidPattern;
        if (index + len > text.len) return Error.InvalidPattern;
        const rune = std.unicode.utf8Decode(text[index .. index + len]) catch return Error.InvalidPattern;
        try out.append(allocator, rune);
        index += len;
    }
    return out.toOwnedSlice(allocator);
}

fn isAsciiDigit(rune: u21) bool {
    return rune >= '0' and rune <= '9';
}

// ---------------------------------------------------------------------------
// Match-position helpers (rune-index -> byte-index mapping)
// ---------------------------------------------------------------------------

/// A match span in byte coordinates.
pub const Match = struct {
    start: usize,
    end: usize,
};

/// Build a rune-index -> byte-offset table. Entry i gives the byte offset of
/// rune i; an extra sentinel at the end gives text.len.
fn runeByteOffsets(allocator: std.mem.Allocator, text: []const u8) Error![]usize {
    var offsets: std.ArrayListUnmanaged(usize) = .empty;
    errdefer offsets.deinit(allocator);

    var byte_idx: usize = 0;
    while (byte_idx < text.len) {
        try offsets.append(allocator, byte_idx);
        const len = std.unicode.utf8ByteSequenceLength(text[byte_idx]) catch return Error.InvalidPattern;
        byte_idx += len;
    }
    // Sentinel for end-of-string.
    try offsets.append(allocator, text.len);
    return offsets.toOwnedSlice(allocator);
}

/// Find the first match of `pattern_text` in `text`. Returns null if no match.
pub fn findFirst(allocator: std.mem.Allocator, text: []const u8, pattern_text: []const u8) Error!?Match {
    const pattern_runes = try decodeUtf8(allocator, pattern_text);
    defer allocator.free(pattern_runes);

    var parser = Parser{ .allocator = allocator, .pattern = pattern_runes };
    var compiled = try parser.parse();
    defer compiled.deinit();

    const text_runes = try decodeUtf8(allocator, text);
    defer allocator.free(text_runes);

    const offsets = try runeByteOffsets(allocator, text);
    defer allocator.free(offsets);

    var end_positions: std.ArrayListUnmanaged(usize) = .empty;
    defer end_positions.deinit(allocator);

    var start: usize = 0;
    while (start <= text_runes.len) : (start += 1) {
        end_positions.clearRetainingCapacity();
        try matchInto(allocator, &compiled, compiled.root, text_runes, start, &end_positions);
        if (end_positions.items.len != 0) {
            // Pick the longest match from this start position.
            var best_end: usize = end_positions.items[0];
            for (end_positions.items[1..]) |ep| {
                if (ep > best_end) best_end = ep;
            }
            return .{ .start = offsets[start], .end = offsets[best_end] };
        }
    }
    return null;
}

/// Find all non-overlapping matches of `pattern_text` in `text`.
pub fn findAll(allocator: std.mem.Allocator, text: []const u8, pattern_text: []const u8) Error![]Match {
    const pattern_runes = try decodeUtf8(allocator, pattern_text);
    defer allocator.free(pattern_runes);

    var parser = Parser{ .allocator = allocator, .pattern = pattern_runes };
    var compiled = try parser.parse();
    defer compiled.deinit();

    const text_runes = try decodeUtf8(allocator, text);
    defer allocator.free(text_runes);

    const offsets = try runeByteOffsets(allocator, text);
    defer allocator.free(offsets);

    var results: std.ArrayListUnmanaged(Match) = .empty;
    errdefer results.deinit(allocator);

    var end_positions: std.ArrayListUnmanaged(usize) = .empty;
    defer end_positions.deinit(allocator);

    var start: usize = 0;
    while (start <= text_runes.len) {
        end_positions.clearRetainingCapacity();
        try matchInto(allocator, &compiled, compiled.root, text_runes, start, &end_positions);
        if (end_positions.items.len != 0) {
            var best_end: usize = end_positions.items[0];
            for (end_positions.items[1..]) |ep| {
                if (ep > best_end) best_end = ep;
            }
            try results.append(allocator, .{ .start = offsets[start], .end = offsets[best_end] });
            // Advance past this match; ensure forward progress.
            start = if (best_end > start) best_end else start + 1;
        } else {
            start += 1;
        }
    }
    return results.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Regex extension library (extract, extractAll, replace, replaceN)
// ---------------------------------------------------------------------------

const types = @import("../env/types.zig");

pub const regex_library = cel_env.Library{
    .name = "cel.lib.ext.regex",
    .install = installRegexLibrary,
};

fn installRegexLibrary(environment: *cel_env.Env) !void {
    const t = environment.types.builtins;
    const str = t.string_type;
    const int = t.int_type;
    const list_str = try environment.types.listOf(str);

    _ = try environment.addFunction("find", true, &.{ str, str }, str, evalFind);
    _ = try environment.addFunction("findAll", true, &.{ str, str }, list_str, evalFindAllMatches);
    _ = try environment.addFunction("findAll", true, &.{ str, str, int }, list_str, evalFindAllLimit);
    _ = try environment.addFunction("regex.extract", false, &.{ str, str }, str, evalExtract);
    _ = try environment.addFunction("regex.extractAll", false, &.{ str, str }, list_str, evalExtractAll);
    _ = try environment.addFunction("regex.replace", false, &.{ str, str, str }, str, evalReplace);
    _ = try environment.addFunction("regex.replaceN", false, &.{ str, str, str, int }, str, evalReplaceN);
}

fn evalFind(allocator: std.mem.Allocator, args: []const value_mod.Value) cel_env.EvalError!value_mod.Value {
    if (args.len != 2 or args[0] != .string or args[1] != .string)
        return value_mod.RuntimeError.TypeMismatch;
    const m = findFirst(allocator, args[0].string, args[1].string) catch |err| switch (err) {
        error.InvalidPattern => return value_mod.RuntimeError.TypeMismatch,
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (m) |match| return .{ .string = try allocator.dupe(u8, args[0].string[match.start..match.end]) };
    return .{ .string = try allocator.dupe(u8, "") };
}

fn evalFindAllMatches(allocator: std.mem.Allocator, args: []const value_mod.Value) cel_env.EvalError!value_mod.Value {
    return evalFindAllWithLimit(allocator, args, null);
}

fn evalFindAllLimit(allocator: std.mem.Allocator, args: []const value_mod.Value) cel_env.EvalError!value_mod.Value {
    if (args.len != 3 or args[2] != .int) return value_mod.RuntimeError.TypeMismatch;
    return evalFindAllWithLimit(allocator, args[0..2], args[2].int);
}

fn evalFindAllWithLimit(
    allocator: std.mem.Allocator,
    args: []const value_mod.Value,
    limit: ?i64,
) cel_env.EvalError!value_mod.Value {
    if (args.len != 2 or args[0] != .string or args[1] != .string)
        return value_mod.RuntimeError.TypeMismatch;
    const all = findAll(allocator, args[0].string, args[1].string) catch |err| switch (err) {
        error.InvalidPattern => return value_mod.RuntimeError.TypeMismatch,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(all);

    const bounded_len: usize = if (limit) |n|
        if (n < 0) all.len else @min(all.len, @as(usize, @intCast(n)))
    else
        all.len;

    var out: std.ArrayListUnmanaged(value_mod.Value) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, bounded_len);
    for (all[0..bounded_len]) |m| {
        out.appendAssumeCapacity(.{ .string = try allocator.dupe(u8, args[0].string[m.start..m.end]) });
    }
    return .{ .list = out };
}

fn evalExtract(allocator: std.mem.Allocator, args: []const value_mod.Value) cel_env.EvalError!value_mod.Value {
    if (args.len != 2 or args[0] != .string or args[1] != .string)
        return value_mod.RuntimeError.TypeMismatch;
    const text = args[0].string;
    const pattern = args[1].string;

    const m = findFirst(allocator, text, pattern) catch |err| switch (err) {
        error.InvalidPattern => return value_mod.RuntimeError.TypeMismatch,
        error.OutOfMemory => return error.OutOfMemory,
    } orelse return value_mod.RuntimeError.NoMatchingOverload;

    return .{ .string = try allocator.dupe(u8, text[m.start..m.end]) };
}

fn evalExtractAll(allocator: std.mem.Allocator, args: []const value_mod.Value) cel_env.EvalError!value_mod.Value {
    if (args.len != 2 or args[0] != .string or args[1] != .string)
        return value_mod.RuntimeError.TypeMismatch;
    const text = args[0].string;
    const pattern = args[1].string;

    const all = findAll(allocator, text, pattern) catch |err| switch (err) {
        error.InvalidPattern => return value_mod.RuntimeError.TypeMismatch,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(all);

    var out: std.ArrayListUnmanaged(value_mod.Value) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, all.len);
    for (all) |m| {
        out.appendAssumeCapacity(.{ .string = try allocator.dupe(u8, text[m.start..m.end]) });
    }
    return .{ .list = out };
}

fn evalReplace(allocator: std.mem.Allocator, args: []const value_mod.Value) cel_env.EvalError!value_mod.Value {
    if (args.len != 3 or args[0] != .string or args[1] != .string or args[2] != .string)
        return value_mod.RuntimeError.TypeMismatch;
    return replaceImpl(allocator, args[0].string, args[1].string, args[2].string, 1);
}

fn evalReplaceN(allocator: std.mem.Allocator, args: []const value_mod.Value) cel_env.EvalError!value_mod.Value {
    if (args.len != 4 or args[0] != .string or args[1] != .string or args[2] != .string or args[3] != .int)
        return value_mod.RuntimeError.TypeMismatch;
    const count_raw = args[3].int;
    if (count_raw < 0) return value_mod.RuntimeError.InvalidIndex;
    const count: usize = @intCast(count_raw);
    return replaceImpl(allocator, args[0].string, args[1].string, args[2].string, count);
}

fn replaceImpl(
    allocator: std.mem.Allocator,
    text: []const u8,
    pattern: []const u8,
    replacement: []const u8,
    max_count: usize,
) cel_env.EvalError!value_mod.Value {
    const all = findAll(allocator, text, pattern) catch |err| switch (err) {
        error.InvalidPattern => return value_mod.RuntimeError.TypeMismatch,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(all);

    const limit = @min(all.len, max_count);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    var prev_end: usize = 0;
    for (all[0..limit]) |m| {
        try buf.appendSlice(allocator, text[prev_end..m.start]);
        try buf.appendSlice(allocator, replacement);
        prev_end = m.end;
    }
    try buf.appendSlice(allocator, text[prev_end..]);

    return .{ .string = try buf.toOwnedSlice(allocator) };
}

test "regex matcher covers upstream string suite patterns" {
    try std.testing.expect(try matches(std.testing.allocator, "hubba", "ubb"));
    try std.testing.expect(!(try matches(std.testing.allocator, "", "foo|bar")));
    try std.testing.expect(try matches(std.testing.allocator, "cows", ""));
    try std.testing.expect(try matches(std.testing.allocator, "abcd", "bc"));
    try std.testing.expect(try matches(std.testing.allocator, "grey", "gr(a|e)y"));
    try std.testing.expect(try matches(std.testing.allocator, "banana", "ba(na)*"));
    try std.testing.expect(try matches(std.testing.allocator, "mañana", "a+ñ+a+"));
    try std.testing.expect(try matches(std.testing.allocator, "🐱😀😀", "(a|😀){2}"));
}

test "matches returns true for exact and partial patterns" {
    const cases = [_]struct { text: []const u8, pattern: []const u8, expected: bool }{
        // Exact match
        .{ .text = "hello", .pattern = "hello", .expected = true },
        // Wildcard .* matches anything
        .{ .text = "hello world", .pattern = "h.*d", .expected = true },
        .{ .text = "hello", .pattern = ".*", .expected = true },
        // Alternation
        .{ .text = "cat", .pattern = "cat|dog", .expected = true },
        .{ .text = "dog", .pattern = "cat|dog", .expected = true },
        .{ .text = "bird", .pattern = "cat|dog", .expected = false },
        // Quantifiers: +, ?, *
        .{ .text = "aab", .pattern = "a+b", .expected = true },
        .{ .text = "b", .pattern = "a+b", .expected = false },
        .{ .text = "ab", .pattern = "a?b", .expected = true },
        .{ .text = "b", .pattern = "a?b", .expected = true },
        .{ .text = "aab", .pattern = "a*b", .expected = true },
        .{ .text = "b", .pattern = "a*b", .expected = true },
        // Dot matches any single char
        .{ .text = "abc", .pattern = "a.c", .expected = true },
        .{ .text = "ac", .pattern = "a.c", .expected = false },
        // Partial match (substring matching)
        .{ .text = "foobar", .pattern = "oba", .expected = true },
        .{ .text = "foobar", .pattern = "xyz", .expected = false },
        // Empty string and empty pattern
        .{ .text = "", .pattern = "", .expected = true },
        .{ .text = "abc", .pattern = "", .expected = true },
        .{ .text = "", .pattern = "a", .expected = false },
        // Escaped special chars
        .{ .text = "a.b", .pattern = "a\\.b", .expected = true },
        .{ .text = "axb", .pattern = "a\\.b", .expected = false },
        .{ .text = "a*b", .pattern = "a\\*b", .expected = true },
        .{ .text = "a+b", .pattern = "a\\+b", .expected = true },
        // Groups
        .{ .text = "ababab", .pattern = "(ab)+", .expected = true },
        .{ .text = "cd", .pattern = "(ab)+", .expected = false },
        // Nested groups
        .{ .text = "abcabc", .pattern = "(a(bc))+", .expected = true },
        // Repeat counts {n}, {n,m}, {n,}
        .{ .text = "aaa", .pattern = "a{3}", .expected = true },
        .{ .text = "aa", .pattern = "a{3}", .expected = false },
        .{ .text = "aa", .pattern = "a{1,3}", .expected = true },
        .{ .text = "aaaa", .pattern = "a{2,}", .expected = true },
        .{ .text = "a", .pattern = "a{2,}", .expected = false },
    };
    for (cases) |case| {
        const result = try matches(std.testing.allocator, case.text, case.pattern);
        try std.testing.expectEqual(case.expected, result);
    }
}

test "matches with unicode patterns" {
    const cases = [_]struct { text: []const u8, pattern: []const u8, expected: bool }{
        .{ .text = "café", .pattern = "caf.", .expected = true },
        .{ .text = "über", .pattern = ".ber", .expected = true },
        .{ .text = "日本語", .pattern = "日.語", .expected = true },
        .{ .text = "🎉🎊", .pattern = "🎉🎊", .expected = true },
        .{ .text = "🎉🎊", .pattern = "🎉.", .expected = true },
        .{ .text = "αβγ", .pattern = "α+β+γ+", .expected = true },
        .{ .text = "ñoño", .pattern = "ñ.ñ.", .expected = true },
    };
    for (cases) |case| {
        const result = try matches(std.testing.allocator, case.text, case.pattern);
        try std.testing.expectEqual(case.expected, result);
    }
}

test "matches rejects invalid regex patterns" {
    const invalid_patterns = [_][]const u8{
        "(abc",   // unclosed group
        "abc)",   // unmatched close paren
        "\\",     // trailing backslash
        "a{",     // unclosed brace
        "a{3,1}", // max < min
        "a{}",    // empty braces
    };
    for (invalid_patterns) |pattern| {
        try std.testing.expectError(Error.InvalidPattern, matches(std.testing.allocator, "test", pattern));
    }
}

test "matches via CEL eval integration" {
    const compile_mod = @import("../compiler/compile.zig");
    const eval_impl = @import("../eval/eval.zig");
    const env_mod = @import("../env/env.zig");
    const Activation = @import("../eval/activation.zig").Activation;

    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: bool }{
        .{ .expr = "'hello'.matches('hello')", .expected = true },
        .{ .expr = "'hello'.matches('h.*o')", .expected = true },
        .{ .expr = "'hello'.matches('xyz')", .expected = false },
        .{ .expr = "'foobar'.matches('o+b')", .expected = true },
        .{ .expr = "'abc'.matches('a.c')", .expected = true },
        .{ .expr = "'ac'.matches('a.c')", .expected = false },
        .{ .expr = "'gray'.matches('gr(a|e)y')", .expected = true },
        .{ .expr = "'grey'.matches('gr(a|e)y')", .expected = true },
        .{ .expr = "'gruy'.matches('gr(a|e)y')", .expected = false },
        .{ .expr = "'aab'.matches('a+b')", .expected = true },
        .{ .expr = "'b'.matches('a+b')", .expected = false },
        .{ .expr = "''.matches('')", .expected = true },
        .{ .expr = "'test'.matches('')", .expected = true },
        .{ .expr = "''.matches('a')", .expected = false },
        .{ .expr = "'a.b'.matches('a\\\\.b')", .expected = true },
        .{ .expr = "'axb'.matches('a\\\\.b')", .expected = false },
        .{ .expr = "'ababab'.matches('(ab)+')", .expected = true },
        .{ .expr = "'aaa'.matches('a{3}')", .expected = true },
        .{ .expr = "'aa'.matches('a{3}')", .expected = false },
    };
    for (cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, result.bool);
    }
}

test "regex.extract returns first match" {
    const compile_mod = @import("../compiler/compile.zig");
    const eval_impl = @import("../eval/eval.zig");
    const env_mod = @import("../env/env.zig");
    const Activation = @import("../eval/activation.zig").Activation;

    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(regex_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: []const u8 }{
        .{ .expr = "regex.extract('hello world', 'w..ld')", .expected = "world" },
        .{ .expr = "regex.extract('foobar', 'o+b')", .expected = "oob" },
        .{ .expr = "regex.extract('abcabc', 'abc')", .expected = "abc" },
    };
    for (cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected, result.string);
    }
}

test "regex.extractAll returns all matches" {
    const compile_mod = @import("../compiler/compile.zig");
    const eval_impl = @import("../eval/eval.zig");
    const env_mod = @import("../env/env.zig");
    const Activation = @import("../eval/activation.zig").Activation;

    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(regex_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: []const []const u8 }{
        .{ .expr = "regex.extractAll('abcabc', 'abc')", .expected = &.{ "abc", "abc" } },
        .{ .expr = "regex.extractAll('no match here', 'xyz')", .expected = &.{} },
        .{ .expr = "regex.extractAll('aaa', 'a')", .expected = &.{ "a", "a", "a" } },
    };
    for (cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected.len, result.list.items.len);
        for (case.expected, 0..) |exp, i| {
            try std.testing.expectEqualStrings(exp, result.list.items[i].string);
        }
    }
}

test "regex.replace replaces first match" {
    const compile_mod = @import("../compiler/compile.zig");
    const eval_impl = @import("../eval/eval.zig");
    const env_mod = @import("../env/env.zig");
    const Activation = @import("../eval/activation.zig").Activation;

    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(regex_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: []const u8 }{
        .{ .expr = "regex.replace('hello world', 'world', 'zig')", .expected = "hello zig" },
        .{ .expr = "regex.replace('aaa', 'a', 'b')", .expected = "baa" },
        .{ .expr = "regex.replace('foobar', 'xyz', 'nope')", .expected = "foobar" },
        .{ .expr = "regex.replace('abc', 'b', '')", .expected = "ac" },
    };
    for (cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected, result.string);
    }
}

test "regex.replaceN replaces up to N matches" {
    const compile_mod = @import("../compiler/compile.zig");
    const eval_impl = @import("../eval/eval.zig");
    const env_mod = @import("../env/env.zig");
    const Activation = @import("../eval/activation.zig").Activation;

    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(regex_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_]struct { expr: []const u8, expected: []const u8 }{
        .{ .expr = "regex.replaceN('aaa', 'a', 'b', 2)", .expected = "bba" },
        .{ .expr = "regex.replaceN('aaa', 'a', 'b', 0)", .expected = "aaa" },
        .{ .expr = "regex.replaceN('aaa', 'a', 'b', 10)", .expected = "bbb" },
        .{ .expr = "regex.replaceN('abab', 'ab', 'x', 1)", .expected = "xab" },
    };
    for (cases) |case| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, case.expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected, result.string);
    }
}

test "find and findAll receiver helpers work" {
    const compile_mod = @import("../compiler/compile.zig");
    const eval_impl = @import("../eval/eval.zig");
    const env_mod = @import("../env/env.zig");
    const Activation = @import("../eval/activation.zig").Activation;

    var environment = try env_mod.Env.initDefault(std.testing.allocator);
    defer environment.deinit();
    try environment.addLibrary(regex_library);
    var activation = Activation.init(std.testing.allocator);
    defer activation.deinit();

    const cases = [_][]const u8{
        "'abc ooob'.find('o+b') == 'ooob'",
        "'foo bar foo'.findAll('foo', 1) == ['foo']",
        "'abc'.find('z+') == ''",
        "'foo bar foo'.findAll('foo') == ['foo', 'foo']",
    };
    for (cases) |expr| {
        var program = try compile_mod.compile(std.testing.allocator, &environment, expr);
        defer program.deinit();
        var result = try eval_impl.evalWithOptions(std.testing.allocator, &program, &activation, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.bool);
    }
}

test "find helpers reject invalid patterns" {
    var text = try value_mod.string(std.testing.allocator, "abc");
    defer text.deinit(std.testing.allocator);
    var bad_pattern = try value_mod.string(std.testing.allocator, "(");
    defer bad_pattern.deinit(std.testing.allocator);

    try std.testing.expectError(value_mod.RuntimeError.TypeMismatch, evalFind(std.testing.allocator, &.{ text, bad_pattern }));
}
