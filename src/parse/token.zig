const std = @import("std");
const span = @import("span.zig");
const strings = @import("string_table.zig");

pub const Tag = enum {
    eof,
    identifier,
    int_lit,
    uint_lit,
    float_lit,
    string_lit,
    bytes_lit,
    bool_true,
    bool_false,
    null_lit,
    in_kw,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
    comma,
    dot,
    question,
    colon,
    plus,
    minus,
    star,
    slash,
    percent,
    bang,
    logical_and,
    logical_or,
    equal_equal,
    bang_equal,
    less,
    less_equal,
    greater,
    greater_equal,
};

pub const Data = union(enum) {
    none,
    string_id: strings.StringTable.Id,
    int_value: i64,
    uint_value: u64,
    float_value: f64,
};

pub const Token = struct {
    tag: Tag,
    where: span.Span,
    data: Data = .none,
};

pub fn isReservedWord(text: []const u8) bool {
    return std.mem.eql(u8, text, "as") or
        std.mem.eql(u8, text, "break") or
        std.mem.eql(u8, text, "const") or
        std.mem.eql(u8, text, "continue") or
        std.mem.eql(u8, text, "else") or
        std.mem.eql(u8, text, "for") or
        std.mem.eql(u8, text, "function") or
        std.mem.eql(u8, text, "if") or
        std.mem.eql(u8, text, "import") or
        std.mem.eql(u8, text, "let") or
        std.mem.eql(u8, text, "loop") or
        std.mem.eql(u8, text, "package") or
        std.mem.eql(u8, text, "namespace") or
        std.mem.eql(u8, text, "return") or
        std.mem.eql(u8, text, "var") or
        std.mem.eql(u8, text, "void") or
        std.mem.eql(u8, text, "while");
}

pub fn tagName(tag: Tag) []const u8 {
    return switch (tag) {
        .eof => "eof",
        .identifier => "identifier",
        .int_lit => "int",
        .uint_lit => "uint",
        .float_lit => "double",
        .string_lit => "string",
        .bytes_lit => "bytes",
        .bool_true => "true",
        .bool_false => "false",
        .null_lit => "null",
        .in_kw => "in",
        .l_paren => "(",
        .r_paren => ")",
        .l_bracket => "[",
        .r_bracket => "]",
        .l_brace => "{",
        .r_brace => "}",
        .comma => ",",
        .dot => ".",
        .question => "?",
        .colon => ":",
        .plus => "+",
        .minus => "-",
        .star => "*",
        .slash => "/",
        .percent => "%",
        .bang => "!",
        .logical_and => "&&",
        .logical_or => "||",
        .equal_equal => "==",
        .bang_equal => "!=",
        .less => "<",
        .less_equal => "<=",
        .greater => ">",
        .greater_equal => ">=",
    };
}

test "tagName returns correct names for all tags" {
    try std.testing.expectEqualStrings("eof", tagName(.eof));
    try std.testing.expectEqualStrings("identifier", tagName(.identifier));
    try std.testing.expectEqualStrings("int", tagName(.int_lit));
    try std.testing.expectEqualStrings("uint", tagName(.uint_lit));
    try std.testing.expectEqualStrings("double", tagName(.float_lit));
    try std.testing.expectEqualStrings("string", tagName(.string_lit));
    try std.testing.expectEqualStrings("bytes", tagName(.bytes_lit));
    try std.testing.expectEqualStrings("true", tagName(.bool_true));
    try std.testing.expectEqualStrings("false", tagName(.bool_false));
    try std.testing.expectEqualStrings("null", tagName(.null_lit));
    try std.testing.expectEqualStrings("in", tagName(.in_kw));
    try std.testing.expectEqualStrings("(", tagName(.l_paren));
    try std.testing.expectEqualStrings(")", tagName(.r_paren));
    try std.testing.expectEqualStrings("[", tagName(.l_bracket));
    try std.testing.expectEqualStrings("]", tagName(.r_bracket));
    try std.testing.expectEqualStrings("{", tagName(.l_brace));
    try std.testing.expectEqualStrings("}", tagName(.r_brace));
    try std.testing.expectEqualStrings(",", tagName(.comma));
    try std.testing.expectEqualStrings(".", tagName(.dot));
    try std.testing.expectEqualStrings("?", tagName(.question));
    try std.testing.expectEqualStrings(":", tagName(.colon));
    try std.testing.expectEqualStrings("+", tagName(.plus));
    try std.testing.expectEqualStrings("-", tagName(.minus));
    try std.testing.expectEqualStrings("*", tagName(.star));
    try std.testing.expectEqualStrings("/", tagName(.slash));
    try std.testing.expectEqualStrings("%", tagName(.percent));
    try std.testing.expectEqualStrings("!", tagName(.bang));
    try std.testing.expectEqualStrings("&&", tagName(.logical_and));
    try std.testing.expectEqualStrings("||", tagName(.logical_or));
    try std.testing.expectEqualStrings("==", tagName(.equal_equal));
    try std.testing.expectEqualStrings("!=", tagName(.bang_equal));
    try std.testing.expectEqualStrings("<", tagName(.less));
    try std.testing.expectEqualStrings("<=", tagName(.less_equal));
    try std.testing.expectEqualStrings(">", tagName(.greater));
    try std.testing.expectEqualStrings(">=", tagName(.greater_equal));
}

test "isReservedWord identifies all reserved words" {
    const reserved = [_][]const u8{
        "as", "break", "const", "continue", "else", "for", "function",
        "if", "import", "let", "loop", "package", "namespace", "return",
        "var", "void", "while",
    };
    for (reserved) |word| {
        try std.testing.expect(isReservedWord(word));
    }
}

test "isReservedWord rejects non-reserved words" {
    try std.testing.expect(!isReservedWord("foo"));
    try std.testing.expect(!isReservedWord("bar"));
    try std.testing.expect(!isReservedWord("true"));
    try std.testing.expect(!isReservedWord("false"));
    try std.testing.expect(!isReservedWord("null"));
    try std.testing.expect(!isReservedWord("in"));
    try std.testing.expect(!isReservedWord(""));
    try std.testing.expect(!isReservedWord("IF"));
    try std.testing.expect(!isReservedWord("PACKAGE"));
}

test "token default data is none" {
    const tok = Token{
        .tag = .eof,
        .where = span.Span.init(0, 0),
    };
    try std.testing.expectEqual(Data.none, tok.data);
}

test "token data union access" {
    const tok_int = Token{
        .tag = .int_lit,
        .where = span.Span.init(0, 3),
        .data = .{ .int_value = 42 },
    };
    try std.testing.expectEqual(@as(i64, 42), tok_int.data.int_value);

    const tok_float = Token{
        .tag = .float_lit,
        .where = span.Span.init(0, 3),
        .data = .{ .float_value = 3.14 },
    };
    try std.testing.expectEqual(@as(f64, 3.14), tok_float.data.float_value);

    const tok_uint = Token{
        .tag = .uint_lit,
        .where = span.Span.init(0, 4),
        .data = .{ .uint_value = 100 },
    };
    try std.testing.expectEqual(@as(u64, 100), tok_uint.data.uint_value);
}
