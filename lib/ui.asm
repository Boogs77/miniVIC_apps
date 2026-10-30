;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                                              ;
;   UI.ASM  -  the parts every application shows the same way  ;
;                                                              ;
;   - PROMPT: a question on row 23, the answer typed after it  ;
;   - YESNO:  a Y/N question on row 23                         ;
;   - DOC_PICK: the list of the SD documents (open / delete)   ;
;   Needs lib/keys, lib/vtext, lib/num, lib/docs.              ;
;   Uses: zp $B0-$B7, RAM $02A0-$02C7 (UI_LINE),               ;
;         $02D8-$02F7 (UI_BUF)                                 ;
;                                                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

UI_LINE     = $02A0    ; 40 characters: a row being built (the apps may use it too)
UI_BUF      = $02D8    ; PROMPT answer (31 + $00)
UI_PTXT     = $B0      ; 2 bytes: question
UI_PMAX     = $B2      ; longest answer
UI_PUPC     = $B3      ; 1 = letters in upper case
UI_PLEN     = $B4      ; answer length
UI_SEL      = $B5      ; DOC_PICK: slot under the bar
UI_ROW      = $B6
UI_ANY      = $B7      ; DOC_PICK: 1 = every type can be opened, 0 = only DOC_T

; PROMPT: question A/X on row 23, the answer in UI_BUF (it starts with what is already
; there), UI_PMAX characters at most. C=0 and A = length (Enter), C=1 Esc
PROMPT:
  STA UI_PTXT
  STX UI_PTXT+1
  LDX #0
.pr_len:
  LDA UI_BUF,X
  BEQ .pr_d
  INX
  BRA .pr_len
.pr_d:
  STX UI_PLEN
.pr_draw:
  LDA #23
  JSR VT_ROW
  STZ VT_INV
  LDA UI_PTXT
  STA VT_P
  LDA UI_PTXT+1
  STA VT_P+1
  JSR VT_STR
  STY UI_ROW             ; (column)
  LDX #0
.pr_c:
  CPX UI_PLEN
  BEQ .pr_cur
  LDA UI_BUF,X
  STA VDP_DATA
  INX
  INC UI_ROW
  BRA .pr_c
.pr_cur:
  LDA #' '+$80           ; cursor
  STA VDP_DATA
  INC UI_ROW
  LDA #40
  SEC
  SBC UI_ROW
  BCC .pr_k
  BEQ .pr_k
  TAX
  LDA #' '
  JSR VT_REP
.pr_k:
  JSR WAITKEY
  CMP #K_CR
  BEQ .pr_ok
  CMP #K_ESC
  BEQ .pr_esc
  CMP #K_BS
  BEQ .pr_bs
  CMP #' '
  BCC .pr_k
  CMP #$7F
  BCS .pr_k
  LDX UI_PLEN
  CPX UI_PMAX
  BCS .pr_k
  LDY UI_PUPC
  BEQ .pr_s
  JSR UI_UPC
.pr_s:
  STA UI_BUF,X
  INX
  STZ UI_BUF,X
  STX UI_PLEN
  BRA .pr_draw
.pr_bs:
  LDX UI_PLEN
  BEQ .pr_k
  DEX
  STZ UI_BUF,X
  STX UI_PLEN
  BRA .pr_draw
.pr_ok:
  LDA UI_PLEN
  CLC
  RTS
.pr_esc:
  SEC
  RTS

; UI_UPC: lower case letter -> upper case. Keeps X, Y
UI_UPC:
  CMP #'a'
  BCC .uu_x
  CMP #'z'+1
  BCS .uu_x
  AND #$DF
.uu_x:
  RTS

; YESNO: question A/X on row 23; C=0 if the answer is Y
YESNO:
  PHX
  PHA
  LDA #23
  JSR VT_ROW
  STZ VT_INV
  PLA
  PLX
  LDY #0
  JSR VT_LINE
  JSR WAITKEY
  AND #$DF
  CMP #'Y'
  BEQ .yn_y
  SEC
  RTS
.yn_y:
  CLC
  RTS

; DOC_PICK: whole-screen list of the documents; arrows (^E ^X) choose, Enter opens,
; Del (^G) deletes after a question, Esc goes back. A/X = title.
; Enter on a free slot, or (UI_ANY = 0) on a document of another type, does nothing.
; C=0 and A = slot to open (index in DOC_IDX), C=1 and A=0 back, C=1 and A=$FF SD error.
; The caller redraws its screen afterwards.
DOC_PICK:
  STA UI_PTXT
  STX UI_PTXT+1
  JSR DOC_RDIDX
  BCC .dp_ok
  LDA #$FF
  RTS
.dp_ok:
  LDA #1
  STA UI_SEL
  JSR VT_CLS
.dp_draw:
  LDA #0
  JSR VT_ROW
  LDA #$80
  STA VT_INV
  LDA UI_PTXT
  LDX UI_PTXT+1
  LDY #0
  JSR VT_LINE
  LDA #1
  STA UI_ROW
.dp_r:
  JSR DP_ROW
  INC UI_ROW
  LDA UI_ROW
  CMP #DOC_SLOTS+1
  BNE .dp_r
  LDA #22
  JSR VT_ROW
  STZ VT_INV
  LDA #<DP_KEYS
  LDX #>DP_KEYS
  LDY #0
  JSR VT_LINE
  LDA #23
  JSR VT_ROW
  LDA #' '
  LDX #40
  JSR VT_REP
.dp_k:
  JSR WAITKEY
  CMP #K_ESC
  BEQ .dp_x
  CMP #K_UP
  BEQ .dp_up
  CMP #'E'-$40
  BEQ .dp_up
  CMP #K_DOWN
  BEQ .dp_dn
  CMP #'X'-$40
  BEQ .dp_dn
  CMP #K_CR
  BEQ .dp_go
  CMP #K_DEL
  BEQ .dp_del
  CMP #'G'-$40
  BEQ .dp_del
  BRA .dp_k
.dp_up:
  DEC UI_SEL
  BNE .dp_draw
  LDA #DOC_SLOTS
  STA UI_SEL
  BRA .dp_draw
.dp_dn:
  INC UI_SEL
  LDA UI_SEL
  CMP #DOC_SLOTS+1
  BNE .dp_draw
  LDA #1
  STA UI_SEL
  BRA .dp_draw
.dp_x:
  LDA #0
  SEC
  RTS
.dp_rd:
  JMP .dp_draw
.dp_del:
  LDA UI_SEL
  JSR DOC_ENTRY
  LDA (DOC_E)
  BEQ .dp_k
  LDA #<DP_QDEL
  LDX #>DP_QDEL
  JSR YESNO
  BCS .dp_rd
  LDA UI_SEL
  JSR DOC_ENTRY
  LDA #0
  STA (DOC_E)
  JSR DOC_WRIDX
  BCC .dp_rd
  LDA #$FF
  RTS
.dp_go:
  LDA UI_SEL
  JSR DOC_ENTRY
  LDA (DOC_E)
  BEQ .dp_k
  LDX UI_ANY
  BNE .dp_open
  CMP DOC_T
  BNE .dp_k
.dp_open:
  LDA UI_SEL
  CLC
  RTS

; DP_ROW: row UI_ROW+1 = slot UI_ROW: number, name, type, length
DP_ROW:
  LDX #39
  LDA #' '
.dr_b:
  STA UI_LINE,X
  DEX
  BPL .dr_b
  LDA UI_ROW
  CMP #10
  BCC .dr_1
  LDX #'1'
  STX UI_LINE+1
  SBC #10
.dr_1:
  ORA #'0'
  STA UI_LINE+2
  LDA UI_ROW
  JSR DOC_ENTRY
  LDA (DOC_E)
  BNE .dr_u
  LDX #6
.dr_e:
  LDA DP_EMPTY,X
  STA UI_LINE+5,X
  DEX
  BPL .dr_e
  BRA .dr_o
.dr_u:
  ASL                    ; type name (1 TEXT, 2 SHEET, 3 FILE, 4 CODE, other ????)
  ASL
  ASL
  CMP #DP_TYPES_END-DP_TYPES
  BCC .dr_t
  LDA #0
.dr_t:
  TAX
  LDY #0
.dr_tl:
  LDA DP_TYPES,X
  STA UI_LINE+19,Y
  INX
  INY
  CPY #5
  BNE .dr_tl
  LDY #4
  LDX #0
.dr_n:
  LDA (DOC_E),Y
  BEQ .dr_l
  STA UI_LINE+5,X
  INY
  INX
  CPX #DOC_NAMELEN
  BNE .dr_n
.dr_l:
  LDY #1
  LDA (DOC_E),Y
  STA NUM
  INY
  LDA (DOC_E),Y
  STA NUM+1
  LDA #<UI_LINE
  STA VT_P
  LDA #>UI_LINE
  STA VT_P+1
  LDY #26
  JSR NUMSTR
  LDX #4
.dr_c:
  LDA DP_BYTES,X
  STA UI_LINE+32,X
  DEX
  BPL .dr_c
.dr_o:
  LDA UI_ROW
  INC A
  JSR VT_ROW
  LDA UI_ROW
  CMP UI_SEL
  BEQ .dr_i
  LDA #0
  BRA .dr_w
.dr_i:
  LDA #$80
.dr_w:
  STA VT_INV
  LDX #0
.dr_wl:
  LDA UI_LINE,X
  ORA VT_INV
  STA VDP_DATA
  INX
  CPX #40
  BNE .dr_wl
  STZ VT_INV
  JMP KB_POLL

DP_EMPTY:   .byte "(EMPTY)"
DP_BYTES:   .byte "BYTES"
DP_TYPES:   .byte "?????   TEXT    SHEET   FILE    CODE    "
DP_TYPES_END:
DP_KEYS:    .byte "ENTER OPEN  DEL DELETE  ESC BACK",0
DP_QDEL:    .byte "DELETE THIS DOCUMENT (Y/N)?",0
