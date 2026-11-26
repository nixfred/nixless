//! The TSC is the clock (PRD section 7, Time). Calibrated once against the
//! ACPI PM timer (3.579545 MHz) over a short, bounded window.
const cpu = @import("cpu.zig");
const serial = @import("serial.zig");

const PM_HZ: u64 = 3_579_545;
const WINDOW_TICKS: u64 = PM_HZ / 50; // 20 ms

pub var tsc_khz: u64 = 0;
var tsc_at_entry: u64 = 0;

pub inline fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// Call first thing in kmain: uptime counts from here.
pub fn markEntry() void {
    tsc_at_entry = rdtsc();
}

fn pmRead(port: u16, is32: bool) u64 {
    const v = cpu.inl(port);
    return if (is32) v else v & 0xFFFFFF;
}

/// Calibrate tsc_khz. Returns false (and leaves tsc_khz 0) if the PM timer
/// does not advance within the bound.
pub fn calibrate(pm_port: u16, pm32: bool) bool {
    if (pm_port == 0) return false;
    const mask: u64 = if (pm32) 0xFFFF_FFFF else 0xFF_FFFF;
    const start = pmRead(pm_port, pm32);
    const t0 = rdtsc();
    var elapsed: u64 = 0;
    var spins: u32 = 0;
    while (elapsed < WINDOW_TICKS and spins < 2_000_000) : (spins += 1) {
        elapsed = (pmRead(pm_port, pm32) -% start) & mask;
    }
    const t1 = rdtsc();
    if (elapsed < WINDOW_TICKS) return false;
    tsc_khz = (t1 - t0) * PM_HZ / (elapsed * 1000);
    return true;
}

pub fn uptimeUs() u64 {
    if (tsc_khz == 0) return 0;
    return (rdtsc() - tsc_at_entry) * 1000 / tsc_khz;
}

/// Busy-wait. Boot-time only (INIT-SIPI timing); bounded by construction.
pub fn delayUs(us: u64) void {
    const end = rdtsc() + usToTsc(us);
    while (rdtsc() < end) cpu.pause();
}

pub fn usToTsc(us: u64) u64 {
    return us * tsc_khz / 1000;
}

pub fn tscInvariant() bool {
    if (cpu.cpuid(0x80000000, 0).eax < 0x80000007) return false;
    return cpu.cpuid(0x80000007, 0).edx & (1 << 8) != 0;
}

/// Hypervisor timing leaf 0x40000010 (EAX = TSC kHz), if the hypervisor offers one.
pub fn hypervisorTscKhz() ?u32 {
    if (cpu.cpuid(1, 0).ecx & (1 << 31) == 0) return null; // not under a hypervisor
    const max = cpu.cpuid(0x40000000, 0).eax;
    if (max < 0x40000010) return null;
    const khz = cpu.cpuid(0x40000010, 0).eax;
    return if (khz == 0) null else khz;
}

pub fn print() void {
    serial.write("tsc: ");
    serial.dec(tsc_khz);
    serial.write(" kHz, invariant ");
    serial.write(if (tscInvariant()) "yes" else "NO");
    serial.write(", hypervisor leaf ");
    if (hypervisorTscKhz()) |k| {
        serial.dec(k);
        serial.write(" kHz\n");
    } else serial.write("none\n");
}
