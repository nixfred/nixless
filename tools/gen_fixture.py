# /// script
# requires-python = ">=3.10"
# dependencies = ["gguf", "numpy"]
# ///
"""Writes tests/fixtures/tiny.gguf: a small synthetic GGUF with every metadata
shape the parser must handle and one Q8_0 matmul case with its expected output.

The expected values come from the `gguf` package's own quantizer and NumPy, not
from Nixless code. The dot product follows the ggml Q8_0 recipe: the activation
vector is quantized to Q8_0 too, each 32-wide block gives an exact int32 dot,
and the float part follows ggml's generic path: sum += isum * (d_w * d_x), float32,
block order, row by row, no fused multiply-add.

Run:  uv run tools/gen_fixture.py
"""
import sys
from pathlib import Path

import numpy as np
from gguf import GGMLQuantizationType as Q
from gguf import GGUFWriter
from gguf.quants import quantize

ROWS, COLS, BLOCK = 32, 128, 32
out = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "tiny.gguf"

rng = np.random.default_rng(20261126)
w = rng.standard_normal((ROWS, COLS)).astype(np.float32)
x = rng.standard_normal(COLS).astype(np.float32)

wq = quantize(w, Q.Q8_0)  # uint8 bytes, shape (ROWS, COLS/32*34)
xq = quantize(x, Q.Q8_0)


def blocks(q, n_blocks):
    """Split raw Q8_0 bytes into (scale f32 per block, int8 quants per block)."""
    raw = np.ascontiguousarray(q).reshape(-1, 34)
    d = raw[:, :2].copy().view(np.float16).astype(np.float32).reshape(-1)
    qs = raw[:, 2:].copy().view(np.int8).reshape(-1, BLOCK)
    assert d.shape[0] == n_blocks
    return d, qs


nb = COLS // BLOCK
wd, wqs = blocks(wq, ROWS * nb)
xd, xqs = blocks(xq, nb)
wd = wd.reshape(ROWS, nb)
wqs = wqs.reshape(ROWS, nb, BLOCK)

y = np.zeros(ROWS, dtype=np.float32)
checksum = 0
for r in range(ROWS):
    acc = np.float32(0)
    for b in range(nb):
        isum = int(np.sum(wqs[r, b].astype(np.int32) * xqs[b].astype(np.int32)))
        checksum += isum
        t = np.float32(isum) * (np.float32(wd[r, b]) * np.float32(xd[b]))
        acc = np.float32(acc + t)
    y[r] = acc

g = GGUFWriter(str(out), "nixless-test")
g.add_name("tiny")
g.add_uint32("nixless.test.u32", 42)
g.add_float32("nixless.test.f32", 1.5)
g.add_bool("nixless.test.bool", True)
g.add_string("nixless.test.str", "hello gguf")
g.add_array("nixless.test.strs", ["a", "bc", "def"])
g.add_array("nixless.test.u32s", [1, 2, 3, 4])
g.add_uint32("nixless.test.rows", ROWS)
g.add_uint32("nixless.test.cols", COLS)
g.add_int64("nixless.test.int_checksum", checksum)
g.add_tensor("test.norm", np.linspace(-1, 1, 64, dtype=np.float32))
g.add_tensor("test.f16", np.linspace(-2, 2, 64, dtype=np.float16))
g.add_tensor("test.w", wq, raw_dtype=Q.Q8_0)
g.add_tensor("test.x", x)
g.add_tensor("test.y", y)
g.write_header_to_file()
g.write_kv_data_to_file()
g.write_tensors_to_file()
g.close()
print(f"wrote {out} ({out.stat().st_size} bytes), int checksum {checksum}, y[0]={y[0]!r}", file=sys.stderr)


# Broken variants for the boot-fatal tests (PRD 14.7). Each must stop the kernel
# with its own FATAL code and never fault.
good = out.read_bytes()
fx = out.parent
(fx / "bad-magic.gguf").write_bytes(b"GGUX" + good[4:])
(fx / "truncated.gguf").write_bytes(good[: len(good) // 2])

t = GGUFWriter(str(fx / "bad-type.gguf"), "nixless-test")
t.add_name("bad-type")
t.add_tensor("blk.0.q4k", np.zeros((1, 144), dtype=np.uint8), raw_dtype=Q.Q4_K)
t.write_header_to_file()
t.write_kv_data_to_file()
t.write_tensors_to_file()
t.close()


# A small synthetic Qwen3: the real tensor names, the real shape quirks (attention
# width n_head*head_dim differs from n_embd, per-head q/k norms, no output.weight so
# the head is tied to token_embd), random Q8_0 weights. Used by the host tests for the
# hyperparameter and inventory checks, and later as a layer-by-layer forward-pass case.
N_LAYER, N_EMBD, N_HEAD, N_KV, HEAD_DIM, N_FF, VOCAB = 2, 64, 4, 2, 32, 128, 256


def write_mini_qwen3(path, *, arch="qwen3", drop=None, widen=None, tensors=True, keys=True):
    """`drop` omits one tensor; `widen` is (name, extra) and makes that tensor's
    first dimension `extra` elements wider (a shape error)."""
    r = np.random.default_rng(20261127)
    w = GGUFWriter(str(path), arch)
    w.add_name("mini")
    if keys and arch == "qwen3":
        p = "qwen3"
        w.add_uint32(f"{p}.block_count", N_LAYER)
        w.add_uint32(f"{p}.context_length", 512)
        w.add_uint32(f"{p}.embedding_length", N_EMBD)
        w.add_uint32(f"{p}.feed_forward_length", N_FF)
        w.add_uint32(f"{p}.attention.head_count", N_HEAD)
        w.add_uint32(f"{p}.attention.head_count_kv", N_KV)
        w.add_float32(f"{p}.rope.freq_base", 1000000.0)
        w.add_float32(f"{p}.attention.layer_norm_rms_epsilon", 1e-6)
        w.add_uint32(f"{p}.attention.key_length", HEAD_DIM)
        w.add_uint32(f"{p}.attention.value_length", HEAD_DIM)
    if not tensors:
        w.write_header_to_file(); w.write_kv_data_to_file(); w.write_tensors_to_file(); w.close()
        return

    def add(name, cols, rows=None):
        if name == drop:
            return
        if widen and widen[0] == name:
            cols += widen[1]
        if rows is None:  # F32 vector
            w.add_tensor(name, (1.0 + 0.1 * r.standard_normal(cols)).astype(np.float32))
        else:
            w.add_tensor(name, quantize((0.2 * r.standard_normal((rows, cols))).astype(np.float32), Q.Q8_0), raw_dtype=Q.Q8_0)

    add("token_embd.weight", N_EMBD, VOCAB)
    add("output_norm.weight", N_EMBD)
    for i in range(N_LAYER):
        b = f"blk.{i}"
        add(f"{b}.attn_norm.weight", N_EMBD)
        add(f"{b}.attn_q.weight", N_EMBD, N_HEAD * HEAD_DIM)
        add(f"{b}.attn_k.weight", N_EMBD, N_KV * HEAD_DIM)
        add(f"{b}.attn_v.weight", N_EMBD, N_KV * HEAD_DIM)
        add(f"{b}.attn_q_norm.weight", HEAD_DIM)
        add(f"{b}.attn_k_norm.weight", HEAD_DIM)
        add(f"{b}.attn_output.weight", N_HEAD * HEAD_DIM, N_EMBD)
        add(f"{b}.ffn_norm.weight", N_EMBD)
        add(f"{b}.ffn_gate.weight", N_EMBD, N_FF)
        add(f"{b}.ffn_up.weight", N_EMBD, N_FF)
        add(f"{b}.ffn_down.weight", N_FF, N_EMBD)
    w.write_header_to_file()
    w.write_kv_data_to_file()
    w.write_tensors_to_file()
    w.close()


write_mini_qwen3(fx / "mini-qwen3.gguf")
write_mini_qwen3(fx / "qwen3-bad-shape.gguf", widen=("blk.1.attn_q.weight", 32))
write_mini_qwen3(fx / "qwen3-missing.gguf", drop="blk.1.ffn_down.weight")
write_mini_qwen3(fx / "bad-arch.gguf", arch="llama", tensors=False)
write_mini_qwen3(fx / "qwen3-no-hparams.gguf", keys=False, tensors=False)
print("wrote mini-qwen3 fixtures", file=sys.stderr)
