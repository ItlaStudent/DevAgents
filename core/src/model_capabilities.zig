//! one fallback classification for catalogs without chat metadata.
const std = @import("std");

const non_chat_patterns = [_][]const u8{
    "rerank",           "vision",        "transcribe",   "safety", "guard",   "-parse",
    "nemoretriever",    "reward",        "moderat",      "lyria",  "imagen-", "-imagen",
    "veo-",             "-veo",          "music",        "-ocr",   "dall-e",  "flux",
    "stable-diffusion", "sdxl",          "image",        "video",  "-audio",  "audio-",
    "robotics",         "deep-research", "computer-use", "-aqa",   "/aqa",    "bge-",
    "studiovoice",
};

// Capability labels are complete tokens, not incidental substrings of a chat
// model's name (embedded-systems, Whisperer, Watts). Keep tokenization identical
// in Zig and SQL. The other specialized family patterns retain their fallback.
const token_delimiters = "/-_.: ";
const non_chat_tokens = [_][]const u8{ "embed", "embedding", "embeddings", "embedcode", "embedqa", "textembedding", "whisper", "tts" };

fn nonChatToken(name: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, name, token_delimiters);
    while (tokens.next()) |token| {
        for (non_chat_tokens) |label| if (std.ascii.eqlIgnoreCase(token, label)) return true;
    }
    return false;
}

pub fn nonChat(name: []const u8) bool {
    if (nonChatToken(name)) return true;
    for (non_chat_patterns) |pattern| {
        if (std.ascii.findIgnoreCasePos(name, 0, pattern) != null) return true;
    }
    return false;
}

/// SQL and Zig use the same patterns. `m` is the model table alias.
pub const sql_filter = blk: {
    @setEvalBranchQuota(10000);
    var sql: []const u8 = " ";
    for (non_chat_patterns) |pattern| {
        sql = sql ++ " AND m.model_name NOT LIKE '%" ++ pattern ++ "%' ";
    }
    var normalized: []const u8 = "lower(m.model_name)";
    for (token_delimiters) |delimiter| {
        normalized = "replace(" ++ normalized ++ ",'" ++ .{delimiter} ++ "','-')";
    }
    for (non_chat_tokens) |token| {
        sql = sql ++ " AND ('-' || " ++ normalized ++ " || '-') NOT LIKE '%-" ++ token ++ "-%' ";
    }
    break :blk sql;
};

/// Explicit output capabilities win over the name fallback. A text output
/// means chat/text generation; image/audio/embedding outputs alone do not.
pub fn fromMetadata(name: []const u8, value: std.json.Value) ?bool {
    if (value != .object) return null;
    if (value.object.get("supportedGenerationMethods")) |methods| {
        if (methods == .array) {
            for (methods.array.items) |method| {
                if (method == .string and (std.mem.eql(u8, method.string, "generateContent") or std.mem.eql(u8, method.string, "generateText"))) return true;
            }
            return false;
        }
    }
    for ([_][]const u8{ "architecture", "modalities" }) |key| {
        const parent = value.object.get(key) orelse continue;
        if (parent != .object) continue;
        const outputs = parent.object.get("output_modalities") orelse parent.object.get("output") orelse continue;
        if (outputs != .array) continue;
        for (outputs.array.items) |output| {
            if (output == .string and std.mem.eql(u8, output.string, "text")) {
                // Transcription/OCR also emit text. A text modality alone must
                // not promote these specialized endpoints into chat models.
                if (nonChatToken(name)) return false;
                for (non_chat_patterns) |pattern| {
                    if (!std.mem.eql(u8, pattern, "vision") and std.ascii.findIgnoreCasePos(name, 0, pattern) != null) return false;
                }
                return true;
            }
        }
        return false;
    }
    return null;
}
