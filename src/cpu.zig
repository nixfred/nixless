//! Thin wrappers over x86-64 instructions. No policy here.

pub inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (value),
          [p] "{dx}" (port),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "{dx}" (port),
    );
}

pub inline fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, hi) << 32) | lo;
}

pub inline fn wrmsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [lo] "{eax}" (@as(u32, @truncate(value))),
          [hi] "{edx}" (@as(u32, @truncate(value >> 32))),
    );
}

pub inline fn cr0() u64 {
    return asm volatile ("mov %%cr0, %[r]"
        : [r] "=r" (-> u64),
    );
}
pub inline fn setCr0(v: u64) void {
    asm volatile ("mov %[v], %%cr0"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}
pub inline fn setCr3(v: u64) void {
    asm volatile ("mov %[v], %%cr3"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}
pub inline fn cr2() u64 {
    return asm volatile ("mov %%cr2, %[r]"
        : [r] "=r" (-> u64),
    );
}
pub inline fn cr3() u64 {
    return asm volatile ("mov %%cr3, %[r]"
        : [r] "=r" (-> u64),
    );
}
pub inline fn cr4() u64 {
    return asm volatile ("mov %%cr4, %[r]"
        : [r] "=r" (-> u64),
    );
}

pub inline fn rbp() u64 {
    return asm volatile ("mov %%rbp, %[r]"
        : [r] "=r" (-> u64),
    );
}

pub const CpuidResult = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

pub inline fn cpuid(leaf: u32, sub: u32) CpuidResult {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (sub),
    );
    return .{ .eax = a, .ebx = b, .ecx = c, .edx = d };
}

pub inline fn inl(port: u16) u32 {
    return asm volatile ("inl %[p], %[r]"
        : [r] "={eax}" (-> u32),
        : [p] "{dx}" (port),
    );
}

pub inline fn enableInterrupts() void {
    asm volatile ("sti" ::: .{ .memory = true });
}

/// Sleep until an interrupt arrives, unless `cond` is already true.
/// `sti; hlt` cannot lose a wakeup: STI takes effect after the next instruction.
pub inline fn sleepUntil(comptime cond: fn () bool) void {
    while (true) {
        asm volatile ("cli" ::: .{ .memory = true });
        if (cond()) return;
        asm volatile ("sti; hlt" ::: .{ .memory = true });
    }
}

pub inline fn pause() void {
    asm volatile ("pause");
}

pub inline fn disableInterrupts() void {
    asm volatile ("cli");
}

/// Idle forever with interrupts off: HLT costs the host nothing (PRD 0b).
pub fn haltForever() noreturn {
    while (true) asm volatile ("cli; hlt");
}
