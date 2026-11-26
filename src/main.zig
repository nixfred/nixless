//! Nixless kernel entry. M1 in progress: GDT/TSS, IDT, panic procedure,
//! Multiboot2 memory map. No heap, no interrupts other than exceptions yet.
const std = @import("std");
const build_options = @import("build_options");
const cpu = @import("cpu.zig");
const serial = @import("serial.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const mb2 = @import("mb2.zig");
const panic_mod = @import("panic.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");

const sym = @import("sym.zig");

noinline fn recurse(n: usize) usize {
    var pad: [512]u8 = undefined;
    pad[n % pad.len] = @truncate(n);
    const v: *volatile u8 = &pad[n % pad.len];
    return recurse(n + 1) +% v.*;
}

fn panicImpl(msg: []const u8, first_addr: ?usize) noreturn {
    panic_mod.softwarePanic(msg, first_addr);
}

pub const panic = std.debug.FullPanic(panicImpl);

/// Deliberate faults for the panic tests (`zig build -Dpanic-test=<kind>`).
fn panicTest(kind: []const u8) void {
    if (kind.len == 0) return;
    serial.write("panic-test: ");
    serial.write(kind);
    serial.write("\n");
    if (std.mem.eql(u8, kind, "pf")) {
        @as(*volatile u8, @ptrFromInt(0x1_0000_0000)).* = 1; // above the 4 GiB boot map
    } else if (std.mem.eql(u8, kind, "null")) {
        _ = @as(*volatile u8, @ptrFromInt(8)).*; // page 0 is unmapped
    } else if (std.mem.eql(u8, kind, "ro")) {
        @as(*volatile u8, @ptrFromInt(sym.textEnd())).* = 1; // first rodata byte
    } else if (std.mem.eql(u8, kind, "so")) {
        _ = recurse(0);
    } else if (std.mem.eql(u8, kind, "de")) {
        asm volatile ("xorl %%edx, %%edx; movl $1, %%eax; xorl %%ecx, %%ecx; divl %%ecx" ::: .{ .rax = true, .rcx = true, .rdx = true });
    } else if (std.mem.eql(u8, kind, "ud")) {
        asm volatile ("ud2");
    } else if (std.mem.eql(u8, kind, "df")) {
        // A bad stack pointer makes exception delivery itself fault: #DF on its IST stack.
        asm volatile ("movabsq $0x100000000000, %%rsp; int3" ::: .{ .memory = true });
    } else if (std.mem.eql(u8, kind, "assert")) {
        @panic("assertion test");
    }
}

export fn kmain(mb2_info: u32) callconv(.c) noreturn {
    serial.init();
    serial.write("nixless " ++ build_options.version ++ " " ++ build_options.git_hash ++ " booting\n");
    gdt.init();
    idt.init();
    const info = mb2.parse(mb2_info);
    mb2.printMemory(info);
    pmm.init(info);
    vmm.registerGuard(sym.bootStackGuard());
    gdt.registerGuards(&vmm.registerGuard);
    vmm.init(info);
    vmm.selfTest();
    panicTest(build_options.panic_test);
    cpu.haltForever();
}
