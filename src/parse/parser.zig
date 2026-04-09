const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const span = @import("span.zig");
const token = @import("token.zig");
const strings = @import("string_table.zig");

pub const Error = std.mem.Allocator.Error ||
    std.fmt.ParseIntError ||
    std.fmt.ParseFloatError ||
    lexer.Error ||
    error{
    UnexpectedToken,
    UnexpectedEof,
    ExpectedExpression,
    ExpectedIdentifier,
    ReservedIdentifier,
    ExpressionNestingExceeded,
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) Error!ast.Ast {
    var p = try Parser.init(allocator, source);
    errdefer p.deinit();

    const root = try p.parseExpr();
    _ = try p.expectTag(.eof);
    p.ast.root = root;

    p.tokens.deinit(allocator);
    return p.releaseAst();
}

pub const max_nesting_depth: u32 = 250;

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: std.ArrayListUnmanaged(token.Token),
    index: usize = 0,
    depth: u32 = 0,
    ast: ast.Ast,

    fn init(allocator: std.mem.Allocator, source: []const u8) !Parser {
        var result = Parser{
            .allocator = allocator,
            .source = source,
            .tokens = .empty,
            .ast = ast.Ast.init(allocator),
        };
        errdefer result.ast.deinit();

        result.tokens = try lexer.tokenize(allocator, source, &result.ast.strings);
        return result;
    }

    fn deinit(self: *Parser) void {
        self.tokens.deinit(self.allocator);
        self.ast.deinit();
    }

    fn releaseAst(self: *Parser) ast.Ast {
        const out = self.ast;
        self.ast = ast.Ast.init(self.allocator);
        return out;
    }

    fn current(self: *const Parser) token.Token {
        return self.tokens.items[self.index];
    }

    fn previous(self: *const Parser) token.Token {
        return self.tokens.items[self.index - 1];
    }

    fn advance(self: *Parser) token.Token {
        const tok = self.current();
        if (tok.tag != .eof) {
            self.index += 1;
        }
        return tok;
    }

    fn matchTag(self: *Parser, tag_: token.Tag) bool {
        if (self.current().tag != tag_) return false;
        _ = self.advance();
        return true;
    }

    fn expectTag(self: *Parser, tag_: token.Tag) Error!token.Token {
        const tok = self.current();
        if (tok.tag != tag_) {
            return if (tok.tag == .eof) Error.UnexpectedEof else Error.UnexpectedToken;
        }
        return self.advance();
    }

    fn parseExpr(self: *Parser) Error!ast.Index {
        if (self.depth >= max_nesting_depth) return Error.ExpressionNestingExceeded;
        self.depth += 1;
        defer self.depth -= 1;
        return self.parseConditional();
    }

    fn parseConditional(self: *Parser) Error!ast.Index {
        var cond = try self.parseLogicalOr();
        if (!self.matchTag(.question)) {
            return cond;
        }

        const then_expr = try self.parseLogicalOr();
        _ = try self.expectTag(.colon);
        const else_expr = try self.parseExpr();

        const where = mergeSpans(self.ast.node(cond).where, self.ast.node(else_expr).where);
        cond = try self.ast.addNode(.{
            .where = where,
            .data = .{ .conditional = .{
                .condition = cond,
                .then_expr = then_expr,
                .else_expr = else_expr,
            } },
        });
        return cond;
    }

    fn parseLogicalOr(self: *Parser) Error!ast.Index {
        return self.parseBinaryChain(parseLogicalAnd, &.{.{ .tag = .logical_or, .op = .logical_or }});
    }

    fn parseLogicalAnd(self: *Parser) Error!ast.Index {
        return self.parseBinaryChain(parseRelation, &.{.{ .tag = .logical_and, .op = .logical_and }});
    }

    fn parseRelation(self: *Parser) Error!ast.Index {
        return self.parseBinaryChain(parseAddition, &.{
            .{ .tag = .less, .op = .less },
            .{ .tag = .less_equal, .op = .less_equal },
            .{ .tag = .greater, .op = .greater },
            .{ .tag = .greater_equal, .op = .greater_equal },
            .{ .tag = .equal_equal, .op = .equal },
            .{ .tag = .bang_equal, .op = .not_equal },
            .{ .tag = .in_kw, .op = .in_set },
        });
    }

    fn parseAddition(self: *Parser) Error!ast.Index {
        return self.parseBinaryChain(parseMultiplication, &.{
            .{ .tag = .plus, .op = .add },
            .{ .tag = .minus, .op = .subtract },
        });
    }

    fn parseMultiplication(self: *Parser) Error!ast.Index {
        return self.parseBinaryChain(parseUnary, &.{
            .{ .tag = .star, .op = .multiply },
            .{ .tag = .slash, .op = .divide },
            .{ .tag = .percent, .op = .remainder },
        });
    }

    const BinarySpec = struct {
        tag: token.Tag,
        op: ast.BinaryOp,
    };

    fn parseBinaryChain(
        self: *Parser,
        comptime subexpr_fn: fn (*Parser) Error!ast.Index,
        comptime ops: []const BinarySpec,
    ) Error!ast.Index {
        var left = try subexpr_fn(self);
        while (true) {
            var matched: ?ast.BinaryOp = null;
            inline for (ops) |spec| {
                if (self.current().tag == spec.tag) {
                    _ = self.advance();
                    matched = spec.op;
                    break;
                }
            }
            const op = matched orelse break;

            const right = try subexpr_fn(self);
            left = try self.ast.addNode(.{
                .where = mergeSpans(self.ast.node(left).where, self.ast.node(right).where),
                .data = .{ .binary = .{
                    .op = op,
                    .left = left,
                    .right = right,
                } },
            });
        }
        return left;
    }

    fn parseUnary(self: *Parser) Error!ast.Index {
        if (self.matchTag(.bang)) {
            if (self.depth >= max_nesting_depth) return Error.ExpressionNestingExceeded;
            self.depth += 1;
            defer self.depth -= 1;
            const expr = try self.parseUnary();
            const op_tok = self.previous();
            return self.ast.addNode(.{
                .where = mergeSpans(op_tok.where, self.ast.node(expr).where),
                .data = .{ .unary = .{
                    .op = .logical_not,
                    .expr = expr,
                } },
            });
        }
        if (self.matchTag(.minus)) {
            if (self.depth >= max_nesting_depth) return Error.ExpressionNestingExceeded;
            self.depth += 1;
            defer self.depth -= 1;
            const op_tok = self.previous();
            const tok = self.current();
            if (tok.tag == .int_lit and tok.data == .uint_value and tok.data.uint_value == @as(u64, std.math.maxInt(i64)) + 1) {
                _ = self.advance();
                return self.ast.addNode(.{
                    .where = mergeSpans(op_tok.where, tok.where),
                    .data = .{ .literal_int = std.math.minInt(i64) },
                });
            }
            const expr = try self.parseUnary();
            return self.ast.addNode(.{
                .where = mergeSpans(op_tok.where, self.ast.node(expr).where),
                .data = .{ .unary = .{
                    .op = .negate,
                    .expr = expr,
                } },
            });
        }
        return self.parseMember();
    }

    fn parseMember(self: *Parser) Error!ast.Index {
        var expr = try self.parsePrimary();

        while (true) {
            switch (self.current().tag) {
                .dot => {
                    _ = self.advance();
                    const optional = self.matchTag(.question);
                    const field = try self.expectIdentifier(true);
                    if (self.matchTag(.l_paren)) {
                        if (optional) return Error.UnexpectedToken;
                        const args = try self.parseArgumentList();
                        const end_tok = self.previous();
                        expr = try self.ast.addNode(.{
                            .where = mergeSpans(self.ast.node(expr).where, end_tok.where),
                            .data = .{ .receiver_call = .{
                                .target = expr,
                                .name = field,
                                .args = args,
                            } },
                        });
                    } else {
                        const field_tok = self.previous();
                        expr = try self.ast.addNode(.{
                            .where = mergeSpans(self.ast.node(expr).where, field_tok.where),
                            .data = .{ .select = .{
                                .target = expr,
                                .field = field,
                                .optional = optional,
                            } },
                        });
                    }
                },
                .l_bracket => {
                    _ = self.advance();
                    const optional = self.matchTag(.question);
                    const index_expr = try self.parseExpr();
                    const end_tok = try self.expectTag(.r_bracket);
                    expr = try self.ast.addNode(.{
                        .where = mergeSpans(self.ast.node(expr).where, end_tok.where),
                        .data = .{ .index = .{
                            .target = expr,
                            .index = index_expr,
                            .optional = optional,
                        } },
                    });
                },
                else => return expr,
            }
        }
    }

    fn parsePrimary(self: *Parser) Error!ast.Index {
        if (self.beginsMessageLiteral()) {
            return self.parseMessageLiteral();
        }

        const tok = self.current();
        switch (tok.tag) {
            .identifier, .dot => return self.parseNameOrCall(),
            .int_lit => {
                if (tok.data == .uint_value) {
                    return Error.IntegerOverflow;
                }
                _ = self.advance();
                return self.ast.addNode(.{
                    .where = tok.where,
                    .data = .{ .literal_int = tok.data.int_value },
                });
            },
            .uint_lit => {
                _ = self.advance();
                return self.ast.addNode(.{
                    .where = tok.where,
                    .data = .{ .literal_uint = tok.data.uint_value },
                });
            },
            .float_lit => {
                _ = self.advance();
                return self.ast.addNode(.{
                    .where = tok.where,
                    .data = .{ .literal_double = tok.data.float_value },
                });
            },
            .string_lit => {
                _ = self.advance();
                return self.ast.addNode(.{
                    .where = tok.where,
                    .data = .{ .literal_string = tok.data.string_id },
                });
            },
            .bytes_lit => {
                _ = self.advance();
                return self.ast.addNode(.{
                    .where = tok.where,
                    .data = .{ .literal_bytes = tok.data.string_id },
                });
            },
            .bool_true => {
                _ = self.advance();
                return self.ast.addNode(.{
                    .where = tok.where,
                    .data = .{ .literal_bool = true },
                });
            },
            .bool_false => {
                _ = self.advance();
                return self.ast.addNode(.{
                    .where = tok.where,
                    .data = .{ .literal_bool = false },
                });
            },
            .null_lit => {
                _ = self.advance();
                return self.ast.addNode(.{
                    .where = tok.where,
                    .data = .literal_null,
                });
            },
            .l_paren => {
                _ = self.advance();
                const expr = try self.parseExpr();
                _ = try self.expectTag(.r_paren);
                return expr;
            },
            .l_bracket => return self.parseListLiteral(),
            .l_brace => return self.parseMapLiteral(),
            else => return Error.ExpectedExpression,
        }
    }

    fn parseNameOrCall(self: *Parser) Error!ast.Index {
        const start_tok = self.current();
        var absolute = false;
        if (self.matchTag(.dot)) {
            absolute = true;
        }

        const name_id = try self.expectIdentifier(false);
        const name_ref = try self.ast.appendName(absolute, &.{name_id});

        if (self.matchTag(.l_paren)) {
            const args = try self.parseArgumentList();
            const end_tok = self.previous();
            return self.ast.addNode(.{
                .where = mergeSpans(start_tok.where, end_tok.where),
                .data = .{ .call = .{
                    .name = name_ref,
                    .args = args,
                } },
            });
        }

        const end_span = self.previous().where;
        return self.ast.addNode(.{
            .where = mergeSpans(start_tok.where, end_span),
            .data = .{ .ident = name_ref },
        });
    }

    fn parseArgumentList(self: *Parser) Error!ast.Range {
        var args: std.ArrayListUnmanaged(ast.Index) = .empty;
        defer args.deinit(self.allocator);

        if (!self.matchTag(.r_paren)) {
            while (true) {
                try args.append(self.allocator, try self.parseExpr());
                if (!self.matchTag(.comma)) break;
            }
            _ = try self.expectTag(.r_paren);
        }

        return self.ast.appendExprRange(args.items);
    }

    fn parseListLiteral(self: *Parser) Error!ast.Index {
        const start_tok = try self.expectTag(.l_bracket);
        var items: std.ArrayListUnmanaged(ast.ListItem) = .empty;
        defer items.deinit(self.allocator);

        if (!self.matchTag(.r_bracket)) {
            while (true) {
                const optional = self.matchTag(.question);
                try items.append(self.allocator, .{
                    .optional = optional,
                    .value = try self.parseExpr(),
                });
                if (!self.matchTag(.comma)) break;
                if (self.current().tag == .r_bracket) break;
            }
            _ = try self.expectTag(.r_bracket);
        }

        const end_tok = self.previous();
        const range = try self.ast.appendListItems(items.items);
        return self.ast.addNode(.{
            .where = mergeSpans(start_tok.where, end_tok.where),
            .data = .{ .list = range },
        });
    }

    fn parseMapLiteral(self: *Parser) Error!ast.Index {
        const start_tok = try self.expectTag(.l_brace);
        var entries: std.ArrayListUnmanaged(ast.MapEntry) = .empty;
        defer entries.deinit(self.allocator);

        if (!self.matchTag(.r_brace)) {
            while (true) {
                const optional = self.matchTag(.question);
                const key = try self.parseExpr();
                _ = try self.expectTag(.colon);
                const value = try self.parseExpr();
                try entries.append(self.allocator, .{
                    .optional = optional,
                    .key = key,
                    .value = value,
                });
                if (!self.matchTag(.comma)) break;
                if (self.current().tag == .r_brace) break;
            }
            _ = try self.expectTag(.r_brace);
        }

        const end_tok = self.previous();
        const range = try self.ast.appendMapEntries(entries.items);
        return self.ast.addNode(.{
            .where = mergeSpans(start_tok.where, end_tok.where),
            .data = .{ .map = range },
        });
    }

    fn parseMessageLiteral(self: *Parser) Error!ast.Index {
        const start_tok = self.current();
        var absolute = false;
        if (self.matchTag(.dot)) {
            absolute = true;
        }

        var segments: std.ArrayListUnmanaged(strings.StringTable.Id) = .empty;
        defer segments.deinit(self.allocator);

        try segments.append(self.allocator, try self.expectIdentifier(true));
        while (self.matchTag(.dot)) {
            try segments.append(self.allocator, try self.expectIdentifier(true));
        }

        const name = try self.ast.appendName(absolute, segments.items);
        _ = try self.expectTag(.l_brace);

        var fields: std.ArrayListUnmanaged(ast.FieldInit) = .empty;
        defer fields.deinit(self.allocator);

        if (!self.matchTag(.r_brace)) {
            while (true) {
                const optional = self.matchTag(.question);
                const field_name = try self.expectIdentifier(true);
                _ = try self.expectTag(.colon);
                const field_value = try self.parseExpr();
                try fields.append(self.allocator, .{
                    .optional = optional,
                    .name = field_name,
                    .value = field_value,
                });
                if (!self.matchTag(.comma)) break;
                if (self.current().tag == .r_brace) break;
            }
            _ = try self.expectTag(.r_brace);
        }

        const end_tok = self.previous();
        const range = try self.ast.appendFieldInits(fields.items);
        return self.ast.addNode(.{
            .where = mergeSpans(start_tok.where, end_tok.where),
            .data = .{ .message = .{
                .name = name,
                .fields = range,
            } },
        });
    }

    fn beginsMessageLiteral(self: *const Parser) bool {
        var i = self.index;
        if (self.tokens.items[i].tag == .dot) {
            i += 1;
        }
        if (i >= self.tokens.items.len or self.tokens.items[i].tag != .identifier) {
            return false;
        }
        i += 1;
        while (i + 1 < self.tokens.items.len and
            self.tokens.items[i].tag == .dot and
            self.tokens.items[i + 1].tag == .identifier)
        {
            i += 2;
        }
        return i < self.tokens.items.len and self.tokens.items[i].tag == .l_brace;
    }

    fn expectIdentifier(self: *Parser, allow_reserved: bool) Error!strings.StringTable.Id {
        const tok = self.current();
        if (tok.tag != .identifier) {
            return if (tok.tag == .eof) Error.UnexpectedEof else Error.ExpectedIdentifier;
        }
        const id = tok.data.string_id;
        if (!allow_reserved and token.isReservedWord(self.ast.strings.get(id))) {
            return Error.ReservedIdentifier;
        }
        _ = self.advance();
        return id;
    }
};

fn mergeSpans(a: span.Span, b: span.Span) span.Span {
    return .{
        .start = a.start,
        .end = b.end,
    };
}

test "parse precedence and conditional" {
    var tree = try parse(std.testing.allocator, "a || b && c ? d : e");
    defer tree.deinit();

    const root = tree.node(tree.root.?);
    try std.testing.expectEqual(ast.Tag.conditional, root.tag());
}

test "parse select index and receiver call" {
    var tree = try parse(std.testing.allocator, "account.emails[1].size()");
    defer tree.deinit();

    const root = tree.node(tree.root.?);
    try std.testing.expectEqual(ast.Tag.receiver_call, root.tag());
}

test "parse message literal and equality" {
    var tree = try parse(std.testing.allocator, "Account{user_id: 'Pokemon'}.user_id == 'Pokemon'");
    defer tree.deinit();

    const root = tree.node(tree.root.?);
    try std.testing.expectEqual(ast.Tag.binary, root.tag());
}

test "parse spec minimum repetition and recursion depths" {
    var expr: std.ArrayListUnmanaged(u8) = .empty;
    defer expr.deinit(std.testing.allocator);

    try expr.appendSlice(std.testing.allocator, "f(");
    for (0..32) |i| {
        if (i > 0) try expr.appendSlice(std.testing.allocator, ", ");
        try @import("../util/fmt.zig").appendFormat(&expr, std.testing.allocator, "{d}", .{i});
    }
    try expr.append(std.testing.allocator, ')');

    var call_tree = try parse(std.testing.allocator, expr.items);
    defer call_tree.deinit();
    try std.testing.expectEqual(ast.Tag.call, call_tree.node(call_tree.root.?).tag());

    expr.clearRetainingCapacity();
    try expr.appendSlice(std.testing.allocator, "root");
    for (0..12) |i| {
        _ = i;
        try expr.appendSlice(std.testing.allocator, ".child");
    }
    var select_tree = try parse(std.testing.allocator, expr.items);
    defer select_tree.deinit();
    try std.testing.expectEqual(ast.Tag.select, select_tree.node(select_tree.root.?).tag());

    expr.clearRetainingCapacity();
    try expr.appendSlice(std.testing.allocator, "root");
    for (0..12) |_| {
        try expr.appendSlice(std.testing.allocator, "[0]");
    }
    var index_tree = try parse(std.testing.allocator, expr.items);
    defer index_tree.deinit();
    try std.testing.expectEqual(ast.Tag.index, index_tree.node(index_tree.root.?).tag());
}

test "parse optionals syntax and literal elision markers" {
    var tree = try parse(
        std.testing.allocator,
        "TestAllTypes{?field: {'k': 1}[?'k']}.?field[?0]",
    );
    defer tree.deinit();

    const root = tree.node(tree.root.?);
    try std.testing.expectEqual(ast.Tag.index, root.tag());
    try std.testing.expect(root.data.index.optional);

    const select_node = tree.node(root.data.index.target);
    try std.testing.expectEqual(ast.Tag.select, select_node.tag());
    try std.testing.expect(select_node.data.select.optional);

    const message_node = tree.node(select_node.data.select.target);
    try std.testing.expectEqual(ast.Tag.message, message_node.tag());
    const field_init = tree.field_inits.items[message_node.data.message.fields.start];
    try std.testing.expect(field_init.optional);

    const field_value = tree.node(field_init.value);
    try std.testing.expectEqual(ast.Tag.index, field_value.tag());
    try std.testing.expect(field_value.data.index.optional);
}

test "parse literal expressions" {
    // Literals that parse to a specific tag (no data check needed beyond tag)
    const tag_cases = [_]struct { expr: []const u8, expected_tag: ast.Tag }{
        .{ .expr = "42", .expected_tag = .literal_int },
        .{ .expr = "0", .expected_tag = .literal_int },
        .{ .expr = "42u", .expected_tag = .literal_uint },
        .{ .expr = "0u", .expected_tag = .literal_uint },
        .{ .expr = "3.14", .expected_tag = .literal_double },
        .{ .expr = "0.0", .expected_tag = .literal_double },
        .{ .expr = ".5", .expected_tag = .literal_double },
        .{ .expr = "null", .expected_tag = .literal_null },
        .{ .expr = "foo", .expected_tag = .ident },
    };
    for (tag_cases) |case| {
        var tree = try parse(std.testing.allocator, case.expr);
        defer tree.deinit();
        const root = tree.node(tree.root.?);
        try std.testing.expectEqual(case.expected_tag, root.tag());
    }

    // Int value checks
    {
        var tree = try parse(std.testing.allocator, "42");
        defer tree.deinit();
        try std.testing.expectEqual(@as(i64, 42), tree.node(tree.root.?).data.literal_int);
    }

    // Uint value check
    {
        var tree = try parse(std.testing.allocator, "42u");
        defer tree.deinit();
        try std.testing.expectEqual(@as(u64, 42), tree.node(tree.root.?).data.literal_uint);
    }

    // Float value check
    {
        var tree = try parse(std.testing.allocator, "3.14");
        defer tree.deinit();
        try std.testing.expectEqual(@as(f64, 3.14), tree.node(tree.root.?).data.literal_double);
    }

    // String value check
    {
        var tree = try parse(std.testing.allocator, "'hello'");
        defer tree.deinit();
        const root = tree.node(tree.root.?);
        try std.testing.expectEqual(ast.Tag.literal_string, root.tag());
        try std.testing.expectEqualStrings("hello", tree.strings.get(root.data.literal_string));
    }

    // Bytes value check
    {
        var tree = try parse(std.testing.allocator, "b'data'");
        defer tree.deinit();
        const root = tree.node(tree.root.?);
        try std.testing.expectEqual(ast.Tag.literal_bytes, root.tag());
        try std.testing.expectEqualStrings("data", tree.strings.get(root.data.literal_bytes));
    }

    // Bool values
    {
        var tree = try parse(std.testing.allocator, "true");
        defer tree.deinit();
        const root = tree.node(tree.root.?);
        try std.testing.expectEqual(ast.Tag.literal_bool, root.tag());
        try std.testing.expect(root.data.literal_bool);
    }
    {
        var tree = try parse(std.testing.allocator, "false");
        defer tree.deinit();
        const root = tree.node(tree.root.?);
        try std.testing.expectEqual(ast.Tag.literal_bool, root.tag());
        try std.testing.expect(!root.data.literal_bool);
    }
}

test "parse unary operators" {
    const cases = [_]struct { expr: []const u8, expected_op: ast.UnaryOp }{
        .{ .expr = "!true", .expected_op = .logical_not },
        .{ .expr = "!false", .expected_op = .logical_not },
        .{ .expr = "-5", .expected_op = .negate },
        .{ .expr = "-x", .expected_op = .negate },
    };
    for (cases) |case| {
        var tree = try parse(std.testing.allocator, case.expr);
        defer tree.deinit();
        const root = tree.node(tree.root.?);
        try std.testing.expectEqual(ast.Tag.unary, root.tag());
        try std.testing.expectEqual(case.expected_op, root.data.unary.op);
    }

    // Double negation: !!x -> unary(not, unary(not, x))
    {
        var tree = try parse(std.testing.allocator, "!!x");
        defer tree.deinit();
        const root = tree.node(tree.root.?);
        try std.testing.expectEqual(ast.Tag.unary, root.tag());
        try std.testing.expectEqual(ast.UnaryOp.logical_not, root.data.unary.op);
        const inner = tree.node(root.data.unary.expr);
        try std.testing.expectEqual(ast.Tag.unary, inner.tag());
        try std.testing.expectEqual(ast.UnaryOp.logical_not, inner.data.unary.op);
    }
}

test "parse binary operators" {
    const cases = [_]struct { expr: []const u8, expected_op: ast.BinaryOp }{
        .{ .expr = "1 + 2", .expected_op = .add },
        .{ .expr = "a - b", .expected_op = .subtract },
        .{ .expr = "a < b", .expected_op = .less },
        .{ .expr = "a <= b", .expected_op = .less_equal },
        .{ .expr = "a > b", .expected_op = .greater },
        .{ .expr = "a >= b", .expected_op = .greater_equal },
        .{ .expr = "a == b", .expected_op = .equal },
        .{ .expr = "a != b", .expected_op = .not_equal },
        .{ .expr = "a in b", .expected_op = .in_set },
    };
    for (cases) |case| {
        var tree = try parse(std.testing.allocator, case.expr);
        defer tree.deinit();
        const root = tree.node(tree.root.?);
        try std.testing.expectEqual(ast.Tag.binary, root.tag());
        try std.testing.expectEqual(case.expected_op, root.data.binary.op);
    }
}

test "parse multiplication has higher precedence than addition" {
    var tree = try parse(std.testing.allocator, "1 + 2 * 3");
    defer tree.deinit();
    const root = tree.node(tree.root.?);
    try std.testing.expectEqual(ast.Tag.binary, root.tag());
    try std.testing.expectEqual(ast.BinaryOp.add, root.data.binary.op);
    const right = tree.node(root.data.binary.right);
    try std.testing.expectEqual(ast.Tag.binary, right.tag());
    try std.testing.expectEqual(ast.BinaryOp.multiply, right.data.binary.op);
}

test "parse division and remainder" {
    var tree = try parse(std.testing.allocator, "10 / 3 % 2");
    defer tree.deinit();
    const root = tree.node(tree.root.?);
    try std.testing.expectEqual(ast.Tag.binary, root.tag());
    try std.testing.expectEqual(ast.BinaryOp.remainder, root.data.binary.op);
    const left = tree.node(root.data.binary.left);
    try std.testing.expectEqual(ast.BinaryOp.divide, left.data.binary.op);
}

test "parse logical and has lower precedence than comparison" {
    var tree = try parse(std.testing.allocator, "a < b && c > d");
    defer tree.deinit();
    const root = tree.node(tree.root.?);
    try std.testing.expectEqual(ast.BinaryOp.logical_and, root.data.binary.op);
    const left = tree.node(root.data.binary.left);
    try std.testing.expectEqual(ast.BinaryOp.less, left.data.binary.op);
    const right = tree.node(root.data.binary.right);
    try std.testing.expectEqual(ast.BinaryOp.greater, right.data.binary.op);
}

test "parse logical or has lower precedence than logical and" {
    var tree = try parse(std.testing.allocator, "a || b && c");
    defer tree.deinit();
    const root = tree.node(tree.root.?);
    try std.testing.expectEqual(ast.BinaryOp.logical_or, root.data.binary.op);
    const right = tree.node(root.data.binary.right);
    try std.testing.expectEqual(ast.BinaryOp.logical_and, right.data.binary.op);
}

test "parse nested parentheses" {
    var tree = try parse(std.testing.allocator, "((1))");
    defer tree.deinit();
    const root = tree.node(tree.root.?);
    try std.testing.expectEqual(ast.Tag.literal_int, root.tag());
    try std.testing.expectEqual(@as(i64, 1), root.data.literal_int);
}

test "parse parentheses override precedence" {
    var tree = try parse(std.testing.allocator, "(1 + 2) * 3");
    defer tree.deinit();
    const root = tree.node(tree.root.?);
    try std.testing.expectEqual(ast.BinaryOp.multiply, root.data.binary.op);
    const left = tree.node(root.data.binary.left);
    try std.testing.expectEqual(ast.BinaryOp.add, left.data.binary.op);
}

test "parse function and receiver calls" {
    // function calls
    {
        const call_cases = [_]struct { expr: []const u8, expected_args: u32 }{
            .{ .expr = "f()", .expected_args = 0 },
            .{ .expr = "f(1)", .expected_args = 1 },
            .{ .expr = "f(1, 2, 3)", .expected_args = 3 },
            .{ .expr = "f(a, b, c, d)", .expected_args = 4 },
        };
        for (call_cases) |case| {
            var tree = try parse(std.testing.allocator, case.expr);
            defer tree.deinit();
            const root = tree.node(tree.root.?);
            try std.testing.expectEqual(ast.Tag.call, root.tag());
            try std.testing.expectEqual(case.expected_args, root.data.call.args.len);
        }
    }

    // receiver calls
    {
        const rcv_cases = [_]struct { expr: []const u8, expected_args: u32 }{
            .{ .expr = "x.f()", .expected_args = 0 },
            .{ .expr = "x.f(a, b)", .expected_args = 2 },
            .{ .expr = "x.f(1, 2, 3)", .expected_args = 3 },
        };
        for (rcv_cases) |case| {
            var tree = try parse(std.testing.allocator, case.expr);
            defer tree.deinit();
            const root = tree.node(tree.root.?);
            try std.testing.expectEqual(ast.Tag.receiver_call, root.tag());
            try std.testing.expectEqual(case.expected_args, root.data.receiver_call.args.len);
        }
    }
}

test "parse select and index expressions" {
    // select
    {
        const select_cases = [_]struct { expr: []const u8, optional: bool }{
            .{ .expr = "x.field", .optional = false },
            .{ .expr = "x.?field", .optional = true },
            .{ .expr = "x.a", .optional = false },
        };
        for (select_cases) |case| {
            var tree = try parse(std.testing.allocator, case.expr);
            defer tree.deinit();
            const root = tree.node(tree.root.?);
            try std.testing.expectEqual(ast.Tag.select, root.tag());
            try std.testing.expectEqual(case.optional, root.data.select.optional);
        }
    }

    // nested select
    {
        var tree = try parse(std.testing.allocator, "x.a.b.c");
        defer tree.deinit();
        const root = tree.node(tree.root.?);
        try std.testing.expectEqual(ast.Tag.select, root.tag());
        const mid = tree.node(root.data.select.target);
        try std.testing.expectEqual(ast.Tag.select, mid.tag());
    }

    // index
    {
        const index_cases = [_]struct { expr: []const u8, optional: bool }{
            .{ .expr = "x[0]", .optional = false },
            .{ .expr = "x[y]", .optional = false },
            .{ .expr = "x[?0]", .optional = true },
        };
        for (index_cases) |case| {
            var tree = try parse(std.testing.allocator, case.expr);
            defer tree.deinit();
            const root = tree.node(tree.root.?);
            try std.testing.expectEqual(ast.Tag.index, root.tag());
            try std.testing.expectEqual(case.optional, root.data.index.optional);
        }
    }
}

test "parse list literals" {
    const cases = [_]struct { expr: []const u8, expected_len: u32 }{
        .{ .expr = "[]", .expected_len = 0 },
        .{ .expr = "[1]", .expected_len = 1 },
        .{ .expr = "[1, 2, 3]", .expected_len = 3 },
        .{ .expr = "[1, 2,]", .expected_len = 2 },
        .{ .expr = "[1, 2, 3, 4, 5]", .expected_len = 5 },
    };
    for (cases) |case| {
        var tree = try parse(std.testing.allocator, case.expr);
        defer tree.deinit();
        const root = tree.node(tree.root.?);
        try std.testing.expectEqual(ast.Tag.list, root.tag());
        try std.testing.expectEqual(case.expected_len, root.data.list.len);
    }
}

test "parse map literals" {
    const cases = [_]struct { expr: []const u8, expected_len: u32 }{
        .{ .expr = "{}", .expected_len = 0 },
        .{ .expr = "{'a': 1}", .expected_len = 1 },
        .{ .expr = "{'a': 1, 'b': 2}", .expected_len = 2 },
        .{ .expr = "{'a': 1,}", .expected_len = 1 },
        .{ .expr = "{'a': 1, 'b': 2, 'c': 3}", .expected_len = 3 },
    };
    for (cases) |case| {
        var tree = try parse(std.testing.allocator, case.expr);
        defer tree.deinit();
        const root = tree.node(tree.root.?);
        try std.testing.expectEqual(ast.Tag.map, root.tag());
        try std.testing.expectEqual(case.expected_len, root.data.map.len);
    }
}

test "parse message construction" {
    const cases = [_]struct { expr: []const u8, expected_fields: u32 }{
        .{ .expr = "Msg{}", .expected_fields = 0 },
        .{ .expr = "Msg{field: 1}", .expected_fields = 1 },
        .{ .expr = "Msg{a: 1, b: 2, c: 3}", .expected_fields = 3 },
    };
    for (cases) |case| {
        var tree = try parse(std.testing.allocator, case.expr);
        defer tree.deinit();
        const root = tree.node(tree.root.?);
        try std.testing.expectEqual(ast.Tag.message, root.tag());
        try std.testing.expectEqual(case.expected_fields, root.data.message.fields.len);
    }
}

test "parse ternary conditional" {
    // Simple ternary
    {
        var tree = try parse(std.testing.allocator, "a ? b : c");
        defer tree.deinit();
        const root = tree.node(tree.root.?);
        try std.testing.expectEqual(ast.Tag.conditional, root.tag());
    }

    // Nested conditional in else branch
    {
        var tree = try parse(std.testing.allocator, "a ? b : c ? d : e");
        defer tree.deinit();
        const root = tree.node(tree.root.?);
        try std.testing.expectEqual(ast.Tag.conditional, root.tag());
        const else_expr = tree.node(root.data.conditional.else_expr);
        try std.testing.expectEqual(ast.Tag.conditional, else_expr.tag());
    }
}

test "parse error cases" {
    const cases = [_]struct { expr: []const u8, expected_error: Error }{
        .{ .expr = "", .expected_error = Error.ExpectedExpression },
        .{ .expr = "(1", .expected_error = Error.UnexpectedEof },
        .{ .expr = "x[0", .expected_error = Error.UnexpectedEof },
        .{ .expr = "1)", .expected_error = Error.UnexpectedToken },
        .{ .expr = "1 +", .expected_error = Error.ExpectedExpression },
        .{ .expr = "{'a' 1}", .expected_error = Error.UnexpectedToken },
        .{ .expr = "package", .expected_error = Error.ReservedIdentifier },
    };
    for (cases) |case| {
        try std.testing.expectError(case.expected_error, parse(std.testing.allocator, case.expr));
    }
}

test "parse chained member and index" {
    var tree = try parse(std.testing.allocator, "a.b[0].c");
    defer tree.deinit();
    const root = tree.node(tree.root.?);
    try std.testing.expectEqual(ast.Tag.select, root.tag());
}

test "parse negative min int" {
    var tree = try parse(std.testing.allocator, "-9223372036854775808");
    defer tree.deinit();
    const root = tree.node(tree.root.?);
    try std.testing.expectEqual(ast.Tag.literal_int, root.tag());
    try std.testing.expectEqual(std.math.minInt(i64), root.data.literal_int);
}

test "parse complex expression" {
    var tree = try parse(std.testing.allocator, "x.size() > 0 && x[0] == 'a'");
    defer tree.deinit();
    const root = tree.node(tree.root.?);
    try std.testing.expectEqual(ast.Tag.binary, root.tag());
    try std.testing.expectEqual(ast.BinaryOp.logical_and, root.data.binary.op);
}

test "parse qualified message name" {
    var tree = try parse(std.testing.allocator, "pkg.Msg{a: 1}");
    defer tree.deinit();
    const root = tree.node(tree.root.?);
    try std.testing.expectEqual(ast.Tag.message, root.tag());
    try std.testing.expectEqual(@as(u32, 2), root.data.message.name.segments.len);
}

test "parse rejects expressions exceeding max nesting depth" {
    // Build a deeply nested expression: (((((...(1)...))))
    var expr: std.ArrayListUnmanaged(u8) = .empty;
    defer expr.deinit(std.testing.allocator);
    for (0..max_nesting_depth + 1) |_| {
        try expr.append(std.testing.allocator, '(');
    }
    try expr.append(std.testing.allocator, '1');
    for (0..max_nesting_depth + 1) |_| {
        try expr.append(std.testing.allocator, ')');
    }
    try std.testing.expectError(Error.ExpressionNestingExceeded, parse(std.testing.allocator, expr.items));

    // Build deeply nested unary: !!!...!true
    var unary_expr: std.ArrayListUnmanaged(u8) = .empty;
    defer unary_expr.deinit(std.testing.allocator);
    for (0..max_nesting_depth + 1) |_| {
        try unary_expr.append(std.testing.allocator, '!');
    }
    try unary_expr.appendSlice(std.testing.allocator, "true");
    try std.testing.expectError(Error.ExpressionNestingExceeded, parse(std.testing.allocator, unary_expr.items));
}

test "parse accepts expressions at exactly max nesting depth" {
    // Nesting depth of exactly max_nesting_depth should succeed
    var expr: std.ArrayListUnmanaged(u8) = .empty;
    defer expr.deinit(std.testing.allocator);
    for (0..max_nesting_depth - 1) |_| {
        try expr.append(std.testing.allocator, '(');
    }
    try expr.append(std.testing.allocator, '1');
    for (0..max_nesting_depth - 1) |_| {
        try expr.append(std.testing.allocator, ')');
    }
    var tree = try parse(std.testing.allocator, expr.items);
    tree.deinit();
}
