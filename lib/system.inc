;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                                              ;
;   SYSTEM.INC  -  miniVIC / BO6502 addresses for the apps     ;
;   BIOS 27.10.26 KEYB/SD jump table, VDP, key codes           ;
;                                                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; ---------------- BIOS jump table ($FD00) ----------------
JT_CHROUT       = $FD00    ; A = char to screen AND serial (not used by the apps)
JT_CHRIN        = $FD03    ; C=1 and A = key, C=0 no key (serial first, then keyboard)
JT_INIT_CRT     = $FD09    ; text mode, VRAM and font of the BIOS
JT_LOAD_RUN_SLOT = $FD0C   ; A = SD slot: loads and runs it (never returns; error: BIOS menu)
JT_SHOW_MENU    = $FD0F    ; back to the BIOS menu (never returns)
JT_SD_READ      = $FD18    ; sector SD_LBA -> buffer X/Y (lo/hi, 512 bytes), C=1 error
JT_SD_WRITE     = $FD1B    ; buffer X/Y -> sector SD_LBA, C=1 error
JT_SD_INIT      = $FD1E    ; C=0 and A = card type, C=1 no card
JT_KB_MODE      = $FD21    ; A<>0 extended keyboard, A=0 classic
SD_LBA          = $0316    ; 4 bytes, sector number, little endian

; ---------------- RAM vectors (everything is polled) ----------------
IRQ_VEC         = $0FA0    ; JSR $0FA0 from the BIOS IRQ handler
NMI_VEC         = $0FD0    ; JSR $0FD0 from the BIOS NMI handler

; ---------------- VDP TMS9918A ----------------
VDP_DATA        = $B000
VDP_REG         = $B001
VRAM_NAME       = $0800    ; name table of the BIOS text mode (40 x 24)
VRAM_FONT       = $0000    ; patterns 0-127 (BIOS font), 128-255 = inverse (made by VT_INIT)

; ---------------- serial W65C51 ----------------
ACIA_DATA   = $C000
ACIA_STATUS = $C001    ; bit 3 = byte received
ACIA_CMD    = $C002    ; BIOS: $8B (no parity, receive IRQ off, DTR on)
ACIA_CTRL   = $C003    ; BIOS: $1F (19200, 8 bits, 1 stop)

; ---------------- key codes (extended mode) ----------------
K_CR            = $0D
K_BS            = $08
K_TAB           = $09
K_ESC           = $1B
K_UP            = $80
K_DOWN          = $81
K_LEFT          = $82
K_RIGHT         = $83
K_HOME          = $84
K_END           = $85
K_PGUP          = $86
K_PGDN          = $87
K_INS           = $88
K_DEL           = $89
K_F1            = $90      ; F1-F12 = $90-$9B
