# AP trampoline: copied to physical 0x8000 and started with INIT-SIPI-SIPI
# (vector 0x08). Real mode -> protected mode -> long mode on the kernel's page
# tables, then calls the kernel entry the BSP stored in the parameter block.
# Intel SDM Vol. 3 section 9.4 (MP initialization), ch. 9.8 (mode switch).
# The assembler places this at its link address, so every address inside it is
# written relative to ap_tramp_start and rebased onto TRAMP.

.intel_syntax noprefix

.set TRAMP,       0x8000
.set P_CR3,       TRAMP + 0xF00     # u32: kernel PML4, below 4 GiB
.set P_STACK,     TRAMP + 0xF08     # u64: top of this AP's stack
.set P_ENTRY,     TRAMP + 0xF10     # u64: address of the kernel's ap_entry

.section .rodata.ap_tramp, "a"
.global ap_tramp_start
.global ap_tramp_end
ap_tramp_start:
.code16
    cli
    cld
    xor ax, ax
    mov ds, ax
    .byte 0x0F, 0x01, 0x16                              # lgdt [disp16]
    .word TRAMP + (tramp_gdtr - ap_tramp_start)
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    .byte 0x66, 0xEA                                    # jmp far 0x08:tramp32
    .long TRAMP + (tramp32 - ap_tramp_start)
    .word 0x08

.code32
tramp32:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov eax, cr4
    or eax, 1 << 5                                      # PAE
    mov cr4, eax
    mov eax, [P_CR3]
    mov cr3, eax
    mov ecx, 0xC0000080                                 # IA32_EFER
    rdmsr
    or eax, (1 << 8) | (1 << 11)                        # LME | NXE
    wrmsr
    mov eax, cr0
    or eax, 1 << 31                                     # PG
    mov cr0, eax
    .byte 0xEA                                          # jmp far 0x18:tramp64
    .long TRAMP + (tramp64 - ap_tramp_start)
    .word 0x18

.code64
tramp64:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    xor eax, eax
    mov fs, ax
    mov gs, ax
    mov rsp, [P_STACK]
    xor ebp, ebp
    mov rax, [P_ENTRY]
    call rax
1:  cli
    hlt
    jmp 1b

.align 8
tramp_gdt:
    .quad 0x0000000000000000
    .quad 0x00CF9A000000FFFF        # 0x08: 32-bit code
    .quad 0x00CF92000000FFFF        # 0x10: data
    .quad 0x00AF9A000000FFFF        # 0x18: 64-bit code
tramp_gdt_end:
tramp_gdtr:
    .word tramp_gdt_end - tramp_gdt - 1
    .long TRAMP + (tramp_gdt - ap_tramp_start)
ap_tramp_end:
