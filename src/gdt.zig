//! Kernel GDT and TSS (Intel SDM Vol. 3 ch. 3 and 7). The TSS carries the IST
//! stacks so double fault, NMI and machine check run on known-good stacks and
//! a bad kernel stack gets reported instead of triple-faulting (PRD 6b).

pub const KERNEL_CS: u16 = 0x08;
pub const KERNEL_DS: u16 = 0x10;
const TSS_SEL: u16 = 0x18;

pub const IST_DOUBLE_FAULT: u3 = 1;
pub const IST_NMI: u3 = 2;
pub const IST_MACHINE_CHECK: u3 = 3;

const IST_STACK_SIZE = 16 * 1024;

/// Hardware layout (SDM Vol. 3 fig. 8-11): 64-bit fields sit at 4-byte
/// offsets, so this must be packed, not an extern struct.
const Tss = packed struct {
    reserved0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    iopb_offset: u16 = 104,
};

comptime {
    if (@bitSizeOf(Tss) != 104 * 8) @compileError("TSS must be 104 bytes");
}

const Gdt = extern struct {
    null_desc: u64 = 0,
    code: u64 = 0x00AF9A000000FFFF, // 64-bit code, DPL 0
    data: u64 = 0x00CF92000000FFFF, // data, DPL 0
    tss_lo: u64 = 0,
    tss_hi: u64 = 0,
};

const Gdtr = packed struct { limit: u16, base: u64 };

var tss: Tss align(16) = .{};
var gdt: Gdt align(16) = .{};
// Each slot is a 4 KiB guard page (left unmapped by vmm) then the stack.
const IST_SLOT = 4096 + IST_STACK_SIZE;
var ist_area: [3 * IST_SLOT]u8 align(4096) = undefined;

/// Tell the page tables which pages to leave unmapped. Call before vmm.init.
pub fn registerGuards(register: *const fn (u64) void) void {
    for (0..3) |i| register(@intFromPtr(&ist_area) + i * IST_SLOT);
}

fn istTop(i: usize) u64 {
    return @intFromPtr(&ist_area) + (i + 1) * IST_SLOT;
}

pub fn init() void {
    tss.ist1 = istTop(0); // double fault
    tss.ist2 = istTop(1); // NMI
    tss.ist3 = istTop(2); // machine check
    const base = @intFromPtr(&tss);
    const limit: u64 = 104 - 1;
    gdt.tss_lo = (limit & 0xFFFF) |
        ((base & 0xFFFFFF) << 16) |
        (@as(u64, 0x89) << 40) | // present, 64-bit TSS (available)
        (((limit >> 16) & 0xF) << 48) |
        (((base >> 24) & 0xFF) << 56);
    gdt.tss_hi = base >> 32;

    const gdtr: Gdtr = .{ .limit = @sizeOf(Gdt) - 1, .base = @intFromPtr(&gdt) };
    asm volatile (
        \\lgdt (%[g])
        \\pushq %[cs]
        \\leaq 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        \\movw %[ds], %%ax
        \\movw %%ax, %%ds
        \\movw %%ax, %%es
        \\movw %%ax, %%ss
        \\xorl %%eax, %%eax
        \\movw %%ax, %%fs
        \\movw %%ax, %%gs
        \\movw %[tr], %%ax
        \\ltr %%ax
        :
        : [g] "r" (&gdtr),
          [cs] "i" (@as(u64, KERNEL_CS)),
          [ds] "i" (KERNEL_DS),
          [tr] "i" (TSS_SEL),
        : .{ .rax = true, .memory = true });
}
