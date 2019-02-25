; reirq.asm: A DOS TSR to redirect one IRQ to another.
;
; The intended use is as a workaround for software hard-coded to
; an IRQ that the hardware can't be set to. For example, some old
; games expect sound card / MIDI interface to be at a certain IRQ,
; but later hardware versions may not support that IRQ setting.
; And, in my case, I have a PS/2 machine on which IRQ 2/9 does not
; work for any ISA card, despite apparently being free, and an
; MPU-401 compatible card that some games expect on IRQ 2.
;
; Note that it doesn't suffice simply to redirect the interrupt
; handler: the Programmable Interrupt Controller's must also be
; updated, e.g., to copy the IRQ mask status between the source
; and target IRQs. This means that there is some overhead both
; in the IRQ handler itself, and in the int 08h timer handler,
; which is used to periodically sync the IRQ masks. It is
; therefore always preferable to configure the IRQ in software,
; if possible.
;
; I also suspect that this might not work on an XT since the
; presence of a second PIC (PC/AT and newer) is assumed. It
; should be quite simple to remove code related to that, but
; the performance overhead on an XT could be unacceptable.
;
; Absolutely no warranty - use at your own risk only!
;
; Change `source_irq` and `target_irq` below to the desired values,
; then assemble with `nasm -o reirq.com reirq.asm`. There are some
; other settings as well, mainly because I tried many things while
; developing this.
;
; Copyright (c) 2019 Kimmo Kulovesi, https://github.com/arkku/

BITS 16

SEGMENT .text
ORG 0x100

source_irq equ 3        ; the IRQ the hardware is set to
target_irq equ 9        ; the IRQ the software expects

; Use DOS services to register? If not, edit the interrupt vector directly.
register_with_int21h equ 1

; Use the old int 27h for TSR? If not, use function 31h of int 21h.
tsr_with_int27h equ 0

; Calculate the corresponding int and bit from the IRQs

%if source_irq == 2 || target_irq == 2
%warning "Using IRQ 2 as requested, but make sure you didn't mean IRQ 9."
%endif

%if source_irq < 0 || source_irq > 15 || target_irq < 0 || target_irq > 15
%error "Invalid IRQ."
%endif

%if source_irq <= 7
source_int equ (0x08 + source_irq)
%else
source_int equ (0x70 + (source_irq - 8))
%endif
source_bit equ (1 << source_irq)

%if target_irq <= 7
target_int equ (0x08 + target_irq)
%else
target_int equ (0x70 + (target_irq - 8))
%endif
target_bit equ (1 << target_irq)

timer_int equ 0x08

; Programmable Interrupt Controllers

pic1_ctrl equ 0x20
pic2_ctrl equ 0xA0
pic1_data equ 0x21
pic2_data equ 0xA1

; If non-zero, use "jump to next instruction" around `in` and `out`.
; I have seen various other PIC-related code use this around
; code related to the IRQ masks, but I don't know why - perhaps
; it has something to do with timing, or just a place to set a
; breakpoint. Things seem to work fine on my systems either way.
;
use_jmpnop equ 0

%if use_jmpnop != 0
%define jmpnop jmp $+2
%else
%define jmpnop
%endif

; If non-zero, save the old IRQ handler. Since there is currently
; no way to unload this TSR, this is only useful for debugging
; and manually unloading (e.g., with debug.com).
save_old_irq equ 0

start:
        jmp setup               ; skip the handlers when run

mutex   db 0                    ; lock for IRQ handler
mutex08 db 0                    ; lock for int 08h handler
next08h dd 0                    ; next int 08h handler
%if save_old_irq != 0
old     dd 0xF0002978           ; old IRQ handler (currently unused)
%endif

irq_handler:
        cmp byte [cs:mutex], 0  ; check if already locked
        je .redirect
        iret
.redirect:
        dec byte [cs:mutex]     ; lock
        push ax
        in al, pic2_data
        jmpnop
        mov ah, al
        in al, pic1_data
        jmpnop
        mov word [cs:start], ax ; store the mask before redirect
        pop ax
        int target_int          ; trigger the target IRQ handler

        push ax
        push bx
        in al, pic2_data
        jmpnop
        mov ah, al
        in al, pic1_data
        jmpnop
        mov bx, ax              ; bx = mask after redirect
        xor ax, word [cs:start]
        jz .done                ; mask is unchanged
        test bx, target_bit
        jz .target_off          ; target bit is unset
        or bx, source_bit       ; target is set so set the source
        jmp .update_mask
.target_off:
        mov ax, ~source_bit
        and bx, ax              ; unset the source as well
.update_mask:
        mov al, bl
        cli
        jmpnop
        out pic1_data, al
        jmpnop
        mov al, bh
        out pic2_data, al
        jmpnop
        sti
.done:
%if (source_irq > 7) && (target_irq <= 7)
        ; signal end of interrupt
        mov al, 20h
        cli
        jmpnop
        out pic2_ctrl, al
        jmpnop
        out pic1_ctrl, al
        jmpnop
%endif
        pop bx
        pop ax
        inc byte [cs:mutex]     ; unlock
        iret

int08_handler:
        pushf
        cli
        call far [cs:next08h]   ; call the original handler
        cmp byte [cs:mutex08], 0
        je .check_mask          ; check mutex
        iret
.check_mask:
        dec byte [cs:mutex08]   ; lock
        push ax
        push bx
        in al, pic1_data
        jmpnop
        mov bl, al
        in al, pic2_data
        jmpnop
        mov bh, al              ; bx = current mask
        mov ax, source_bit      ; ax = source IRQ bit
        test bx, target_bit     ; is target masked?
        jz .target_unmasked
        test bx, ax             ; is source masked?
        jnz .done               ; both are masked
        or bx, ax               ; mask source
        jmp .set_mask
.target_unmasked:
        test bx, ax             ; is source masked?
        jz .done                ; both are unmasked
        not ax
        and bx, ax              ; unmask source
.set_mask:
        mov al, bl
        jmpnop
        out pic1_data, al
        jmpnop
        mov al, bh
        out pic2_data, al
        jmpnop
.done:
        pop bx
        pop ax
        inc byte [cs:mutex08]   ; unlock
        iret

setup:
        push cs
        pop ds
%if register_with_int21h
        ; obtain current handler
        mov ax, (0x3500 | timer_int)
        int 0x21
        mov word [next08h], bx
        mov word [next08h + 2], es

        ; install handler
        mov ax, (0x2500 | timer_int)
        mov dx, int08_handler
        int 0x21

        ; obtain current handler
%if save_old_irq != 0
        mov ax, (0x3500 | source_int)
        int 0x21
        mov word [old], bx
        mov word [old + 2], es
%endif

        ; install handler
        mov ax, (0x2500 | source_int)
        mov dx, irq_handler
        int 0x21
%else
        ; set handler directly in the interrupt vector
        xor ax, ax
        mov es, ax
        mov bx, int08_handler
        cli

        ; int 08h handler
        mov ax, [es:timer_int * 4]
        mov word [next08h], ax
        mov ax, [es:timer_int * 4 + 2]
        mov word [next08h + 2], ax
        mov [es:timer_int * 4], bx
        mov [es:timer_int * 4 + 2], cs

        ; source IRQ handler
        mov bx, irq_handler
%if save_old_irq != 0
        mov ax, [es:source_int * 4]
        mov word [old], ax
        mov ax, [es:source_int * 4 + 2]
        mov word [old + 2], ax
%endif
        mov [es:source_int * 4], bx
        mov [es:source_int * 4 + 2], cs

        sti
        push cs
        pop es
%endif

        ; free environment
        mov es, [0x002C]
        mov ax, 0x4900
        int 21h

        ; terminate and stay resident
%if tsr_with_int27h != 0
        mov dx, setup
        int 0x27
%else
        mov ax, setup
        mov dx, ax
        mov cl, 4
        shr dx, cl              ; divide by 16
        and ax, 0x0F            ; check for remainder
        jz .tsr
        inc dx                  ; add 1 for incomplete paragraph
.tsr:
        mov ax, 0x3100
        int 0x21
%endif
