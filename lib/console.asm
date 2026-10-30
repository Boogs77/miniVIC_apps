;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                                              ;
;   CONSOLE.ASM  -  a scrolling 40 x 24 text console           ;
;                                                              ;
;   Writes at the cursor, CR goes to the next row, the screen  ;
;   scrolls up at the bottom (rows copied in VRAM, no RAM      ;
;   copy of the screen). CON_GETS reads a typed line.          ;
;   Needs lib/keys, lib/vtext.                                 ;
;   Uses: zp $EC-$EF, RAM $0560-$0587 (row), $0590-$05B7 (line);
;                                                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

CON_ROW     = $EC
CON_COL     = $ED
CON_LEN     = $EE      ; length of the typed line
CON_MAX     = $EF      ; longest line CON_GETS accepts
CON_ROWB    = $0560    ; one row while scrolling
CON_LINE    = $0590    ; the typed line, $00 at the end

; CON_CLS: blank screen, cursor at the top left
CON_CLS:
  STZ CON_ROW
  STZ CON_COL
  JMP VT_CLS

; CON_PUT: A at the cursor (CR = new row). Keeps A, X, Y
CON_PUT:
  PHA
  PHX
  PHY
  CMP #K_CR
  BEQ .cp_nl
  PHA
  LDA CON_ROW
  LDX CON_COL
  JSR VT_AT
  PLA
  STA VDP_DATA
  INC CON_COL
  LDA CON_COL
  CMP #40
  BCC .cp_x
.cp_nl:
  JSR CON_NL
.cp_x:
  PLY
  PLX
  PLA
  RTS

; CON_NL: cursor to the start of the next row, scrolling at the bottom
CON_NL:
  STZ CON_COL
  LDA CON_ROW
  CMP #23
  BCS CON_SCROLL
  INC CON_ROW
  RTS

; CON_SCROLL: rows 1-23 up by one, row 23 blank
CON_SCROLL:
  LDY #1
.cs_r:
  TYA
  JSR VT_ROWAD
  JSR VT_RADDR
  LDX #0
.cs_rd:
  LDA VDP_DATA
  STA CON_ROWB,X
  INX
  CPX #40
  BNE .cs_rd
  TYA
  DEC A
  JSR VT_ROW
  LDX #0
.cs_wr:
  LDA CON_ROWB,X
  STA VDP_DATA
  INX
  CPX #40
  BNE .cs_wr
  JSR KB_POLL
  INY
  CPY #24
  BNE .cs_r
  LDA #23
  JSR VT_ROW
  LDA #' '
  LDX #40
  JMP VT_REP

; VT_ROWAD: A = row -> A/X = VRAM address of its column 0. Keeps Y
VT_ROWAD:
  TAX
  LDA VT_ROWLO,X
  PHA
  LDA VT_ROWHI,X
  TAX
  PLA
  RTS

; CON_STR: the $00-terminated string A/X
CON_STR:
  STA VT_P
  STX VT_P+1
  LDY #0
.ct_l:
  LDA (VT_P),Y
  BEQ .ct_x
  JSR CON_PUT
  INY
  BNE .ct_l
.ct_x:
  RTS

CON_SP:
  LDA #' '
  JMP CON_PUT

CON_CR:
  LDA #K_CR
  JMP CON_PUT

; CON_HEX: A as 2 hex digits. Keeps X, Y
CON_HEX:
  PHA
  LSR
  LSR
  LSR
  LSR
  JSR .ch_d
  PLA
  PHA
  AND #$0F
  JSR .ch_d
  PLA
  RTS
.ch_d:
  CMP #10
  BCC .ch_n
  ADC #'A'-10-1-'0'      ; (C=1)
.ch_n:
  ADC #'0'
  JMP CON_PUT

; CON_GETS: reads a line at the cursor into CON_LINE. CON_LINE may hold a start text of
; CON_LEN characters (printed first). Letters become upper case. A = length (Enter)
CON_GETS:
  LDX #0
.cg_p:
  CPX CON_LEN
  BEQ .cg_c
  LDA CON_LINE,X
  JSR CON_PUT
  INX
  BRA .cg_p
.cg_c:
  LDA CON_ROW            ; cursor
  LDX CON_COL
  JSR VT_AT
  LDA #' '+$80
  STA VDP_DATA
  JSR WAITKEY
  CMP #K_CR
  BEQ .cg_ok
  CMP #K_BS
  BEQ .cg_bs
  CMP #' '
  BCC .cg_c
  CMP #$7F
  BCS .cg_c
  LDX CON_LEN
  CPX CON_MAX
  BCS .cg_c
  JSR UI_UPC
  STA CON_LINE,X
  INC CON_LEN
  LDX CON_COL            ; (the last column is kept for the cursor)
  CPX #39
  BCS .cg_c
  JSR CON_PUT
  BRA .cg_c
.cg_bs:
  LDA CON_LEN
  BEQ .cg_c
  DEC CON_LEN
  LDA CON_COL
  BEQ .cg_c
  LDA CON_ROW
  LDX CON_COL
  JSR VT_AT
  LDA #' '
  STA VDP_DATA
  DEC CON_COL
  BRA .cg_c
.cg_ok:
  LDA CON_ROW            ; no cursor left behind
  LDX CON_COL
  JSR VT_AT
  LDA #' '
  STA VDP_DATA
  LDX CON_LEN
  STZ CON_LINE,X
  JSR CON_CR
  LDA CON_LEN
  RTS
