//! Multiboot2 boot information (spec section 3.6). Both boot paths hand the
//! kernel this structure, so the kernel never knows which path it came from.
const serial = @import("serial.zig");

const Tag = extern struct { kind: u32, size: u32 };

const TAG_END = 0;
const TAG_CMDLINE = 1;
const TAG_MMAP = 6;
const TAG_ACPI_OLD = 14;
const TAG_ACPI_NEW = 15;

pub const MemType = enum(u32) { available = 1, reserved = 2, acpi_reclaimable = 3, nvs = 4, bad = 5, _ };

pub const MemRegion = extern struct { base: u64, length: u64, kind: u32, reserved: u32 };

pub const Info = struct {
    base: usize,
    mmap: []align(1) const MemRegion = &.{},
    rsdp: ?usize = null, // physical address of the RSDP copy inside the info
    cmdline: []const u8 = &.{},
};

fn tagData(t: *const Tag) usize {
    return @intFromPtr(t) + @sizeOf(Tag);
}

/// Walk the tag list. `addr` is the physical address GRUB passed in EBX.
pub fn parse(addr: usize) Info {
    var info: Info = .{ .base = addr };
    const total = @as(*const u32, @ptrFromInt(addr)).*;
    var p = addr + 8;
    while (p < addr + total) {
        const t: *const Tag = @ptrFromInt(p);
        if (t.kind == TAG_END) break;
        switch (t.kind) {
            TAG_MMAP => {
                const entry_size = @as(*const u32, @ptrFromInt(tagData(t))).*;
                if (entry_size == @sizeOf(MemRegion)) {
                    const first = tagData(t) + 8;
                    const n = (t.size - @sizeOf(Tag) - 8) / entry_size;
                    info.mmap = @as([*]align(1) const MemRegion, @ptrFromInt(first))[0..n];
                }
            },
            TAG_ACPI_OLD, TAG_ACPI_NEW => info.rsdp = tagData(t),
            TAG_CMDLINE => {
                const s: [*]const u8 = @ptrFromInt(tagData(t));
                var n: usize = 0;
                while (n < t.size - @sizeOf(Tag) and s[n] != 0) n += 1;
                info.cmdline = s[0..n];
            },
            else => {},
        }
        p += (t.size + 7) & ~@as(usize, 7);
    }
    return info;
}

pub fn printMemory(info: Info) void {
    var usable: u64 = 0;
    var regions: u64 = 0;
    var top: u64 = 0;
    for (info.mmap) |r| {
        if (r.kind == @intFromEnum(MemType.available)) {
            usable += r.length;
            regions += 1;
            if (r.base + r.length > top) top = r.base + r.length;
        }
    }
    serial.write("mem: usable ");
    serial.dec(usable >> 20);
    serial.write(" MiB in ");
    serial.dec(regions);
    serial.write(" regions, top ");
    serial.hex(top);
    serial.write("\n");
    if (info.rsdp) |a| {
        serial.write("acpi: rsdp tag at ");
        serial.hex(a);
        serial.write("\n");
    } else serial.write("acpi: no rsdp tag\n");
}
