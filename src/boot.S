# Nixless boot stub (GRUB path A): Multiboot2 header, 32-bit entry,
# CPUID check, identity-mapped first 4 GiB, long mode, call kmain.
# Intel SDM Vol. 3 ch. 9 and 4 (mode switch, paging), Multiboot2 spec.
# GRUB zeroes .bss for ELF kernels (Multiboot2 spec), so the page tables
# below start zeroed.

.intel_syntax noprefix

.set MB2_MAGIC,      0xE85250D6
.set MB2_ARCH_I386,  0
.set MB2_BOOT_MAGIC, 0x36D76289
.set COM1,           0x3F8

.section .multiboot2, "a"
.align 8
mb2_header:
    .long MB2_MAGIC
    .long MB2_ARCH_I386
    .long mb2_header_end - mb2_header
    .long -(MB2_MAGIC + MB2_ARCH_I386 + (mb2_header_end - mb2_header))
    # information request: memory map (6), ACPI RSDP old (14) and new (15)
    .short 1
    .short 0
    .long 20
    .long 6
    .long 14
    .long 15
    .align 8
    # end tag
    .short 0
    .short 0
    .long 8
mb2_header_end:

.section .boot.text, "ax"
.code32
.global _start
_start:
    cli
    cld
    cmp eax, MB2_BOOT_MAGIC
    jne .Lerr_magic
    mov esp, offset boot_stack_top
    mov [mb2_info], ebx

    # Long mode available? CPUID 0x80000001 EDX bit 29.
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000001
    jb .Lerr_nolm
    mov eax, 0x80000001
    cpuid
    test edx, 1 << 29
    jz .Lerr_nolm

    # PML4[0] -> PDPT; PDPT[0..3] -> PD0..PD3; PDs map 2 MiB pages (P|RW|PS).
    mov eax, offset pdpt
    or eax, 0x3
    mov [pml4], eax
    xor ecx, ecx
1:  mov eax, ecx
    shl eax, 12
    add eax, offset pd
    or eax, 0x3
    mov [pdpt + ecx * 8], eax
    inc ecx
    cmp ecx, 4
    jne 1b
    xor ecx, ecx
2:  mov eax, ecx
    shl eax, 21
    or eax, 0x83
    mov [pd + ecx * 8], eax
    inc ecx
    cmp ecx, 2048
    jne 2b

    mov eax, cr4
    or eax, 1 << 5              # PAE
    mov cr4, eax
    mov eax, offset pml4
    mov cr3, eax
    mov ecx, 0xC0000080         # IA32_EFER
    rdmsr
    or eax, (1 << 8) | (1 << 11)    # LME | NXE
    wrmsr
    mov eax, cr0
    or eax, 1 << 31             # PG
    mov cr0, eax
    lgdt [gdt_ptr]
    .byte 0xEA                  # far jump to 64-bit code segment
    .long long_entry
    .word 0x08

.Lerr_magic:
    mov esi, offset msg_magic
    jmp .Lfatal
.Lerr_nolm:
    mov esi, offset msg_nolm
.Lfatal:
    mov dx, COM1
.Lfatal_next:
    mov al, [esi]
    test al, al
    jz .Lhalt
    out dx, al
    inc esi
    jmp .Lfatal_next
.Lhalt:
    hlt
    jmp .Lhalt

.code64
long_entry:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    xor eax, eax
    mov fs, ax
    mov gs, ax
    mov rsp, offset boot_stack_top
    xor ebp, ebp
    mov edi, [mb2_info]
    call kmain
.Lkmain_returned:
    cli
    hlt
    jmp .Lkmain_returned

.section .boot.rodata, "a"
msg_magic: .asciz "nixless: FATAL E_BAD_BOOT_MAGIC: not entered by a Multiboot2 loader\n"
msg_nolm:  .asciz "nixless: FATAL E_NO_LONGMODE: CPU has no long mode\n"

.align 8
gdt:
    .quad 0x0000000000000000
    .quad 0x00AF9A000000FFFF    # 0x08: 64-bit code
    .quad 0x00CF92000000FFFF    # 0x10: data
gdt_end:
gdt_ptr:
    .word gdt_end - gdt - 1
    .long gdt

.section .bss
.align 4096
pml4:       .skip 4096
pdpt:       .skip 4096
pd:         .skip 4096 * 4
mb2_info:   .skip 8
.align 4096
.global boot_stack_guard
boot_stack_guard: .skip 4096    # left unmapped by vmm.init
boot_stack: .skip 16384
boot_stack_top:
