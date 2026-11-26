//! Kernel page tables. Still identity mapped (PRD 3.2: the higher half is a
//! later step); what changes from the boot tables:
//!   - RAM above 4 GiB is mapped (2 MiB pages, write-back);
//!   - memory-mapped I/O below 4 GiB is uncached;
//!   - the kernel image is mapped with 4 KiB pages: text RX, rodata R, data RW,
//!     all but text NX, and CR0.WP makes read-only really read-only;
//!   - page 0 and every registered guard page are left unmapped.
const mb2 = @import("mb2.zig");
const pmm = @import("pmm.zig");
const cpu = @import("cpu.zig");
const serial = @import("serial.zig");

const sym = @import("sym.zig");

const P: u64 = 1;
const RW: u64 = 2;
const PWT: u64 = 8;
const PCD: u64 = 0x10;
const PS: u64 = 0x80;
const NX: u64 = @as(u64, 1) << 63;
const ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;
const LARGE: u64 = 2 * 1024 * 1024;

var pml4: [*]u64 = undefined;
var guards: [16]u64 = [_]u64{0} ** 16;
var guard_count: usize = 0;

/// Register a 4 KiB page that must stay unmapped. Call before init().
pub fn registerGuard(addr: u64) void {
    guards[guard_count] = addr & ~@as(u64, 0xFFF);
    guard_count += 1;
}

pub fn isGuardAddr(addr: u64) bool {
    const page = addr & ~@as(u64, 0xFFF);
    for (guards[0..guard_count]) |g| if (g == page) return true;
    return false;
}

fn table(parent: [*]u64, idx: usize) [*]u64 {
    const e = parent[idx];
    if (e & P != 0) return @ptrFromInt(e & ADDR_MASK);
    const f = pmm.alloc() orelse @panic("E_OOM: out of frames for page tables");
    parent[idx] = f | P | RW;
    return @ptrFromInt(f);
}

fn pdFor(va: u64) [*]u64 {
    const pdpt = table(pml4, @intCast((va >> 39) & 511));
    return table(pdpt, @intCast((va >> 30) & 511));
}

fn map4k(va: u64, pa: u64, flags: u64) void {
    const pt = table(pdFor(va), @intCast((va >> 21) & 511));
    pt[@intCast((va >> 12) & 511)] = pa | flags | P;
}

fn map2m(va: u64, flags: u64) void {
    pdFor(va)[@intCast((va >> 21) & 511)] = va | flags | P | PS;
}

const Kind = enum { ram, mmio, none };

fn classify(base: u64, end: u64, info: mb2.Info) Kind {
    var reserved = false;
    for (info.mmap) |r| {
        if (r.base >= end or r.base + r.length <= base) continue;
        switch (r.kind) {
            1, 3, 4 => return .ram, // available, ACPI reclaimable, ACPI NVS
            else => reserved = true,
        }
    }
    if (reserved or end <= 0x1_0000_0000) return .mmio;
    return .none;
}

/// AP trampoline page: the one RWX page, because the AP executes it with
/// paging on for one instruction (mode switch) before jumping into the kernel.
pub const TRAMPOLINE: u64 = 0x8000;

/// Unmap one 4 KiB page, splitting a 2 MiB mapping if needed (guard pages).
pub fn unmap4k(va: u64) void {
    const pd = pdFor(va);
    const idx: usize = @intCast((va >> 21) & 511);
    const e = pd[idx];
    if (e & P != 0 and e & PS != 0) {
        const pt: [*]u64 = @ptrFromInt(pmm.alloc() orelse @panic("E_OOM: no frame to split a 2 MiB page"));
        const flags = e & ~(PS | ADDR_MASK | (@as(u64, 1) << 12));
        const base = e & 0x000F_FFFF_FFE0_0000;
        for (0..512) |i| pt[i] = (base + i * 0x1000) | flags;
        pd[idx] = @intFromPtr(pt) | P | RW;
    }
    const pt = table(pd, idx);
    pt[@intCast((va >> 12) & 511)] = 0;
    asm volatile ("invlpg (%[a])"
        :
        : [a] "r" (va),
        : .{ .memory = true });
}

pub fn cr3Value() u64 {
    return @intFromPtr(pml4);
}

pub fn init(info: mb2.Info) void {
    const kstart: u64 = sym.kernelStart();
    const text_end: u64 = sym.textEnd();
    const rodata_end: u64 = sym.rodataEnd();

    var top: u64 = 0x1_0000_0000;
    for (info.mmap) |r| {
        // Only memory counts toward the top; reserved holes above 4 GiB stay unmapped.
        const is_mem = r.kind == 1 or r.kind == 3 or r.kind == 4;
        if (is_mem and r.base + r.length > top) top = r.base + r.length;
    }
    top = (top + LARGE - 1) & ~(LARGE - 1);

    pml4 = @ptrFromInt(pmm.alloc() orelse @panic("E_OOM: no frame for the PML4"));

    // First 2 MiB: 4 KiB pages, so the kernel image gets exact permissions.
    var pa: u64 = 0x1000; // page 0 stays unmapped
    while (pa < LARGE) : (pa += 0x1000) {
        var flags: u64 = RW | NX;
        if (pa >= kstart and pa < text_end) flags = 0 // text: read + execute
        else if (pa >= text_end and pa < rodata_end) flags = NX; // rodata: read only
        if (isGuardAddr(pa)) continue;
        if (pa == TRAMPOLINE) flags = RW; // executable on purpose, see above
        map4k(pa, pa, flags);
    }

    // Everything else in 2 MiB pages, by what the memory map says it is.
    var va: u64 = LARGE;
    while (va < top) : (va += LARGE) {
        switch (classify(va, va + LARGE, info)) {
            .ram => map2m(va, RW | NX),
            .mmio => map2m(va, RW | NX | PCD | PWT),
            .none => {},
        }
    }

    // The image lives in the first 2 MiB (linker.ld asserts it), so the 4 KiB loop above covers it.

    cpu.setCr0(cpu.cr0() | (1 << 16)); // WP: supervisor honors read-only pages
    cpu.setCr3(@intFromPtr(pml4));
    serial.write("vmm: page tables loaded, mapped up to ");
    serial.hex(top);
    serial.write("\n");
}

/// Write and read back a pattern through the new map at the highest free frame.
pub fn selfTest() void {
    const pa = pmm.allocTop() orelse @panic("vmm self test: no free frame");
    const p: *volatile u64 = @ptrFromInt(pa);
    p.* = 0x4E49_584C_4553_5321; // "NIXLESS!"
    if (p.* != 0x4E49_584C_4553_5321) @panic("vmm self test: readback mismatch");
    pmm.free(pa);
    serial.write("vmm: direct map ok, tested ");
    serial.hex(pa);
    serial.write("\n");
}
