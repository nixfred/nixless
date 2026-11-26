//! Qwen3 hyperparameters and tensor inventory (PRD section 9, M3 step a).
//! Reads the architecture's keys from the GGUF, finds every tensor the forward
//! pass will touch, and checks type and shape, so the engine never meets a
//! surprise. A mismatch comes back as a `Problem` with a stable code and the
//! name of the key or tensor, never as a fault later.
//!
//! Shape convention (GGUF): `ne[0]` is the input width (columns of the weight
//! matrix), `ne[1]` the output width (rows). Matrices are Q8_0, norms are F32.
//! Attention width `n_head * head_dim` need not equal `n_embd` (0.6B: 2048 vs 1024).
const std = @import("std");
const gguf = @import("gguf.zig");
const serial = @import("serial.zig");

pub const MAX_LAYERS = 64;
const F32 = 0;
const Q8_0 = 8;

pub const Config = struct {
    n_layer: u32,
    n_embd: u32,
    n_ff: u32,
    n_head: u32,
    n_kv: u32,
    head_dim: u32,
    n_ctx_train: u32,
    vocab: u32,
    rope_base: f32,
    eps: f32,
    /// Output head shares token_embd (no output.weight in the file).
    tied: bool,

    pub fn attnWidth(c: Config) u32 {
        return c.n_head * c.head_dim;
    }
    pub fn kvWidth(c: Config) u32 {
        return c.n_kv * c.head_dim;
    }
};

pub const Layer = struct {
    attn_norm: *const gguf.Tensor,
    wq: *const gguf.Tensor,
    wk: *const gguf.Tensor,
    wv: *const gguf.Tensor,
    q_norm: *const gguf.Tensor,
    k_norm: *const gguf.Tensor,
    wo: *const gguf.Tensor,
    ffn_norm: *const gguf.Tensor,
    w_gate: *const gguf.Tensor,
    w_up: *const gguf.Tensor,
    w_down: *const gguf.Tensor,
};

pub const Weights = struct {
    cfg: Config,
    tok_embd: *const gguf.Tensor,
    out_norm: *const gguf.Tensor,
    /// The output projection: output.weight, or token_embd when tied.
    out: *const gguf.Tensor,
    layers: [MAX_LAYERS]Layer,
    /// Total bytes of every tensor in the file.
    weight_bytes: u64,
};

/// Why a model was refused. `code` is the stable FATAL code; `subject` is the
/// key or tensor name; `what` says what is wrong. All text lives in `buf` or in
/// string literals, so the Problem can be printed after the call returns.
pub const Problem = struct {
    code: []const u8 = "",
    subject: []const u8 = "",
    what: []const u8 = "",
    buf: [160]u8 = undefined,
    name: [48]u8 = undefined,

    fn set(p: *Problem, code: []const u8, subject: []const u8, what: []const u8) error{Invalid} {
        p.code = code;
        const n = @min(subject.len, p.name.len);
        @memcpy(p.name[0..n], subject[0..n]);
        p.subject = p.name[0..n];
        p.what = what;
        return error.Invalid;
    }
    fn setFmt(p: *Problem, code: []const u8, subject: []const u8, comptime fmt: []const u8, args: anytype) error{Invalid} {
        const text = std.fmt.bufPrint(&p.buf, fmt, args) catch "(detail too long)";
        return p.set(code, subject, text);
    }
};

// Sanity ceilings: the engine's static buffers are sized from these.
const MAX_EMBD = 8192;
const MAX_FF = 32768;
const MAX_HEAD = 128;
const MAX_HEAD_DIM = 256;
const MAX_VOCAB = 1 << 20;

fn key(m: *const gguf.Model, p: *Problem, comptime name: []const u8) error{Invalid}!u32 {
    const v = m.findUint("qwen3." ++ name) orelse return p.set("E_MODEL_KEY", "qwen3." ++ name, "missing or not an unsigned integer");
    if (v == 0 or v > std.math.maxInt(u32)) return p.set("E_MODEL_KEY", "qwen3." ++ name, "out of range");
    return @intCast(v);
}

fn keyFloat(m: *const gguf.Model, p: *Problem, comptime name: []const u8) error{Invalid}!f32 {
    const v = m.find("qwen3." ++ name) orelse return p.set("E_MODEL_KEY", "qwen3." ++ name, "missing");
    const f: f64 = switch (v) {
        .float => |x| x,
        else => return p.set("E_MODEL_KEY", "qwen3." ++ name, "not a float"),
    };
    if (!(f > 0) or f > 1e12) return p.set("E_MODEL_KEY", "qwen3." ++ name, "out of range");
    return @floatCast(f);
}

fn typeLetters(kind: u32) []const u8 {
    return gguf.typeName(kind);
}

/// Find `name` and check it is a `kind` tensor with exactly these dimensions.
fn want(m: *const gguf.Model, p: *Problem, name: []const u8, kind: u32, dims: []const u64) error{Invalid}!*const gguf.Tensor {
    const t = m.tensor(name) orelse return p.set("E_MODEL_MISSING", name, "tensor not found");
    if (t.kind != kind) {
        return p.setFmt("E_MODEL_SHAPE", name, "type {s}, expected {s}", .{ typeLetters(t.kind), typeLetters(kind) });
    }
    var ok = t.n_dims == dims.len;
    if (ok) {
        for (dims, 0..) |d, i| {
            if (t.ne[i] != d) ok = false;
        }
    }
    if (!ok) {
        if (dims.len == 1) {
            return p.setFmt("E_MODEL_SHAPE", name, "{d} dims, ne0 {d}; expected 1 dim of {d}", .{ t.n_dims, t.ne[0], dims[0] });
        }
        return p.setFmt("E_MODEL_SHAPE", name, "{d} dims, ne {d} x {d}; expected {d} x {d}", .{ t.n_dims, t.ne[0], t.ne[1], dims[0], dims[1] });
    }
    return t;
}

fn layerName(buf: []u8, i: usize, comptime suffix: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "blk.{d}." ++ suffix, .{i}) catch unreachable;
}

/// Read the hyperparameters and the tensor inventory. On failure `p` says why.
pub fn fromModel(m: *const gguf.Model, w: *Weights, p: *Problem) error{Invalid}!void {
    const arch = m.findString("general.architecture") orelse return p.set("E_ARCH_UNSUPPORTED", "general.architecture", "missing");
    if (!std.mem.eql(u8, arch, "qwen3")) return p.set("E_ARCH_UNSUPPORTED", arch, "only qwen3 runs in this build");

    var c: Config = undefined;
    c.n_layer = try key(m, p, "block_count");
    c.n_embd = try key(m, p, "embedding_length");
    c.n_ff = try key(m, p, "feed_forward_length");
    c.n_head = try key(m, p, "attention.head_count");
    c.n_kv = try key(m, p, "attention.head_count_kv");
    c.head_dim = try key(m, p, "attention.key_length");
    c.n_ctx_train = try key(m, p, "context_length");
    c.rope_base = try keyFloat(m, p, "rope.freq_base");
    c.eps = try keyFloat(m, p, "attention.layer_norm_rms_epsilon");
    if ((try key(m, p, "attention.value_length")) != c.head_dim) return p.set("E_MODEL_KEY", "qwen3.attention.value_length", "must equal key_length");

    if (c.n_layer > MAX_LAYERS) return p.set("E_MODEL_KEY", "qwen3.block_count", "too many layers for this build");
    if (c.n_embd > MAX_EMBD or c.n_ff > MAX_FF or c.n_head > MAX_HEAD or c.head_dim > MAX_HEAD_DIM)
        return p.set("E_MODEL_KEY", "qwen3", "a dimension is beyond this build's limits");
    if (c.n_head % c.n_kv != 0) return p.set("E_MODEL_KEY", "qwen3.attention.head_count_kv", "head_count must be a multiple of it");
    if (c.head_dim % 2 != 0) return p.set("E_MODEL_KEY", "qwen3.attention.key_length", "must be even (rotary pairs)");
    // Every matmul input width must be whole Q8_0 blocks.
    const widths = [_]u32{ c.n_embd, c.n_ff, c.attnWidth() };
    for (widths) |x| {
        if (x % 32 != 0) return p.set("E_MODEL_KEY", "qwen3", "a matrix width is not a multiple of 32");
    }

    // Vocabulary size comes from the embedding table.
    const te = m.tensor("token_embd.weight") orelse return p.set("E_MODEL_MISSING", "token_embd.weight", "tensor not found");
    if (te.n_dims != 2 or te.ne[1] == 0 or te.ne[1] > MAX_VOCAB) return p.set("E_MODEL_SHAPE", "token_embd.weight", "not a 2-D table of sane size");
    c.vocab = @intCast(te.ne[1]);
    const tok_embd = try want(m, p, "token_embd.weight", Q8_0, &.{ c.n_embd, c.vocab });
    const out_norm = try want(m, p, "output_norm.weight", F32, &.{c.n_embd});

    c.tied = m.tensor("output.weight") == null;
    const out = if (c.tied) tok_embd else try want(m, p, "output.weight", Q8_0, &.{ c.n_embd, c.vocab });

    const aw: u64 = c.attnWidth();
    const kw: u64 = c.kvWidth();
    var nb: [48]u8 = undefined;
    for (0..c.n_layer) |i| {
        w.layers[i] = .{
            .attn_norm = try want(m, p, layerName(&nb, i, "attn_norm.weight"), F32, &.{c.n_embd}),
            .wq = try want(m, p, layerName(&nb, i, "attn_q.weight"), Q8_0, &.{ c.n_embd, aw }),
            .wk = try want(m, p, layerName(&nb, i, "attn_k.weight"), Q8_0, &.{ c.n_embd, kw }),
            .wv = try want(m, p, layerName(&nb, i, "attn_v.weight"), Q8_0, &.{ c.n_embd, kw }),
            .q_norm = try want(m, p, layerName(&nb, i, "attn_q_norm.weight"), F32, &.{c.head_dim}),
            .k_norm = try want(m, p, layerName(&nb, i, "attn_k_norm.weight"), F32, &.{c.head_dim}),
            .wo = try want(m, p, layerName(&nb, i, "attn_output.weight"), Q8_0, &.{ aw, c.n_embd }),
            .ffn_norm = try want(m, p, layerName(&nb, i, "ffn_norm.weight"), F32, &.{c.n_embd}),
            .w_gate = try want(m, p, layerName(&nb, i, "ffn_gate.weight"), Q8_0, &.{ c.n_embd, c.n_ff }),
            .w_up = try want(m, p, layerName(&nb, i, "ffn_up.weight"), Q8_0, &.{ c.n_embd, c.n_ff }),
            .w_down = try want(m, p, layerName(&nb, i, "ffn_down.weight"), Q8_0, &.{ c.n_ff, c.n_embd }),
        };
    }

    // Everything found must account for every tensor in the file: an unknown
    // extra tensor (a bias, an expert, a LoRA) means a model this engine would run wrong.
    const expected: usize = 2 + @as(usize, @intFromBool(!c.tied)) + 11 * @as(usize, c.n_layer);
    if (m.tensor_count != expected) {
        return p.setFmt("E_MODEL_SHAPE", "tensors", "file has {d}, a plain qwen3 of {d} layers has {d}", .{ m.tensor_count, c.n_layer, expected });
    }

    var total: u64 = 0;
    for (m.tensors[0..m.tensor_count]) |t| total += t.nbytes;
    w.cfg = c;
    w.tok_embd = tok_embd;
    w.out_norm = out_norm;
    w.out = out;
    w.weight_bytes = total;
}

/// One-line summary and the key sizes. Floats print as integers (no float formatting here).
pub fn print(w: *const Weights) void {
    const c = w.cfg;
    serial.write("qwen3: ");
    serial.dec(c.n_layer);
    serial.write(" layers, d ");
    serial.dec(c.n_embd);
    serial.write(", ff ");
    serial.dec(c.n_ff);
    serial.write(", heads ");
    serial.dec(c.n_head);
    serial.write("/");
    serial.dec(c.n_kv);
    serial.write(" kv x ");
    serial.dec(c.head_dim);
    serial.write(", vocab ");
    serial.dec(c.vocab);
    serial.write(", ctx ");
    serial.dec(c.n_ctx_train);
    serial.write(", rope base ");
    serial.dec(@intFromFloat(c.rope_base));
    serial.write(", eps ");
    serial.dec(@intFromFloat(c.eps * 1.0e9));
    serial.write("e-9, ");
    serial.write(if (c.tied) "tied head" else "own head");
    serial.write("\n");
    serial.write("qwen3: weights ");
    serial.dec(w.weight_bytes >> 20);
    serial.write(" MiB, KV cache (f16) ");
    serial.dec(2 * 2 * @as(u64, c.n_layer) * c.kvWidth() >> 10);
    serial.write(" KiB per token\n");
}
