//! Addresses of linker-script symbols, taken with `lea` on purpose.
//! `@intFromPtr(&extern_sym) > N` compiled to `cmpq $N, sym(%rip)` (a compare
//! of the symbol's CONTENTS, via a GOT form lld resolved without a slot), which
//! read garbage past the image under OVMF. `lea` cannot be turned into that.

pub inline fn kernelStart() u64 {
    return asm ("leaq __kernel_start(%%rip), %[r]"
        : [r] "=r" (-> u64),
    );
}
pub inline fn textEnd() u64 {
    return asm ("leaq __text_end(%%rip), %[r]"
        : [r] "=r" (-> u64),
    );
}
pub inline fn rodataEnd() u64 {
    return asm ("leaq __rodata_end(%%rip), %[r]"
        : [r] "=r" (-> u64),
    );
}
pub inline fn kernelEnd() u64 {
    return asm ("leaq __kernel_end(%%rip), %[r]"
        : [r] "=r" (-> u64),
    );
}
pub inline fn apTrampStart() u64 {
    return asm ("leaq ap_tramp_start(%%rip), %[r]"
        : [r] "=r" (-> u64),
    );
}
pub inline fn apTrampEnd() u64 {
    return asm ("leaq ap_tramp_end(%%rip), %[r]"
        : [r] "=r" (-> u64),
    );
}
pub inline fn bootStackGuard() u64 {
    return asm ("leaq boot_stack_guard(%%rip), %[r]"
        : [r] "=r" (-> u64),
    );
}
