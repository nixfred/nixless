//! Nixless kernel, M0: serial banner, then halt. No heap, no interrupts yet.
const std = @import("std");
const build_options = @import("build_options");

const COM1: u16 = 0x3F8;

inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (value),
          [p] "{dx}" (port),
    );
}

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "{dx}" (port),
    );
}

/// 16550 UART, 115200 8N1, polled (PRD section 7).
fn serialInit() void {
    outb(COM1 + 1, 0x00); // no interrupts
    outb(COM1 + 3, 0x80); // DLAB on
    outb(COM1 + 0, 0x01); // divisor 1 = 115200
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03); // 8N1, DLAB off
    outb(COM1 + 2, 0xC7); // FIFO on, cleared, 14-byte threshold
    outb(COM1 + 4, 0x0B); // DTR, RTS, OUT2
}

fn serialPutc(c: u8) void {
    // Bounded wait for the transmit-holding register (PRD section 0b: no
    // unbounded spin). A dropped byte beats a hung CPU.
    var tries: u32 = 0;
    while (tries < 100_000) : (tries += 1) {
        if (inb(COM1 + 5) & 0x20 != 0) break;
        std.atomic.spinLoopHint();
    }
    outb(COM1, c);
}

fn serialWrite(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') serialPutc('\r');
        serialPutc(c);
    }
}

/// Idle forever with interrupts off: HLT costs the host nothing (PRD 0b).
fn haltForever() noreturn {
    while (true) asm volatile ("cli; hlt");
}

fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    serialWrite("nixless PANIC: ");
    serialWrite(msg);
    serialWrite("\n");
    haltForever();
}

pub const panic = std.debug.FullPanic(panicImpl);

export fn kmain(mb2_info: u32) callconv(.c) noreturn {
    _ = mb2_info;
    serialInit();
    serialWrite("nixless " ++ build_options.version ++ " " ++ build_options.git_hash ++ " booting\n");
    haltForever();
}
