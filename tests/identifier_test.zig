const std = @import("std");
const testing = std.testing;
const zlexer = @import("zlexer");
const Lexer = zlexer.Lexer;

test "plain ASCII identifier" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "myVar");
    var tok = try lex.nextToken(.div_allowed);
    defer tok.deinit(allocator);
    try testing.expectEqual(zlexer.TokenType.identifier, tok.type);
    try testing.expectEqualStrings("myVar", tok.lexeme);
    try testing.expect(tok.owned_value == null);
}

test "identifier with $ and _ and digits" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "$_foo123");
    var tok = try lex.nextToken(.div_allowed);
    defer tok.deinit(allocator);
    try testing.expectEqual(zlexer.TokenType.identifier, tok.type);
    try testing.expectEqualStrings("$_foo123", tok.lexeme);
}

test "unicode identifier (non-ASCII letters)" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "café");
    var tok = try lex.nextToken(.div_allowed);
    defer tok.deinit(allocator);
    try testing.expectEqual(zlexer.TokenType.identifier, tok.type);
    try testing.expectEqualStrings("café", tok.lexeme);
}

test "digit cannot start an identifier" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "1abc");
    // "1abc" lexes as a numeric literal, then errors because an
    // IdentifierStart may not immediately follow a NumericLiteral.
    try testing.expectError(zlexer.LexError.InvalidNumericLiteral, lex.nextToken(.div_allowed));
}

test "identifier with \\u escape decodes and is not treated as a keyword" {
    const allocator = testing.allocator;
    // if decodes to "if" -- but since it's spelled with an escape, it
    // must NOT be recognized as the `if` keyword (ECMA-262 12.7.2).
    var lex = Lexer.init(allocator, "\\u0069f");
    var tok = try lex.nextToken(.div_allowed);
    defer tok.deinit(allocator);
    try testing.expectEqual(zlexer.TokenType.identifier, tok.type);
    try testing.expect(tok.owned_value != null);
    try testing.expectEqualStrings("if", tok.owned_value.?);
}

test "identifier with \\u{...} escape (astral-safe form)" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "a\\u{62}c");
    var tok = try lex.nextToken(.div_allowed);
    defer tok.deinit(allocator);
    try testing.expectEqual(zlexer.TokenType.identifier, tok.type);
    try testing.expectEqualStrings("abc", tok.owned_value.?);
}

test "reserved keywords tokenize to their own TokenType" {
    const allocator = testing.allocator;
    const cases = .{
        .{ "function", zlexer.TokenType.keyword_function },
        .{ "return", zlexer.TokenType.keyword_return },
        .{ "null", zlexer.TokenType.keyword_null },
        .{ "true", zlexer.TokenType.keyword_true },
        .{ "false", zlexer.TokenType.keyword_false },
        .{ "instanceof", zlexer.TokenType.keyword_instanceof },
    };
    inline for (cases) |case| {
        var lex = Lexer.init(allocator, case[0]);
        var tok = try lex.nextToken(.div_allowed);
        defer tok.deinit(allocator);
        try testing.expectEqual(case[1], tok.type);
    }
}

test "contextual keywords tokenize as plain identifiers" {
    const allocator = testing.allocator;
    const cases = [_][]const u8{ "let", "static", "async", "await", "yield_not_kw", "of", "get", "set" };
    for (cases) |src| {
        var lex = Lexer.init(allocator, src);
        var tok = try lex.nextToken(.div_allowed);
        defer tok.deinit(allocator);
        try testing.expectEqual(zlexer.TokenType.identifier, tok.type);
    }
    // "yield" itself IS an unconditional ReservedWord per Table 34.
    var lex = Lexer.init(allocator, "yield");
    var tok = try lex.nextToken(.div_allowed);
    defer tok.deinit(allocator);
    try testing.expectEqual(zlexer.TokenType.keyword_yield, tok.type);
}

test "private identifier (#foo)" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "#foo");
    var tok = try lex.nextToken(.div_allowed);
    defer tok.deinit(allocator);
    try testing.expectEqual(zlexer.TokenType.private_identifier, tok.type);
    try testing.expectEqualStrings("#foo", tok.lexeme);
}

test "hashbang comment at the very start of the source is skipped" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "#!/usr/bin/env node\nfoo");
    var tok = try lex.nextToken(.div_allowed);
    defer tok.deinit(allocator);
    try testing.expectEqual(zlexer.TokenType.identifier, tok.type);
    try testing.expectEqualStrings("foo", tok.lexeme);
}
