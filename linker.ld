/* Nixless kernel, GRUB path A: loaded at 1 MiB, identity mapped (M0).
   The Multiboot2 header must sit in the first 32 KiB of the file. */
ENTRY(_start)

PHDRS {
    text   PT_LOAD FLAGS(5);   /* R X */
    rodata PT_LOAD FLAGS(4);   /* R   */
    data   PT_LOAD FLAGS(6);   /* R W */
}

SECTIONS {
    . = 1M;

    .text : ALIGN(4096) {
        KEEP(*(.multiboot2))
        *(.boot.text)
        *(.text .text.*)
    } :text

    .rodata : ALIGN(4096) {
        *(.boot.rodata)
        *(.rodata .rodata.*)
    } :rodata

    .data : ALIGN(4096) {
        *(.data .data.*)
    } :data

    .bss : ALIGN(4096) {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note.*)
        *(.comment)
    }
}
