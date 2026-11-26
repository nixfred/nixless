//! Local APIC (xAPIC MMIO) and its one-shot timer (PRD 0b: no periodic tick).
//! Intel SDM Vol. 3 ch. 11. TSC-deadline mode when CPUID offers it, else the
//! LAPIC counter in one-shot mode calibrated against the TSC.
const cpu = @import("cpu.zig");
const clock = @import("clock.zig");
const serial = @import("serial.zig");

pub const VEC_TIMER: u8 = 0x40;
pub const VEC_WAKE: u8 = 0x41;
pub const VEC_SPURIOUS: u8 = 0xFF;

const REG_ID = 0x20;
const REG_EOI = 0xB0;
const REG_SVR = 0xF0;
const REG_LVT_TIMER = 0x320;
const REG_TIMER_INIT = 0x380;
const REG_TIMER_CUR = 0x390;
const REG_TIMER_DIV = 0x3E0;

const IA32_APIC_BASE = 0x1B;
const IA32_TSC_DEADLINE = 0x6E0;

var base: u64 = 0xFEE00000;
var deadline_mode = false;
var counts_per_us: u64 = 0; // one-shot mode only
pub var timer_fired: u64 = 0;

inline fn read(reg: u64) u32 {
    return @as(*volatile u32, @ptrFromInt(base + reg)).*;
}
inline fn write(reg: u64, v: u32) void {
    @as(*volatile u32, @ptrFromInt(base + reg)).* = v;
}

pub fn id() u32 {
    return read(REG_ID) >> 24;
}

pub fn eoi() void {
    write(REG_EOI, 0);
}

/// The BIOS leaves the 8259 PICs mapped over vectors 8..15, which collide with
/// CPU exceptions. Remap them out of the way, then mask every line: Nixless
/// uses the LAPIC only. (ICW1..4 per the 8259A datasheet.)
pub fn disablePic() void {
    cpu.outb(0x20, 0x11);
    cpu.outb(0xA0, 0x11);
    cpu.outb(0x21, 0x20); // master offset 0x20
    cpu.outb(0xA1, 0x28); // slave offset 0x28
    cpu.outb(0x21, 0x04);
    cpu.outb(0xA1, 0x02);
    cpu.outb(0x21, 0x01);
    cpu.outb(0xA1, 0x01);
    cpu.outb(0x21, 0xFF); // mask all
    cpu.outb(0xA1, 0xFF);
}

/// Enable this CPU's LAPIC and decide the timer mode. `addr` comes from the MADT.
pub fn init(addr: u64) void {
    disablePic();
    base = addr;
    cpu.wrmsr(IA32_APIC_BASE, (cpu.rdmsr(IA32_APIC_BASE) & ~@as(u64, 0xFFFFF000)) | (addr & 0xFFFFF000) | (1 << 11));
    write(REG_SVR, @as(u32, 0x100) | VEC_SPURIOUS); // software enable
    deadline_mode = cpu.cpuid(1, 0).ecx & (1 << 24) != 0;
    if (!deadline_mode) calibrateCounter();
    serial.write("lapic: id ");
    serial.dec(id());
    serial.write(if (deadline_mode) ", timer tsc-deadline\n" else ", timer one-shot counter\n");
}

fn calibrateCounter() void {
    write(REG_TIMER_DIV, 0xB); // divide by 1
    write(REG_LVT_TIMER, @as(u32, 0x10000) | VEC_TIMER); // masked, one-shot
    write(REG_TIMER_INIT, 0xFFFF_FFFF);
    const t0 = clock.rdtsc();
    const span = clock.usToTsc(10_000);
    while (clock.rdtsc() - t0 < span) {}
    const used = 0xFFFF_FFFF - read(REG_TIMER_CUR);
    write(REG_TIMER_INIT, 0);
    counts_per_us = used / 10_000;
    if (counts_per_us == 0) counts_per_us = 1;
}

/// Arm a single interrupt `us` microseconds from now.
pub fn armOneShotUs(us: u64) void {
    if (deadline_mode) {
        write(REG_LVT_TIMER, (@as(u32, 2) << 17) | VEC_TIMER); // TSC-deadline mode
        cpu.wrmsr(IA32_TSC_DEADLINE, clock.rdtsc() + clock.usToTsc(us));
    } else {
        write(REG_LVT_TIMER, VEC_TIMER); // one-shot
        write(REG_TIMER_INIT, @intCast(@min(us * counts_per_us, 0xFFFF_FFFF)));
    }
}

pub fn onTimer() void {
    timer_fired += 1;
    eoi();
}
