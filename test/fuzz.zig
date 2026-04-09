const std = @import("std");
const cel = @import("cel");
const appendFormat = cel.util.fmt.appendFormat;
const checker = cel.checker.check;
const env = cel.env.env;
const eval = cel.eval.eval;
const lexer = cel.parse.lexer;
const parser = cel.parse.parser;
const strings = cel.parse.string_table;
const value = cel.env.value;

test "deterministic lexer fuzz smoke does not crash" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const random = prng.random();

    var source = std.ArrayListUnmanaged(u8).empty;
    defer source.deinit(std.testing.allocator);

    var table = strings.StringTable{};
    defer table.deinit(std.testing.allocator);

    for (0..1000) |_| {
        source.clearRetainingCapacity();
        const len = random.intRangeAtMost(usize, 0, 64);
        try source.ensureTotalCapacity(std.testing.allocator, len);
        for (0..len) |_| {
            source.appendAssumeCapacity(random.int(u8));
        }

        var toks = lexer.tokenize(std.testing.allocator, source.items, &table) catch continue;
        toks.deinit(std.testing.allocator);
    }
}

test "deterministic parser fuzz smoke does not crash" {
    var prng = std.Random.DefaultPrng.init(0xBAD5EED);
    const random = prng.random();

    var source = std.ArrayListUnmanaged(u8).empty;
    defer source.deinit(std.testing.allocator);

    for (0..1000) |_| {
        source.clearRetainingCapacity();
        const len = random.intRangeAtMost(usize, 0, 96);
        try source.ensureTotalCapacity(std.testing.allocator, len);
        for (0..len) |_| {
            const next = switch (random.uintLessThan(u8, 8)) {
                0 => random.intRangeAtMost(u8, 'a', 'z'),
                1 => random.intRangeAtMost(u8, '0', '9'),
                2 => "[]{}().,:?+-*/%!<>='\""[random.uintLessThan(usize, 18)],
                3 => ' ',
                4 => '\n',
                5 => '\t',
                else => random.int(u8),
            };
            source.appendAssumeCapacity(next);
        }

        var tree = parser.parse(std.testing.allocator, source.items) catch continue;
        tree.deinit();
    }
}

test "generated expression fuzz is evaluation-stable" {
    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    var activation = eval.Activation.init(std.testing.allocator);
    defer activation.deinit();

    var prng = std.Random.DefaultPrng.init(0x1234ABCD);
    const random = prng.random();

    var expr = std.ArrayListUnmanaged(u8).empty;
    defer expr.deinit(std.testing.allocator);

    for (0..300) |_| {
        expr.clearRetainingCapacity();
        try writeRandomExpr(std.testing.allocator, random, &expr, 0);

        var program = checker.compileUnchecked(std.testing.allocator, &environment, expr.items) catch continue;
        defer program.deinit();

        const first = eval.eval(std.testing.allocator, &program, &activation);
        const second = eval.eval(std.testing.allocator, &program, &activation);

        if (first) |first_value| {
            defer {
                var temp = first_value;
                temp.deinit(std.testing.allocator);
            }
            var second_value = try second;
            defer second_value.deinit(std.testing.allocator);
            try std.testing.expect(first_value.eql(second_value));
        } else |first_err| {
            try std.testing.expectError(first_err, second);
        }
    }
}

test "malformed inputs report stable parser and checker errors" {
    const parse_cases = [_]struct {
        source: []const u8,
        want: anyerror,
    }{
        .{ .source = "1 +", .want = parser.Error.ExpectedExpression },
        .{ .source = "a ? : b", .want = parser.Error.ExpectedExpression },
        .{ .source = "{foo: }", .want = parser.Error.ExpectedExpression },
        .{ .source = "[1, 2", .want = parser.Error.UnexpectedEof },
    };

    for (parse_cases) |case| {
        try expectParseError(case.want, case.source);
    }

    var environment = try env.Env.initDefault(std.testing.allocator);
    defer environment.deinit();

    const check_cases = [_]struct {
        source: []const u8,
        want: anyerror,
    }{
        .{ .source = "missing_name", .want = checker.Error.UndefinedIdentifier },
        .{ .source = "has(1)", .want = checker.Error.InvalidMacro },
        .{ .source = "{[1]: 2}", .want = checker.Error.InvalidMapKeyType },
        .{ .source = "1.all(x, x > 0)", .want = checker.Error.InvalidMacro },
    };

    for (check_cases) |case| {
        try expectCompileError(case.want, &environment, case.source);
    }
}

fn writeRandomExpr(
    allocator: std.mem.Allocator,
    random: std.Random,
    buffer: *std.ArrayListUnmanaged(u8),
    depth: usize,
) !void {
    if (depth >= 3) {
        try writeAtom(allocator, random, buffer);
        return;
    }

    switch (random.uintLessThan(u8, 7)) {
        0 => try writeAtom(allocator, random, buffer),
        1 => {
            try buffer.append(allocator, '(');
            try buffer.appendSlice(allocator, if (random.boolean()) "!" else "-");
            try writeRandomExpr(allocator, random, buffer, depth + 1);
            try buffer.append(allocator, ')');
        },
        2 => {
            try buffer.append(allocator, '(');
            try writeRandomExpr(allocator, random, buffer, depth + 1);
            try buffer.appendSlice(allocator, switch (random.uintLessThan(u8, 8)) {
                0 => " + ",
                1 => " - ",
                2 => " * ",
                3 => " == ",
                4 => " != ",
                5 => " < ",
                6 => " && ",
                else => " || ",
            });
            try writeRandomExpr(allocator, random, buffer, depth + 1);
            try buffer.append(allocator, ')');
        },
        3 => {
            try buffer.append(allocator, '(');
            try writeRandomExpr(allocator, random, buffer, depth + 1);
            try buffer.appendSlice(allocator, " ? ");
            try writeRandomExpr(allocator, random, buffer, depth + 1);
            try buffer.appendSlice(allocator, " : ");
            try writeRandomExpr(allocator, random, buffer, depth + 1);
            try buffer.append(allocator, ')');
        },
        4 => {
            try buffer.append(allocator, '[');
            const count = random.intRangeAtMost(u8, 0, 3);
            for (0..count) |i| {
                if (i != 0) try buffer.appendSlice(allocator, ", ");
                try writeRandomExpr(allocator, random, buffer, depth + 1);
            }
            try buffer.append(allocator, ']');
        },
        5 => {
            try buffer.append(allocator, '{');
            const count = random.intRangeAtMost(u8, 0, 2);
            for (0..count) |i| {
                if (i != 0) try buffer.appendSlice(allocator, ", ");
                try appendFormat(buffer, allocator,"'k{d}': ", .{i});
                try writeRandomExpr(allocator, random, buffer, depth + 1);
            }
            try buffer.append(allocator, '}');
        },
        else => {
            try buffer.appendSlice(allocator, "size(");
            try buffer.append(allocator, '[');
            const count = random.intRangeAtMost(u8, 0, 3);
            for (0..count) |i| {
                if (i != 0) try buffer.appendSlice(allocator, ", ");
                try appendFormat(buffer, allocator,"{d}", .{random.intRangeAtMost(i64, -3, 9)});
            }
            try buffer.appendSlice(allocator, "])");
        },
    }
}

fn writeAtom(
    allocator: std.mem.Allocator,
    random: std.Random,
    buffer: *std.ArrayListUnmanaged(u8),
) !void {
    switch (random.uintLessThan(u8, 5)) {
        0 => try appendFormat(buffer, allocator,"{d}", .{random.intRangeAtMost(i64, -10, 10)}),
        1 => try buffer.appendSlice(allocator, if (random.boolean()) "true" else "false"),
        2 => {
            try buffer.append(allocator, '\'');
            try buffer.append(allocator, "abcxyz"[random.uintLessThan(usize, 6)]);
            try buffer.append(allocator, '\'');
        },
        3 => try buffer.appendSlice(allocator, "null"),
        else => try buffer.appendSlice(allocator, if (random.boolean()) "1u" else "2.5"),
    }
}

// ---------------------------------------------------------------------------
// Coverage-guided fuzz targets (zig test -ffuzz)
// ---------------------------------------------------------------------------

// Coverage-guided fuzz targets. These use std.testing.fuzz which:
// - Without -ffuzz: runs once with first corpus entry as a smoke test
// - With -ffuzz: runs the coverage-guided fuzzer for real
//
// To fuzz: zig test src/eval.zig -lc -ffuzz --test-filter "fuzz lexer"

test "fuzz lexer" {
    try std.testing.fuzz({}, fuzzLexer, .{
        .corpus = &.{ "1 + 2", "'hello'", "true && false" },
    });
}

fn fuzzLexer(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buf: [512]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0);
    const alloc = std.heap.page_allocator;
    var st = strings.StringTable{};
    var tokens = lexer.tokenize(alloc, buf[0..len], &st) catch return;
    tokens.deinit(alloc);
    st.deinit(alloc);
}

test "fuzz parser" {
    try std.testing.fuzz({}, fuzzParser, .{
        .corpus = &.{ "1 + 2", "[1, 2]", "{'a': 1}", "f(x)" },
    });
}

fn fuzzParser(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buf: [512]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0);
    const alloc = std.heap.page_allocator;
    var tree = parser.parse(alloc, buf[0..len]) catch return;
    tree.deinit();
}

test "fuzz compile and eval" {
    try std.testing.fuzz({}, fuzzCompileEval, .{
        .corpus = &.{ "1 + 2", "true", "'a' + 'b'", "[1,2].size()" },
    });
}

fn fuzzCompileEval(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buf: [256]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0);
    const alloc = std.heap.page_allocator;
    var environment = env.Env.initDefault(alloc) catch return;
    defer environment.deinit();
    var program = checker.compile(alloc, &environment, buf[0..len]) catch return;
    defer program.deinit();
    var activation = eval.Activation.init(alloc);
    defer activation.deinit();
    var result = eval.eval(alloc, &program, &activation) catch return;
    result.deinit(alloc);
}

fn expectParseError(expected: anyerror, source: []const u8) !void {
    const parsed = parser.parse(std.testing.allocator, source) catch |err| {
        try std.testing.expectEqual(expected, err);
        return;
    };
    var tree = parsed;
    defer tree.deinit();
    return error.TestExpectedError;
}

fn expectCompileError(expected: anyerror, environment: *env.Env, source: []const u8) !void {
    const compiled = checker.compile(std.testing.allocator, environment, source) catch |err| {
        try std.testing.expectEqual(expected, err);
        return;
    };
    var program = compiled;
    defer program.deinit();
    return error.TestExpectedError;
}
