const std = @import("std");

pub const TokenType = enum {
    eof,

    identifier,
    private_identifier, // #foo

    numeric_literal,
    bigint_literal,
    string_literal,
    /// `plain text, no substitutions`
    template_no_substitution,
    /// `` `head${ ``
    template_head,
    /// `}middle${`
    template_middle,
    /// `` }tail` ``
    template_tail,
    regex_literal,

    keyword_null,
    keyword_true,
    keyword_false,

    keyword_break,
    keyword_case,
    keyword_catch,
    keyword_class,
    keyword_const,
    keyword_continue,
    keyword_debugger,
    keyword_default,
    keyword_delete,
    keyword_do,
    keyword_else,
    keyword_export,
    keyword_extends,
    keyword_finally,
    keyword_for,
    keyword_function,
    keyword_if,
    keyword_import,
    keyword_in,
    keyword_instanceof,
    keyword_new,
    keyword_return,
    keyword_super,
    keyword_switch,
    keyword_this,
    keyword_throw,
    keyword_try,
    keyword_typeof,
    keyword_var,
    keyword_void,
    keyword_while,
    keyword_with,
    keyword_yield,

    // Punctuators (ECMA-262 12.8).
    punct_lbrace,
    punct_rbrace,
    punct_lparen,
    punct_rparen,
    punct_lbracket,
    punct_rbracket,
    punct_dot,
    punct_ellipsis, // ...
    punct_semi,
    punct_comma,
    punct_lt,
    punct_gt,
    punct_le,
    punct_ge,
    punct_eq, // ==
    punct_ne, // !=
    punct_eqeqeq, // ===
    punct_noteqeq, // !==
    punct_plus,
    punct_minus,
    punct_star,
    punct_percent,
    punct_starstar, // **
    punct_plusplus,
    punct_minusminus,
    punct_shl, // <<
    punct_shr, // >>
    punct_ushr, // >>>
    punct_amp,
    punct_pipe,
    punct_caret,
    punct_bang,
    punct_tilde,
    punct_ampamp, // &&
    punct_pipepipe, // ||
    punct_question_question, // ??
    punct_question,
    punct_colon,
    punct_question_dot, // ?.
    punct_assign, // =
    punct_plus_assign,
    punct_minus_assign,
    punct_star_assign,
    punct_percent_assign,
    punct_starstar_assign,
    punct_shl_assign,
    punct_shr_assign,
    punct_ushr_assign,
    punct_amp_assign,
    punct_pipe_assign,
    punct_caret_assign,
    punct_ampamp_assign, // &&=
    punct_pipepipe_assign, // ||=
    punct_question_question_assign, // ??=
    punct_arrow, // =>
    punct_slash,
    punct_slash_assign,
};

const keyword_map = std.StaticStringMap(TokenType).initComptime(.{
    .{ "break", .keyword_break },
    .{ "case", .keyword_case },
    .{ "catch", .keyword_catch },
    .{ "class", .keyword_class },
    .{ "const", .keyword_const },
    .{ "continue", .keyword_continue },
    .{ "debugger", .keyword_debugger },
    .{ "default", .keyword_default },
    .{ "delete", .keyword_delete },
    .{ "do", .keyword_do },
    .{ "else", .keyword_else },
    .{ "export", .keyword_export },
    .{ "extends", .keyword_extends },
    .{ "false", .keyword_false },
    .{ "finally", .keyword_finally },
    .{ "for", .keyword_for },
    .{ "function", .keyword_function },
    .{ "if", .keyword_if },
    .{ "import", .keyword_import },
    .{ "in", .keyword_in },
    .{ "instanceof", .keyword_instanceof },
    .{ "new", .keyword_new },
    .{ "null", .keyword_null },
    .{ "return", .keyword_return },
    .{ "super", .keyword_super },
    .{ "switch", .keyword_switch },
    .{ "this", .keyword_this },
    .{ "throw", .keyword_throw },
    .{ "true", .keyword_true },
    .{ "try", .keyword_try },
    .{ "typeof", .keyword_typeof },
    .{ "var", .keyword_var },
    .{ "void", .keyword_void },
    .{ "while", .keyword_while },
    .{ "with", .keyword_with },
    .{ "yield", .keyword_yield },
});

/// Only the ECMA-262 Table 34 unconditionally-reserved words map to their own
/// TokenType. Contextual keywords (`let`, `static`, `async`, `await`, `of`,
/// `get`, `set`, and strict-mode-only future-reserved words like
/// `implements`/`interface`/`package`/`private`/`protected`/`public`) are
/// deliberately left as plain `.identifier` tokens: their reserved status
/// depends on strict-mode / grammar position, which is the parser's job
/// (not yet built), not the lexer's -- ECMA-262's own ReservedWord
/// production is purely lexical and doesn't include them either.
pub fn keywordFromLexeme(lexeme: []const u8) ?TokenType {
    return keyword_map.get(lexeme);
}

pub const Token = struct {
    type: TokenType,
    /// Slice into the original source for most tokens (zero-copy). Only
    /// meaningful as raw text for punctuators/keywords/identifiers without
    /// escapes/numbers; string/template contents with escapes use
    /// `owned_value` instead since decoding requires materializing new bytes.
    lexeme: []const u8,
    /// Set only for string/template literals containing an escape sequence,
    /// or identifiers containing a `\u` escape. Caller frees.
    owned_value: ?[]u8 = null,
    /// Set only for `.numeric_literal` (never for `.bigint_literal`, which
    /// keeps its raw digit text in `lexeme`/`owned_value` since a BigInt's
    /// value isn't representable as f64 -- there's no BigInt runtime type in
    /// this ecosystem yet).
    numeric_value: ?f64 = null,
    /// Present only for `.regex_literal`: the flags text after the closing
    /// `/`, e.g. "gi". `lexeme` for a regex_literal covers just the pattern
    /// body (between the slashes), not the flags.
    regex_flags: ?[]const u8 = null,
    start: usize,
    end: usize,
    line: u32,
    column: u32,
    /// True if a LineTerminator occurred between the previous token and this
    /// one -- needed by the future parser's Automatic Semicolon Insertion.
    had_line_terminator_before: bool,

    pub fn deinit(self: *Token, allocator: std.mem.Allocator) void {
        if (self.owned_value) |v| allocator.free(v);
    }
};
