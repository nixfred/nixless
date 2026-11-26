//! Physical frame allocator: one bit per 4 KiB frame (set = used).
//! Memory below 1 MiB stays reserved (AP trampoline, BIOS areas later).
const mb2 = @import("mb2.zig");
const serial = @import("serial.zig");

pub const FRAME: u64 = 4096;

const sym = @import("sym.zig");

var bitmap: [*]u64 = undefined;
var frames: u64 = 0;
var free_frames: u64 = 0;
var hint: u64 = 0;

inline fn isUsed(f: u64) bool {
    return bitmap[f >> 6] & (@as(u64, 1) << @as(u6, @intCast(f & 63))) != 0;
}
inline fn setUsed(f: u64) void {
    bitmap[f >> 6] |= @as(u64, 1) << @as(u6, @intCast(f & 63));
}
inline fn setFree(f: u64) void {
    bitmap[f >> 6] &= ~(@as(u64, 1) << @as(u6, @intCast(f & 63)));
}

fn reserve(base: u64, len: u64) void {
    var f = base / FRAME;
    const end = (base + len + FRAME - 1) / FRAME;
    while (f < end and f < frames) : (f += 1) {
        if (!isUsed(f)) {
            setUsed(f);
            free_frames -= 1;
        }
    }
}

pub fn init(info: mb2.Info) void {
    const kstart: u64 = sym.kernelStart();
    const kend: u64 = sym.kernelEnd();
    const info_total: u64 = @as(*const u32, @ptrFromInt(info.base)).*;

    var top: u64 = 0;
    for (info.mmap) |r| {
        if (r.kind == @intFromEnum(mb2.MemType.available) and r.base + r.length > top) top = r.base + r.length;
    }
    frames = (top + FRAME - 1) / FRAME;
    const bitmap_bytes = (((frames + 63) / 64) * 8 + FRAME - 1) & ~(FRAME - 1);

    // Put the bitmap in the first usable region above the kernel and the boot info.
    var floor = kend;
    if (info.base + info_total > floor) floor = info.base + info_total;
    floor = (floor + FRAME - 1) & ~(FRAME - 1);
    var placed = false;
    for (info.mmap) |r| {
        if (r.kind != @intFromEnum(mb2.MemType.available)) continue;
        const start = if (r.base > floor) r.base else floor;
        if (start + bitmap_bytes <= r.base + r.length and start + bitmap_bytes <= 0x1_0000_0000) {
            bitmap = @ptrFromInt(start);
            placed = true;
            break;
        }
    }
    if (!placed) @panic("E_OOM: no room for the frame bitmap");
    const bm_base = @intFromPtr(bitmap);

    // Everything used, then free what is really available and not reserved.
    for (0..bitmap_bytes / 8) |i| bitmap[i] = ~@as(u64, 0);
    free_frames = 0;
    for (info.mmap) |r| {
        if (r.kind != @intFromEnum(mb2.MemType.available)) continue;
        var f = (r.base + FRAME - 1) / FRAME;
        const end = (r.base + r.length) / FRAME;
        while (f < end) : (f += 1) {
            if (isUsed(f)) {
                setFree(f);
                free_frames += 1;
            }
        }
    }
    reserve(0, 0x100000); // low 1 MiB
    reserve(kstart, kend - kstart);
    reserve(info.base, info_total);
    reserve(bm_base, bitmap_bytes);

    serial.write("pmm: ");
    serial.dec(free_frames * FRAME >> 20);
    serial.write(" MiB free, bitmap ");
    serial.dec(bitmap_bytes >> 10);
    serial.write(" KiB\n");
}

/// A zeroed frame below 4 GiB (page tables early on are reached by identity).
pub fn alloc() ?u64 {
    var scanned: u64 = 0;
    var f = hint;
    while (scanned < frames) : (scanned += 1) {
        if (f >= frames) f = 0;
        if (!isUsed(f)) {
            setUsed(f);
            free_frames -= 1;
            hint = f + 1;
            const pa = f * FRAME;
            if (pa >= 0x1_0000_0000) {
                setFree(f);
                free_frames += 1;
                return null;
            }
            const p: [*]volatile u64 = @ptrFromInt(pa);
            for (0..512) |i| p[i] = 0;
            return pa;
        }
        f += 1;
    }
    return null;
}

/// Highest free frame (any address), not zeroed. For the direct-map self test.
pub fn allocTop() ?u64 {
    var f = frames;
    while (f > 0) {
        f -= 1;
        if (!isUsed(f)) {
            setUsed(f);
            free_frames -= 1;
            return f * FRAME;
        }
    }
    return null;
}

pub fn free(pa: u64) void {
    const f = pa / FRAME;
    if (f < frames and isUsed(f)) {
        setFree(f);
        free_frames += 1;
    }
}

pub fn freeBytes() u64 {
    return free_frames * FRAME;
}
