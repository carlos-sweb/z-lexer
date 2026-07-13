const std = @import("std");
const testing = std.testing;
const zlexer = @import("zlexer");
const Lexer = zlexer.Lexer;
const TT = zlexer.TokenType;

fn expectTokens(allocator: std.mem.Allocator, source: []const u8, expected: []const TT) !void {
    var lex = Lexer.init(allocator, source);
    for (expected) |exp| {
        var tok = try lex.nextToken(.div_allowed);
        defer tok.deinit(allocator);
        try testing.expectEqual(exp, tok.type);
    }
    var eof = try lex.nextToken(.div_allowed);
    defer eof.deinit(allocator);
    try testing.expectEqual(TT.eof, eof.type);
}

test "maximal munch: >>> before >> before > and their assign forms" {
    const allocator = testing.allocator;
    try expectTokens(allocator, ">>>=", &.{.punct_ushr_assign});
    try expectTokens(allocator, ">>>", &.{.punct_ushr});
    try expectTokens(allocator, ">>=", &.{.punct_shr_assign});
    try expectTokens(allocator, ">>", &.{.punct_shr});
    try expectTokens(allocator, ">=", &.{.punct_ge});
    try expectTokens(allocator, ">", &.{.punct_gt});
}

test "maximal munch: ** before * and their assign forms" {
    const allocator = testing.allocator;
    try expectTokens(allocator, "**=", &.{.punct_starstar_assign});
    try expectTokens(allocator, "**", &.{.punct_starstar});
    try expectTokens(allocator, "*=", &.{.punct_star_assign});
    try expectTokens(allocator, "*", &.{.punct_star});
}

test "logical/nullish assignment operators (nullish-coalescing, and, or)" {
    const allocator = testing.allocator;
    try expectTokens(allocator, "??=", &.{.punct_question_question_assign});
    try expectTokens(allocator, "??", &.{.punct_question_question});
    try expectTokens(allocator, "&&=", &.{.punct_ampamp_assign});
    try expectTokens(allocator, "&&", &.{.punct_ampamp});
    try expectTokens(allocator, "||=", &.{.punct_pipepipe_assign});
    try expectTokens(allocator, "||", &.{.punct_pipepipe});
}

test "optional chaining ?. vs ternary+number (a ?.5:1)" {
    const allocator = testing.allocator;
    try expectTokens(allocator, "a?.b", &.{ .identifier, .punct_question_dot, .identifier });
    // `?.5` must NOT be `?.` + `5` -- it's `?` followed by the number `.5`.
    try expectTokens(allocator, "a?.5:1", &.{ .identifier, .punct_question, .numeric_literal, .punct_colon, .numeric_literal });
}

test "arrow, spread/rest, and strict equality" {
    const allocator = testing.allocator;
    try expectTokens(allocator, "=>", &.{.punct_arrow});
    try expectTokens(allocator, "...", &.{.punct_ellipsis});
    try expectTokens(allocator, "===", &.{.punct_eqeqeq});
    try expectTokens(allocator, "!==", &.{.punct_noteqeq});
    try expectTokens(allocator, "==", &.{.punct_eq});
    try expectTokens(allocator, "!=", &.{.punct_ne});
}

test "division vs regex disambiguation is caller-driven via LexContext" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "/a/g");
    var as_regex = try lex.nextToken(.regex_allowed);
    defer as_regex.deinit(allocator);
    try testing.expectEqual(TT.regex_literal, as_regex.type);
    try testing.expectEqualStrings("a", as_regex.lexeme);
    try testing.expectEqualStrings("g", as_regex.regex_flags.?);

    var lex2 = Lexer.init(allocator, "/a/g");
    var as_div = try lex2.nextToken(.div_allowed);
    defer as_div.deinit(allocator);
    try testing.expectEqual(TT.punct_slash, as_div.type);
}

test "all bracket/brace/paren punctuators" {
    const allocator = testing.allocator;
    try expectTokens(allocator, "{}()[]", &.{ .punct_lbrace, .punct_rbrace, .punct_lparen, .punct_rparen, .punct_lbracket, .punct_rbracket });
}
