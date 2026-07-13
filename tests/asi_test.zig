const std = @import("std");
const testing = std.testing;
const zlexer = @import("zlexer");
const Lexer = zlexer.Lexer;

test "had_line_terminator_before is false on the same line" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "a b");
    var a = try lex.nextToken(.div_allowed);
    defer a.deinit(allocator);
    var b = try lex.nextToken(.div_allowed);
    defer b.deinit(allocator);
    try testing.expect(!b.had_line_terminator_before);
}

test "had_line_terminator_before is true across a newline" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "a\nb");
    var a = try lex.nextToken(.div_allowed);
    defer a.deinit(allocator);
    var b = try lex.nextToken(.div_allowed);
    defer b.deinit(allocator);
    try testing.expect(b.had_line_terminator_before);
}

test "had_line_terminator_before is true even through a single-line comment" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "a // comment\nb");
    var a = try lex.nextToken(.div_allowed);
    defer a.deinit(allocator);
    var b = try lex.nextToken(.div_allowed);
    defer b.deinit(allocator);
    try testing.expect(b.had_line_terminator_before);
}

test "a multi-line block comment counts as having a LineTerminator" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "a /* line1\nline2 */ b");
    var a = try lex.nextToken(.div_allowed);
    defer a.deinit(allocator);
    var b = try lex.nextToken(.div_allowed);
    defer b.deinit(allocator);
    try testing.expect(b.had_line_terminator_before);
}

test "a single-line block comment does not count as a LineTerminator" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "a /* comment */ b");
    var a = try lex.nextToken(.div_allowed);
    defer a.deinit(allocator);
    var b = try lex.nextToken(.div_allowed);
    defer b.deinit(allocator);
    try testing.expect(!b.had_line_terminator_before);
}

test "line/column tracking across multiple lines" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "a\nbb\nccc");
    var a = try lex.nextToken(.div_allowed);
    defer a.deinit(allocator);
    try testing.expectEqual(@as(u32, 1), a.line);
    try testing.expectEqual(@as(u32, 1), a.column);

    var b = try lex.nextToken(.div_allowed);
    defer b.deinit(allocator);
    try testing.expectEqual(@as(u32, 2), b.line);
    try testing.expectEqual(@as(u32, 1), b.column);

    var c = try lex.nextToken(.div_allowed);
    defer c.deinit(allocator);
    try testing.expectEqual(@as(u32, 3), c.line);
    try testing.expectEqual(@as(u32, 1), c.column);
}

test "unterminated block comment errors" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "a /* never closed");
    var a = try lex.nextToken(.div_allowed);
    defer a.deinit(allocator);
    try testing.expectError(zlexer.LexError.UnterminatedComment, lex.nextToken(.div_allowed));
}
