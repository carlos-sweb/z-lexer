const std = @import("std");
const Allocator = std.mem.Allocator;
const zregexp = @import("zregexp");
const token_mod = @import("token.zig");

pub const Token = token_mod.Token;
pub const TokenType = token_mod.TokenType;

pub const LexError = error{
    UnterminatedString,
    UnterminatedTemplate,
    UnterminatedComment,
    UnterminatedRegex,
    InvalidEscapeSequence,
    InvalidNumericLiteral,
    InvalidUnicodeEscape,
    UnexpectedCharacter,
    OutOfMemory,
};

/// The classic lexer/parser cooperation point (ECMA-262 12.1's
/// InputElementRegExp vs InputElementDiv goal symbols): after `)` `]` an
/// identifier, a number, `this`/`super`, etc., '/' means division; at the
/// start of an expression, '/' starts a RegularExpressionLiteral. There is
/// no parser yet, so this is passed explicitly by the caller (a test
/// harness today; a future Parser repo will compute it from grammar
/// position).
pub const LexContext = enum { regex_allowed, div_allowed };

fn isLineTerminatorCp(cp: u21) bool {
    return cp == 0x0A or cp == 0x0D or cp == 0x2028 or cp == 0x2029;
}

fn isLineTerminatorByte(b: u8) bool {
    return b == '\n' or b == '\r';
}

fn isWhiteSpaceCp(cp: u21) bool {
    return switch (cp) {
        0x09, 0x0B, 0x0C, 0x20, 0xA0, 0xFEFF => true,
        else => cp >= 0x80 and zregexp.unicode.isInCategory(cp, .Zs),
    };
}

/// ECMA-262 12.7.1 ID_Start: Unicode Lu/Ll/Lt/Lm/Lo/Nl, plus '$'/'_'.
fn isIdStart(cp: u21) bool {
    if (cp == '$' or cp == '_') return true;
    if (cp < 0x80) return (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z');
    inline for (.{ .Lu, .Ll, .Lt, .Lm, .Lo, .Nl }) |cat| {
        if (zregexp.unicode.isInCategory(cp, cat)) return true;
    }
    return false;
}

/// ECMA-262 12.7.1 ID_Continue: ID_Start plus Unicode Mn/Mc/Nd/Pc, plus
/// ZWNJ (U+200C) / ZWJ (U+200D).
fn isIdContinue(cp: u21) bool {
    if (cp == 0x200C or cp == 0x200D) return true;
    if (isIdStart(cp)) return true;
    if (cp < 0x80) return cp >= '0' and cp <= '9';
    inline for (.{ .Mn, .Mc, .Nd, .Pc }) |cat| {
        if (zregexp.unicode.isInCategory(cp, cat)) return true;
    }
    return false;
}

fn isAsciiDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isHexDigit(c: u8) bool {
    return isAsciiDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
fn isOctalDigit(c: u8) bool {
    return c >= '0' and c <= '7';
}
fn isBinaryDigit(c: u8) bool {
    return c == '0' or c == '1';
}

fn appendCodepointUtf8(out: *std.ArrayList(u8), allocator: Allocator, cp: u21) LexError!void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch return LexError.InvalidUnicodeEscape;
    try out.appendSlice(allocator, buf[0..len]);
}

pub const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: u32,
    column: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator, source: []const u8) Lexer {
        var pos: usize = 0;
        // HashbangComment (12.5): "#!" as the very first two bytes consumes
        // the rest of the first line.
        if (source.len >= 2 and source[0] == '#' and source[1] == '!') {
            pos = 2;
            while (pos < source.len and !isLineTerminatorByte(source[pos])) : (pos += 1) {}
        }
        return .{ .source = source, .pos = pos, .line = 1, .column = 1, .allocator = allocator };
    }

    fn peekByteAt(self: *Lexer, offset: usize) ?u8 {
        const p = self.pos + offset;
        if (p >= self.source.len) return null;
        return self.source[p];
    }

    fn decodeAt(self: *Lexer, pos: usize) ?struct { cp: u21, len: u3 } {
        if (pos >= self.source.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(self.source[pos]) catch return null;
        if (pos + len > self.source.len) return null;
        const cp = std.unicode.utf8Decode(self.source[pos .. pos + len]) catch return null;
        return .{ .cp = cp, .len = len };
    }

    fn advanceBytes(self: *Lexer, n: usize) void {
        self.pos += n;
        self.column += @intCast(n);
    }

    /// Advances by exactly one source codepoint, updating line/column
    /// (CRLF counts as a single line terminator).
    fn advanceCodepoint(self: *Lexer) void {
        const d = self.decodeAt(self.pos) orelse {
            self.pos += 1;
            self.column += 1;
            return;
        };
        if (isLineTerminatorCp(d.cp)) {
            if (d.cp == '\r' and self.peekByteAt(d.len) == '\n') {
                self.pos += d.len + 1;
            } else {
                self.pos += d.len;
            }
            self.line += 1;
            self.column = 1;
        } else {
            self.pos += d.len;
            self.column += 1;
        }
    }

    /// Skips WhiteSpace, LineTerminatorSequence, and comments. Returns
    /// whether a LineTerminator was seen (a multi-line comment that spans a
    /// LineTerminator counts too, per 12.9.1's SyntaxError-avoidance rule
    /// for [no LineTerminator here] restrictions).
    fn skipWhitespaceAndComments(self: *Lexer) LexError!bool {
        var had_lt = false;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t' or c == 0x0B or c == 0x0C) {
                self.pos += 1;
                self.column += 1;
                continue;
            }
            if (c == '\n' or c == '\r') {
                had_lt = true;
                self.advanceCodepoint();
                continue;
            }
            if (c == '/' and self.peekByteAt(1) == '/') {
                self.advanceBytes(2);
                while (self.pos < self.source.len and !isLineTerminatorByte(self.source[self.pos])) {
                    self.advanceCodepoint();
                }
                continue;
            }
            if (c == '/' and self.peekByteAt(1) == '*') {
                self.advanceBytes(2);
                var closed = false;
                while (self.pos < self.source.len) {
                    if (self.source[self.pos] == '*' and self.peekByteAt(1) == '/') {
                        self.advanceBytes(2);
                        closed = true;
                        break;
                    }
                    if (isLineTerminatorByte(self.source[self.pos])) had_lt = true;
                    self.advanceCodepoint();
                }
                if (!closed) return LexError.UnterminatedComment;
                continue;
            }
            if (c >= 0x80) {
                const d = self.decodeAt(self.pos) orelse break;
                if (isLineTerminatorCp(d.cp)) {
                    had_lt = true;
                    self.advanceCodepoint();
                    continue;
                }
                if (isWhiteSpaceCp(d.cp)) {
                    self.advanceCodepoint();
                    continue;
                }
                break;
            }
            break;
        }
        return had_lt;
    }

    fn makeToken(self: *Lexer, ty: TokenType, start: usize, had_lt: bool, line: u32, column: u32) Token {
        return .{
            .type = ty,
            .lexeme = self.source[start..self.pos],
            .start = start,
            .end = self.pos,
            .line = line,
            .column = column,
            .had_line_terminator_before = had_lt,
        };
    }

    pub fn nextToken(self: *Lexer, ctx: LexContext) LexError!Token {
        const had_lt = try self.skipWhitespaceAndComments();
        const start = self.pos;
        const line = self.line;
        const column = self.column;

        if (self.pos >= self.source.len) {
            return self.makeToken(.eof, start, had_lt, line, column);
        }

        const c = self.source[self.pos];

        if (c == '"' or c == '\'') return self.lexString(had_lt, line, column);
        if (c == '`') return self.lexTemplatePart(true, had_lt, line, column);
        if (isAsciiDigit(c)) return self.lexNumber(had_lt, line, column);
        if (c == '.') {
            if (self.peekByteAt(1)) |n| {
                if (isAsciiDigit(n)) return self.lexNumber(had_lt, line, column);
            }
        }
        if (c == '/' and ctx == .regex_allowed) return self.lexRegex(had_lt, line, column);
        if (c == '#') return self.lexPrivateIdentifier(had_lt, line, column);
        if (c == '$' or c == '_' or c == '\\' or c >= 0x80 or std.ascii.isAlphabetic(c)) {
            return self.lexIdentifierOrKeyword(had_lt, line, column);
        }

        return self.lexPunctuator(had_lt, line, column);
    }

    // ===== Identifiers / keywords =====

    fn scanUnicodeEscapeValue(self: *Lexer) LexError!u21 {
        if (self.pos < self.source.len and self.source[self.pos] == '{') {
            self.advanceBytes(1);
            const digit_start = self.pos;
            while (self.pos < self.source.len and isHexDigit(self.source[self.pos])) self.advanceBytes(1);
            if (self.pos == digit_start or self.pos >= self.source.len or self.source[self.pos] != '}') {
                return LexError.InvalidUnicodeEscape;
            }
            const digits = self.source[digit_start..self.pos];
            self.advanceBytes(1); // '}'
            const value = std.fmt.parseInt(u32, digits, 16) catch return LexError.InvalidUnicodeEscape;
            if (value > 0x10FFFF) return LexError.InvalidUnicodeEscape;
            return @intCast(value);
        }
        if (self.pos + 4 > self.source.len) return LexError.InvalidUnicodeEscape;
        const digits = self.source[self.pos .. self.pos + 4];
        for (digits) |ch| {
            if (!isHexDigit(ch)) return LexError.InvalidUnicodeEscape;
        }
        const value = std.fmt.parseInt(u16, digits, 16) catch return LexError.InvalidUnicodeEscape;
        self.advanceBytes(4);
        return value;
    }

    /// Scans exactly one identifier character -- a literal codepoint or a
    /// `\uXXXX`/`\u{X...}` escape -- requiring ID_Start when `is_first`,
    /// ID_Continue otherwise. Returns true and advances past it if found;
    /// returns false (without advancing) if the next character just isn't
    /// part of an identifier at all.
    fn scanIdentifierPart(self: *Lexer, is_first: bool, saw_escape: *bool) LexError!bool {
        if (self.pos >= self.source.len) return false;
        if (self.source[self.pos] == '\\') {
            if (self.peekByteAt(1) != 'u') return false;
            self.advanceBytes(2);
            const cp = try self.scanUnicodeEscapeValue();
            const ok = if (is_first) isIdStart(cp) else isIdContinue(cp);
            if (!ok) return LexError.InvalidUnicodeEscape;
            saw_escape.* = true;
            return true;
        }
        const d = self.decodeAt(self.pos) orelse return false;
        const ok = if (is_first) isIdStart(d.cp) else isIdContinue(d.cp);
        if (!ok) return false;
        self.pos += d.len;
        self.column += 1;
        return true;
    }

    /// Re-decodes a byte range already validated by scanIdentifierPart()
    /// (only ever contains identifier-part codepoints and \u escapes) into
    /// an owned, escape-free UTF-8 buffer.
    fn decodeIdentifierEscapes(self: *Lexer, raw: []const u8) LexError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\') {
                var j = i + 2; // skip "\u"
                var cp: u21 = undefined;
                if (raw[j] == '{') {
                    const close = std.mem.indexOfScalarPos(u8, raw, j, '}').?;
                    cp = @intCast(std.fmt.parseInt(u32, raw[j + 1 .. close], 16) catch unreachable);
                    j = close + 1;
                } else {
                    cp = std.fmt.parseInt(u16, raw[j .. j + 4], 16) catch unreachable;
                    j += 4;
                }
                try appendCodepointUtf8(&out, self.allocator, cp);
                i = j;
            } else {
                const len = std.unicode.utf8ByteSequenceLength(raw[i]) catch return LexError.InvalidUnicodeEscape;
                try out.appendSlice(self.allocator, raw[i .. i + len]);
                i += len;
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn lexIdentifierOrKeyword(self: *Lexer, had_lt: bool, line: u32, column: u32) LexError!Token {
        const start = self.pos;
        var saw_escape = false;

        const first_ok = try self.scanIdentifierPart(true, &saw_escape);
        if (!first_ok) return LexError.UnexpectedCharacter;
        while (true) {
            const before = self.pos;
            const advanced = try self.scanIdentifierPart(false, &saw_escape);
            if (!advanced) {
                self.pos = before;
                break;
            }
        }

        const raw = self.source[start..self.pos];

        // A ReservedWord must be spelled literally -- an identifier written
        // with a \u escape (e.g. "if") is never treated as a keyword,
        // even if decoding it would produce the same characters.
        if (!saw_escape) {
            if (token_mod.keywordFromLexeme(raw)) |kw| {
                return self.makeToken(kw, start, had_lt, line, column);
            }
        }

        var tok = self.makeToken(.identifier, start, had_lt, line, column);
        if (saw_escape) tok.owned_value = try self.decodeIdentifierEscapes(raw);
        return tok;
    }

    fn lexPrivateIdentifier(self: *Lexer, had_lt: bool, line: u32, column: u32) LexError!Token {
        const start = self.pos;
        self.advanceBytes(1); // '#'
        var saw_escape = false;
        const ok = try self.scanIdentifierPart(true, &saw_escape);
        if (!ok) return LexError.UnexpectedCharacter;
        while (true) {
            const before = self.pos;
            const advanced = try self.scanIdentifierPart(false, &saw_escape);
            if (!advanced) {
                self.pos = before;
                break;
            }
        }
        var tok = self.makeToken(.private_identifier, start, had_lt, line, column);
        if (saw_escape) tok.owned_value = try self.decodeIdentifierEscapes(self.source[start + 1 .. self.pos]);
        return tok;
    }

    // ===== Numeric literals =====

    fn scanDigits(self: *Lexer, pred: *const fn (u8) bool) LexError!void {
        if (self.pos >= self.source.len or !pred(self.source[self.pos])) return LexError.InvalidNumericLiteral;
        var prev_was_digit = true;
        self.advanceBytes(1);
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (pred(c)) {
                prev_was_digit = true;
                self.advanceBytes(1);
            } else if (c == '_') {
                if (!prev_was_digit) return LexError.InvalidNumericLiteral;
                prev_was_digit = false;
                self.advanceBytes(1);
            } else break;
        }
        if (!prev_was_digit) return LexError.InvalidNumericLiteral;
    }

    fn scanDigitsAllowEmpty(self: *Lexer, pred: *const fn (u8) bool) LexError!void {
        if (self.pos < self.source.len and pred(self.source[self.pos])) {
            try self.scanDigits(pred);
        }
    }

    fn computeNumericValue(self: *Lexer, raw_in: []const u8, radix: u8, is_legacy_octal: bool) LexError!f64 {
        var text = raw_in;
        // Keep the *original, untruncated* allocation around for freeing --
        // `text` gets narrowed to `buf[0..w]` below, and Allocator.free()
        // requires the exact slice it handed out, not a sub-slice of it.
        var stripped: ?[]u8 = null;
        defer if (stripped) |s| self.allocator.free(s);
        if (std.mem.indexOfScalar(u8, text, '_') != null) {
            const buf = self.allocator.alloc(u8, text.len) catch return LexError.OutOfMemory;
            stripped = buf;
            var w: usize = 0;
            for (text) |c| {
                if (c != '_') {
                    buf[w] = c;
                    w += 1;
                }
            }
            text = buf[0..w];
        }

        if (radix == 10) {
            return std.fmt.parseFloat(f64, text) catch LexError.InvalidNumericLiteral;
        }

        // Non-decimal integer (hex/octal/binary/legacy-octal): accumulate
        // digit-by-digit as a float, mirroring ECMA-262's own MV() algorithm
        // for these forms -- naturally saturates toward the nearest
        // representable f64 for arbitrarily long digit runs, instead of
        // erroring on overflow the way a fixed-width integer parse would.
        const digits = if (is_legacy_octal) text[1..] else text[2..];
        var value: f64 = 0;
        for (digits) |c| {
            const digit = std.fmt.charToDigit(c, radix) catch return LexError.InvalidNumericLiteral;
            value = value * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(digit));
        }
        return value;
    }

    fn lexNumber(self: *Lexer, had_lt: bool, line: u32, column: u32) LexError!Token {
        const start = self.pos;
        var radix: u8 = 10;
        var is_legacy_octal = false;
        var is_non_octal_decimal = false;
        var has_dot_or_exp = false;

        if (self.source[self.pos] == '.') {
            self.advanceBytes(1);
            try self.scanDigits(isAsciiDigit);
            has_dot_or_exp = true;
        } else if (self.source[self.pos] == '0' and self.peekByteAt(1) != null and
            (self.peekByteAt(1).? == 'x' or self.peekByteAt(1).? == 'X' or
                self.peekByteAt(1).? == 'o' or self.peekByteAt(1).? == 'O' or
                self.peekByteAt(1).? == 'b' or self.peekByteAt(1).? == 'B'))
        {
            const n = self.peekByteAt(1).?;
            self.advanceBytes(2);
            radix = switch (n) {
                'x', 'X' => @as(u8, 16),
                'o', 'O' => @as(u8, 8),
                'b', 'B' => @as(u8, 2),
                else => unreachable,
            };
            const pred: *const fn (u8) bool = switch (radix) {
                16 => isHexDigit,
                8 => isOctalDigit,
                2 => isBinaryDigit,
                else => unreachable,
            };
            try self.scanDigits(pred);
        } else if (self.source[self.pos] == '0' and self.peekByteAt(1) != null and isAsciiDigit(self.peekByteAt(1).?)) {
            var j = self.pos + 1;
            var all_octal = true;
            while (j < self.source.len and isAsciiDigit(self.source[j])) : (j += 1) {
                if (self.source[j] > '7') all_octal = false;
            }
            self.column += @intCast(j - self.pos);
            self.pos = j;
            if (all_octal) {
                is_legacy_octal = true;
                radix = 8;
            } else {
                is_non_octal_decimal = true;
            }
        } else {
            try self.scanDigits(isAsciiDigit);
            if (self.pos < self.source.len and self.source[self.pos] == '.') {
                self.advanceBytes(1);
                try self.scanDigitsAllowEmpty(isAsciiDigit);
                has_dot_or_exp = true;
            }
        }

        if (radix == 10 and !is_legacy_octal and !is_non_octal_decimal and
            self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E'))
        {
            self.advanceBytes(1);
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                self.advanceBytes(1);
            }
            try self.scanDigits(isAsciiDigit);
            has_dot_or_exp = true;
        }

        var is_bigint = false;
        if (!has_dot_or_exp and !is_legacy_octal and !is_non_octal_decimal and
            self.pos < self.source.len and self.source[self.pos] == 'n')
        {
            is_bigint = true;
            self.advanceBytes(1);
        }

        // NumericLiteral's [lookahead != IdentifierStart, lookahead != DecimalDigit] restriction.
        if (self.pos < self.source.len) {
            if (self.decodeAt(self.pos)) |d| {
                if (isIdStart(d.cp) or (d.cp >= '0' and d.cp <= '9')) return LexError.InvalidNumericLiteral;
            }
        }

        const raw = self.source[start..self.pos];
        var tok = self.makeToken(if (is_bigint) .bigint_literal else .numeric_literal, start, had_lt, line, column);
        if (is_bigint) {
            tok.lexeme = raw[0 .. raw.len - 1];
        } else {
            tok.numeric_value = try self.computeNumericValue(raw, radix, is_legacy_octal);
        }
        return tok;
    }

    // ===== String literals =====

    fn ensureMaterialized(self: *Lexer, out: *std.ArrayList(u8), had_escape: *bool, content_start: usize) LexError!void {
        if (had_escape.*) return;
        try out.appendSlice(self.allocator, self.source[content_start..self.pos]);
        had_escape.* = true;
    }

    fn consumeLegacyOctalEscape(self: *Lexer, out: *std.ArrayList(u8)) LexError!void {
        var value: u32 = 0;
        var count: u32 = 0;
        while (count < 3 and self.pos < self.source.len and isOctalDigit(self.source[self.pos])) {
            const next_value = value * 8 + (self.source[self.pos] - '0');
            if (next_value > 255) break;
            value = next_value;
            self.advanceBytes(1);
            count += 1;
        }
        if (count == 0) {
            // \8 or \9: NonOctalDecimalEscapeSequence -- represents itself (non-strict mode).
            try out.append(self.allocator, self.source[self.pos]);
            self.advanceBytes(1);
            return;
        }
        try appendCodepointUtf8(out, self.allocator, @intCast(value));
    }

    /// Shared by string and template literals: `self.pos` is at the '\'.
    fn consumeStringEscape(self: *Lexer, out: *std.ArrayList(u8)) LexError!void {
        self.advanceBytes(1);
        if (self.pos >= self.source.len) return LexError.UnterminatedString;
        const c = self.source[self.pos];
        switch (c) {
            'n' => {
                try out.append(self.allocator, '\n');
                self.advanceBytes(1);
            },
            't' => {
                try out.append(self.allocator, '\t');
                self.advanceBytes(1);
            },
            'r' => {
                try out.append(self.allocator, '\r');
                self.advanceBytes(1);
            },
            'b' => {
                try out.append(self.allocator, 0x08);
                self.advanceBytes(1);
            },
            'f' => {
                try out.append(self.allocator, 0x0C);
                self.advanceBytes(1);
            },
            'v' => {
                try out.append(self.allocator, 0x0B);
                self.advanceBytes(1);
            },
            '0' => {
                if (self.peekByteAt(1) != null and isAsciiDigit(self.peekByteAt(1).?)) {
                    try self.consumeLegacyOctalEscape(out);
                } else {
                    try out.append(self.allocator, 0x00);
                    self.advanceBytes(1);
                }
            },
            '1'...'9' => try self.consumeLegacyOctalEscape(out),
            'x' => {
                self.advanceBytes(1);
                if (self.pos + 2 > self.source.len or !isHexDigit(self.source[self.pos]) or !isHexDigit(self.source[self.pos + 1])) {
                    return LexError.InvalidEscapeSequence;
                }
                const value = std.fmt.parseInt(u8, self.source[self.pos .. self.pos + 2], 16) catch return LexError.InvalidEscapeSequence;
                try appendCodepointUtf8(out, self.allocator, value);
                self.advanceBytes(2);
            },
            'u' => {
                self.advanceBytes(1);
                const first = try self.scanUnicodeEscapeValue();
                var cp: u21 = first;
                if (first >= 0xD800 and first <= 0xDBFF and self.peekByteAt(0) == '\\' and self.peekByteAt(1) == 'u') {
                    const save = self.pos;
                    self.advanceBytes(2);
                    const second = try self.scanUnicodeEscapeValue();
                    if (second >= 0xDC00 and second <= 0xDFFF) {
                        cp = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00);
                    } else {
                        self.pos = save;
                        cp = 0xFFFD;
                    }
                } else if ((first >= 0xD800 and first <= 0xDBFF) or (first >= 0xDC00 and first <= 0xDFFF)) {
                    cp = 0xFFFD;
                }
                try appendCodepointUtf8(out, self.allocator, cp);
            },
            '\n' => {
                self.pos += 1;
                self.line += 1;
                self.column = 1;
            },
            '\r' => {
                self.pos += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '\n') self.pos += 1;
                self.line += 1;
                self.column = 1;
            },
            else => {
                // \', \", \\, and CharacterEscapeSequence's catch-all
                // (any other char escapes to itself, e.g. \z -> z).
                const d = self.decodeAt(self.pos) orelse return LexError.InvalidEscapeSequence;
                try appendCodepointUtf8(out, self.allocator, d.cp);
                self.pos += d.len;
                self.column += 1;
            },
        }
    }

    fn lexString(self: *Lexer, had_lt: bool, line: u32, column: u32) LexError!Token {
        const quote = self.source[self.pos];
        const start = self.pos;
        self.advanceBytes(1);
        const content_start = self.pos;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var had_escape = false;

        while (true) {
            if (self.pos >= self.source.len) return LexError.UnterminatedString;
            const c = self.source[self.pos];
            if (c == quote) {
                self.advanceBytes(1);
                break;
            }
            if (c == '\n' or c == '\r') return LexError.UnterminatedString;
            if (c == '\\') {
                try self.ensureMaterialized(&out, &had_escape, content_start);
                try self.consumeStringEscape(&out);
                continue;
            }
            const d = self.decodeAt(self.pos) orelse return LexError.InvalidEscapeSequence;
            if (had_escape) try appendCodepointUtf8(&out, self.allocator, d.cp);
            self.pos += d.len;
            self.column += 1;
        }

        var tok = self.makeToken(.string_literal, start, had_lt, line, column);
        if (had_escape) {
            tok.owned_value = try out.toOwnedSlice(self.allocator);
        } else {
            out.deinit(self.allocator);
        }
        return tok;
    }

    // ===== Template literals =====

    fn lexTemplatePart(self: *Lexer, is_head: bool, had_lt: bool, line: u32, column: u32) LexError!Token {
        const start = self.pos;
        self.advanceBytes(1); // leading '`' or '}'
        const content_start = self.pos;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var had_escape = false;

        while (true) {
            if (self.pos >= self.source.len) return LexError.UnterminatedTemplate;
            const c = self.source[self.pos];

            if (c == '`') {
                self.advanceBytes(1);
                var tok = self.makeToken(if (is_head) .template_no_substitution else .template_tail, start, had_lt, line, column);
                if (had_escape) {
                    tok.owned_value = try out.toOwnedSlice(self.allocator);
                } else {
                    out.deinit(self.allocator);
                }
                return tok;
            }
            if (c == '$' and self.peekByteAt(1) == '{') {
                self.advanceBytes(2);
                var tok = self.makeToken(if (is_head) .template_head else .template_middle, start, had_lt, line, column);
                if (had_escape) {
                    tok.owned_value = try out.toOwnedSlice(self.allocator);
                } else {
                    out.deinit(self.allocator);
                }
                return tok;
            }
            if (c == '\\') {
                try self.ensureMaterialized(&out, &had_escape, content_start);
                try self.consumeStringEscape(&out);
                continue;
            }
            if (c == '\r') {
                // TV normalizes CRLF/CR to LF (TRV, the raw value, is not
                // exposed by this lexer -- out of scope, see README).
                try self.ensureMaterialized(&out, &had_escape, content_start);
                try out.append(self.allocator, '\n');
                self.pos += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '\n') self.pos += 1;
                self.line += 1;
                self.column = 1;
                continue;
            }
            const d = self.decodeAt(self.pos) orelse return LexError.InvalidEscapeSequence;
            if (had_escape) try appendCodepointUtf8(&out, self.allocator, d.cp);
            if (isLineTerminatorCp(d.cp)) {
                self.pos += d.len;
                self.line += 1;
                self.column = 1;
            } else {
                self.pos += d.len;
                self.column += 1;
            }
        }
    }

    /// See LexContext's doc comment: called instead of nextToken() when the
    /// caller's own `${`/`}` brace-depth tracking has determined that the
    /// '}' sitting at the current position closes a template substitution
    /// rather than being an ordinary punctuator. Requires self.pos to be
    /// sitting exactly at that '}', not yet consumed.
    pub fn continueTemplate(self: *Lexer) LexError!Token {
        const line = self.line;
        const column = self.column;
        std.debug.assert(self.pos < self.source.len and self.source[self.pos] == '}');
        return self.lexTemplatePart(false, false, line, column);
    }

    // ===== Regex literals =====

    fn lexRegex(self: *Lexer, had_lt: bool, line: u32, column: u32) LexError!Token {
        const start = self.pos;
        self.advanceBytes(1); // leading '/'
        var in_class = false;

        while (true) {
            if (self.pos >= self.source.len) return LexError.UnterminatedRegex;
            const c = self.source[self.pos];
            if (isLineTerminatorByte(c)) return LexError.UnterminatedRegex;
            if (c == '\\') {
                self.advanceBytes(1);
                if (self.pos >= self.source.len or isLineTerminatorByte(self.source[self.pos])) return LexError.UnterminatedRegex;
                const d = self.decodeAt(self.pos) orelse return LexError.UnterminatedRegex;
                self.pos += d.len;
                self.column += 1;
                continue;
            }
            if (c == '[') {
                in_class = true;
                self.advanceBytes(1);
                continue;
            }
            if (c == ']') {
                in_class = false;
                self.advanceBytes(1);
                continue;
            }
            if (c == '/' and !in_class) {
                self.advanceBytes(1);
                break;
            }
            const d = self.decodeAt(self.pos) orelse return LexError.UnterminatedRegex;
            self.pos += d.len;
            self.column += 1;
        }

        const body_end = self.pos - 1;
        const pattern = self.source[start + 1 .. body_end];
        const flags_start = self.pos;
        while (self.pos < self.source.len) {
            const d = self.decodeAt(self.pos) orelse break;
            if (!isIdContinue(d.cp)) break;
            self.pos += d.len;
            self.column += 1;
        }
        const flags = self.source[flags_start..self.pos];

        var tok = self.makeToken(.regex_literal, start, had_lt, line, column);
        tok.lexeme = pattern;
        tok.regex_flags = flags;
        return tok;
    }

    // ===== Punctuators =====

    fn lexPunctuator(self: *Lexer, had_lt: bool, line: u32, column: u32) LexError!Token {
        const start = self.pos;
        const c = self.source[self.pos];
        const c1 = self.peekByteAt(1);
        const c2 = self.peekByteAt(2);
        const c3 = self.peekByteAt(3);

        const ty: TokenType = switch (c) {
            '{' => blk: {
                self.advanceBytes(1);
                break :blk .punct_lbrace;
            },
            '}' => blk: {
                self.advanceBytes(1);
                break :blk .punct_rbrace;
            },
            '(' => blk: {
                self.advanceBytes(1);
                break :blk .punct_lparen;
            },
            ')' => blk: {
                self.advanceBytes(1);
                break :blk .punct_rparen;
            },
            '[' => blk: {
                self.advanceBytes(1);
                break :blk .punct_lbracket;
            },
            ']' => blk: {
                self.advanceBytes(1);
                break :blk .punct_rbracket;
            },
            ';' => blk: {
                self.advanceBytes(1);
                break :blk .punct_semi;
            },
            ',' => blk: {
                self.advanceBytes(1);
                break :blk .punct_comma;
            },
            ':' => blk: {
                self.advanceBytes(1);
                break :blk .punct_colon;
            },
            '~' => blk: {
                self.advanceBytes(1);
                break :blk .punct_tilde;
            },
            '.' => blk: {
                if (c1 == '.' and c2 == '.') {
                    self.advanceBytes(3);
                    break :blk .punct_ellipsis;
                }
                self.advanceBytes(1);
                break :blk .punct_dot;
            },
            '?' => blk: {
                if (c1 == '?' and c2 == '=') {
                    self.advanceBytes(3);
                    break :blk .punct_question_question_assign;
                }
                if (c1 == '?') {
                    self.advanceBytes(2);
                    break :blk .punct_question_question;
                }
                // `?.` is not a token when followed by a digit (that's `? .5` /
                // conditional-then-number, e.g. `a ?.5:1`).
                if (c1 == '.' and !(c2 != null and c2.? >= '0' and c2.? <= '9')) {
                    self.advanceBytes(2);
                    break :blk .punct_question_dot;
                }
                self.advanceBytes(1);
                break :blk .punct_question;
            },
            '<' => blk: {
                if (c1 == '<' and c2 == '=') {
                    self.advanceBytes(3);
                    break :blk .punct_shl_assign;
                }
                if (c1 == '<') {
                    self.advanceBytes(2);
                    break :blk .punct_shl;
                }
                if (c1 == '=') {
                    self.advanceBytes(2);
                    break :blk .punct_le;
                }
                self.advanceBytes(1);
                break :blk .punct_lt;
            },
            '>' => blk: {
                if (c1 == '>' and c2 == '>' and c3 == '=') {
                    self.advanceBytes(4);
                    break :blk .punct_ushr_assign;
                }
                if (c1 == '>' and c2 == '>') {
                    self.advanceBytes(3);
                    break :blk .punct_ushr;
                }
                if (c1 == '>' and c2 == '=') {
                    self.advanceBytes(3);
                    break :blk .punct_shr_assign;
                }
                if (c1 == '>') {
                    self.advanceBytes(2);
                    break :blk .punct_shr;
                }
                if (c1 == '=') {
                    self.advanceBytes(2);
                    break :blk .punct_ge;
                }
                self.advanceBytes(1);
                break :blk .punct_gt;
            },
            '=' => blk: {
                if (c1 == '=' and c2 == '=') {
                    self.advanceBytes(3);
                    break :blk .punct_eqeqeq;
                }
                if (c1 == '=') {
                    self.advanceBytes(2);
                    break :blk .punct_eq;
                }
                if (c1 == '>') {
                    self.advanceBytes(2);
                    break :blk .punct_arrow;
                }
                self.advanceBytes(1);
                break :blk .punct_assign;
            },
            '!' => blk: {
                if (c1 == '=' and c2 == '=') {
                    self.advanceBytes(3);
                    break :blk .punct_noteqeq;
                }
                if (c1 == '=') {
                    self.advanceBytes(2);
                    break :blk .punct_ne;
                }
                self.advanceBytes(1);
                break :blk .punct_bang;
            },
            '+' => blk: {
                if (c1 == '+') {
                    self.advanceBytes(2);
                    break :blk .punct_plusplus;
                }
                if (c1 == '=') {
                    self.advanceBytes(2);
                    break :blk .punct_plus_assign;
                }
                self.advanceBytes(1);
                break :blk .punct_plus;
            },
            '-' => blk: {
                if (c1 == '-') {
                    self.advanceBytes(2);
                    break :blk .punct_minusminus;
                }
                if (c1 == '=') {
                    self.advanceBytes(2);
                    break :blk .punct_minus_assign;
                }
                self.advanceBytes(1);
                break :blk .punct_minus;
            },
            '*' => blk: {
                if (c1 == '*' and c2 == '=') {
                    self.advanceBytes(3);
                    break :blk .punct_starstar_assign;
                }
                if (c1 == '*') {
                    self.advanceBytes(2);
                    break :blk .punct_starstar;
                }
                if (c1 == '=') {
                    self.advanceBytes(2);
                    break :blk .punct_star_assign;
                }
                self.advanceBytes(1);
                break :blk .punct_star;
            },
            '/' => blk: {
                if (c1 == '=') {
                    self.advanceBytes(2);
                    break :blk .punct_slash_assign;
                }
                self.advanceBytes(1);
                break :blk .punct_slash;
            },
            '%' => blk: {
                if (c1 == '=') {
                    self.advanceBytes(2);
                    break :blk .punct_percent_assign;
                }
                self.advanceBytes(1);
                break :blk .punct_percent;
            },
            '&' => blk: {
                if (c1 == '&' and c2 == '=') {
                    self.advanceBytes(3);
                    break :blk .punct_ampamp_assign;
                }
                if (c1 == '&') {
                    self.advanceBytes(2);
                    break :blk .punct_ampamp;
                }
                if (c1 == '=') {
                    self.advanceBytes(2);
                    break :blk .punct_amp_assign;
                }
                self.advanceBytes(1);
                break :blk .punct_amp;
            },
            '|' => blk: {
                if (c1 == '|' and c2 == '=') {
                    self.advanceBytes(3);
                    break :blk .punct_pipepipe_assign;
                }
                if (c1 == '|') {
                    self.advanceBytes(2);
                    break :blk .punct_pipepipe;
                }
                if (c1 == '=') {
                    self.advanceBytes(2);
                    break :blk .punct_pipe_assign;
                }
                self.advanceBytes(1);
                break :blk .punct_pipe;
            },
            '^' => blk: {
                if (c1 == '=') {
                    self.advanceBytes(2);
                    break :blk .punct_caret_assign;
                }
                self.advanceBytes(1);
                break :blk .punct_caret;
            },
            else => return LexError.UnexpectedCharacter,
        };
        return self.makeToken(ty, start, had_lt, line, column);
    }
};
