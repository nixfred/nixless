//! Host-side tests for the GGUF parser (`zig build test`): the fixture parses,
//! every truncation is rejected, and thousands of mutated copies never read
//! outside the file (the test build keeps safety checks on, so a stray index panics).
const std = @import("std");
const gguf = @import("gguf.zig");

test {
    _ = @import("qwen3_test.zig");
}

const fixture: []const u8 = @embedFile("tiny.gguf");
var model: gguf.Model = undefined;

test "fixture parses and exposes its metadata" {
    try gguf.parse(fixture, &model);
    try std.testing.expectEqual(@as(usize, 5), model.tensor_count);
    try std.testing.expectEqualStrings("nixless-test", model.findString("general.architecture").?);
    try std.testing.expectEqual(@as(u64, 42), model.findUint("nixless.test.u32").?);
    try std.testing.expectEqual(@as(i64, 200901), model.findInt("nixless.test.int_checksum").?);
    const arr = model.find("nixless.test.strs").?.array;
    try std.testing.expectEqual(@as(u64, 3), arr.count);
    const w = model.tensor("test.w").?;
    try std.testing.expectEqual(@as(u64, 32 * 4 * 34), w.nbytes);
    try std.testing.expectEqual(@as(usize, 32 * 4 * 34), model.bytes(w).len);
    try std.testing.expect(model.tensor("nope") == null);
    try std.testing.expect(gguf.firstUnsupported(&model) == null);
}

test "every truncation is rejected" {
    var n: usize = 0;
    while (n < fixture.len) : (n += 1) {
        try std.testing.expect(std.meta.isError(gguf.parse(fixture[0..n], &model)));
    }
}

test "mutated files never escape" {
    var buf: [fixture.len]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x6e69786c657373);
    const rnd = prng.random();
    var accepted: usize = 0;
    for (0..30000) |_| {
        @memcpy(&buf, fixture);
        const flips = rnd.intRangeAtMost(usize, 1, 4);
        for (0..flips) |_| {
            // Bias toward the header and tables, where the parser's decisions live.
            const at = if (rnd.boolean()) rnd.uintLessThan(usize, 400) else rnd.uintLessThan(usize, buf.len);
            buf[at] = rnd.int(u8);
        }
        if (gguf.parse(&buf, &model)) |_| {
            accepted += 1;
            for (model.tensors[0..model.tensor_count]) |*t| {
                if (t.nbytes == 0) continue;
                const b = model.bytes(t);
                std.mem.doNotOptimizeAway(b[0] +% b[b.len - 1]);
            }
            _ = model.find("general.architecture");
        } else |_| {}
    }
    try std.testing.expect(accepted > 0); // mutations in the data section stay valid
}
