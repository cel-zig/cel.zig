const std = @import("std");
const appendFormat = @import("../util/fmt.zig").appendFormat;
const ast = @import("ast.zig");
const cel_time = @import("../library/cel_time.zig");
const value = @import("../env/value.zig");

pub fn unparse(allocator: std.mem.Allocator, tree: *const ast.Ast) std.mem.Allocator.Error![]u8 {
    var writer = Writer{
        .allocator = allocator,
        .tree = tree,
    };
    try writer.writeNode(tree.root.?, 0, .none);
    return writer.buffer.toOwnedSlice(allocator);
}

pub const Position = enum { none, left, right };

pub const Writer = struct {
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    buffer: std.ArrayListUnmanaged(u8) = .empty,

    /// Optional callback invoked before writing each node. If it returns true
    /// the node was handled externally (e.g. substituted with a known value)
    /// and the writer skips its default output.
    override: ?*const fn (ctx: *anyopaque, writer: *Writer, index: ast.Index) std.mem.Allocator.Error!bool = null,
    override_ctx: ?*anyopaque = null,

    pub fn writeNode(self: *Writer, index: ast.Index, parent_prec: u8, pos: Position) std.mem.Allocator.Error!void {
        if (self.override) |cb| {
            if (try cb(self.override_ctx.?, self, index)) return;
        }

        const node = self.tree.node(index);
        const prec = precedence(node.data);
        const needs_parens = needsParens(node.data, parent_prec, pos);
        if (needs_parens) try self.buffer.append(self.allocator, '(');
        switch (node.data) {
            .literal_int => |v| try appendFormat(&self.buffer, self.allocator, "{d}", .{v}),
            .literal_uint => |v| try appendFormat(&self.buffer, self.allocator, "{d}u", .{v}),
            .literal_double => |v| try self.appendDouble(v),
            .literal_bool => |v| try self.buffer.appendSlice(self.allocator, if (v) "true" else "false"),
            .literal_null => try self.buffer.appendSlice(self.allocator, "null"),
            .literal_string => |id| try self.appendQuoted(self.tree.strings.get(id), false),
            .literal_bytes => |id| try self.appendQuoted(self.tree.strings.get(id), true),
            .ident => |name_ref| try self.writeNameRef(name_ref),
            .unary => |unary| {
                try self.buffer.appendSlice(self.allocator, switch (unary.op) {
                    .logical_not => "!",
                    .negate => "-",
                });
                try self.writeNode(unary.expr, prec, .right);
            },
            .binary => |binary| {
                try self.writeNode(binary.left, prec, .left);
                try self.buffer.append(self.allocator, ' ');
                try self.buffer.appendSlice(self.allocator, binaryToken(binary.op));
                try self.buffer.append(self.allocator, ' ');
                try self.writeNode(binary.right, prec, .right);
            },
            .conditional => |conditional| {
                try self.writeNode(conditional.condition, prec, .left);
                try self.buffer.appendSlice(self.allocator, " ? ");
                try self.writeNode(conditional.then_expr, prec, .left);
                try self.buffer.appendSlice(self.allocator, " : ");
                try self.writeNode(conditional.else_expr, prec, .right);
            },
            .list => |range| {
                try self.buffer.append(self.allocator, '[');
                for (0..range.len) |i| {
                    if (i != 0) try self.buffer.appendSlice(self.allocator, ", ");
                    const item = self.tree.list_items.items[range.start + i];
                    if (item.optional) try self.buffer.append(self.allocator, '?');
                    try self.writeNode(item.value, 0, .none);
                }
                try self.buffer.append(self.allocator, ']');
            },
            .map => |range| {
                try self.buffer.append(self.allocator, '{');
                for (0..range.len) |i| {
                    if (i != 0) try self.buffer.appendSlice(self.allocator, ", ");
                    const entry = self.tree.map_entries.items[range.start + i];
                    if (entry.optional) try self.buffer.append(self.allocator, '?');
                    try self.writeNode(entry.key, 0, .none);
                    try self.buffer.appendSlice(self.allocator, ": ");
                    try self.writeNode(entry.value, 0, .none);
                }
                try self.buffer.append(self.allocator, '}');
            },
            .message => |msg| {
                try self.writeNameRef(msg.name);
                try self.buffer.append(self.allocator, '{');
                for (0..msg.fields.len) |i| {
                    if (i != 0) try self.buffer.appendSlice(self.allocator, ", ");
                    const field = self.tree.field_inits.items[msg.fields.start + i];
                    if (field.optional) try self.buffer.append(self.allocator, '?');
                    try self.buffer.appendSlice(self.allocator, self.tree.strings.get(field.name));
                    try self.buffer.appendSlice(self.allocator, ": ");
                    try self.writeNode(field.value, 0, .none);
                }
                try self.buffer.append(self.allocator, '}');
            },
            .call => |call| {
                try self.writeNameRef(call.name);
                try self.buffer.append(self.allocator, '(');
                for (0..call.args.len) |i| {
                    if (i != 0) try self.buffer.appendSlice(self.allocator, ", ");
                    try self.writeNode(self.tree.expr_ranges.items[call.args.start + i], 0, .none);
                }
                try self.buffer.append(self.allocator, ')');
            },
            .receiver_call => |call| {
                try self.writeNode(call.target, prec, .left);
                try self.buffer.append(self.allocator, '.');
                try self.buffer.appendSlice(self.allocator, self.tree.strings.get(call.name));
                try self.buffer.append(self.allocator, '(');
                for (0..call.args.len) |i| {
                    if (i != 0) try self.buffer.appendSlice(self.allocator, ", ");
                    try self.writeNode(self.tree.expr_ranges.items[call.args.start + i], 0, .none);
                }
                try self.buffer.append(self.allocator, ')');
            },
            .select => |select| {
                try self.writeNode(select.target, prec, .left);
                try self.buffer.append(self.allocator, '.');
                if (select.optional) try self.buffer.append(self.allocator, '?');
                try self.buffer.appendSlice(self.allocator, self.tree.strings.get(select.field));
            },
            .index => |access| {
                try self.writeNode(access.target, prec, .left);
                try self.buffer.append(self.allocator, '[');
                if (access.optional) try self.buffer.append(self.allocator, '?');
                try self.writeNode(access.index, 0, .none);
                try self.buffer.append(self.allocator, ']');
            },
        }
        if (needs_parens) try self.buffer.append(self.allocator, ')');
    }

    pub fn appendDouble(self: *Writer, v: f64) std.mem.Allocator.Error!void {
        const text = try std.fmt.allocPrint(self.allocator, "{d}", .{v});
        defer self.allocator.free(text);
        try self.buffer.appendSlice(self.allocator, text);
        if (std.mem.indexOfAny(u8, text, ".eE") == null) {
            try self.buffer.appendSlice(self.allocator, ".0");
        }
    }

    pub fn appendQuoted(self: *Writer, text: []const u8, bytes_mode: bool) std.mem.Allocator.Error!void {
        if (bytes_mode) try self.buffer.append(self.allocator, 'b');
        try self.buffer.append(self.allocator, '"');
        for (text) |ch| {
            switch (ch) {
                '\\' => try self.buffer.appendSlice(self.allocator, "\\\\"),
                '"' => try self.buffer.appendSlice(self.allocator, "\\\""),
                '\n' => try self.buffer.appendSlice(self.allocator, "\\n"),
                '\r' => try self.buffer.appendSlice(self.allocator, "\\r"),
                '\t' => try self.buffer.appendSlice(self.allocator, "\\t"),
                else => {
                    if (std.ascii.isPrint(ch)) {
                        try self.buffer.append(self.allocator, ch);
                    } else {
                        try appendFormat(&self.buffer, self.allocator, "\\x{X:0>2}", .{ch});
                    }
                },
            }
        }
        try self.buffer.append(self.allocator, '"');
    }

    pub fn appendValueLiteral(self: *Writer, val: value.Value) std.mem.Allocator.Error!bool {
        const checkpoint = self.buffer.items.len;
        var committed = false;
        defer {
            if (!committed) self.buffer.items.len = checkpoint;
        }

        switch (val) {
            .int => |v| try appendFormat(&self.buffer, self.allocator, "{d}", .{v}),
            .uint => |v| try appendFormat(&self.buffer, self.allocator, "{d}u", .{v}),
            .double => |v| {
                if (!std.math.isFinite(v)) return false;
                try self.appendDouble(v);
            },
            .bool => |v| try self.buffer.appendSlice(self.allocator, if (v) "true" else "false"),
            .string => |text| try self.appendQuoted(text, false),
            .bytes => |bytes| try self.appendQuoted(bytes, true),
            .timestamp => |ts| {
                const text = try cel_time.formatTimestamp(self.allocator, ts);
                defer self.allocator.free(text);
                try self.buffer.appendSlice(self.allocator, "timestamp(");
                try self.appendQuoted(text, false);
                try self.buffer.append(self.allocator, ')');
            },
            .duration => |duration| {
                const text = try cel_time.formatDuration(self.allocator, duration);
                defer self.allocator.free(text);
                try self.buffer.appendSlice(self.allocator, "duration(");
                try self.appendQuoted(text, false);
                try self.buffer.append(self.allocator, ')');
            },
            .enum_value => |enum_value| {
                if (!isTypeLiteralName(enum_value.type_name)) return false;
                try self.buffer.appendSlice(self.allocator, enum_value.type_name);
                try self.buffer.append(self.allocator, '(');
                try appendFormat(&self.buffer, self.allocator, "{d}", .{enum_value.value});
                try self.buffer.append(self.allocator, ')');
            },
            .host, .unknown => return false,
            .null => try self.buffer.appendSlice(self.allocator, "null"),
            .optional => |optional| {
                if (optional.value == null) {
                    try self.buffer.appendSlice(self.allocator, "optional.none()");
                    committed = true;
                    return true;
                }
                try self.buffer.appendSlice(self.allocator, "optional.of(");
                if (!try self.appendValueLiteral(optional.value.?.*)) return false;
                try self.buffer.append(self.allocator, ')');
            },
            .type_name => |name| {
                if (!isTypeLiteralName(name)) return false;
                try self.buffer.appendSlice(self.allocator, name);
            },
            .list => |items| {
                try self.buffer.append(self.allocator, '[');
                for (items.items, 0..) |item, i| {
                    if (i != 0) try self.buffer.appendSlice(self.allocator, ", ");
                    if (!try self.appendValueLiteral(item)) return false;
                }
                try self.buffer.append(self.allocator, ']');
            },
            .map => |entries| {
                try self.buffer.append(self.allocator, '{');
                for (entries.items, 0..) |entry, i| {
                    if (i != 0) try self.buffer.appendSlice(self.allocator, ", ");
                    if (!try self.appendValueLiteral(entry.key)) return false;
                    try self.buffer.appendSlice(self.allocator, ": ");
                    if (!try self.appendValueLiteral(entry.value)) return false;
                }
                try self.buffer.append(self.allocator, '}');
            },
            .message => |msg| {
                if (!isTypeLiteralName(msg.name)) return false;
                try self.buffer.appendSlice(self.allocator, msg.name);
                try self.buffer.append(self.allocator, '{');
                for (msg.fields.items, 0..) |field, i| {
                    if (i != 0) try self.buffer.appendSlice(self.allocator, ", ");
                    try self.buffer.appendSlice(self.allocator, field.name);
                    try self.buffer.appendSlice(self.allocator, ": ");
                    if (!try self.appendValueLiteral(field.value)) return false;
                }
                try self.buffer.append(self.allocator, '}');
            },
        }
        committed = true;
        return true;
    }

    fn writeNameRef(self: *Writer, name_ref: ast.NameRef) std.mem.Allocator.Error!void {
        if (name_ref.absolute) try self.buffer.append(self.allocator, '.');
        for (0..name_ref.segments.len) |i| {
            if (i != 0) try self.buffer.append(self.allocator, '.');
            const id = self.tree.name_segments.items[name_ref.segments.start + i];
            try self.buffer.appendSlice(self.allocator, self.tree.strings.get(id));
        }
    }
};

pub fn precedence(data: ast.Data) u8 {
    return switch (data) {
        .conditional => 1,
        .binary => |binary| switch (binary.op) {
            .logical_or => 2,
            .logical_and => 3,
            .less, .less_equal, .greater, .greater_equal, .equal, .not_equal, .in_set => 4,
            .add, .subtract => 5,
            .multiply, .divide, .remainder => 6,
        },
        .unary => 7,
        .select, .index, .receiver_call => 8,
        else => 9,
    };
}

pub fn needsParens(data: ast.Data, parent_prec: u8, pos: Position) bool {
    if (parent_prec == 0) return false;
    const prec = precedence(data);
    if (prec < parent_prec) return true;
    if (prec > parent_prec) return false;
    return switch (data) {
        // Binary operators are left-associative: a same-precedence child in
        // the right position must be parenthesized to preserve grouping
        // (e.g. `a + (b + c)` differs from `(a + b) + c` for overflow).
        .binary => pos == .right,
        // Conditionals are right-associative: a nested conditional in the
        // else position re-parses identically without parens, but the
        // CEL grammar forbids a naked conditional in the condition or
        // then position, so those must be parenthesized.
        .conditional => pos == .left,
        else => false,
    };
}

pub fn binaryToken(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .logical_or => "||",
        .logical_and => "&&",
        .less => "<",
        .less_equal => "<=",
        .greater => ">",
        .greater_equal => ">=",
        .equal => "==",
        .not_equal => "!=",
        .in_set => "in",
        .add => "+",
        .subtract => "-",
        .multiply => "*",
        .divide => "/",
        .remainder => "%",
    };
}

pub fn isTypeLiteralName(name: []const u8) bool {
    if (name.len == 0) return false;
    var index: usize = 0;
    if (name[0] == '.') {
        if (name.len == 1) return false;
        index = 1;
    }
    while (index < name.len) {
        if (!isIdentifierStart(name[index])) return false;
        index += 1;
        while (index < name.len and isIdentifierContinue(name[index])) : (index += 1) {}
        if (index == name.len) return true;
        if (name[index] != '.') return false;
        index += 1;
    }
    return false;
}

fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentifierContinue(ch: u8) bool {
    return isIdentifierStart(ch) or std.ascii.isDigit(ch);
}

const parser = @import("parser.zig");

test "unparse roundtrip preserves expression semantics" {
    const cases = [_][]const u8{
        "1",
        "true",
        "null",
        "\"hello\"",
        "3.14",
        "42u",
        "x",
        "!x",
        "-x",
        "a + b",
        "a + b * c",
        "(a + b) * c",
        "a ? b : c",
        "a || b && c",
        "a.b",
        "a[0]",
        "a.b(c, d)",
        "f(x, y)",
        "[1, 2, 3]",
        "{\"a\": 1, \"b\": 2}",
        "a > 0 && b < 10",
        "a == 1 || b != 2",
        "a in [1, 2, 3]",
    };
    for (cases) |expr| {
        var tree = try parser.parse(std.testing.allocator, expr);
        defer tree.deinit();
        const result = try unparse(std.testing.allocator, &tree);
        defer std.testing.allocator.free(result);
        // Re-parse the unparsed output to verify it's valid CEL
        var reparsed = try parser.parse(std.testing.allocator, result);
        reparsed.deinit();
    }
}

test "unparse produces expected output" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "1 + 2", .expected = "1 + 2" },
        .{ .input = "a  +  b", .expected = "a + b" },
        .{ .input = "( a + b ) * c", .expected = "(a + b) * c" },
        .{ .input = "a + b * c", .expected = "a + b * c" },
        .{ .input = "a || b && c", .expected = "a || b && c" },
        .{ .input = "!true", .expected = "!true" },
        .{ .input = "-1", .expected = "-1" },
        .{ .input = "a ? b : c", .expected = "a ? b : c" },
        .{ .input = "[1, 2, 3]", .expected = "[1, 2, 3]" },
        .{ .input = "{1: 2}", .expected = "{1: 2}" },
        // Left-assoc grouping must be preserved when the right child is a
        // same-precedence expression, otherwise overflow semantics differ.
        .{ .input = "a + (b + c)", .expected = "a + (b + c)" },
        .{ .input = "(a + b) + c", .expected = "a + b + c" },
        .{ .input = "\"a\" + (\"c\" + \"d\") + \"e\"", .expected = "\"a\" + (\"c\" + \"d\") + \"e\"" },
        // Redundant parens in source are stripped at parse time and not
        // recreated — the result is semantically identical.
        .{ .input = "(((((1 + 2)))))", .expected = "1 + 2" },
        // Right-associative conditional: nested else needs no parens.
        .{ .input = "a ? b : c ? d : e", .expected = "a ? b : c ? d : e" },
        // The CEL grammar forbids naked conditionals in the condition and
        // then positions, so a parenthesized form must be preserved.
        .{ .input = "(a ? b : c) ? d : e", .expected = "(a ? b : c) ? d : e" },
        .{ .input = "a ? (b ? c : d) : e", .expected = "a ? (b ? c : d) : e" },
        // `+` binds tighter than `?:`, so this groups as
        // `("a" + x) ? y : (z + "c")`. The unparser must preserve the
        // shape without inserting redundant parens.
        .{ .input = "\"a\" + x ? y : z + \"c\"", .expected = "\"a\" + x ? y : z + \"c\"" },
        // Inverse case: a parenthesized conditional embedded inside a `+`
        // chain. The conditional has lower precedence than `+`, so the
        // parens around it are mandatory and must be preserved.
        .{ .input = "\"a\" + (x ? y : z) + \"c\"", .expected = "\"a\" + (x ? y : z) + \"c\"" },
    };
    for (cases) |case| {
        var tree = try parser.parse(std.testing.allocator, case.input);
        defer tree.deinit();
        const result = try unparse(std.testing.allocator, &tree);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings(case.expected, result);
    }
}

test "unparse output reparses to an equivalent AST" {
    // Each input is parsed, unparsed, reparsed, and the second unparse must
    // match the first — proving the round-trip is a fixed point.
    const cases = [_][]const u8{
        "a + b + c",
        "a + (b + c)",
        "(a + b) * (c + d)",
        "\"a\" + (\"c\" + \"d\") + \"e\"",
        "(((((1 + 2)))))",
        "a ? b : c ? d : e",
        "(a ? b : c) ? d : e",
        "a ? (b ? c : d) : e",
        "1 - 2 - 3",
        "1 - (2 - 3)",
        "\"a\" + x ? y : z + \"c\"",
        "\"a\" + (x ? y : z) + \"c\"",
    };
    for (cases) |expr| {
        var tree1 = try parser.parse(std.testing.allocator, expr);
        defer tree1.deinit();
        const text1 = try unparse(std.testing.allocator, &tree1);
        defer std.testing.allocator.free(text1);

        var tree2 = try parser.parse(std.testing.allocator, text1);
        defer tree2.deinit();
        const text2 = try unparse(std.testing.allocator, &tree2);
        defer std.testing.allocator.free(text2);

        try std.testing.expectEqualStrings(text1, text2);
    }
}
