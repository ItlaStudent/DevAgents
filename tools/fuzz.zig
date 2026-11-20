const std = @import("std");
const core = @import("core");
const providers = @import("providers");

const DEFAULT_SEED: u64 = 0xDEADBEEF_CAFE_BABE;
const DEFAULT_ITERS: usize = 100_000;
const MAX_INPUT_LEN: usize = 4096;

// ── PRNG SplitMix64 (determinista, portable) ──────────────────────────

fn splitmix64(seed: *u64) u64 {
    seed.* +%= 0x9e3779b97f4a7c15;
    var z = seed.*;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn randomUsize(seed: *u64, max: usize) usize {
    if (max == 0) return 0;
    return @intCast(splitmix64(seed) % @as(u64, @intCast(max)));
}

fn randomByte(seed: *u64) u8 {
    return @intCast(splitmix64(seed) & 0xFF);
}

// ── Mutación de entradas ──────────────────────────────────────────────

fn mutate(seed: *u64, input: []u8) []u8 {
    if (input.len == 0) return input;
    const op = randomUsize(seed, 12);

    switch (op) {
        0 => { // bit flip
            const idx = randomUsize(seed, input.len);
            const bit: u3 = @intCast(randomUsize(seed, 8));
            input[idx] ^= @as(u8, 1) << bit;
        },
        1 => { // byte substitution
            const idx = randomUsize(seed, input.len);
            input[idx] = randomByte(seed);
        },
        2 => { // zero injection
            const idx = randomUsize(seed, input.len);
            input[idx] = 0;
        },
        3 => { // high-byte injection (0xFF)
            const idx = randomUsize(seed, input.len);
            input[idx] = 0xFF;
        },
        4 => { // special char injection
            const idx = randomUsize(seed, input.len);
            const specials = [_]u8{ '\\', '\'', '\"', '\n', '\r', '\t', 0x1B, 0x00, '{', '}', '[', ']', ':', ',', '|' };
            input[idx] = specials[randomUsize(seed, specials.len)];
        },
        5 => { // delete chunk (set range to spaces)
            const start = randomUsize(seed, input.len);
            const end = @min(input.len, start + randomUsize(seed, 32) + 1);
            for (input[start..end]) |*b| b.* = ' ';
        },
        6 => { // truncate (inject null at random position)
            const idx = randomUsize(seed, input.len);
            input[idx] = 0;
        },
        7 => { // repeat first byte many times
            const repeats = @min(randomUsize(seed, 64) + 1, input.len);
            const b = input[0];
            for (input[0..repeats]) |*byte| byte.* = b;
        },
        8 => { // unterminated quote injection
            const idx = randomUsize(seed, input.len);
            input[idx] = '"';
        },
        9 => { // newline injection
            const idx = randomUsize(seed, input.len);
            input[idx] = '\n';
        },
        10 => { // increment bytes
            const start = randomUsize(seed, input.len);
            const end = @min(input.len, start + randomUsize(seed, 16) + 1);
            for (input[start..end]) |*b| b.* +%= 1;
        },
        11 => { // decrement bytes
            const start = randomUsize(seed, input.len);
            const end = @min(input.len, start + randomUsize(seed, 16) + 1);
            for (input[start..end]) |*b| b.* -%= 1;
        },
        else => {},
    }
    return input;
}

// ── Corpus: entradas validas para cada parser ─────────────────────────

const CorpusEntry = struct {
    name: []const u8,
    inputs: []const []const u8,
};

const corpuses = [_]CorpusEntry{
    .{
        .name = "sse",
        .inputs = &.{
            "data: hello world\n\n",
            "event: update\ndata: {\"x\":1}\n\n",
            "id: 42\ndata: test\n\n",
            "data: line1\ndata: line2\n\n",
            ": heartbeat\n\n",
            "data: \n\n",
            "data: unicode ©\n\n",
            "event: error\ndata: {\"msg\":\"failed\"}\nid: 1\n\n",
        },
    },
    .{
        .name = "artifacts",
        .inputs = &.{
            "[{\"field\":\"a.c\",\"content\":\"hello\"}]",
            "[{\"field\":\"src/main.zig\",\"content\":\"const std = @import(\\\"std\\\");\"}]",
            "[{\"field\":\"p\",\"content\":\"x\"},{\"field\":\"q\",\"content\":\"y\"}]",
            "[{\"field\":\"\",\"content\":\"\"}]",
            "[{\"field\":\"with\\nescape\",\"content\":\"tab\\t\"}]",
        },
    },
    .{
        .name = "llm_response",
        .inputs = &.{
            "[{\"field\":\"a.c\",\"content\":\"hello\"}]",
            "[{\"field\":\"main.zig\",\"content\":\"pub fn main() void {}\"}]",
            "[{\"field\":\"x\",\"content\":\"1\"},{\"field\":\"y\",\"content\":\"2\"}]",
            "[{\"field\":\"\",\"content\":\"\"}]",
            "[{\"field\":\"f\",\"content\":\"v\"}]",
        },
    },
    .{
        .name = "frontmatter",
        .inputs = &.{
            "---\ntitle: Hello\n---",
            "---\ntitle: Test\ndescription: A longer description\n---",
            "---\nname: agent\ntools: [a, b, c]\n---",
            "---\ndescription: |\n  line 1\n  line 2\n---",
            "---\ntitle: Nested|\nbody: |\n  indented\n  content\n---",
            "---\nkey: value with 'quotes'\nother: simple\n---",
        },
    },
    .{
        .name = "divisions",
        .inputs = &.{
            "[{\"id\":\"d1\",\"name\":\"Engineering\",\"description\":\"desc\",\"agentCount\":5,\"roomId\":\"r1\"}]",
            "[{\"id\":\"d1\",\"name\":\"Eng\",\"description\":\"\",\"agentCount\":0,\"roomId\":\"r\"},{\"id\":\"d2\",\"name\":\"QA\",\"description\":\"q\",\"agentCount\":3,\"roomId\":\"r2\"}]",
            "[]",
        },
    },
    .{
        .name = "agents",
        .inputs = &.{
            "[{\"id\":\"a1\",\"name\":\"coder\",\"role\":\"dev\",\"model\":\"deep\",\"room\":\"r1\",\"status\":\"active\"}]",
            "[{\"id\":\"a1\",\"name\":\"n\",\"role\":\"r\",\"model\":\"m\",\"room\":\"x\",\"status\":\"s\",\"capabilities\":[\"c1\",\"c2\"]}]",
            "[]",
        },
    },
    .{
        .name = "manifest",
        .inputs = &.{
            "{\"name\":\"Example\",\"version\":\"1.0\",\"abi_version\":1,\"dll\":\"example.dll\"}",
            "{\"name\":\"P\",\"version\":\"2.0\",\"abi_version\":2,\"dll\":\"plugin.dll\",\"capabilities\":[{\"kind\":\"provider\",\"name\":\"X\",\"description\":\"Y\"}]}",
            "{\"name\":\"\",\"version\":\"\",\"abi_version\":0,\"dll\":\"\"}",
        },
    },
};

// ── Estadisticas ──────────────────────────────────────────────────────

const TargetStats = struct {
    name: []const u8,
    total: usize = 0,
    errors: usize = 0,
    ok: usize = 0,
    crashes: usize = 0,
    leaked_bytes: usize = 0,
};

// ── Main fuzz loop ────────────────────────────────────────────────────

pub fn main() !void {
    const num_iters = DEFAULT_ITERS;

    var seed: u64 = DEFAULT_SEED;
    var buf: [MAX_INPUT_LEN]u8 = undefined;

    var stats: [corpuses.len]TargetStats = undefined;
    for (corpuses, 0..) |corpus, i| {
        stats[i] = .{ .name = corpus.name };
    }

    std.debug.print("FUZZ: seed=0x{X:0>16} iters={d} targets={d}\n", .{ DEFAULT_SEED, num_iters, corpuses.len });

    const iters_per_target = num_iters / corpuses.len;

    for (corpuses, 0..) |corpus, ci| {
        std.debug.print("  [{s}] starting {d} iterations...\n", .{ corpus.name, iters_per_target });
        var st = &stats[ci];

        for (0..iters_per_target) |_| {
            // Pick random base input
            const base_idx = randomUsize(&seed, corpus.inputs.len);
            const base = corpus.inputs[base_idx];

            // Copy base into buffer with mutation space
            const copy_len = @min(base.len, MAX_INPUT_LEN - 64);
            @memcpy(buf[0..copy_len], base[0..copy_len]);

            // Apply mutation
            const mutated = mutate(&seed, buf[0..copy_len]);

            st.total += 1;
            fuzzOne(std.heap.page_allocator, corpus.name, mutated, st) catch |err| {
                if (err == error.OutOfMemory) {
                    st.errors += 1;
                } else {
                    st.crashes += 1;
                    std.debug.print("    CRASH [{s}] input(len={d}): ", .{ corpus.name, mutated.len });
                    // Print first 80 chars as hex
                    for (mutated, 0..) |b, j| {
                        if (j >= 80) break;
                        std.debug.print("{X:0>2} ", .{b});
                    }
                    std.debug.print("\n", .{});
                }
            };
        }

        std.debug.print("  [{s}] total={d} ok={d} errors={d} crashes={d}\n", .{ st.name, st.total, st.ok, st.errors, st.crashes });
    }

    var total_crashes: usize = 0;
    for (stats) |st| total_crashes += st.crashes;

    if (total_crashes > 0) {
        std.debug.print("\nFAIL: {d} crashes detected\n", .{total_crashes});
        std.process.exit(1);
    }
    std.debug.print("\nPASS: 0 crashes in {d} iterations\n", .{num_iters});
}

fn fuzzOne(allocator: std.mem.Allocator, target_name: []const u8, input: []const u8, st: *TargetStats) !void {
    if (std.mem.eql(u8, target_name, "sse")) {
        fuzzSse(allocator, input) catch |err| {
            if (err == error.InvalidEvent or err == error.OutOfMemory) {
                st.errors += 1;
                return;
            }
            return err;
        };
        st.ok += 1;
    } else if (std.mem.eql(u8, target_name, "artifacts")) {
        core.cli_worker.fuzz_parseArtifactsFromOutput(allocator, input) catch |err| {
            if (err == error.InvalidArtifact or err == error.OutOfMemory) {
                st.errors += 1;
                return;
            }
            return err;
        };
        st.ok += 1;
    } else if (std.mem.eql(u8, target_name, "llm_response")) {
        core.worker_backend.fuzz_parseLlmResponse(allocator, input) catch |err| {
            if (err == error.InvalidArtifact or err == error.OutOfMemory) {
                st.errors += 1;
                return;
            }
            return err;
        };
        st.ok += 1;
    } else if (std.mem.eql(u8, target_name, "frontmatter")) {
        const maybe_fm = core.tool_discovery.parseFrontmatter(allocator, input) catch |err| {
            if (err == error.OutOfMemory) {
                st.errors += 1;
                return;
            }
            return err;
        };
        if (maybe_fm) |fm| {
            var mfm = fm;
            mfm.deinit();
        }
        st.ok += 1;
    } else if (std.mem.eql(u8, target_name, "divisions")) {
        const adapter = core.pixel_adapter.PixelAdapter{ .allocator = allocator };
        _ = adapter.parseDivisions(input) catch {
            st.errors += 1;
            return;
        };
        st.ok += 1;
    } else if (std.mem.eql(u8, target_name, "agents")) {
        const adapter = core.pixel_adapter.PixelAdapter{ .allocator = allocator };
        _ = adapter.parseAgents(input) catch {
            st.errors += 1;
            return;
        };
        st.ok += 1;
    } else if (std.mem.eql(u8, target_name, "manifest")) {
        const loader = core.plugin_loader.PluginLoader{ .allocator = allocator };
        _ = loader.parseManifest(input) catch {
            st.errors += 1;
            return;
        };
        st.ok += 1;
    }
}

// ── SSE fuzzer (usa reader en memoria) ───────────────────────────────

fn fuzzSse(allocator: std.mem.Allocator, input: []const u8) !void {
    // Use a temporary copy with sentinel for .fixed reader
    var buf_copy: [MAX_INPUT_LEN + 1]u8 = undefined;
    const copy_len = @min(input.len, MAX_INPUT_LEN);
    @memcpy(buf_copy[0..copy_len], input[0..copy_len]);
    // Ensure null termination for .fixed reader
    for (buf_copy[copy_len..]) |*b| b.* = 0;

    var reader: std.Io.Reader = .fixed(buf_copy[0..copy_len :0]);
    var stream = try providers.sse.SseStream.init(allocator, &reader);
    defer stream.deinit();

    while (true) {
        var event = (try stream.nextEvent()) orelse break;
        defer event.deinit();
    }
}

// ── Test rapido para verificacion ─────────────────────────────────────

test "fuzz: smoke test with small iteration count" {
    // This test just verifies the fuzzer infrastructure works
    // by running a minimal fuzz pass (not a real coverage test).
    var seed: u64 = DEFAULT_SEED;
    var buf: [MAX_INPUT_LEN]u8 = undefined;
    const allocator = std.testing.allocator;

    for (corpuses[0..@min(2, corpuses.len)]) |corpus| {
        for (0..10) |_| {
            const base_idx = randomUsize(&seed, corpus.inputs.len);
            const base = corpus.inputs[base_idx];
            const copy_len = @min(base.len, MAX_INPUT_LEN - 64);
            @memcpy(buf[0..copy_len], base[0..copy_len]);
            _ = mutate(&seed, buf[0..copy_len]);
        }
    }

    // Smoke fuzz a single frontmatter input
    const maybe_fm = core.tool_discovery.parseFrontmatter(allocator, "---\ntitle: test\n---") catch null;
    if (maybe_fm) |fm| {
        var mfm = fm;
        mfm.deinit();
    }

    // Smoke fuzz a single SSE input
    const test_sse = "data: hello\n\n";
    var reader2: std.Io.Reader = .fixed(test_sse);
    var stream2 = try providers.sse.SseStream.init(allocator, &reader2);
    defer stream2.deinit();
    var ev2 = (try stream2.nextEvent()) orelse return error.TestFailed;
    defer ev2.deinit();
}

test "fuzz: parseArtifactsFromOutput handles edge cases" {
    const allocator = std.testing.allocator;

    // Empty
    try std.testing.expectError(error.InvalidArtifact, core.cli_worker.fuzz_parseArtifactsFromOutput(allocator, ""));
    // Just whitespace
    try std.testing.expectError(error.InvalidArtifact, core.cli_worker.fuzz_parseArtifactsFromOutput(allocator, "   "));
    // Unclosed bracket
    try std.testing.expectError(error.InvalidArtifact, core.cli_worker.fuzz_parseArtifactsFromOutput(allocator, "["));
    // Random garbage
    try std.testing.expectError(error.InvalidArtifact, core.cli_worker.fuzz_parseArtifactsFromOutput(allocator, "NOT_JSON_AT_ALL"));
    // Partial
    try std.testing.expectError(error.InvalidArtifact, core.cli_worker.fuzz_parseArtifactsFromOutput(allocator, "[{\"field\":\"x\",\"cont"));
}

test "fuzz: parseLlmResponse handles edge cases" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidArtifact, core.worker_backend.fuzz_parseLlmResponse(allocator, ""));
    try std.testing.expectError(error.InvalidArtifact, core.worker_backend.fuzz_parseLlmResponse(allocator, "["));
    try std.testing.expectError(error.InvalidArtifact, core.worker_backend.fuzz_parseLlmResponse(allocator, "not json"));
    try std.testing.expectError(error.InvalidArtifact, core.worker_backend.fuzz_parseLlmResponse(allocator, "[{\"field\":\"x\"}]"));
}

test "fuzz: parseFrontmatter handles nested pipe blocks" {
    const allocator = std.testing.allocator;
    const input = "---\ntitle: Deep|\nouter: |\n  level1\n  level2\n---";
    const maybe_fm = core.tool_discovery.parseFrontmatter(allocator, input) catch return error.TestUnexpectedError;
    if (maybe_fm) |fm| {
        var mfm = fm;
        defer mfm.deinit();
        try std.testing.expect(mfm.map.count() > 0);
    } else {
        return error.TestUnexpectedError;
    }
}

test "fuzz: parseDivisions handles malformed JSON" {
    const allocator = std.testing.allocator;
    const adapter = core.pixel_adapter.PixelAdapter.init(allocator);

    // Varias cadenas malformadas no deben entrar en bucle infinito ni causar crash.
    _ = adapter.parseDivisions("not json") catch {};
    _ = adapter.parseDivisions("{ \"bad\": true }") catch {};
    _ = adapter.parseDivisions("[ { \"name\": 123 } ]") catch {};
}

test "fuzz: parseAgents handles malformed JSON" {
    const allocator = std.testing.allocator;
    const adapter = core.pixel_adapter.PixelAdapter.init(allocator);

    try std.testing.expectError(error.ParseError, adapter.parseAgents("not json"));
    try std.testing.expectError(error.ParseError, adapter.parseAgents("[]]"));

    const agents = try adapter.parseAgents("[]");
    try std.testing.expectEqual(@as(usize, 0), agents.len);
}

test "fuzz: parseManifest handles edge cases" {
    const allocator = std.testing.allocator;
    const loader = core.plugin_loader.PluginLoader{ .allocator = allocator };

    try std.testing.expectError(error.ManifestInvalid, loader.parseManifest("not json"));
    try std.testing.expectError(error.ManifestInvalid, loader.parseManifest("[]"));
    try std.testing.expectError(error.ManifestInvalid, loader.parseManifest("{}"));
}

test "fuzz: PRNG is deterministic" {
    var seed1: u64 = DEFAULT_SEED;
    var seed2: u64 = DEFAULT_SEED;
    for (0..100) |_| {
        try std.testing.expectEqual(splitmix64(&seed1), splitmix64(&seed2));
    }
}
