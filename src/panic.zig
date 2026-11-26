//! Panic procedure (PRD 6b), single-core version: take the flag, dump on
//! COM1, halt. NMI to other cores arrives with SMP.
const std = @import("std");
const build_options = @import("build_options");
const cpu = @import("cpu.zig");
const serial = @import("serial.zig");
const idt = @import("idt.zig");
const vmm = @import("vmm.zig");

var panicking = std.atomic.Value(bool).init(false);

const exception_names = [32][]const u8{
    "#DE divide error",           "#DB debug",                 "NMI",                        "#BP breakpoint",
    "#OF overflow",               "#BR bound range",           "#UD invalid opcode",         "#NM device not available",
    "#DF double fault",           "coprocessor overrun",       "#TS invalid TSS",            "#NP segment not present",
    "#SS stack fault",            "#GP general protection",    "#PF page fault",             "reserved 15",
    "#MF x87 error",              "#AC alignment check",       "#MC machine check",          "#XM SIMD error",
    "#VE virtualization",         "#CP control protection",    "reserved 22",                "reserved 23",
    "reserved 24",                "reserved 25",               "reserved 26",                "reserved 27",
    "#HV hypervisor injection",   "#VC VMM communication",     "#SX security",               "reserved 31",
};

fn begin(reason: []const u8) void {
    cpu.disableInterrupts();
    if (panicking.swap(true, .acq_rel)) cpu.haltForever(); // second panic: stay quiet
    serial.write("\nnixless PANIC: ");
    serial.write(reason);
    serial.write("\n  nixless " ++ build_options.version ++ " " ++ build_options.git_hash ++ "\n");
}

fn reg(name: []const u8, v: u64) void {
    serial.write("  ");
    serial.write(name);
    serial.write(" ");
    serial.hexFixed(v, 16);
    serial.write("\n");
}

fn controlRegs() void {
    reg("cr0", cpu.cr0());
    reg("cr2", cpu.cr2());
    reg("cr3", cpu.cr3());
    reg("cr4", cpu.cr4());
}

/// Frame-pointer walk. Addresses only; resolve on the host with addr2line.
fn backtrace(start_rbp: u64) void {
    serial.write("  backtrace:");
    var bp = start_rbp;
    var depth: u32 = 0;
    // The kernel runs identity mapped below 4 GiB (M0), so these reads are safe.
    while (depth < 16 and bp >= 0x1000 and bp < 0x1_0000_0000 and bp & 7 == 0) : (depth += 1) {
        const ret = @as(*const u64, @ptrFromInt(bp + 8)).*;
        const next = @as(*const u64, @ptrFromInt(bp)).*;
        serial.write(" ");
        serial.hex(ret);
        if (next <= bp) break;
        bp = next;
    }
    serial.write("\n");
}

pub fn exceptionPanic(frame: *idt.Frame) noreturn {
    const overflow = (frame.vector == 14 or frame.vector == 8) and vmm.isGuardAddr(cpu.cr2());
    begin(if (overflow) "STACK OVERFLOW (guard page hit)" else if (frame.vector < 32) exception_names[@intCast(frame.vector)] else "unknown exception");
    serial.write("  vector ");
    serial.dec(frame.vector);
    serial.write(" error ");
    serial.hex(frame.error_code);
    serial.write("\n");
    reg("rip", frame.rip);
    reg("rsp", frame.rsp);
    reg("rflags", frame.rflags);
    reg("cs ", frame.cs);
    reg("rax", frame.rax);
    reg("rbx", frame.rbx);
    reg("rcx", frame.rcx);
    reg("rdx", frame.rdx);
    reg("rsi", frame.rsi);
    reg("rdi", frame.rdi);
    reg("rbp", frame.rbp);
    reg("r8 ", frame.r8);
    reg("r9 ", frame.r9);
    reg("r10", frame.r10);
    reg("r11", frame.r11);
    reg("r12", frame.r12);
    reg("r13", frame.r13);
    reg("r14", frame.r14);
    reg("r15", frame.r15);
    controlRegs();
    serial.write("  backtrace: ");
    serial.hex(frame.rip);
    serial.write("\n");
    backtrace(frame.rbp);
    cpu.haltForever();
}

pub fn softwarePanic(msg: []const u8, first_addr: ?usize) noreturn {
    begin(msg);
    if (first_addr) |a| reg("at ", a);
    controlRegs();
    backtrace(cpu.rbp());
    cpu.haltForever();
}
