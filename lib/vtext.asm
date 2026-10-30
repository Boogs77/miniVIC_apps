;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                                              ;
;   VTEXT.ASM  -  40 x 24 text screen on the TMS9918A          ;
;                                                              ;
;   BIOS text mode (VDP interrupt off, so the main loop can    ;
;   write the VRAM at any time). VT_INIT also builds the       ;
;   inverse font: codes $80-$FF = codes $00-$7F inverted,      ;
;   used for the cursor, the status bar and the marked block.  ;
;   Long loops call KB_POLL (lib/keys.asm).                    ;
;   Uses: zp $A2-$A4, RAM $0800-$0BFF only inside VT_INIT      ;
;                                                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

VT_P        = $A2      ; 2 bytes: string pointer
VT_INV      = $A4      ; ORed to every character of VT_STR ($80 = inverse)
VT_FONTTMP  = $0800    ; RAM copy of the font (1 KB, only during VT_INIT)

; VT_INIT: text mode of the BIOS, inverse font, empty screen
VT_INIT:
  JSR JT_INIT_CRT
  LDA #<VRAM_FONT        ; read patterns 0-127 (1 KB)
  LDX #>VRAM_FONT
  JSR VT_RADDR
  LDX #0                 ; (the VRAM address increases by itself)
.vi_r0:
  LDA VDP_DATA
  STA VT_FONTTMP,X
  INX
  BNE .vi_r0
.vi_r1:
  LDA VDP_DATA
  STA VT_FONTTMP+$100,X
  INX
  BNE .vi_r1
.vi_r2:
  LDA VDP_DATA
  STA VT_FONTTMP+$200,X
  INX
  BNE .vi_r2
.vi_r3:
  LDA VDP_DATA
  STA VT_FONTTMP+$300,X
  INX
  BNE .vi_r3
  LDA #<(VRAM_FONT+$400) ; inverted copy at pattern 128
  LDX #>(VRAM_FONT+$400)
  JSR VT_WADDR
  LDX #0
.vi_w0:
  LDA VT_FONTTMP,X
  EOR #$FF
  STA VDP_DATA
  INX
  BNE .vi_w0
.vi_w1:
  LDA VT_FONTTMP+$100,X
  EOR #$FF
  STA VDP_DATA
  INX
  BNE .vi_w1
.vi_w2:
  LDA VT_FONTTMP+$200,X
  EOR #$FF
  STA VDP_DATA
  INX
  BNE .vi_w2
.vi_w3:
  LDA VT_FONTTMP+$300,X
  EOR #$FF
  STA VDP_DATA
  INX
  BNE .vi_w3
  STZ VT_INV
  JMP VT_CLS

; VT_WADDR: VRAM write address A (lo) / X (hi)
VT_WADDR:
  STA VDP_REG
  TXA
  ORA #$40
  STA VDP_REG
  RTS

; VT_RADDR: VRAM read address A (lo) / X (hi)
VT_RADDR:
  STA VDP_REG
  STX VDP_REG
  RTS

; VT_ROW: write address at column 0 of row A (0-23). Keeps Y
VT_ROW:
  TAX
  LDA VT_ROWLO,X
  PHA
  LDA VT_ROWHI,X
  TAX
  PLA
  JMP VT_WADDR

; VT_AT: write address at row A, column X. Keeps Y
VT_AT:
  PHX
  TAX
  PLA
  CLC
  ADC VT_ROWLO,X
  PHA
  LDA VT_ROWHI,X
  ADC #0
  TAX
  PLA
  JMP VT_WADDR

; VT_REP: writes X times the character A
VT_REP:
  CPX #0
  BEQ .vr_x
.vr_l:
  STA VDP_DATA
  PHA
  TXA
  AND #$0F
  BNE .vr_n
  JSR KB_POLL
.vr_n:
  PLA
  DEX
  BNE .vr_l
.vr_x:
  RTS

; VT_STR: writes the $00-terminated string at VT_P (ORA VT_INV). Y = characters written
VT_STR:
  LDY #0
.vs_l:
  LDA (VT_P),Y
  BEQ .vs_x
  ORA VT_INV
  STA VDP_DATA
  INY
  TYA
  AND #$0F
  BNE .vs_l
  JSR KB_POLL
  BRA .vs_l
.vs_x:
  RTS

; VT_LINE: string A/X (lo/hi) at the current address, then spaces (ORA VT_INV) up to
; column 40 of the row. Y = start column on entry
VT_LINE:
  STA VT_P
  STX VT_P+1
  STY .vl_c
  JSR VT_STR
  TYA
  CLC
  ADC .vl_c
  STA .vl_c
  LDA #40
  SEC
  SBC .vl_c
  BCC .vl_x
  TAX
  LDA #' '
  ORA VT_INV
  JMP VT_REP
.vl_x:
  RTS
.vl_c:
  .byte 0

; VT_CLS: whole screen blank
VT_CLS:
  LDA #<VRAM_NAME
  LDX #>VRAM_NAME
  JSR VT_WADDR
  LDY #4                 ; 4 x 240 = 960
.vc_l:
  LDA #' '
  LDX #240
  JSR VT_REP
  DEY
  BNE .vc_l
  RTS

VT_ROWLO:
  .byte <(VRAM_NAME+0*40),<(VRAM_NAME+1*40),<(VRAM_NAME+2*40),<(VRAM_NAME+3*40)
  .byte <(VRAM_NAME+4*40),<(VRAM_NAME+5*40),<(VRAM_NAME+6*40),<(VRAM_NAME+7*40)
  .byte <(VRAM_NAME+8*40),<(VRAM_NAME+9*40),<(VRAM_NAME+10*40),<(VRAM_NAME+11*40)
  .byte <(VRAM_NAME+12*40),<(VRAM_NAME+13*40),<(VRAM_NAME+14*40),<(VRAM_NAME+15*40)
  .byte <(VRAM_NAME+16*40),<(VRAM_NAME+17*40),<(VRAM_NAME+18*40),<(VRAM_NAME+19*40)
  .byte <(VRAM_NAME+20*40),<(VRAM_NAME+21*40),<(VRAM_NAME+22*40),<(VRAM_NAME+23*40)
VT_ROWHI:
  .byte >(VRAM_NAME+0*40),>(VRAM_NAME+1*40),>(VRAM_NAME+2*40),>(VRAM_NAME+3*40)
  .byte >(VRAM_NAME+4*40),>(VRAM_NAME+5*40),>(VRAM_NAME+6*40),>(VRAM_NAME+7*40)
  .byte >(VRAM_NAME+8*40),>(VRAM_NAME+9*40),>(VRAM_NAME+10*40),>(VRAM_NAME+11*40)
  .byte >(VRAM_NAME+12*40),>(VRAM_NAME+13*40),>(VRAM_NAME+14*40),>(VRAM_NAME+15*40)
  .byte >(VRAM_NAME+16*40),>(VRAM_NAME+17*40),>(VRAM_NAME+18*40),>(VRAM_NAME+19*40)
  .byte >(VRAM_NAME+20*40),>(VRAM_NAME+21*40),>(VRAM_NAME+22*40),>(VRAM_NAME+23*40)
