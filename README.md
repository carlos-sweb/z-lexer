# Z-Lexer

[![Zig Version](https://img.shields.io/badge/zig-0.16-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

ECMAScript tokenizer (ECMA-262 §12, the Lexical Grammar) in Zig 0.16 — the first repo of the actual JS *engine* (as opposed to the [z-*](https://github.com/carlos-sweb) value-type ecosystem it will eventually feed into), part of the same micro-library family.

## Why this is its own repo, independent of everything else

The lexer doesn't produce runtime values — it produces `Token`s, a purely syntactic concept. It has no dependency on [z-value](https://github.com/carlos-sweb/z-value)'s `JSValue`, same independence [z-number](https://github.com/carlos-sweb/z-number) has from the rest of the ecosystem. Its one real dependency is [zregex](https://github.com/carlos-sweb/z-regex), reused for Unicode `General_Category` lookup (`ID_Start`/`ID_Continue` classification) rather than duplicating ~21k lines of UCD-derived tables in a second repo.

## Design

- **Zero-copy by default**: `Token.lexeme` is a slice into the original source for the vast majority of tokens (punctuators, keywords, identifiers, numbers). `Token.owned_value` is only allocated when a string/template literal contains an escape sequence, or an identifier contains a `\u` escape — the caller frees it via `Token.deinit()`.
- **Numbers are computed at lex time**: `Token.numeric_value: ?f64` holds the already-parsed value for `.numeric_literal` tokens (source-grammar parsing — decimal/hex/octal/binary/legacy-octal, numeric separators, distinct from `Number()`/`parseFloat`'s runtime-coercion grammar, which [z-number](https://github.com/carlos-sweb/z-number) already implements and isn't reusable here). `.bigint_literal` tokens keep their raw digit text instead (`lexeme`), since a BigInt's value isn't representable as `f64` — there's no BigInt runtime type in this ecosystem yet; the lexer recognizes the `123n` syntax without evaluating it.
- **Lexer/parser cooperation, explicit rather than guessed**: two spots in ECMA-262's own grammar are genuinely ambiguous without a parser:
  - `/` is either division or the start of a `RegExpLiteral` depending on grammar position. `nextToken(ctx: LexContext)` takes this as an explicit parameter (`.regex_allowed` / `.div_allowed`) — a future Parser will compute it from grammar position; a test harness (or any other caller) drives it directly today.
  - A template literal's `${...}` substitution can contain arbitrary expressions, including nested `{}` (an object literal) that must **not** be mistaken for the substitution's own closing `}`. `continueTemplate()` is a separate entry point from `nextToken()` for exactly this: the caller tracks `${`/`}` brace depth itself (trivial — increment on `.punct_lbrace`, decrement on `.punct_rbrace` while depth > 0), and when a `.punct_rbrace` token is produced at depth 0, rewinds the lexer to that token's `start`/`line`/`column` (public fields) and calls `continueTemplate()` instead of treating it as an ordinary punctuator. See `tests/template_test.zig`'s `TemplateDriver` for a complete, tested implementation of this pattern — the template a future Parser will follow.
- **Reserved words are purely lexical, per spec**: only the ECMA-262 Table 34 *unconditionally* reserved words (`if`, `function`, `return`, `null`, `true`, ...) get their own `TokenType`. Contextual keywords (`let`, `static`, `async`, `await`, `of`, `get`, `set`, and strict-mode-only future-reserved words) tokenize as plain `.identifier` — their reserved status depends on strict-mode/grammar position, which belongs to the not-yet-built parser, not the lexer. An identifier spelled with a `\u` escape (`if`) is never treated as a keyword either, even if decoding it produces the same characters as one — this is itself a spec rule (12.7.2), not a simplification.

## Coverage

Whitespace/line terminators/comments (`//`, `/* */`, hashbang `#!`, with `had_line_terminator_before` tracking for the future parser's Automatic Semicolon Insertion) · identifiers and keywords (Unicode `ID_Start`/`ID_Continue`, `\u`/`\u{...}` escapes) · full punctuator maximal munch (`?.`, `??`, `??=`, `**`, `**=`, `>>>=`, `...`, etc.) · numeric literals (decimal, `0x`/`0o`/`0b`, legacy octal, `_` separators, BigInt `n` suffix) · string literals (both quote styles, full escape grammar including `\u`/`\x`/legacy octal/line continuation, surrogate-pair combining) · template literals (head/middle/tail splitting, nested templates) · regex literals (character-class-aware delimiter scanning, gated by `LexContext`) · private identifiers (`#foo`).

## Known simplifications

- Operates on UTF-8 source (`[]const u8`), not UTF-16 code units as the spec technically requires — same "practical compatibility, not literal spec fidelity" scope decision already made throughout this ecosystem (e.g. z-string's UTF-16-*indexed*-but-UTF-8-*stored* design).
- A `\u`/surrogate-pair escape sequence that doesn't form a valid pair decodes to U+FFFD rather than being preserved as a lone surrogate, since the underlying UTF-8 storage can't represent one at all — same decision already made in [z-json](https://github.com/carlos-sweb/z-json)'s `\uXXXX` handling.
- Non-decimal integer literals (hex/octal/binary) beyond 2^53 or so lose precision the same way any JS engine's `f64`-backed `Number` does — verified against real Node/V8 output (see `tests/numeric_test.zig`'s "Node-verified" test) rather than assumed.
- Template literals only expose the cooked value (`TV`), not the raw value (`TRV`) needed for tagged templates' `.raw` property — not needed until tagged templates are implemented at the parser/interpreter level.
- No strict-mode tracking (legacy octal escapes/literals are always accepted) — strict-mode early errors are a parser-level concern per spec, not the lexer's.

## Usage

```zig
const zlexer = @import("zlexer");

var lex = zlexer.Lexer.init(allocator, "const x = 1 + 2;");
while (true) {
    var tok = try lex.nextToken(.regex_allowed);
    defer tok.deinit(allocator);
    if (tok.type == .eof) break;
    // ...
}
```

## Testing

```bash
zig build test
```

## License

MIT
