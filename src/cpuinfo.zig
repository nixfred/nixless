//! CPUID probe and SIMD state enablement (PRD 3.2 step 6, section 11).
//! The kernel itself is SSE-free; this only turns on the register state so
//! the inference kernels can use AVX2 / AVX-512 later. Runs on every CPU.
const cpu = @import("cpu.zig");
const serial = @import("serial.zig");

pub const Features = struct {
    xsave: bool = false,
    avx: bool = false,
    avx2: bool = false,
    fma: bool = false,
    f16c: bool = false,
    avx512f: bool = false,
    avx512bw: bool = false,
    avx512vl: bool = false,
    avx512vnni: bool = false,
};

pub var features: Features = .{};
pub var xcr0: u64 = 0;

extern fn simd_selftest_avx2() void;
extern fn simd_selftest_avx512() void;

fn xsetbv(value: u64) void {
    asm volatile (".byte 0x0f, 0x01, 0xd1" // xsetbv
        :
        : [lo] "{eax}" (@as(u32, @truncate(value))),
          [hi] "{edx}" (@as(u32, @truncate(value >> 32))),
          [ecx] "{ecx}" (@as(u32, 0)),
        : .{ .memory = true });
}

pub fn probe() void {
    const l1 = cpu.cpuid(1, 0);
    const max = cpu.cpuid(0, 0).eax;
    var f: Features = .{};
    f.xsave = l1.ecx & (1 << 26) != 0;
    f.avx = l1.ecx & (1 << 28) != 0;
    f.fma = l1.ecx & (1 << 12) != 0;
    f.f16c = l1.ecx & (1 << 29) != 0;
    if (max >= 7) {
        const l7 = cpu.cpuid(7, 0);
        f.avx2 = l7.ebx & (1 << 5) != 0;
        f.avx512f = l7.ebx & (1 << 16) != 0;
        f.avx512bw = l7.ebx & (1 << 30) != 0;
        f.avx512vl = l7.ebx & (1 << 31) != 0;
        f.avx512vnni = l7.ecx & (1 << 11) != 0;
    }
    features = f;
}

/// Enable SSE/AVX/AVX-512 register state on the calling CPU.
pub fn enableSimdState() void {
    cpu.setCr4(cpu.cr4() | (1 << 9) | (1 << 10)); // OSFXSR, OSXMMEXCPT
    if (!features.xsave) return;
    cpu.setCr4(cpu.cr4() | (1 << 18)); // OSXSAVE
    const supported = cpu.cpuid(0xD, 0).eax;
    var want: u64 = 0x3; // x87 + SSE
    if (features.avx) want |= 0x4;
    if (features.avx512f) want |= 0xE0; // opmask, ZMM_Hi256, Hi16_ZMM
    xcr0 = want & supported;
    xsetbv(xcr0);
}

pub fn selfTest() void {
    if (features.avx2 and xcr0 & 0x4 != 0) simd_selftest_avx2();
    if (features.avx512f and xcr0 & 0xE0 == 0xE0) simd_selftest_avx512();
}

fn flag(name: []const u8, on: bool) void {
    if (!on) return;
    serial.write(" ");
    serial.write(name);
}

pub fn print() void {
    var brand: [48]u8 = undefined;
    for (0..3) |i| {
        const r = cpu.cpuid(@intCast(0x80000002 + i), 0);
        const words = [4]u32{ r.eax, r.ebx, r.ecx, r.edx };
        for (words, 0..) |w, j| {
            for (0..4) |k| brand[i * 16 + j * 4 + k] = @truncate(w >> @as(u5, @intCast(k * 8)));
        }
    }
    var s: []const u8 = &brand;
    while (s.len > 0 and (s[0] == ' ' or s[0] == 0)) s = s[1..];
    var n: usize = 0;
    while (n < s.len and s[n] != 0) n += 1;
    serial.write("cpu: ");
    serial.write(s[0..n]);
    serial.write("\nsimd:");
    flag("avx", features.avx);
    flag("avx2", features.avx2);
    flag("fma", features.fma);
    flag("f16c", features.f16c);
    flag("avx512f", features.avx512f);
    flag("avx512bw", features.avx512bw);
    flag("avx512vl", features.avx512vl);
    flag("avx512vnni", features.avx512vnni);
    serial.write(" (xcr0 ");
    serial.hex(xcr0);
    serial.write(")\n");
}
