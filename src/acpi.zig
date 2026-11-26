//! Just enough ACPI: RSDP -> (X)SDT -> MADT (CPUs, LAPIC, IOAPIC) and FADT
//! (PM timer port). ACPI 6.5 sections 5.2.5 to 5.2.9 and 5.2.12.
const serial = @import("serial.zig");

pub const MAX_CPUS = 256;

pub const Info = struct {
    lapic_addr: u64 = 0xFEE00000,
    apic_ids: [MAX_CPUS]u8 = [_]u8{0} ** MAX_CPUS,
    cpu_count: usize = 0,
    ioapic_addr: u32 = 0,
    pm_timer_port: u16 = 0,
    pm_timer_32bit: bool = false,
};

fn rd8(a: u64) u8 {
    return @as(*const volatile u8, @ptrFromInt(a)).*;
}
fn rd16(a: u64) u16 {
    return @as(*align(1) const volatile u16, @ptrFromInt(a)).*;
}
fn rd32(a: u64) u32 {
    return @as(*align(1) const volatile u32, @ptrFromInt(a)).*;
}
fn rd64(a: u64) u64 {
    return @as(*align(1) const volatile u64, @ptrFromInt(a)).*;
}

fn checksumOk(a: u64, len: u64) bool {
    var sum: u8 = 0;
    var i: u64 = 0;
    while (i < len) : (i += 1) sum +%= rd8(a + i);
    return sum == 0;
}

fn sigIs(a: u64, sig: *const [4]u8) bool {
    return rd8(a) == sig[0] and rd8(a + 1) == sig[1] and rd8(a + 2) == sig[2] and rd8(a + 3) == sig[3];
}

fn parseMadt(a: u64, info: *Info) void {
    const len = rd32(a + 4);
    info.lapic_addr = rd32(a + 36);
    var p = a + 44;
    while (p + 2 <= a + len) {
        const kind = rd8(p);
        const elen = rd8(p + 1);
        if (elen < 2) break;
        switch (kind) {
            0 => { // processor local APIC: acpi id, apic id, flags (bit 0 enabled, bit 1 online-capable)
                const flags = rd32(p + 4);
                if (flags & 3 != 0 and info.cpu_count < MAX_CPUS) {
                    info.apic_ids[info.cpu_count] = rd8(p + 3);
                    info.cpu_count += 1;
                }
            },
            1 => if (info.ioapic_addr == 0) {
                info.ioapic_addr = rd32(p + 4);
            },
            5 => info.lapic_addr = rd64(p + 4), // local APIC address override
            else => {},
        }
        p += elen;
    }
}

fn parseFadt(a: u64, info: *Info) void {
    info.pm_timer_port = @truncate(rd32(a + 76)); // PM_TMR_BLK
    info.pm_timer_32bit = rd32(a + 112) & (1 << 8) != 0; // FADT flags: TMR_VAL_EXT
}

/// `rsdp` is the address of the RSDP copy inside the Multiboot2 info.
pub fn parse(rsdp: u64) ?Info {
    if (!(rd8(rsdp) == 'R' and rd8(rsdp + 1) == 'S' and rd8(rsdp + 2) == 'D' and rd8(rsdp + 3) == ' ')) return null;
    if (!checksumOk(rsdp, 20)) return null;
    const revision = rd8(rsdp + 15);
    var info: Info = .{};

    var sdt: u64 = rd32(rsdp + 16);
    var entry: u64 = 4;
    if (revision >= 2 and rd64(rsdp + 24) != 0) {
        sdt = rd64(rsdp + 24);
        entry = 8;
    }
    if (!checksumOk(sdt, rd32(sdt + 4))) return null;
    const count = (rd32(sdt + 4) - 36) / entry;
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const t = if (entry == 8) rd64(sdt + 36 + i * 8) else rd32(sdt + 36 + i * 4);
        if (!checksumOk(t, rd32(t + 4))) continue;
        if (sigIs(t, "APIC")) parseMadt(t, &info);
        if (sigIs(t, "FACP")) parseFadt(t, &info);
    }
    return info;
}

pub fn print(info: *const Info) void {
    serial.write("acpi: ");
    serial.dec(info.cpu_count);
    serial.write(" cpus, lapic ");
    serial.hex(info.lapic_addr);
    serial.write(", ioapic ");
    serial.hex(info.ioapic_addr);
    serial.write(", pm timer port ");
    serial.hex(info.pm_timer_port);
    serial.write(if (info.pm_timer_32bit) " (32-bit)\n" else " (24-bit)\n");
}
