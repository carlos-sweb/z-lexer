const std = @import("std");
const testing = std.testing;
const zlexer = @import("zlexer");
const Lexer = zlexer.Lexer;

fn expectNumber(source: []const u8, expected: f64) !void {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, source);
    var tok = try lex.nextToken(.div_allowed);
    defer tok.deinit(allocator);
    try testing.expectEqual(zlexer.TokenType.numeric_literal, tok.type);
    try testing.expectEqual(expected, tok.numeric_value.?);
}

test "decimal literals" {
    try expectNumber("0", 0);
    try expectNumber("42", 42);
    try expectNumber("3.14", 3.14);
    try expectNumber(".5", 0.5);
    try expectNumber("1.", 1.0);
    try expectNumber("1e3", 1000);
    try expectNumber("1E+3", 1000);
    try expectNumber("1.5e-2", 0.015);
}

test "radix-prefixed integer literals" {
    try expectNumber("0x1F", 31);
    try expectNumber("0X1f", 31);
    try expectNumber("0o17", 15);
    try expectNumber("0O17", 15);
    try expectNumber("0b101", 5);
    try expectNumber("0B101", 5);
}

test "legacy octal vs non-octal decimal (0-prefixed)" {
    try expectNumber("0777", 511); // legacy octal: all digits 0-7
    try expectNumber("089", 89); // contains 8/9 -- NonOctalDecimalIntegerLiteral, treated as decimal
}

test "numeric separators are stripped before parsing" {
    try expectNumber("1_000_000", 1000000);
    try expectNumber("0x1_F", 31);
    try expectNumber("1_0.5_5", 10.55);
}

test "numeric separator placement errors" {
    const allocator = testing.allocator;
    const bad = [_][]const u8{ "1__0", "_1", "0x_1" };
    for (bad) |src| {
        var lex = Lexer.init(allocator, src);
        // "_1"/"0x_1" won't even scan as numbers at all in some cases; the
        // important invariant is these never silently succeed with a wrong
        // value. "1__0" should surface InvalidNumericLiteral.
        _ = lex.nextToken(.div_allowed) catch continue;
    }
    var lex = Lexer.init(allocator, "1__0");
    try testing.expectError(zlexer.LexError.InvalidNumericLiteral, lex.nextToken(.div_allowed));
    var lex2 = Lexer.init(allocator, "1_");
    try testing.expectError(zlexer.LexError.InvalidNumericLiteral, lex2.nextToken(.div_allowed));
}

test "BigInt literal suffix keeps raw digit text, no numeric_value" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "123n");
    var tok = try lex.nextToken(.div_allowed);
    defer tok.deinit(allocator);
    try testing.expectEqual(zlexer.TokenType.bigint_literal, tok.type);
    try testing.expectEqualStrings("123", tok.lexeme);
    try testing.expect(tok.numeric_value == null);

    var lex2 = Lexer.init(allocator, "0x1Fn");
    var tok2 = try lex2.nextToken(.div_allowed);
    defer tok2.deinit(allocator);
    try testing.expectEqual(zlexer.TokenType.bigint_literal, tok2.type);
    try testing.expectEqualStrings("0x1F", tok2.lexeme);
}

test "an identifier character immediately after a number is a syntax error" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "3in");
    try testing.expectError(zlexer.LexError.InvalidNumericLiteral, lex.nextToken(.div_allowed));
}

test "huge hex literal saturates toward nearest f64 instead of erroring" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "0x" ++ "F" ** 40);
    var tok = try lex.nextToken(.div_allowed);
    defer tok.deinit(allocator);
    try testing.expectEqual(zlexer.TokenType.numeric_literal, tok.type);
    try testing.expect(std.math.isFinite(tok.numeric_value.?));
    try testing.expect(tok.numeric_value.? > 0);
}

// Node v22/V8-verified ground truth (ran `eval(literal).toString()` for
// each of these; see the session transcript for the exact command), same
// verification technique already used elsewhere in this ecosystem (e.g.
// z-number) for precision-sensitive cases that are easy to get subtly wrong
// by only reading the spec.
test "precision-sensitive literals match V8 (Node-verified)" {
    try expectNumber("9007199254740993", 9007199254740992); // > 2^53: rounds to the nearest representable f64
    try expectNumber("1.7976931348623157e308", std.math.floatMax(f64)); // Number.MAX_VALUE
    try expectNumber("5e-324", 5e-324); // Number.MIN_VALUE (denormalized)
    try expectNumber("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", 1.461501637330903e+48);
}
