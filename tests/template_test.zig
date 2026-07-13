const std = @import("std");
const testing = std.testing;
const zlexer = @import("zlexer");
const Lexer = zlexer.Lexer;
const TT = zlexer.TokenType;

/// Minimal stand-in for what a future Parser will do: track `${`/`}` brace
/// depth so nested braces inside a substitution expression (e.g. an object
/// literal) aren't mistaken for the template's own closing delimiter. This
/// is the exact cooperation model LexContext/continueTemplate() were
/// designed for -- see lexer.zig's doc comments.
const TemplateDriver = struct {
    lex: *Lexer,
    depth_stack: std.ArrayList(u32),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, lex: *Lexer) TemplateDriver {
        return .{ .lex = lex, .depth_stack = .empty, .allocator = allocator };
    }
    fn deinit(self: *TemplateDriver) void {
        self.depth_stack.deinit(self.allocator);
    }

    fn next(self: *TemplateDriver) !zlexer.Token {
        if (self.depth_stack.items.len == 0) {
            // Not inside any substitution: lex normally. A template_head
            // here opens one (depth starts at 0 -- no unmatched '{' yet).
            const tok = try self.lex.nextToken(.regex_allowed);
            if (tok.type == .template_head) try self.depth_stack.append(self.allocator, 0);
            return tok;
        }

        // Inside a substitution: lex normally and track brace depth so a
        // nested object literal's braces aren't mistaken for the
        // template's own closing delimiter.
        var tok = try self.lex.nextToken(.regex_allowed);
        const top = &self.depth_stack.items[self.depth_stack.items.len - 1];
        if (tok.type == .punct_lbrace) {
            top.* += 1;
            return tok;
        }
        if (tok.type == .punct_rbrace) {
            if (top.* > 0) {
                top.* -= 1;
                return tok;
            }
            // depth == 0: this '}' is actually the template's own
            // continuation, not an ordinary punctuator -- rewind to its
            // start and re-lex as a template part instead.
            self.lex.pos = tok.start;
            self.lex.line = tok.line;
            self.lex.column = tok.column;
            tok.deinit(self.allocator);
            const cont = try self.lex.continueTemplate();
            if (cont.type == .template_tail) _ = self.depth_stack.pop();
            return cont;
        }
        if (tok.type == .template_head) try self.depth_stack.append(self.allocator, 0);
        return tok;
    }
};

fn content(tok: zlexer.Token) []const u8 {
    return tok.owned_value orelse blk: {
        // Strip the leading '`'/'}' delimiter and trailing '`' or the "${" it ends with.
        var s = tok.lexeme;
        s = s[1..];
        if (tok.type == .template_head or tok.type == .template_middle) {
            s = s[0 .. s.len - 2];
        } else {
            s = s[0 .. s.len - 1];
        }
        break :blk s;
    };
}

test "template with no substitution is a single token" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "`plain text`");
    var tok = try lex.nextToken(.regex_allowed);
    defer tok.deinit(allocator);
    try testing.expectEqual(TT.template_no_substitution, tok.type);
    try testing.expectEqualStrings("plain text", content(tok));
}

test "template with one substitution: head, expr tokens, tail" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "`a${1+2}b`");
    var driver = TemplateDriver.init(allocator, &lex);
    defer driver.deinit();

    var head = try driver.next();
    defer head.deinit(allocator);
    try testing.expectEqual(TT.template_head, head.type);
    try testing.expectEqualStrings("a", content(head));

    var n1 = try driver.next();
    defer n1.deinit(allocator);
    try testing.expectEqual(TT.numeric_literal, n1.type);
    try testing.expectEqual(@as(f64, 1), n1.numeric_value.?);

    var plus = try driver.next();
    defer plus.deinit(allocator);
    try testing.expectEqual(TT.punct_plus, plus.type);

    var n2 = try driver.next();
    defer n2.deinit(allocator);
    try testing.expectEqual(TT.numeric_literal, n2.type);
    try testing.expectEqual(@as(f64, 2), n2.numeric_value.?);

    var tail = try driver.next();
    defer tail.deinit(allocator);
    try testing.expectEqual(TT.template_tail, tail.type);
    try testing.expectEqualStrings("b", content(tail));
}

test "nested braces from an object literal inside a substitution don't confuse the driver" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "`x${ {a:1} }y`");
    var driver = TemplateDriver.init(allocator, &lex);
    defer driver.deinit();

    const expected = [_]TT{ .template_head, .punct_lbrace, .identifier, .punct_colon, .numeric_literal, .punct_rbrace, .template_tail };
    for (expected) |exp| {
        var tok = try driver.next();
        defer tok.deinit(allocator);
        try testing.expectEqual(exp, tok.type);
    }
}

test "multiple substitutions: head, middle, tail" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "`${1}-${2}`");
    var driver = TemplateDriver.init(allocator, &lex);
    defer driver.deinit();

    const expected = [_]TT{ .template_head, .numeric_literal, .template_middle, .numeric_literal, .template_tail };
    for (expected) |exp| {
        var tok = try driver.next();
        defer tok.deinit(allocator);
        try testing.expectEqual(exp, tok.type);
    }
}

test "nested template inside a substitution" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "`outer${`inner`}end`");
    var driver = TemplateDriver.init(allocator, &lex);
    defer driver.deinit();

    var outer_head = try driver.next();
    defer outer_head.deinit(allocator);
    try testing.expectEqual(TT.template_head, outer_head.type);
    try testing.expectEqualStrings("outer", content(outer_head));

    var inner = try driver.next();
    defer inner.deinit(allocator);
    try testing.expectEqual(TT.template_no_substitution, inner.type);
    try testing.expectEqualStrings("inner", content(inner));

    var outer_tail = try driver.next();
    defer outer_tail.deinit(allocator);
    try testing.expectEqual(TT.template_tail, outer_tail.type);
    try testing.expectEqualStrings("end", content(outer_tail));
}

test "template with an escape sequence materializes owned_value" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "`a\\nb`");
    var tok = try lex.nextToken(.regex_allowed);
    defer tok.deinit(allocator);
    try testing.expectEqual(TT.template_no_substitution, tok.type);
    try testing.expectEqualStrings("a\nb", tok.owned_value.?);
}

test "unterminated template errors" {
    const allocator = testing.allocator;
    var lex = Lexer.init(allocator, "`abc");
    try testing.expectError(zlexer.LexError.UnterminatedTemplate, lex.nextToken(.regex_allowed));
}
