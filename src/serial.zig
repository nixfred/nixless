//! COM1, 16550 UART, 115200 8N1, polled (PRD section 7).
const std = @import("std");
const cpu = @import("cpu.zig");

const COM1: u16 = 0x3F8;

pub fn init() void {
    cpu.outb(COM1 + 1, 0x00); // no interrupts
    cpu.outb(COM1 + 3, 0x80); // DLAB on
    cpu.outb(COM1 + 0, 0x01); // divisor 1 = 115200
    cpu.outb(COM1 + 1, 0x00);
    cpu.outb(COM1 + 3, 0x03); // 8N1, DLAB off
    cpu.outb(COM1 + 2, 0xC7); // FIFO on, cleared, 14-byte threshold
    cpu.outb(COM1 + 4, 0x0B); // DTR, RTS, OUT2
}

pub fn putc(c: u8) void {
    // Bounded wait for the transmit-holding register (PRD section 0b: no
    // unbounded spin). A dropped byte beats a hung CPU.
    var tries: u32 = 0;
    while (tries < 100_000) : (tries += 1) {
        if (cpu.inb(COM1 + 5) & 0x20 != 0) break;
        std.atomic.spinLoopHint();
    }
    cpu.outb(COM1, c);
}

pub fn write(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') putc('\r');
        putc(c);
    }
}

const digits = "0123456789abcdef";

/// 0x followed by exactly `nibbles` hex digits.
pub fn hexFixed(v: u64, nibbles: u6) void {
    write("0x");
    var i: u7 = nibbles;
    while (i > 0) {
        i -= 1;
        putc(digits[@as(usize, @intCast((v >> @as(u6, @intCast(i * 4))) & 0xF))]);
    }
}

/// 0x followed by the shortest hex form.
pub fn hex(v: u64) void {
    var n: u6 = 1;
    while (n < 16 and (v >> @as(u6, @intCast(n * 4))) != 0) n += 1;
    hexFixed(v, n);
}

pub fn dec(v: u64) void {
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var x = v;
    if (x == 0) {
        putc('0');
        return;
    }
    while (x != 0) : (x /= 10) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(x % 10));
    }
    write(buf[i..]);
}
