//! Host-side tests for the Qwen3 hyperparameter and inventory checks. The fixtures
//! are small synthetic models (tools/gen_fixture.py) with the real tensor names
//! and the real shape quirks, plus broken variants that must be refused with a
//! stable code that names the culprit.
const std = @import("std");
const gguf = @import("gguf.zig");
const qwen3 = @import("qwen3.zig");

var model: gguf.Model = undefined;
var weights: qwen3.Weights = undefined;

fn check(file: []const u8) !qwen3.Problem {
    try gguf.parse(file, &model);
    var p: qwen3.Problem = .{};
    qwen3.fromModel(&model, &weights, &p) catch return p;
    return .{};
}

test "the mini model passes and the config reads back" {
    const p = try check(@embedFile("mini-qwen3.gguf"));
    try std.testing.expectEqualStrings("", p.code);
    const c = weights.cfg;
    try std.testing.expectEqual(@as(u32, 2), c.n_layer);
    try std.testing.expectEqual(@as(u32, 64), c.n_embd);
    try std.testing.expectEqual(@as(u32, 128), c.n_ff);
    try std.testing.expectEqual(@as(u32, 4), c.n_head);
    try std.testing.expectEqual(@as(u32, 2), c.n_kv);
    try std.testing.expectEqual(@as(u32, 32), c.head_dim);
    try std.testing.expectEqual(@as(u32, 256), c.vocab);
    try std.testing.expectEqual(@as(f32, 1000000.0), c.rope_base);
    try std.testing.expect(c.tied);
    // attention is wider than the embedding, like the real 0.6B (2048 vs 1024).
    try std.testing.expectEqual(@as(u32, 128), c.attnWidth());
    try std.testing.expect(weights.out == weights.tok_embd);
    try std.testing.expectEqual(@as(u64, 128), weights.layers[1].wq.ne[1]);
    try std.testing.expectEqual(@as(u64, 128), weights.layers[1].wo.ne[0]);
    try std.testing.expect(weights.weight_bytes > 100_000);
}

test "a file that is not qwen3 is refused as an unsupported architecture" {
    const p = try check(@embedFile("bad-arch.gguf"));
    try std.testing.expectEqualStrings("E_ARCH_UNSUPPORTED", p.code);
    try std.testing.expectEqualStrings("llama", p.subject);
}

test "missing hyperparameter keys name the first one missing" {
    const p = try check(@embedFile("qwen3-no-hparams.gguf"));
    try std.testing.expectEqualStrings("E_MODEL_KEY", p.code);
    try std.testing.expectEqualStrings("qwen3.block_count", p.subject);
}

test "a wrong tensor shape names the tensor and both shapes" {
    const p = try check(@embedFile("qwen3-bad-shape.gguf"));
    try std.testing.expectEqualStrings("E_MODEL_SHAPE", p.code);
    try std.testing.expectEqualStrings("blk.1.attn_q.weight", p.subject);
    try std.testing.expect(std.mem.indexOf(u8, p.what, "expected 64 x 128") != null);
}

test "a missing tensor names the tensor" {
    const p = try check(@embedFile("qwen3-missing.gguf"));
    try std.testing.expectEqualStrings("E_MODEL_MISSING", p.code);
    try std.testing.expectEqualStrings("blk.1.ffn_down.weight", p.subject);
}

test "the test fixture is not a qwen3" {
    const p = try check(@embedFile("tiny.gguf"));
    try std.testing.expectEqualStrings("E_ARCH_UNSUPPORTED", p.code);
}
