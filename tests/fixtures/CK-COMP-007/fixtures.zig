//! Synthetic, UNVERIFIED local quota formats; no user data.
pub const paths = [_][]const u8{
    "tests/fixtures/CK-COMP-007/codex-normal.jsonl",
    "tests/fixtures/CK-COMP-007/codex-80.jsonl",
    "tests/fixtures/CK-COMP-007/codex-100.jsonl",
    "tests/fixtures/CK-COMP-007/codex-unknown.jsonl",
    "tests/fixtures/CK-COMP-007/claude-code-normal.jsonl",
    "tests/fixtures/CK-COMP-007/claude-code-80.jsonl",
    "tests/fixtures/CK-COMP-007/claude-code-100.jsonl",
    "tests/fixtures/CK-COMP-007/claude-code-unknown.jsonl",
};
pub const contents = [_][]const u8{
    @embedFile("codex-normal.jsonl"),
    @embedFile("codex-80.jsonl"),
    @embedFile("codex-100.jsonl"),
    @embedFile("codex-unknown.jsonl"),
    @embedFile("claude-code-normal.jsonl"),
    @embedFile("claude-code-80.jsonl"),
    @embedFile("claude-code-100.jsonl"),
    @embedFile("claude-code-unknown.jsonl"),
};
