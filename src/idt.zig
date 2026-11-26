//! IDT with a handler on every CPU exception vector (0..31). All exceptions
//! are fatal in M1 and go to the panic procedure (PRD 6b).
const gdt = @import("gdt.zig");
const panic_mod = @import("panic.zig");

const Entry = extern struct {
    offset_lo: u16 = 0,
    selector: u16 = 0,
    ist: u8 = 0,
    type_attr: u8 = 0,
    offset_mid: u16 = 0,
    offset_hi: u32 = 0,
    zero: u32 = 0,
};

const Idtr = packed struct { limit: u16, base: u64 };

extern const isr_table: [32]u64;

var idt: [256]Entry align(16) = [_]Entry{.{}} ** 256;

fn istFor(vector: usize) u8 {
    return switch (vector) {
        2 => gdt.IST_NMI,
        8 => gdt.IST_DOUBLE_FAULT,
        18 => gdt.IST_MACHINE_CHECK,
        else => 0,
    };
}

pub fn init() void {
    for (0..32) |v| {
        const h = isr_table[v];
        idt[v] = .{
            .offset_lo = @truncate(h),
            .selector = gdt.KERNEL_CS,
            .ist = istFor(v),
            .type_attr = 0x8E, // present, DPL 0, 64-bit interrupt gate
            .offset_mid = @truncate(h >> 16),
            .offset_hi = @truncate(h >> 32),
        };
    }
    const idtr: Idtr = .{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&idtr),
        : .{ .memory = true });
}

/// Register frame built by isr_common (lowest address first).
pub const Frame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rbx: u64,
    rdx: u64,
    rcx: u64,
    rax: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

export fn exception_dispatch(frame: *Frame) callconv(.c) void {
    panic_mod.exceptionPanic(frame);
}
