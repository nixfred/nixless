//! Application CPUs: start them, park them in HLT, wake them with an IPI.
//! PRD 0b: an idle core executes HLT with interrupts enabled; there is no
//! polling loop and no periodic tick. Work is published by the BSP, which
//! then sends the wake IPI (vector 0x41); an AP that finishes sends one back.
const std = @import("std");
const acpi = @import("acpi.zig");
const clock = @import("clock.zig");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const lapic = @import("lapic.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");
const sym = @import("sym.zig");
const vmm = @import("vmm.zig");

const STACK_SIZE = 16 * 1024;
// Per-AP block: [guard][stack][guard][IST stack], 4 KiB pages.
const BLOCK_FRAMES = 1 + STACK_SIZE / 4096 + 1 + STACK_SIZE / 4096;

var apic_ids: [acpi.MAX_CPUS]u8 = undefined;
var cpu_count: usize = 1; // including the BSP
var bsp_id: u32 = 0;

var online = std.atomic.Value(usize).init(1);
var boot_index = std.atomic.Value(usize).init(0);

// One word per CPU: the work generation it has already handled.
var seen: [acpi.MAX_CPUS]std.atomic.Value(u32) = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** acpi.MAX_CPUS;
var generation = std.atomic.Value(u32).init(0);
var done = std.atomic.Value(usize).init(0);
var results: [acpi.MAX_CPUS]u64 = [_]u64{0} ** acpi.MAX_CPUS;
const SLICE: u64 = 1 << 20;

fn sliceSum(index: usize) u64 {
    var s: u64 = 0;
    var x: u64 = index * SLICE;
    const end = x + SLICE;
    while (x < end) : (x += 1) s +%= x *% x +% 1;
    return s;
}

fn runWork(index: usize) void {
    results[index] = sliceSum(index);
}

/// Entered on each AP by the trampoline, on that AP's own stack.
export fn ap_entry() callconv(.c) noreturn {
    const index = boot_index.load(.acquire);
    const pc: *gdt.PerCpu = @ptrFromInt(percpu_base[index]);
    gdt.initAp(pc, ist_top[index]);
    idt.load();
    cpu.setCr0(cpu.cr0() | (1 << 16)); // WP, as on the BSP
    lapic.initAp();
    _ = online.fetchAdd(1, .acq_rel);

    // Park: HLT with interrupts enabled, wake on the IPI, look for work.
    while (true) {
        cpu.disableInterrupts();
        const gen = generation.load(.acquire);
        if (seen[index].load(.monotonic) != gen) {
            seen[index].store(gen, .monotonic);
            runWork(index);
            _ = done.fetchAdd(1, .acq_rel);
            lapic.sendIpi(bsp_id, lapic.icrFixed(lapic.VEC_WAKE));
            continue;
        }
        asm volatile ("sti; hlt" ::: .{ .memory = true });
    }
}

var percpu_base: [acpi.MAX_CPUS]u64 = undefined;
var ist_top: [acpi.MAX_CPUS]u64 = undefined;

fn allBack() bool {
    return done.load(.acquire) >= cpu_count - 1;
}

/// Bring up every CPU the MADT lists. Prints the result.
pub fn start(info: *const acpi.Info) void {
    bsp_id = lapic.id();
    const tramp_len = sym.apTrampEnd() - sym.apTrampStart();
    if (tramp_len > 0xF00) @panic("AP trampoline too large");
    const dst: [*]u8 = @ptrFromInt(vmm.TRAMPOLINE);
    const src: [*]const u8 = @ptrFromInt(sym.apTrampStart());
    @memcpy(dst[0..tramp_len], src[0..tramp_len]);
    @as(*volatile u32, @ptrFromInt(vmm.TRAMPOLINE + 0xF00)).* = @intCast(vmm.cr3Value());
    @as(*volatile u64, @ptrFromInt(vmm.TRAMPOLINE + 0xF10)).* = @intFromPtr(&ap_entry);

    var started: usize = 1;
    for (info.apic_ids[0..info.cpu_count]) |id| {
        if (id == bsp_id) continue;
        const idx = started;

        // Stack block and per-CPU GDT/TSS, with unmapped guard pages.
        const block = pmm.allocContig(BLOCK_FRAMES) orelse @panic("E_OOM: no frames for an AP stack");
        const pc = pmm.alloc() orelse @panic("E_OOM: no frame for an AP GDT");
        percpu_base[idx] = pc;
        vmm.unmap4k(block);
        const stack_base = block + 4096;
        const guard2 = stack_base + STACK_SIZE;
        vmm.unmap4k(guard2);
        ist_top[idx] = guard2 + 4096 + STACK_SIZE;
        @as(*volatile u64, @ptrFromInt(vmm.TRAMPOLINE + 0xF08)).* = stack_base + STACK_SIZE;
        boot_index.store(idx, .release);

        const before = online.load(.acquire);
        lapic.sendIpi(id, lapic.ICR_INIT);
        clock.delayUs(10_000);
        lapic.sendIpi(id, lapic.icrSipi(@intCast(vmm.TRAMPOLINE >> 12)));
        clock.delayUs(200);
        lapic.sendIpi(id, lapic.icrSipi(@intCast(vmm.TRAMPOLINE >> 12)));

        var waited: u64 = 0;
        while (online.load(.acquire) == before and waited < 500_000) : (waited += 100) clock.delayUs(100);
        if (online.load(.acquire) == before) {
            serial.write("smp: AP with apic id ");
            serial.dec(id);
            serial.write(" did not start\n");
            continue;
        }
        apic_ids[idx] = id;
        started += 1;
    }
    cpu_count = started;
    serial.write("smp: ");
    serial.dec(cpu_count);
    serial.write(" cores online\n");
}

/// Every core, the BSP included, sums its own slice; the BSP checks all of them.
pub fn parallelSumTest() void {
    done.store(0, .release);
    results[0] = 0;
    const gen = generation.fetchAdd(1, .acq_rel) + 1;
    _ = gen;
    for (1..cpu_count) |i| lapic.sendIpi(apic_ids[i], lapic.icrFixed(lapic.VEC_WAKE));
    runWork(0);
    cpu.enableInterrupts();
    cpu.sleepUntil(allBack);

    var ok = true;
    var total: u64 = 0;
    for (0..cpu_count) |i| {
        if (results[i] != sliceSum(i)) ok = false;
        total +%= results[i];
    }
    serial.write(if (ok) "smp: parallel sum ok on " else "smp: parallel sum MISMATCH on ");
    serial.dec(cpu_count);
    serial.write(" cores, total ");
    serial.hex(total);
    serial.write("\n");
    if (!ok) @panic("smp: parallel sum mismatch");
}
