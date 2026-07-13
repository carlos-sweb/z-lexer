const std = @import("std");
const testing = std.testing;
const zlexer = @import("zlexer");
const Lexer = zlexer.Lexer;

fn expectString(source: []const u8, expected: []const u8) !void {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, source);
    var tok = try lex.nextToken(.div_allowed);
    defer tok.deinit(allocator);
    try testing.expectEqual(zlexer.TokenType.string_literal, tok.type);
    if (tok.owned_value) |v| {
        try testing.expectEqualStrings(expected, v);
    } else {
        try testing.expectEqualStrings(expected, tok.lexeme[1 .. tok.lexeme.len - 1]);
    }
}

test "plain strings, no escapes, single and double quotes" {
    try expectString("\"hello\"", "hello");
    try expectString("'hello'", "hello");
    try expectString("''", "");
}

test "common escape sequences" {
    try expectString("\"a\\nb\"", "a\nb");
    try expectString("\"a\\tb\"", "a\tb");
    try expectString("\"a\\\\b\"", "a\\b");
    try expectString("\"a\\\"b\"", "a\"b");
    try expectString("'a\\'b'", "a'b");
}

test "\\xXX and \\uXXXX escapes" {
    try expectString("\"\\x41\"", "A");
    try expectString("\"\\u0041\"", "A");
    try expectString("\"\\u{1F600}\"", "\u{1F600}");
}

test "surrogate pair \\u escapes combine into one astral codepoint" {
    try expectString("\"\\ud83d\\ude00\"", "\u{1F600}");
}

test "line continuation: backslash + LineTerminator produces nothing" {
    try expectString("\"a\\\nb\"", "ab");
}

test "legacy octal escape and NUL" {
    try expectString("\"\\0\"", "\x00");
    try expectString("\"\\101\"", "A"); // octal 101 == 65 == 'A'
}

test "unterminated string errors" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "\"abc");
    try testing.expectError(zlexer.LexError.UnterminatedString, lex.nextToken(.div_allowed));

    var lex2 = Lexer.init(allocator, "\"abc\ndef\"");
    try testing.expectError(zlexer.LexError.UnterminatedString, lex2.nextToken(.div_allowed));
}

test "string without escapes has no owned_value (zero-copy)" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "\"plain\"");
    var tok = try lex.nextToken(.div_allowed);
    defer tok.deinit(allocator);
    try testing.expect(tok.owned_value == null);
    try testing.expectEqualStrings("\"plain\"", tok.lexeme);
}
