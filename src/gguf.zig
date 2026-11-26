//! GGUF v3 reader (PRD section 9). Works in place on the bytes the loader
//! delivered: nothing is copied and nothing is allocated. Every read is bounds
//! checked, so a truncated or hostile file gives an error, never a fault.
//! Format: ggml repository, docs/gguf.md.
const std = @import("std");
const serial = @import("serial.zig");

pub const MAX_TENSORS = 1024;
pub const MAX_DIMS = 4;
const DEFAULT_ALIGNMENT = 32;

pub const Error = error{ BadMagic, BadVersion, Truncated, BadValue, TooMany, BadTensor, BadAlignment };

/// ggml tensor types. Only the first three are loadable in v1 (PRD 9).
pub const TensorType = enum(u32) { f32 = 0, f16 = 1, q8_0 = 8, _ };

pub const ValueType = enum(u32) { u8 = 0, i8, u16, i16, u32, i32, f32, bool, string, array, u64, i64, f64, _ };

pub const Tensor = struct {
    name: []const u8,
    kind: u32,
    n_dims: u32,
    ne: [MAX_DIMS]u64,
    /// Offset from the start of the data section.
    offset: u64,
    /// Size in bytes (0 until the type is supported).
    nbytes: u64,
    pub fn elements(self: Tensor) u64 {
        var n: u64 = 1;
        for (self.ne[0..self.n_dims]) |d| n *= d;
        return n;
    }
};

/// Block geometry of a supported type, or null.
pub fn blockInfo(kind: u32) ?struct { elems: u64, bytes: u64 } {
    return switch (kind) {
        0 => .{ .elems = 1, .bytes = 4 },
        1 => .{ .elems = 1, .bytes = 2 },
        8 => .{ .elems = 32, .bytes = 34 },
        else => null,
    };
}

pub fn typeName(kind: u32) []const u8 {
    return switch (kind) {
        0 => "F32",
        1 => "F16",
        2 => "Q4_0",
        3 => "Q4_1",
        6 => "Q5_0",
        7 => "Q5_1",
        8 => "Q8_0",
        10 => "Q2_K",
        11 => "Q3_K",
        12 => "Q4_K",
        13 => "Q5_K",
        14 => "Q6_K",
        15 => "Q8_K",
        30 => "BF16",
        else => "unknown",
    };
}

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn take(r: *Reader, n: u64) Error![]const u8 {
        if (n > r.buf.len - r.pos) return error.Truncated;
        const s = r.buf[r.pos..][0..@intCast(n)];
        r.pos += @intCast(n);
        return s;
    }
    fn int(r: *Reader, comptime T: type) Error!T {
        const s = try r.take(@sizeOf(T));
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }
    fn string(r: *Reader) Error![]const u8 {
        const n = try r.int(u64);
        return r.take(n);
    }
};

pub const Value = union(enum) {
    uint: u64,
    int: i64,
    float: f64,
    boolean: bool,
    string: []const u8,
    /// Element type and count; the elements stay in the file.
    array: struct { elem: u32, count: u64, start: usize },
};

/// Fixed-size scalars skip in one step; strings and nested arrays walk.
fn scalarSize(t: u32) ?u64 {
    return switch (t) {
        0, 1, 7 => 1,
        2, 3 => 2,
        4, 5, 6 => 4,
        10, 11, 12 => 8,
        else => null,
    };
}

fn skipValue(r: *Reader, t: u32, depth: u32) Error!void {
    if (scalarSize(t)) |n| {
        _ = try r.take(n);
        return;
    }
    switch (t) {
        8 => _ = try r.string(),
        9 => {
            if (depth >= 2) return error.BadValue;
            const et = try r.int(u32);
            const n = try r.int(u64);
            if (scalarSize(et)) |sz| {
                const total = std.math.mul(u64, sz, n) catch return error.Truncated;
                _ = try r.take(total);
            } else {
                var i: u64 = 0;
                while (i < n) : (i += 1) try skipValue(r, et, depth + 1);
            }
        },
        else => return error.BadValue,
    }
}

fn readValue(r: *Reader, t: u32) Error!Value {
    return switch (t) {
        0 => .{ .uint = try r.int(u8) },
        1 => .{ .int = try r.int(i8) },
        2 => .{ .uint = try r.int(u16) },
        3 => .{ .int = try r.int(i16) },
        4 => .{ .uint = try r.int(u32) },
        5 => .{ .int = try r.int(i32) },
        6 => .{ .float = @as(f32, @bitCast(try r.int(u32))) },
        7 => blk: {
            const b = try r.int(u8);
            if (b > 1) return error.BadValue;
            break :blk .{ .boolean = b == 1 };
        },
        8 => .{ .string = try r.string() },
        9 => blk: {
            const et = try r.int(u32);
            const n = try r.int(u64);
            const start = r.pos;
            var i: u64 = 0;
            if (scalarSize(et)) |sz| {
                _ = try r.take(std.math.mul(u64, sz, n) catch return error.Truncated);
            } else while (i < n) : (i += 1) try skipValue(r, et, 1);
            break :blk .{ .array = .{ .elem = et, .count = n, .start = start } };
        },
        10 => .{ .uint = try r.int(u64) },
        11 => .{ .int = try r.int(i64) },
        12 => .{ .float = @as(f64, @bitCast(try r.int(u64))) },
        else => error.BadValue,
    };
}

pub const Model = struct {
    file: []const u8,
    version: u32,
    kv_count: u64,
    kv_start: usize,
    tensor_count: usize,
    alignment: u64,
    /// File offset of the tensor data section.
    data_start: usize,
    tensors: [MAX_TENSORS]Tensor,

    pub fn tensor(self: *const Model, name: []const u8) ?*const Tensor {
        for (self.tensors[0..self.tensor_count]) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }

    /// The tensor's bytes, inside the file.
    pub fn bytes(self: *const Model, t: *const Tensor) []const u8 {
        return self.file[self.data_start + @as(usize, @intCast(t.offset)) ..][0..@intCast(t.nbytes)];
    }

    /// Look a metadata key up. Linear scan: used at load time, not per token.
    pub fn find(self: *const Model, key: []const u8) ?Value {
        var r: Reader = .{ .buf = self.file, .pos = self.kv_start };
        var i: u64 = 0;
        while (i < self.kv_count) : (i += 1) {
            const k = r.string() catch return null;
            const t = r.int(u32) catch return null;
            if (std.mem.eql(u8, k, key)) return readValue(&r, t) catch null;
            skipValue(&r, t, 0) catch return null;
        }
        return null;
    }

    pub fn findString(self: *const Model, key: []const u8) ?[]const u8 {
        const v = self.find(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn findInt(self: *const Model, key: []const u8) ?i64 {
        const v = self.find(key) orelse return null;
        return switch (v) {
            .int => |i| i,
            .uint => |u| @bitCast(u),
            else => null,
        };
    }

    pub fn findUint(self: *const Model, key: []const u8) ?u64 {
        const v = self.find(key) orelse return null;
        return switch (v) {
            .uint => |u| u,
            else => null,
        };
    }
};

/// Parse and validate. The header, every key/value, every tensor info and
/// every tensor byte range are checked; a file that passes cannot make the
/// engine read outside itself.
pub fn parse(file: []const u8, out: *Model) Error!void {
    var r: Reader = .{ .buf = file };
    const magic = try r.take(4);
    if (!std.mem.eql(u8, magic, "GGUF")) return error.BadMagic;
    const version = try r.int(u32);
    if (version != 3) return error.BadVersion;
    const tensor_count = try r.int(u64);
    const kv_count = try r.int(u64);
    // Each tensor info and key/value takes well over 8 bytes: this rejects absurd counts cheaply.
    if (tensor_count > MAX_TENSORS) return error.TooMany;
    if (kv_count > file.len / 8) return error.Truncated;

    out.file = file;
    out.version = version;
    out.kv_count = kv_count;
    out.kv_start = r.pos;
    out.tensor_count = @intCast(tensor_count);
    out.alignment = DEFAULT_ALIGNMENT;

    var i: u64 = 0;
    while (i < kv_count) : (i += 1) {
        const k = try r.string();
        const t = try r.int(u32);
        if (std.mem.eql(u8, k, "general.alignment")) {
            const v = try readValue(&r, t);
            switch (v) {
                .uint => |a| {
                    if (a == 0 or a > 4096 or (a & (a - 1)) != 0) return error.BadAlignment;
                    out.alignment = a;
                },
                else => return error.BadAlignment,
            }
        } else try skipValue(&r, t, 0);
    }

    for (0..out.tensor_count) |n| {
        const name = try r.string();
        const n_dims = try r.int(u32);
        if (n_dims == 0 or n_dims > MAX_DIMS) return error.BadTensor;
        var ne = [_]u64{1} ** MAX_DIMS;
        for (0..n_dims) |d| {
            ne[d] = try r.int(u64);
            if (ne[d] == 0) return error.BadTensor;
        }
        const kind = try r.int(u32);
        const offset = try r.int(u64);
        out.tensors[n] = .{ .name = name, .kind = kind, .n_dims = n_dims, .ne = ne, .offset = offset, .nbytes = 0 };
    }

    const a: usize = @intCast(out.alignment);
    out.data_start = (r.pos + a - 1) / a * a;
    if (out.data_start > file.len) return error.Truncated;
    const data_len: u64 = file.len - out.data_start;

    // Sizes and ranges. Types the engine cannot run keep nbytes 0 and are
    // reported by `firstUnsupported`; their ranges are not trusted either way.
    for (out.tensors[0..out.tensor_count]) |*t| {
        const bi = blockInfo(t.kind) orelse continue;
        var n: u64 = 1;
        for (t.ne[0..t.n_dims]) |d| n = std.math.mul(u64, n, d) catch return error.BadTensor;
        if (t.ne[0] % bi.elems != 0) return error.BadTensor;
        const size = std.math.mul(u64, n / bi.elems, bi.bytes) catch return error.BadTensor;
        if (t.offset % out.alignment != 0) return error.BadTensor;
        const end = std.math.add(u64, t.offset, size) catch return error.BadTensor;
        if (end > data_len) return error.Truncated;
        t.nbytes = size;
    }
}

/// First tensor whose type the engine cannot run, if any.
pub fn firstUnsupported(m: *const Model) ?*const Tensor {
    for (m.tensors[0..m.tensor_count]) |*t| {
        if (blockInfo(t.kind) == null) return t;
    }
    return null;
}

pub fn print(m: *const Model) void {
    serial.write("gguf: v");
    serial.dec(m.version);
    serial.write(", ");
    serial.dec(m.kv_count);
    serial.write(" keys, ");
    serial.dec(m.tensor_count);
    serial.write(" tensors, align ");
    serial.dec(m.alignment);
    serial.write(", ");
    serial.dec(m.file.len);
    serial.write(" bytes\n");
    if (m.findString("general.architecture")) |a| {
        serial.write("gguf: arch ");
        serial.write(a);
        if (m.findString("general.name")) |n| {
            serial.write(", name ");
            serial.write(n);
        }
        serial.write("\n");
    }
}
