//! Model loading: find the boot module, parse the GGUF in place, and run the
//! built-in matmul test when the file is the test fixture. Every failure is a
//! boot-fatal with a stable code (PRD 6b): one line, then halt.
const cpu = @import("cpu.zig");
const gguf = @import("gguf.zig");
const mb2 = @import("mb2.zig");
const quant = @import("quant.zig");
const serial = @import("serial.zig");
const std = @import("std");

var model: gguf.Model = undefined;

pub fn fatal(code: []const u8, detail: []const u8) noreturn {
    serial.write("nixless: FATAL ");
    serial.write(code);
    serial.write(": ");
    serial.write(detail);
    serial.write("\n");
    cpu.haltForever();
}

fn parseError(e: gguf.Error) []const u8 {
    return switch (e) {
        error.BadMagic => "not a GGUF file (bad magic)",
        error.BadVersion => "unsupported GGUF version (need 3)",
        error.Truncated => "file is truncated or a range runs past its end",
        error.BadValue => "bad metadata value type",
        error.TooMany => "too many tensors",
        error.BadTensor => "bad tensor info (dims, size or offset)",
        error.BadAlignment => "bad general.alignment",
    };
}

/// Load and validate the model module. Returns the parsed model.
pub fn load(info: *const mb2.Info) *const gguf.Model {
    if (info.module_count == 0) fatal("E_NO_MODEL", "no boot module (module2 in grub.cfg)");
    var m = info.modules[0];
    for (info.modules[0..info.module_count]) |c| {
        if (std.mem.eql(u8, c.cmdline, "model")) m = c;
    }
    const file: []const u8 = @as([*]const u8, @ptrFromInt(m.start))[0 .. m.end - m.start];
    gguf.parse(file, &model) catch |e| fatal("E_GGUF_BAD", parseError(e));
    if (gguf.firstUnsupported(&model)) |t| {
        serial.write("nixless: FATAL E_GGUF_TYPE: tensor ");
        serial.write(t.name);
        serial.write(" has type ");
        serial.write(gguf.typeName(t.kind));
        serial.write(" (");
        serial.dec(t.kind);
        serial.write(")\n");
        cpu.haltForever();
    }
    gguf.print(&model);
    return &model;
}

// Static work buffers for the self-test (the test matrix is 32 x 128).
var act: [64]quant.ActBlock = undefined;
var xf: [2048]f32 = undefined;
var yf: [256]f32 = undefined;

fn rd32(b: []const u8, i: usize) f32 {
    return @bitCast(std.mem.readInt(u32, b[i * 4 ..][0..4], .little));
}

fn relErrPpm(a: f32, b: f32) u64 {
    const d = if (a > b) a - b else b - a;
    const m = if (b < 0) -b else b;
    if (m == 0) return if (d == 0) 0 else 1_000_000;
    return @intFromFloat(d / m * 1_000_000.0);
}

/// If the file is the Nixless test fixture, run its Q8_0 matmul and compare to
/// the expected values stored in the file (made by NumPy, see tools/gen_fixture.py).
pub fn selfTest(m: *const gguf.Model) void {
    const arch = m.findString("general.architecture") orelse return;
    if (!std.mem.eql(u8, arch, "nixless-test")) return;
    const rows: usize = @intCast(m.findUint("nixless.test.rows") orelse fatal("E_GGUF_BAD", "fixture: no rows"));
    const cols: usize = @intCast(m.findUint("nixless.test.cols") orelse fatal("E_GGUF_BAD", "fixture: no cols"));
    const w = m.tensor("test.w") orelse fatal("E_GGUF_BAD", "fixture: no test.w");
    const x = m.tensor("test.x") orelse fatal("E_GGUF_BAD", "fixture: no test.x");
    const y = m.tensor("test.y") orelse fatal("E_GGUF_BAD", "fixture: no test.y");
    if (cols > xf.len or cols / quant.BLOCK > act.len or rows > yf.len) fatal("E_GGUF_BAD", "fixture too large for the self-test");
    if (w.kind != 8 or w.ne[0] != cols or w.ne[1] != rows or x.elements() != cols or y.elements() != rows)
        fatal("E_GGUF_BAD", "fixture: tensor shapes do not match");

    const xb = m.bytes(x);
    for (0..cols) |i| xf[i] = rd32(xb, i);
    const nb = cols / quant.BLOCK;
    quant.quantizeRow(xf[0..cols], act[0..nb]);
    const sum = quant.matvecQ8(m.bytes(w), rows, cols, act[0..nb], &yf);

    const want_sum: i64 = m.findInt("nixless.test.int_checksum") orelse fatal("E_GGUF_BAD", "fixture: no checksum");
    const yb = m.bytes(y);
    var worst: u64 = 0;
    for (0..rows) |r| {
        const e = relErrPpm(yf[r], rd32(yb, r));
        if (e > worst) worst = e;
    }
    serial.write("matmul: q8_0 ");
    serial.dec(rows);
    serial.write("x");
    serial.dec(cols);
    serial.write(" int checksum ");
    serial.dec(@intCast(sum));
    serial.write(if (sum == want_sum) " exact, worst rel error " else " WRONG, worst rel error ");
    serial.dec(worst);
    serial.write(" ppm (limit 10)\n");
    if (sum != want_sum or worst > 10) fatal("E_SELFTEST", "q8_0 matmul does not match NumPy");
    serial.write("matmul: ok vs NumPy\n");

    // The AVX2 kernel must give the very same bits as the reference.
    if (quant.haveAvx2()) {
        var ya: [256]f32 = undefined;
        const sum2 = quant.matvecQ8Avx2(m.bytes(w), rows, cols, act[0..nb], &ya);
        var same = sum2 == sum;
        for (0..rows) |r| {
            if (@as(u32, @bitCast(ya[r])) != @as(u32, @bitCast(yf[r]))) same = false;
        }
        serial.write(if (same) "matmul: avx2 kernel bit-identical to the reference\n" else "matmul: avx2 kernel DIFFERS from the reference\n");
        if (!same) fatal("E_SELFTEST", "q8_0 avx2 kernel differs from the reference");
    } else serial.write("matmul: avx2 not available, reference only\n");
}
