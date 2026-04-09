const std = @import("std");
const span = @import("span.zig");
const strings = @import("string_table.zig");
const token = @import("token.zig");

pub const Error = error{
    UnexpectedCharacter,
    UnterminatedString,
    InvalidEscape,
    InvalidUnicodeEscape,
    InvalidNumber,
    IntegerOverflow,
    InvalidUtf8InString,
};

pub fn tokenize(
    allocator: std.mem.Allocator,
    source: []const u8,
    table: *strings.StringTable,
) !std.ArrayListUnmanaged(token.Token) {
    var lexer = Lexer{
        .allocator = allocator,
        .source = source,
        .offset = 0,
        .strings = table,
    };
    return lexer.tokenizeAll();
}

const Lexer = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    offset: usize,
    strings: *strings.StringTable,

    fn tokenizeAll(self: *Lexer) !std.ArrayListUnmanaged(token.Token) {
        var out: std.ArrayListUnmanaged(token.Token) = .empty;
        errdefer out.deinit(self.allocator);

        while (true) {
            try self.skipIgnored();

            const tok = try self.nextToken();
            try out.append(self.allocator, tok);
            if (tok.tag == .eof) {
                break;
            }
        }

        return out;
    }

    fn nextToken(self: *Lexer) !token.Token {
        const start = self.offset;
        const ch = self.peek() orelse return .{
            .tag = .eof,
            .where = span.Span.init(start, start),
        };

        const dot_starts_float = ch == '.' and blk: {
            const next = self.peekAt(1) orelse break :blk false;
            break :blk isDigit(next);
        };
        if (isDigit(ch) or dot_starts_float) {
            return self.lexNumber();
        }

        if (isIdentStart(ch)) {
            if (self.isBytesPrefix()) {
                return self.lexStringLike(true);
            }
            if (self.isRawStringPrefix()) {
                return self.lexStringLike(false);
            }
            return self.lexIdentifier();
        }

        if (ch == '"' or ch == '\'') {
            return self.lexStringLike(false);
        }

        if (ch == '`') {
            return self.lexQuotedIdentifier();
        }

        self.offset += 1;
        return switch (ch) {
            '(' => .{ .tag = .l_paren, .where = span.Span.init(start, self.offset) },
            ')' => .{ .tag = .r_paren, .where = span.Span.init(start, self.offset) },
            '[' => .{ .tag = .l_bracket, .where = span.Span.init(start, self.offset) },
            ']' => .{ .tag = .r_bracket, .where = span.Span.init(start, self.offset) },
            '{' => .{ .tag = .l_brace, .where = span.Span.init(start, self.offset) },
            '}' => .{ .tag = .r_brace, .where = span.Span.init(start, self.offset) },
            ',' => .{ .tag = .comma, .where = span.Span.init(start, self.offset) },
            '.' => .{ .tag = .dot, .where = span.Span.init(start, self.offset) },
            '?' => .{ .tag = .question, .where = span.Span.init(start, self.offset) },
            ':' => .{ .tag = .colon, .where = span.Span.init(start, self.offset) },
            '+' => .{ .tag = .plus, .where = span.Span.init(start, self.offset) },
            '-' => .{ .tag = .minus, .where = span.Span.init(start, self.offset) },
            '*' => .{ .tag = .star, .where = span.Span.init(start, self.offset) },
            '%' => .{ .tag = .percent, .where = span.Span.init(start, self.offset) },
            '/' => .{ .tag = .slash, .where = span.Span.init(start, self.offset) },
            '!' => if (self.matchChar('=')) .{
                .tag = .bang_equal,
                .where = span.Span.init(start, self.offset),
            } else .{
                .tag = .bang,
                .where = span.Span.init(start, self.offset),
            },
            '=' => if (self.matchChar('=')) .{
                .tag = .equal_equal,
                .where = span.Span.init(start, self.offset),
            } else Error.UnexpectedCharacter,
            '<' => if (self.matchChar('=')) .{
                .tag = .less_equal,
                .where = span.Span.init(start, self.offset),
            } else .{
                .tag = .less,
                .where = span.Span.init(start, self.offset),
            },
            '>' => if (self.matchChar('=')) .{
                .tag = .greater_equal,
                .where = span.Span.init(start, self.offset),
            } else .{
                .tag = .greater,
                .where = span.Span.init(start, self.offset),
            },
            '&' => if (self.matchChar('&')) .{
                .tag = .logical_and,
                .where = span.Span.init(start, self.offset),
            } else Error.UnexpectedCharacter,
            '|' => if (self.matchChar('|')) .{
                .tag = .logical_or,
                .where = span.Span.init(start, self.offset),
            } else Error.UnexpectedCharacter,
            else => Error.UnexpectedCharacter,
        };
    }

    fn lexIdentifier(self: *Lexer) !token.Token {
        const start = self.offset;
        self.offset += 1;
        while (self.peek()) |ch| {
            if (!isIdentContinue(ch)) break;
            self.offset += 1;
        }

        const text = self.source[start..self.offset];
        if (std.mem.eql(u8, text, "true")) {
            return .{ .tag = .bool_true, .where = span.Span.init(start, self.offset) };
        }
        if (std.mem.eql(u8, text, "false")) {
            return .{ .tag = .bool_false, .where = span.Span.init(start, self.offset) };
        }
        if (std.mem.eql(u8, text, "null")) {
            return .{ .tag = .null_lit, .where = span.Span.init(start, self.offset) };
        }
        if (std.mem.eql(u8, text, "in")) {
            return .{ .tag = .in_kw, .where = span.Span.init(start, self.offset) };
        }

        const id = try self.strings.intern(self.allocator, text);
        return .{
            .tag = .identifier,
            .where = span.Span.init(start, self.offset),
            .data = .{ .string_id = id },
        };
    }

    fn lexNumber(self: *Lexer) !token.Token {
        const start = self.offset;

        if (self.peek() == '.') {
            self.offset += 1;
            try self.consumeDigits();
            try self.consumeExponentIfPresent();
            const text = self.source[start..self.offset];
            return .{
                .tag = .float_lit,
                .where = span.Span.init(start, self.offset),
                .data = .{ .float_value = try std.fmt.parseFloat(f64, text) },
            };
        }

        try self.consumeDigits();

        if (self.peek() == 'x' or self.peek() == 'X') {
            if (self.offset != start + 1 or self.source[start] != '0') {
                return Error.InvalidNumber;
            }
            self.offset += 1;
            const hex_start = self.offset;
            while (self.peek()) |ch| {
                if (!isHexDigit(ch)) break;
                self.offset += 1;
            }
            if (hex_start == self.offset) {
                return Error.InvalidNumber;
            }
            const digits = self.source[hex_start..self.offset];
            if (self.peek() == 'u' or self.peek() == 'U') {
                self.offset += 1;
                return .{
                    .tag = .uint_lit,
                    .where = span.Span.init(start, self.offset),
                    .data = .{ .uint_value = try std.fmt.parseInt(u64, digits, 16) },
                };
            }

            const parsed = try std.fmt.parseInt(u64, digits, 16);
            if (parsed > std.math.maxInt(i64)) {
                return .{
                    .tag = .int_lit,
                    .where = span.Span.init(start, self.offset),
                    .data = .{ .uint_value = parsed },
                };
            }
            return .{
                .tag = .int_lit,
                .where = span.Span.init(start, self.offset),
                .data = .{ .int_value = @intCast(parsed) },
            };
        }

        const dot_index = self.offset;
        const has_fraction = self.peek() == '.' and blk: {
            const next = self.peekAt(1) orelse break :blk false;
            break :blk isDigit(next);
        };
        if (has_fraction) {
            self.offset += 1;
            try self.consumeDigits();
            try self.consumeExponentIfPresent();
            const text = self.source[start..self.offset];
            return .{
                .tag = .float_lit,
                .where = span.Span.init(start, self.offset),
                .data = .{ .float_value = try std.fmt.parseFloat(f64, text) },
            };
        }
        _ = dot_index;

        if (self.peek() == 'e' or self.peek() == 'E') {
            try self.consumeExponentIfPresent();
            const text = self.source[start..self.offset];
            return .{
                .tag = .float_lit,
                .where = span.Span.init(start, self.offset),
                .data = .{ .float_value = try std.fmt.parseFloat(f64, text) },
            };
        }

        const digits = self.source[start..self.offset];
        if (self.peek() == 'u' or self.peek() == 'U') {
            self.offset += 1;
            return .{
                .tag = .uint_lit,
                .where = span.Span.init(start, self.offset),
                .data = .{ .uint_value = try std.fmt.parseInt(u64, digits, 10) },
            };
        }

        const parsed = try std.fmt.parseInt(u64, digits, 10);
        if (parsed > std.math.maxInt(i64)) {
            return .{
                .tag = .int_lit,
                .where = span.Span.init(start, self.offset),
                .data = .{ .uint_value = parsed },
            };
        }
        return .{
            .tag = .int_lit,
            .where = span.Span.init(start, self.offset),
            .data = .{ .int_value = @intCast(parsed) },
        };
    }

    fn lexStringLike(self: *Lexer, comptime is_bytes: bool) !token.Token {
        const start = self.offset;

        if (is_bytes) {
            self.offset += 1;
        }

        var raw = false;
        if (self.peek() == 'r' or self.peek() == 'R') {
            raw = true;
            self.offset += 1;
        }

        const quote = self.peek() orelse return Error.UnterminatedString;
        if (quote != '"' and quote != '\'') {
            return Error.UnexpectedCharacter;
        }

        const triple = self.peekAt(1) == quote and self.peekAt(2) == quote;
        self.offset += if (triple) 3 else 1;

        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        defer buffer.deinit(self.allocator);

        while (true) {
            const ch = self.peek() orelse return Error.UnterminatedString;

            if (triple) {
                if (ch == quote and self.peekAt(1) == quote and self.peekAt(2) == quote) {
                    self.offset += 3;
                    break;
                }
            } else {
                if (ch == quote) {
                    self.offset += 1;
                    break;
                }
                if (ch == '\n' or ch == '\r') {
                    return Error.UnterminatedString;
                }
            }

            if (!raw and ch == '\\') {
                self.offset += 1;
                try self.decodeEscape(is_bytes, &buffer);
                continue;
            }

            try buffer.append(self.allocator, ch);
            self.offset += 1;
        }

        if (!is_bytes and !std.unicode.utf8ValidateSlice(buffer.items)) {
            return Error.InvalidUtf8InString;
        }

        const id = try self.strings.intern(self.allocator, buffer.items);
        return .{
            .tag = if (is_bytes) .bytes_lit else .string_lit,
            .where = span.Span.init(start, self.offset),
            .data = .{ .string_id = id },
        };
    }

    fn lexQuotedIdentifier(self: *Lexer) !token.Token {
        const start = self.offset;
        self.offset += 1;
        const content_start = self.offset;
        while (self.peek()) |ch| {
            if (ch == '`') {
                const id = try self.strings.intern(self.allocator, self.source[content_start..self.offset]);
                self.offset += 1;
                return .{
                    .tag = .identifier,
                    .where = span.Span.init(start, self.offset),
                    .data = .{ .string_id = id },
                };
            }
            self.offset += 1;
        }
        return Error.UnterminatedString;
    }

    fn decodeEscape(self: *Lexer, comptime is_bytes: bool, buffer: *std.ArrayListUnmanaged(u8)) !void {
        const ch = self.peek() orelse return Error.UnterminatedString;
        self.offset += 1;

        switch (ch) {
            'a' => try buffer.append(self.allocator, 0x07),
            'b' => try buffer.append(self.allocator, 0x08),
            'f' => try buffer.append(self.allocator, 0x0c),
            'n' => try buffer.append(self.allocator, '\n'),
            'r' => try buffer.append(self.allocator, '\r'),
            't' => try buffer.append(self.allocator, '\t'),
            'v' => try buffer.append(self.allocator, 0x0b),
            '\\' => try buffer.append(self.allocator, '\\'),
            '?' => try buffer.append(self.allocator, '?'),
            '"' => try buffer.append(self.allocator, '"'),
            '\'' => try buffer.append(self.allocator, '\''),
            '`' => try buffer.append(self.allocator, '`'),
            'x', 'X' => {
                const value = try self.parseFixedHex(2);
                if (is_bytes)
                    try buffer.append(self.allocator, @intCast(value))
                else
                    try appendCodepoint(self.allocator, buffer, value);
            },
            'u' => {
                const value = try self.parseFixedHex(4);
                try appendCodepoint(self.allocator, buffer, value);
            },
            'U' => {
                const value = try self.parseFixedHex(8);
                try appendCodepoint(self.allocator, buffer, value);
            },
            '0'...'3' => {
                const d0: u32 = ch - '0';
                const d1 = try self.consumeOctalDigit();
                const d2 = try self.consumeOctalDigit();
                const value: u32 = (d0 * 64) + (d1 * 8) + d2;
                if (is_bytes)
                    try buffer.append(self.allocator, @intCast(value))
                else
                    try appendCodepoint(self.allocator, buffer, value);
            },
            else => return Error.InvalidEscape,
        }
    }

    fn parseFixedHex(self: *Lexer, comptime count: usize) !u32 {
        if (self.remaining() < count) {
            return Error.InvalidUnicodeEscape;
        }

        var value: u32 = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const ch = self.peek() orelse return Error.InvalidUnicodeEscape;
            const nibble = hexValue(ch) orelse return Error.InvalidUnicodeEscape;
            value = (value << 4) | nibble;
            self.offset += 1;
        }
        return value;
    }

    fn consumeOctalDigit(self: *Lexer) !u32 {
        const ch = self.peek() orelse return Error.InvalidEscape;
        if (ch < '0' or ch > '7') {
            return Error.InvalidEscape;
        }
        self.offset += 1;
        return ch - '0';
    }

    fn consumeExponentIfPresent(self: *Lexer) !void {
        if (!(self.peek() == 'e' or self.peek() == 'E')) {
            return;
        }
        self.offset += 1;
        if (self.peek() == '+' or self.peek() == '-') {
            self.offset += 1;
        }
        const start = self.offset;
        try self.consumeDigits();
        if (start == self.offset) {
            return Error.InvalidNumber;
        }
    }

    fn consumeDigits(self: *Lexer) !void {
        const start = self.offset;
        while (self.peek()) |ch| {
            if (!isDigit(ch)) break;
            self.offset += 1;
        }
        if (start == self.offset) {
            return Error.InvalidNumber;
        }
    }

    fn skipIgnored(self: *Lexer) !void {
        while (self.peek()) |ch| {
            switch (ch) {
                ' ', '\t', '\n', '\r', '\x0c' => self.offset += 1,
                '/' => {
                    if (self.peekAt(1) == '/') {
                        self.offset += 2;
                        while (self.peek()) |comment_ch| {
                            if (comment_ch == '\n') break;
                            self.offset += 1;
                        }
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn isRawStringPrefix(self: *const Lexer) bool {
        const ch = self.peek() orelse return false;
        if (ch != 'r' and ch != 'R') return false;
        const next = self.peekAt(1) orelse return false;
        return next == '"' or next == '\'';
    }

    fn isBytesPrefix(self: *const Lexer) bool {
        const ch = self.peek() orelse return false;
        if (ch != 'b' and ch != 'B') return false;

        const next = self.peekAt(1) orelse return false;
        if (next == '"' or next == '\'') return true;
        if (next != 'r' and next != 'R') return false;

        const third = self.peekAt(2) orelse return false;
        return third == '"' or third == '\'';
    }

    fn remaining(self: *const Lexer) usize {
        return self.source.len - self.offset;
    }

    fn peek(self: *const Lexer) ?u8 {
        return self.peekAt(0);
    }

    fn peekAt(self: *const Lexer, delta: usize) ?u8 {
        const idx = self.offset + delta;
        if (idx >= self.source.len) return null;
        return self.source[idx];
    }

    fn matchChar(self: *Lexer, expected: u8) bool {
        if (self.peek() != expected) return false;
        self.offset += 1;
        return true;
    }
};

fn appendCodepoint(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayListUnmanaged(u8),
    value: u32,
) !void {
    if (value > std.math.maxInt(u21)) {
        return Error.InvalidUnicodeEscape;
    }
    const codepoint: u21 = @intCast(value);
    if (!std.unicode.utf8ValidCodepoint(codepoint)) {
        return Error.InvalidUnicodeEscape;
    }
    var encoded: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &encoded) catch return Error.InvalidUnicodeEscape;
    try buffer.appendSlice(allocator, encoded[0..len]);
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn isHexDigit(ch: u8) bool {
    return hexValue(ch) != null;
}

fn hexValue(ch: u8) ?u32 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => (ch - 'a') + 10,
        'A'...'F' => (ch - 'A') + 10,
        else => null,
    };
}

fn isIdentStart(ch: u8) bool {
    return ch == '_' or (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
}

fn isIdentContinue(ch: u8) bool {
    return isIdentStart(ch) or isDigit(ch);
}

test "lex operators and punctuation" {
    var table = strings.StringTable{};
    defer table.deinit(std.testing.allocator);

    var toks = try tokenize(std.testing.allocator, "&& || == != <= >= < > + - * / % ! ? : , . () [] {}", &table);
    defer toks.deinit(std.testing.allocator);

    const expected = [_]token.Tag{
        .logical_and, .logical_or, .equal_equal, .bang_equal, .less_equal,
        .greater_equal, .less, .greater, .plus, .minus, .star, .slash,
        .percent, .bang, .question, .colon, .comma, .dot, .l_paren,
        .r_paren, .l_bracket, .r_bracket, .l_brace, .r_brace, .eof,
    };
    try std.testing.expectEqual(expected.len, toks.items.len);
    for (expected, toks.items) |want, got| {
        try std.testing.expectEqual(want, got.tag);
    }
}

test "lex identifiers keywords and reserved words" {
    var table = strings.StringTable{};
    defer table.deinit(std.testing.allocator);

    var toks = try tokenize(std.testing.allocator, "foo in true false null package", &table);
    defer toks.deinit(std.testing.allocator);

    try std.testing.expectEqual(token.Tag.identifier, toks.items[0].tag);
    try std.testing.expectEqual(token.Tag.in_kw, toks.items[1].tag);
    try std.testing.expectEqual(token.Tag.bool_true, toks.items[2].tag);
    try std.testing.expectEqual(token.Tag.bool_false, toks.items[3].tag);
    try std.testing.expectEqual(token.Tag.null_lit, toks.items[4].tag);
    try std.testing.expectEqual(token.Tag.identifier, toks.items[5].tag);
    try std.testing.expect(token.isReservedWord(table.get(toks.items[5].data.string_id)));
}

test "lex numeric literals" {
    var table = strings.StringTable{};
    defer table.deinit(std.testing.allocator);

    var toks = try tokenize(std.testing.allocator, "123 456u 0x10 0x20u 1.5 .25 1e3", &table);
    defer toks.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 123), toks.items[0].data.int_value);
    try std.testing.expectEqual(@as(u64, 456), toks.items[1].data.uint_value);
    try std.testing.expectEqual(@as(i64, 16), toks.items[2].data.int_value);
    try std.testing.expectEqual(@as(u64, 32), toks.items[3].data.uint_value);
    try std.testing.expectEqual(@as(f64, 1.5), toks.items[4].data.float_value);
    try std.testing.expectEqual(@as(f64, 0.25), toks.items[5].data.float_value);
    try std.testing.expectEqual(@as(f64, 1000.0), toks.items[6].data.float_value);
}

test "lex string and bytes literals" {
    var table = strings.StringTable{};
    defer table.deinit(std.testing.allocator);

    var toks = try tokenize(
        std.testing.allocator,
        "'hello' r\"a\\nb\" b'\\x41' br'\\x41' \"🤪\"",
        &table,
    );
    defer toks.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hello", table.get(toks.items[0].data.string_id));
    try std.testing.expectEqualStrings("a\\nb", table.get(toks.items[1].data.string_id));
    try std.testing.expectEqualStrings("A", table.get(toks.items[2].data.string_id));
    try std.testing.expectEqualStrings("\\x41", table.get(toks.items[3].data.string_id));
    try std.testing.expectEqualStrings("🤪", table.get(toks.items[4].data.string_id));
}

test "lex comments and bytes raw prefix" {
    var table = strings.StringTable{};
    defer table.deinit(std.testing.allocator);

    var toks = try tokenize(std.testing.allocator, "a // ignored\n br\"x\"", &table);
    defer toks.deinit(std.testing.allocator);

    try std.testing.expectEqual(token.Tag.identifier, toks.items[0].tag);
    try std.testing.expectEqual(token.Tag.bytes_lit, toks.items[1].tag);
    try std.testing.expectEqualStrings("x", table.get(toks.items[1].data.string_id));
}

test "lex empty and whitespace-only input yields only eof" {
    const cases = [_][]const u8{
        "",
        "   \t\n\r  ",
        "// this is a comment",
        "   // comment with leading whitespace",
    };
    for (cases) |input| {
        var table = strings.StringTable{};
        defer table.deinit(std.testing.allocator);
        var toks = try tokenize(std.testing.allocator, input, &table);
        defer toks.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), toks.items.len);
        try std.testing.expectEqual(token.Tag.eof, toks.items[0].tag);
    }
}

test "lex single character tokens individually" {
    const cases = .{
        .{ "(", token.Tag.l_paren },
        .{ ")", token.Tag.r_paren },
        .{ "[", token.Tag.l_bracket },
        .{ "]", token.Tag.r_bracket },
        .{ "{", token.Tag.l_brace },
        .{ "}", token.Tag.r_brace },
        .{ ",", token.Tag.comma },
        .{ ".", token.Tag.dot },
        .{ "?", token.Tag.question },
        .{ ":", token.Tag.colon },
        .{ "+", token.Tag.plus },
        .{ "-", token.Tag.minus },
        .{ "*", token.Tag.star },
        .{ "%", token.Tag.percent },
        .{ "!", token.Tag.bang },
        .{ "<", token.Tag.less },
        .{ ">", token.Tag.greater },
    };
    inline for (cases) |case| {
        var table = strings.StringTable{};
        defer table.deinit(std.testing.allocator);
        var toks = try tokenize(std.testing.allocator, case[0], &table);
        defer toks.deinit(std.testing.allocator);
        try std.testing.expectEqual(case[1], toks.items[0].tag);
        try std.testing.expectEqual(token.Tag.eof, toks.items[1].tag);
    }
}

test "lex multi-character operators individually" {
    const cases = .{
        .{ "<=", token.Tag.less_equal },
        .{ ">=", token.Tag.greater_equal },
        .{ "==", token.Tag.equal_equal },
        .{ "!=", token.Tag.bang_equal },
        .{ "&&", token.Tag.logical_and },
        .{ "||", token.Tag.logical_or },
    };
    inline for (cases) |case| {
        var table = strings.StringTable{};
        defer table.deinit(std.testing.allocator);
        var toks = try tokenize(std.testing.allocator, case[0], &table);
        defer toks.deinit(std.testing.allocator);
        try std.testing.expectEqual(case[1], toks.items[0].tag);
        try std.testing.expectEqual(token.Tag.eof, toks.items[1].tag);
    }
}

test "lex string and bytes escape sequences and variants" {
    const Case = struct { input: []const u8, expected_tag: token.Tag, expected_value: []const u8 };
    const cases = [_]Case{
        // escape sequences
        .{ .input = "\"\\n\\t\\\\\\\"\"", .expected_tag = .string_lit, .expected_value = "\n\t\\\"" },
        .{ .input = "'\\'hello\\''", .expected_tag = .string_lit, .expected_value = "'hello'" },
        .{ .input = "\"\\x41\\x42\"", .expected_tag = .string_lit, .expected_value = "AB" },
        .{ .input = "\"\\u0041\\U00000042\"", .expected_tag = .string_lit, .expected_value = "AB" },
        .{ .input = "'\\101'", .expected_tag = .string_lit, .expected_value = "A" },
        // raw strings
        .{ .input = "r\"hello\\nworld\"", .expected_tag = .string_lit, .expected_value = "hello\\nworld" },
        .{ .input = "r'raw\\ttext'", .expected_tag = .string_lit, .expected_value = "raw\\ttext" },
        // bytes literals
        .{ .input = "b\"hello\"", .expected_tag = .bytes_lit, .expected_value = "hello" },
        .{ .input = "b'data'", .expected_tag = .bytes_lit, .expected_value = "data" },
        .{ .input = "br'\\x41'", .expected_tag = .bytes_lit, .expected_value = "\\x41" },
        // empty string
        .{ .input = "\"\"", .expected_tag = .string_lit, .expected_value = "" },
        // triple-quoted strings
        .{ .input = "'''hello\nworld'''", .expected_tag = .string_lit, .expected_value = "hello\nworld" },
        .{ .input = "\"\"\"multi\nline\"\"\"", .expected_tag = .string_lit, .expected_value = "multi\nline" },
    };
    for (cases) |case| {
        var table = strings.StringTable{};
        defer table.deinit(std.testing.allocator);
        var toks = try tokenize(std.testing.allocator, case.input, &table);
        defer toks.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected_tag, toks.items[0].tag);
        try std.testing.expectEqualStrings(case.expected_value, table.get(toks.items[0].data.string_id));
    }
}

test "lex integer literals individually" {
    const IntCase = struct { input: []const u8, tag: token.Tag, int_value: ?i64 = null, uint_value: ?u64 = null };
    const cases = [_]IntCase{
        .{ .input = "0", .tag = .int_lit, .int_value = 0 },
        .{ .input = "42", .tag = .int_lit, .int_value = 42 },
        .{ .input = "123", .tag = .int_lit, .int_value = 123 },
        .{ .input = "9223372036854775807", .tag = .int_lit, .int_value = std.math.maxInt(i64) },
        .{ .input = "9223372036854775808", .tag = .int_lit, .uint_value = @as(u64, std.math.maxInt(i64)) + 1 },
        .{ .input = "0x10", .tag = .int_lit, .int_value = 16 },
        .{ .input = "42u", .tag = .uint_lit, .uint_value = 42 },
        .{ .input = "42U", .tag = .uint_lit, .uint_value = 42 },
        .{ .input = "0u", .tag = .uint_lit, .uint_value = 0 },
        .{ .input = "0xFFu", .tag = .uint_lit, .uint_value = 255 },
        .{ .input = "0x20u", .tag = .uint_lit, .uint_value = 32 },
    };
    for (cases) |case| {
        var table = strings.StringTable{};
        defer table.deinit(std.testing.allocator);
        var toks = try tokenize(std.testing.allocator, case.input, &table);
        defer toks.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.tag, toks.items[0].tag);
        if (case.int_value) |iv| {
            try std.testing.expectEqual(iv, toks.items[0].data.int_value);
        }
        if (case.uint_value) |uv| {
            try std.testing.expectEqual(uv, toks.items[0].data.uint_value);
        }
    }
}

test "lex float literals individually" {
    const FloatCase = struct { input: []const u8, expected: f64 };
    const cases = [_]FloatCase{
        .{ .input = "1.5", .expected = 1.5 },
        .{ .input = "0.0", .expected = 0.0 },
        .{ .input = "3.14", .expected = 3.14 },
        .{ .input = ".5", .expected = 0.5 },
        .{ .input = ".123", .expected = 0.123 },
        .{ .input = ".0", .expected = 0.0 },
        .{ .input = "1e10", .expected = 1e10 },
        .{ .input = "2E3", .expected = 2e3 },
        .{ .input = "1.5e2", .expected = 1.5e2 },
        .{ .input = "3.0e-1", .expected = 3.0e-1 },
        .{ .input = "5e+2", .expected = 5e+2 },
    };
    for (cases) |case| {
        var table = strings.StringTable{};
        defer table.deinit(std.testing.allocator);
        var toks = try tokenize(std.testing.allocator, case.input, &table);
        defer toks.deinit(std.testing.allocator);
        try std.testing.expectEqual(token.Tag.float_lit, toks.items[0].tag);
        try std.testing.expectEqual(case.expected, toks.items[0].data.float_value);
    }
}

test "lex error cases" {
    const cases = [_]struct { input: []const u8, expected_error: Error }{
        .{ .input = "'hello", .expected_error = Error.UnterminatedString },
        .{ .input = "\"hello", .expected_error = Error.UnterminatedString },
        .{ .input = "'hello\nworld'", .expected_error = Error.UnterminatedString },
        .{ .input = "`unterminated", .expected_error = Error.UnterminatedString },
        .{ .input = "'\\q'", .expected_error = Error.InvalidEscape },
        .{ .input = "'\\uD800'", .expected_error = Error.InvalidUnicodeEscape },
        .{ .input = "'\\uDFFF'", .expected_error = Error.InvalidUnicodeEscape },
        .{ .input = "1e", .expected_error = Error.InvalidNumber },
        .{ .input = "0x", .expected_error = Error.InvalidNumber },
        .{ .input = "&", .expected_error = Error.UnexpectedCharacter },
        .{ .input = "|", .expected_error = Error.UnexpectedCharacter },
        .{ .input = "=", .expected_error = Error.UnexpectedCharacter },
        .{ .input = "~", .expected_error = Error.UnexpectedCharacter },
    };
    for (cases) |case| {
        var table = strings.StringTable{};
        defer table.deinit(std.testing.allocator);
        try std.testing.expectError(case.expected_error, tokenize(std.testing.allocator, case.input, &table));
    }
}

test "lex reserved words as identifiers" {
    var table = strings.StringTable{};
    defer table.deinit(std.testing.allocator);

    var toks = try tokenize(std.testing.allocator, "package namespace void", &table);
    defer toks.deinit(std.testing.allocator);

    try std.testing.expectEqual(token.Tag.identifier, toks.items[0].tag);
    try std.testing.expect(token.isReservedWord(table.get(toks.items[0].data.string_id)));
    try std.testing.expectEqual(token.Tag.identifier, toks.items[1].tag);
    try std.testing.expectEqual(token.Tag.identifier, toks.items[2].tag);
}

test "lex consecutive tokens without whitespace" {
    var table = strings.StringTable{};
    defer table.deinit(std.testing.allocator);

    var toks = try tokenize(std.testing.allocator, "1+2*3", &table);
    defer toks.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 6), toks.items.len);
    try std.testing.expectEqual(token.Tag.int_lit, toks.items[0].tag);
    try std.testing.expectEqual(token.Tag.plus, toks.items[1].tag);
    try std.testing.expectEqual(token.Tag.int_lit, toks.items[2].tag);
    try std.testing.expectEqual(token.Tag.star, toks.items[3].tag);
    try std.testing.expectEqual(token.Tag.int_lit, toks.items[4].tag);
    try std.testing.expectEqual(token.Tag.eof, toks.items[5].tag);
}

test "lex identifier-like tokens adjacent to parens" {
    var table = strings.StringTable{};
    defer table.deinit(std.testing.allocator);

    var toks = try tokenize(std.testing.allocator, "f(x)", &table);
    defer toks.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), toks.items.len);
    try std.testing.expectEqual(token.Tag.identifier, toks.items[0].tag);
    try std.testing.expectEqual(token.Tag.l_paren, toks.items[1].tag);
    try std.testing.expectEqual(token.Tag.identifier, toks.items[2].tag);
    try std.testing.expectEqual(token.Tag.r_paren, toks.items[3].tag);
}

test "lex backtick quoted identifier" {
    var table = strings.StringTable{};
    defer table.deinit(std.testing.allocator);

    var toks = try tokenize(std.testing.allocator, "`my field`", &table);
    defer toks.deinit(std.testing.allocator);

    try std.testing.expectEqual(token.Tag.identifier, toks.items[0].tag);
    try std.testing.expectEqualStrings("my field", table.get(toks.items[0].data.string_id));
}

test "lex slash not followed by slash is division" {
    var table = strings.StringTable{};
    defer table.deinit(std.testing.allocator);

    var toks = try tokenize(std.testing.allocator, "a / b", &table);
    defer toks.deinit(std.testing.allocator);

    try std.testing.expectEqual(token.Tag.identifier, toks.items[0].tag);
    try std.testing.expectEqual(token.Tag.slash, toks.items[1].tag);
    try std.testing.expectEqual(token.Tag.identifier, toks.items[2].tag);
}

test "lex span positions are correct" {
    var table = strings.StringTable{};
    defer table.deinit(std.testing.allocator);

    var toks = try tokenize(std.testing.allocator, "ab + cd", &table);
    defer toks.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), toks.items[0].where.start);
    try std.testing.expectEqual(@as(u32, 2), toks.items[0].where.end);
    try std.testing.expectEqual(@as(u32, 3), toks.items[1].where.start);
    try std.testing.expectEqual(@as(u32, 4), toks.items[1].where.end);
    try std.testing.expectEqual(@as(u32, 5), toks.items[2].where.start);
    try std.testing.expectEqual(@as(u32, 7), toks.items[2].where.end);
}

// Empty string, unicode surrogates, and bytes raw prefix are all tested
// in the consolidated "lex string and bytes escape sequences and variants" and
// "lex error cases" tests above.
