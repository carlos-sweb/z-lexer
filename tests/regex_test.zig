const std = @import("std");
const testing = std.testing;
const zlexer = @import("zlexer");
const Lexer = zlexer.Lexer;

test "simple regex literal with flags" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "/abc/gi");
    var tok = try lex.nextToken(.regex_allowed);
    defer tok.deinit(allocator);
    try testing.expectEqual(zlexer.TokenType.regex_literal, tok.type);
    try testing.expectEqualStrings("abc", tok.lexeme);
    try testing.expectEqualStrings("gi", tok.regex_flags.?);
}

test "regex literal with no flags" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "/x+/");
    var tok = try lex.nextToken(.regex_allowed);
    defer tok.deinit(allocator);
    try testing.expectEqualStrings("x+", tok.lexeme);
    try testing.expectEqualStrings("", tok.regex_flags.?);
}

test "a slash inside a character class does not end the literal" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "/[a/b]/");
    var tok = try lex.nextToken(.regex_allowed);
    defer tok.deinit(allocator);
    try testing.expectEqualStrings("[a/b]", tok.lexeme);
}

test "an escaped slash does not end the literal" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "/a\\/b/");
    var tok = try lex.nextToken(.regex_allowed);
    defer tok.deinit(allocator);
    try testing.expectEqualStrings("a\\/b", tok.lexeme);
}

test "unterminated regex literal errors" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "/abc");
    try testing.expectError(zlexer.LexError.UnterminatedRegex, lex.nextToken(.regex_allowed));
}

test "a line terminator inside a regex literal is a syntax error" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "/abc\ndef/");
    try testing.expectError(zlexer.LexError.UnterminatedRegex, lex.nextToken(.regex_allowed));
}
