;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                                              ;
;   CALC  -  miniVIC CALC, spreadsheet (VisiCalc style)        ;
;   65C02 assembly, TMS9918A text mode 40 x 24                 ;
;   Needs the BIOS 27.10.26 KEYB/SD                            ;
;                                                              ;
;   - 26 x 99 cells (A1..Z99); a cell holds a label, a number  ;
;     or a formula; only the cells in use take memory          ;
;   - numbers: fixed point, 2 decimals (lib/fix32.asm)         ;
;   - formulas: + - * / with precedence, ( ), -x, cells (A1,   ;
;     $A$1), @SUM @AVG @MIN @MAX @COUNT over ranges (A1:B9 or  ;
;     A1...B9) and lists, @ABS( ) @INT( )                      ;
;   - an entry that starts with a letter or " is a label,      ;
;     otherwise a value (so a formula starts with + ( or @)    ;
;   - recalculation after every change, over the cells in use  ;
;     (heap order), repeated while values change (8 passes)    ;
;   - / commands: Blank, Clear, Replicate (relative copy,      ;
;     $ = absolute), Width, Save, Load, Quit; > go to,         ;
;     ! recalc; F1 help, F2 edit the cell, Del blanks it       ;
;   - sheets saved on the SD as text (one cell per line)       ;
;                                                              ;
;   MEMORY                                                     ;
;   $0050-$00FF  zero page (app $50-$9F, lib $A0-$E3)          ;
;   $0210-$029F  edit buffer, name, line buffers               ;
;   $0500-$053F  value stack of the formulas                   ;
;   $0600-$07FF  SD document index                             ;
;   $0800-$09FF  sector buffer for save / load                 ;
;   $1000-...    code, then the cell heap up to $6BE3          ;
;   $6BE4-$7FFF  cell table: 26 x 99 pointers                  ;
;                                                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

 .include "lib/system.inc"

; ---------------- parameters ----------------
NCOLS       = 26
NROWS       = 99
TABLE       = $8000-NCOLS*NROWS*2
GROWS       = 20       ; grid rows on the screen (screen rows 3-22)
HDRW        = 3        ; row number column
TXTMAX      = 36       ; longest cell entry
T_LABEL     = 1
T_VAL       = 2        ; a constant number
T_FORM      = 3        ; a formula
T_ERR       = $80
NAMELEN     = 12
CR          = $0D

; ---------------- zero page ----------------
CX          = $50      ; cursor cell
CY          = $51
LCOL        = $52      ; first column / row on the screen
TROW        = $53
CW          = $54      ; column width
NVIS        = $55      ; columns on the screen
HTOP        = $56      ; 2 bytes: end of the cell heap
MODF        = $58
DIRTY       = $59      ; 1 = whole grid to redraw
MSGP        = $5A      ; 2 bytes
EPOS        = $5C      ; formula: position in the text
ESP         = $5D      ; formula: stack pointer to go back to on an error
VSP         = $5E      ; value stack pointer
CELL        = $5F      ; 2 bytes: record of a cell
IDX         = $61      ; 2 bytes: cell index (row * 26 + col)
TP          = $63      ; 2 bytes: its table entry
RC          = $65      ; cell column / row (CELLTP, refs)
RR          = $66
SC0         = $67      ; range
SR0         = $68
SC1         = $69
SR1         = $6A
AGG         = $6B      ; 4 bytes: @function accumulator
ACNT        = $6F      ; 2 bytes: values counted
AFN         = $71      ; @function: 0 SUM 1 AVG 2 MIN 3 MAX 4 COUNT
T0          = $72
T1          = $73
T2          = $74
T3          = $75
P0          = $76      ; 2 bytes
P1          = $78      ; 2 bytes
P2          = $7A      ; 2 bytes
ELEN        = $7C      ; edit buffer length
EDIT        = $7D      ; 1 = typing a cell entry
CHG         = $7E      ; recalculation: a value changed
PASS        = $7F
DOCSLOT     = $80
PCX         = $81      ; cursor drawn last time ($FF = none)
PCY         = $82
DC          = $83      ; replicate: column / row shift
DR          = $84
TC0         = $85      ; replicate: target
TR0         = $86
TC1         = $87
TR1         = $88
GR          = $89      ; grid drawing: row, column
GC          = $8A
SECN        = $8B      ; save / load: sector number
SPOS        = $8C      ; 2 bytes: position in SECBUF
SLEN        = $8E      ; 2 bytes: bytes left to read
LNL         = $90      ; length of the line being loaded
RANGE       = $91      ; 1 = the last reference was a range
INV         = $92      ; $80 = cell drawn in inverse
XC          = $93      ; replicate: target cell
XR          = $94
RREF        = $95      ; MOVEREFS: row being rebuilt
LC          = $96      ; replicate: source cell of the block loop
LR          = $97
KIND        = $98      ; COPYONE: kind of the source cell
DIRC        = $99      ; replicate: 1 = columns backwards
DIRR        = $9A      ;            1 = rows backwards

; ---------------- RAM ----------------
EBUF        = $0210    ; cell entry being typed / built (36 + $00)
DOCNAME     = $0238    ; 12 + $00
LINEB       = $0248    ; line of a loaded sheet (40 + $00)
FIELD       = $0278    ; a cell as it is drawn (up to 20 characters)
VSTK        = $0500    ; value stack: 16 x 4 bytes
VSTK_N      = 16
SECBUF      = $0800    ; sector buffer (after VT_INIT, which uses it only at the start)

 .org $0FD0
  RTS                    ; NMI trampoline (the VDP interrupt is off)
 .org $1000

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; start and main loop

RESET:
  SEI
  CLD
  LDX #$FF
  TXS
  LDA #$60
  STA IRQ_VEC
  JSR VT_INIT
  JSR KB_INIT
  LDA #2                 ; type 2 = sheet
  STA DOC_T
  JSR SHEETNEW
  LDA #<M_HELLO
  LDX #>M_HELLO
  JSR SETMSG
MAIN:
  JSR FITVIEW
  LDA DIRTY
  BEQ .mn_c
  STZ DIRTY
  JSR DRAWALL
  BRA .mn_s
.mn_c:
  JSR DRAWCUR            ; only the old and the new cursor cell
.mn_s:
  JSR STATUS
  JSR EDITLINE
  JSR MSGLINE
IDLE:
  JSR GETKEY
  BCC IDLE
.mn_k:
  JSR DOKEY
  JSR KEYREADY
  BCC MAIN
  JSR GETKEY
  BRA .mn_k

; DOKEY: key A
DOKEY:
  STZ MSGP+1
  LDX EDIT
  BEQ .dk_n
  JMP EDITKEY
.dk_n:
  CMP #'/'
  BNE .dk_1
  JMP CMD_SLASH
.dk_1:
  CMP #'>'
  BNE .dk_2
  JMP CMD_GOTO
.dk_2:
  CMP #'!'
  BNE .dk_3
  JSR RECALC
  LDA #1
  STA DIRTY
  RTS
.dk_3:
  CMP #' '
  BCC .dk_c
  CMP #$7F
  BCS .dk_e
  STZ ELEN               ; a character starts a new entry
  LDX #1
  STX EDIT
  JMP EDITKEY
.dk_e:
  CMP #K_DEL
  BNE .dk_f1
  JMP CMD_BLANK
.dk_f1:
  CMP #K_F1
  BNE .dk_f2
  JMP CMD_HELP
.dk_f2:
  CMP #K_F1+1
  BNE .dk_c
  JMP CMD_EDIT
.dk_c:
  JMP MOVEKEY

; MOVEKEY: cursor keys (arrows, ^E ^X ^S ^D, Home, PgUp, PgDn). C=1 if A was not one
MOVEKEY:
  CMP #K_UP
  BEQ .mk_u
  CMP #'E'-$40
  BEQ .mk_u
  CMP #K_DOWN
  BEQ .mk_d
  CMP #'X'-$40
  BEQ .mk_d
  CMP #K_CR
  BEQ .mk_d
  CMP #K_LEFT
  BEQ .mk_l
  CMP #'S'-$40
  BEQ .mk_l
  CMP #K_RIGHT
  BEQ .mk_r
  CMP #'D'-$40
  BEQ .mk_r
  CMP #K_TAB
  BEQ .mk_r
  CMP #K_HOME
  BEQ .mk_h
  CMP #K_PGUP
  BEQ .mk_pu
  CMP #'R'-$40
  BEQ .mk_pu
  CMP #K_PGDN
  BEQ .mk_pd
  CMP #'C'-$40
  BEQ .mk_pd
  SEC
  RTS
.mk_u:
  LDA CY
  BEQ .mk_x
  DEC CY
  BRA .mk_x
.mk_d:
  LDA CY
  CMP #NROWS-1
  BCS .mk_x
  INC CY
  BRA .mk_x
.mk_l:
  LDA CX
  BEQ .mk_x
  DEC CX
  BRA .mk_x
.mk_r:
  LDA CX
  CMP #NCOLS-1
  BCS .mk_x
  INC CX
  BRA .mk_x
.mk_h:
  STZ CX
  STZ CY
  BRA .mk_x
.mk_pu:
  LDA CY
  SEC
  SBC #GROWS
  BCS .mk_ps
  LDA #0
.mk_ps:
  STA CY
  BRA .mk_x
.mk_pd:
  LDA CY
  CLC
  ADC #GROWS
  CMP #NROWS
  BCC .mk_ps
  LDA #NROWS-1
  BRA .mk_ps
.mk_x:
  CLC
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; entry

; EDITKEY: key A while typing an entry
EDITKEY:
  CMP #K_ESC
  BEQ .ek_esc
  CMP #K_BS
  BEQ .ek_bs
  CMP #' '
  BCC .ek_ctl
  CMP #$7F
  BCS .ek_ctl
  LDX ELEN
  CPX #TXTMAX
  BCS .ek_x
  STA EBUF,X
  INX
  STZ EBUF,X
  STX ELEN
.ek_x:
  RTS
.ek_bs:
  LDX ELEN
  BEQ .ek_x
  DEX
  STZ EBUF,X
  STX ELEN
  RTS
.ek_esc:
  STZ EDIT
  RTS
.ek_ctl:
  PHA                    ; Enter or a cursor key: the entry goes in, then the move
  JSR MOVEKEY_TEST
  PLA
  BCS .ek_x              ; other keys are ignored while typing
  PHA
  STZ EDIT
  LDA CX
  STA RC
  LDA CY
  STA RR
  JSR STOREENTRY
  JSR RECALC
  LDA #1
  STA DIRTY
  STA MODF
  PLA
  CMP #K_CR              ; Enter stays on the cell
  BEQ .ek_x
  JMP MOVEKEY

; MOVEKEY_TEST: C=0 if A is Enter or a cursor key
MOVEKEY_TEST:
  LDX #MKEYS_N-1
.mt_l:
  CMP MKEYS,X
  BEQ .mt_y
  DEX
  BPL .mt_l
  SEC
  RTS
.mt_y:
  CLC
  RTS
MKEYS:
  .byte K_CR, K_UP, K_DOWN, K_LEFT, K_RIGHT, K_TAB, K_HOME, K_PGUP, K_PGDN
  .byte 'E'-$40, 'X'-$40, 'S'-$40, 'D'-$40, 'R'-$40, 'C'-$40
MKEYS_N     = 15

; STOREENTRY: EBUF (ELEN characters) into cell RC/RR: label, number or formula.
; An empty entry (or a lone ") blanks the cell. C=1 memory full
STOREENTRY:
  STZ EBUF+TXTMAX
  LDA ELEN
  BNE .se_1
  JMP CLRCELL
.se_1:
  LDA EBUF
  CMP #'"'
  BEQ .se_q
  JSR ISLETTER
  BCS .se_v              ; not a letter: a value
  LDA #T_LABEL
  JMP SETCELL
.se_q:
  LDX #0                 ; "label: the quote goes away
.se_ql:
  LDA EBUF+1,X
  STA EBUF,X
  INX
  CPX ELEN
  BNE .se_ql
  DEC ELEN
  BEQ .se_clr
  LDA #T_LABEL
  JMP SETCELL
.se_clr:
  JMP CLRCELL
.se_v:
  LDA #<EBUF             ; a plain number?
  STA F_PTR
  LDA #>EBUF
  STA F_PTR+1
  LDY #0
  LDA EBUF
  CMP #'-'
  BNE .se_p
  INY
.se_p:
  JSR F_PARSE
  BCS .se_f
  LDA EBUF,Y
  BNE .se_f
  LDA EBUF
  CMP #'-'
  BNE .se_pp
  JSR F_NEG
.se_pp:
  LDA #T_VAL
  JMP SETCELL
.se_f:
  LDA #T_FORM            ; a formula: RECALC works out its value
  JMP SETCELL

; ISLETTER: C=0 if A is a letter
ISLETTER:
  AND #$DF
  CMP #'A'
  BCC .il_n
  CMP #'Z'+1
  BCS .il_n
  CLC
  RTS
.il_n:
  SEC
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; cells

; CELLTP: RC / RR -> IDX = RR*26 + RC, TP = its table entry
CELLTP:
  LDA RR
  STA T0
  STZ T1
  ASL T0                 ; *2
  ROL T1
  LDA T0
  STA IDX
  LDA T1
  STA IDX+1
  ASL T0                 ; *8
  ROL T1
  ASL T0
  ROL T1
  CLC
  LDA IDX
  ADC T0
  STA IDX
  LDA IDX+1
  ADC T1
  STA IDX+1
  ASL T0                 ; *16
  ROL T1
  CLC
  LDA IDX
  ADC T0
  STA IDX
  LDA IDX+1
  ADC T1
  STA IDX+1
  CLC
  LDA IDX
  ADC RC
  STA IDX
  BCC .ct_a
  INC IDX+1
.ct_a:
  LDA IDX                ; TP = TABLE + IDX * 2
  ASL
  STA TP
  LDA IDX+1
  ROL
  STA TP+1
  CLC
  LDA TP
  ADC #<TABLE
  STA TP
  LDA TP+1
  ADC #>TABLE
  STA TP+1
  RTS

; GETCELL: CELL = record of RC/RR (Z=1 empty)
GETCELL:
  JSR CELLTP
  LDY #1
  LDA (TP),Y
  STA CELL+1
  LDA (TP)
  STA CELL
  ORA CELL+1
  RTS

; CLRCELL: RC/RR empty
CLRCELL:
  JSR CELLTP
  LDA #0
  STA (TP)
  LDY #1
  STA (TP),Y
  CLC
  RTS

; SETCELL: RC/RR = type A, value FA (numbers), text EBUF. C=1 memory full
SETCELL:
  STA T3
  JSR CELLTP
  LDX #0                 ; text length with its $00
.sc_l:
  LDA EBUF,X
  BEQ .sc_e
  INX
  BRA .sc_l
.sc_e:
  TXA
  CLC
  ADC #9
  STA T2                 ; record length
  JSR ROOM
  BCC .sc_ok
  JSR GCOLLECT
  JSR CELLTP             ; (GCOLLECT used TP)
  JSR ROOM
  BCC .sc_ok
  LDA #<M_FULL
  LDX #>M_FULL
  JSR SETMSG
  SEC
  RTS
.sc_ok:
  LDA HTOP
  STA CELL
  LDA HTOP+1
  STA CELL+1
  LDY #0
  LDA T2
  STA (CELL),Y
  INY
  LDA IDX
  STA (CELL),Y
  INY
  LDA IDX+1
  STA (CELL),Y
  INY
  LDA T3
  STA (CELL),Y
  LDX #0
.sc_v:
  INY
  LDA FA,X
  STA (CELL),Y
  INX
  CPX #4
  BNE .sc_v
  LDX #0
.sc_t:
  INY
  LDA EBUF,X
  STA (CELL),Y
  BEQ .sc_d
  INX
  BRA .sc_t
.sc_d:
  LDA CELL               ; table entry
  STA (TP)
  LDY #1
  LDA CELL+1
  STA (TP),Y
  CLC
  LDA HTOP
  ADC T2
  STA HTOP
  BCC .sc_x
  INC HTOP+1
.sc_x:
  CLC
  RTS

; ROOM: C=0 if T2 bytes fit between HTOP and TABLE
ROOM:
  CLC
  LDA HTOP
  ADC T2
  STA T0
  LDA HTOP+1
  ADC #0
  STA T1
  LDA #<TABLE            ; TABLE >= HTOP + T2 ?
  CMP T0
  LDA #>TABLE
  SBC T1
  BCS .rm_ok
  SEC
  RTS
.rm_ok:
  CLC
  RTS

; GCOLLECT: compacts the heap (the records still in the table move down)
GCOLLECT:
  LDA #<HEAP0
  STA P0
  STA P1
  LDA #>HEAP0
  STA P0+1
  STA P1+1
.gc_l:
  LDA P0
  CMP HTOP
  LDA P0+1
  SBC HTOP+1
  BCS .gc_x
  LDY #1                 ; its table entry
  LDA (P0),Y
  STA IDX
  INY
  LDA (P0),Y
  STA IDX+1
  LDA IDX
  ASL
  STA TP
  LDA IDX+1
  ROL
  STA TP+1
  CLC
  LDA TP
  ADC #<TABLE
  STA TP
  LDA TP+1
  ADC #>TABLE
  STA TP+1
  LDA (P0)
  STA T0                 ; length
  LDA (TP)
  CMP P0
  BNE .gc_n
  LDY #1
  LDA (TP),Y
  CMP P0+1
  BNE .gc_n
  LDA P1                 ; alive: copy down, the table follows
  STA (TP)
  LDA P1+1
  STA (TP),Y
  LDY #0
.gc_c:
  LDA (P0),Y
  STA (P1),Y
  INY
  CPY T0
  BNE .gc_c
  CLC
  LDA P1
  ADC T0
  STA P1
  BCC .gc_n
  INC P1+1
.gc_n:
  CLC
  LDA P0
  ADC T0
  STA P0
  BCC .gc_p
  INC P0+1
.gc_p:
  JSR KB_POLL
  BRA .gc_l
.gc_x:
  LDA P1
  STA HTOP
  LDA P1+1
  STA HTOP+1
  RTS

; SHEETNEW: empty sheet, column width 9
SHEETNEW:
  STZ P0                 ; from the page of TABLE (the end of the heap goes too)
  LDA #>TABLE
  STA P0+1
  LDY #0
.sn_l:
  LDA #0
  STA (P0),Y
  INY
  BNE .sn_l
  INC P0+1
  BPL .sn_l              ; up to $7FFF
  LDA #<HEAP0
  STA HTOP
  LDA #>HEAP0
  STA HTOP+1
  STZ CX
  STZ CY
  STZ LCOL
  STZ TROW
  STZ MODF
  STZ EDIT
  STZ DOCSLOT
  LDA #9
  JSR SETWIDTH
  LDX #NAMELEN
.sn_n:
  STZ DOCNAME,X
  DEX
  BPL .sn_n
  LDA #1
  STA DIRTY
  RTS

; SETWIDTH: column width A (4-18), NVIS = 37 / width
SETWIDTH:
  STA CW
  LDA #40-HDRW
  LDX #0
.sw_l:
  CMP CW
  BCC .sw_x
  SBC CW
  INX
  BRA .sw_l
.sw_x:
  STX NVIS
  LDA #1
  STA DIRTY
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; recalculation and formulas

; RECALC: every formula, in the order of the cell heap (the cells in use only), again
; while a value changes (8 passes at most: chains written backwards need more)
RECALC:
  STZ PASS
.rc_p:
  STZ CHG
  LDA #<HEAP0
  STA P2
  LDA #>HEAP0
  STA P2+1
.rc_l:
  LDA P2                 ; up to HTOP
  CMP HTOP
  LDA P2+1
  SBC HTOP+1
  BCS .rc_e
  LDY #1                 ; still in the table? (an old copy of a cell is not)
  LDA (P2),Y
  ASL
  STA TP
  INY
  LDA (P2),Y
  ROL
  STA TP+1
  CLC
  LDA TP
  ADC #<TABLE
  STA TP
  LDA TP+1
  ADC #>TABLE
  STA TP+1
  LDA (TP)
  CMP P2
  BNE .rc_n
  LDY #1
  LDA (TP),Y
  CMP P2+1
  BNE .rc_n
  LDY #3
  LDA (P2),Y
  AND #$7F
  CMP #T_FORM
  BNE .rc_n
  LDA P2
  STA CELL
  LDA P2+1
  STA CELL+1
  JSR EVALCELL
.rc_n:
  CLC
  LDA (P2)
  ADC P2
  STA P2
  BCC .rc_k
  INC P2+1
.rc_k:
  JSR KB_POLL
  BRA .rc_l
.rc_e:
  INC PASS
  LDA CHG
  BEQ .rc_x
  LDA PASS
  CMP #8
  BCC .rc_p
.rc_x:
  RTS

; EVALCELL: works out the formula of CELL and keeps value and error flag (CHG = 1 if new)
EVALCELL:
  LDA CELL
  PHA
  LDA CELL+1
  PHA
  JSR EVAL
  PLA
  STA CELL+1
  PLA
  STA CELL
  LDA #T_FORM
  BCC .ev_ok
  LDA #T_FORM+T_ERR
  JSR F_ZERO
.ev_ok:
  LDY #3
  CMP (CELL),Y
  BEQ .ev_s
  LDX #1
  STX CHG
.ev_s:
  STA (CELL),Y
  LDX #0
.ev_v:
  INY
  LDA FA,X
  CMP (CELL),Y
  BEQ .ev_w
  LDA #1
  STA CHG
  LDA FA,X
.ev_w:
  STA (CELL),Y
  INX
  CPX #4
  BNE .ev_v
  RTS

; EVAL: formula text of CELL -> FA. C=1 error (bad formula, overflow, error cell)
EVAL:
  CLC
  LDA CELL
  ADC #8
  STA F_PTR
  LDA CELL+1
  ADC #0
  STA F_PTR+1
  STZ EPOS
  STZ VSP
  TSX
  STX ESP
  JSR EXPR
  JSR PEEK
  BNE EERR               ; something left over
  CLC
  RTS
EERR:
  LDX ESP                ; back to the caller of EVAL
  TXS
  SEC
  RTS

; PEEK: A = next character that is not a space (Z=1 end of the text)
PEEK:
  LDY EPOS
.pk_l:
  LDA (F_PTR),Y
  CMP #' '
  BNE .pk_x
  INY
  STY EPOS
  BRA .pk_l
.pk_x:
  CMP #0
  RTS

; EXPR: term { + term | - term }
EXPR:
  JSR TERM
.ex_l:
  JSR PEEK
  CMP #'+'
  BEQ .ex_o
  CMP #'-'
  BEQ .ex_o
  RTS
.ex_o:
  PHA
  INC EPOS
  JSR PUSHFA
  JSR TERM
  JSR POPAB
  PLA
  CMP #'+'
  BEQ .ex_a
  JSR F_SUB
  BRA .ex_c
.ex_a:
  JSR F_ADD
.ex_c:
  BCS EERR
  BRA .ex_l

; TERM: factor { * factor | / factor }
TERM:
  JSR FACTOR
.tm_l:
  JSR PEEK
  CMP #'*'
  BEQ .tm_o
  CMP #'/'
  BEQ .tm_o
  RTS
.tm_o:
  PHA
  INC EPOS
  JSR PUSHFA
  JSR FACTOR
  JSR POPAB
  PLA
  CMP #'*'
  BEQ .tm_m
  JSR F_DIV
  BRA .tm_c
.tm_m:
  JSR F_MUL
.tm_c:
  BCS EERR
  BRA .tm_l

; FACTOR: number, cell, (expr), -factor, +factor, @function
FACTOR:
  JSR PEEK
  CMP #'('
  BNE .fa_1
  INC EPOS
  JSR EXPR
  JMP CLOSEP
.fa_1:
  CMP #'-'
  BNE .fa_2
  INC EPOS
  JSR FACTOR
  JMP F_NEG
.fa_2:
  CMP #'+'
  BNE .fa_3
  INC EPOS
  JMP FACTOR
.fa_3:
  CMP #'@'
  BNE .fa_4
  JMP FUNC
.fa_4:
  CMP #'.'
  BEQ .fa_n
  CMP #'0'
  BCC .fa_5
  CMP #'9'+1
  BCS .fa_5
.fa_n:
  LDY EPOS
  JSR F_PARSE
  BCS .fa_e
  STY EPOS
  RTS
.fa_5:
  JSR PARSEREF
  BCS .fa_e
  JMP CELLVAL
.fa_e:
  JMP EERR

; CLOSEP: a ) must follow
CLOSEP:
  JSR PEEK
  CMP #')'
  BNE .cp_e
  INC EPOS
  RTS
.cp_e:
  JMP EERR

; PUSHFA / POPAB: value stack. POPAB: FB = FA (right operand), FA = popped (left one)
PUSHFA:
  LDA VSP
  CMP #VSTK_N*4
  BCS .pu_e
  TAX
  LDA FA
  STA VSTK,X
  LDA FA+1
  STA VSTK+1,X
  LDA FA+2
  STA VSTK+2,X
  LDA FA+3
  STA VSTK+3,X
  TXA
  CLC
  ADC #4
  STA VSP
  RTS
.pu_e:
  JMP EERR
POPAB:
  LDA FA
  STA FB
  LDA FA+1
  STA FB+1
  LDA FA+2
  STA FB+2
  LDA FA+3
  STA FB+3
  SEC
  LDA VSP
  SBC #4
  STA VSP
  TAX
  LDA VSTK,X
  STA FA
  LDA VSTK+1,X
  STA FA+1
  LDA VSTK+2,X
  STA FA+2
  LDA VSTK+3,X
  STA FA+3
  RTS

; PARSEREF: [$]letter[$]digits at EPOS -> RC, RR (0-based). C=1 not a cell
PARSEREF:
  JSR PEEK
  LDY EPOS
  CMP #'$'
  BNE .pr_c
  INY
  LDA (F_PTR),Y
.pr_c:
  JSR ISLETTER
  BCS .pr_e
  AND #$DF
  SEC
  SBC #'A'
  STA RC
  INY
  LDA (F_PTR),Y
  CMP #'$'
  BNE .pr_d
  INY
.pr_d:
  LDA #0                 ; row: 1 or 2 digits, 1..99
  STA RR
  LDX #0
.pr_dl:
  LDA (F_PTR),Y
  CMP #'0'
  BCC .pr_de
  CMP #'9'+1
  BCS .pr_de
  AND #$0F
  PHA
  LDA RR                 ; RR * 10 + digit
  ASL
  ASL
  ADC RR
  ASL
  STA RR
  PLA
  ADC RR
  STA RR
  INY
  INX
  CPX #3
  BCS .pr_e
  BRA .pr_dl
.pr_de:
  CPX #0
  BEQ .pr_e
  LDA RR
  BEQ .pr_e
  CMP #NROWS+1
  BCS .pr_e
  DEC RR
  STY EPOS
  CLC
  RTS
.pr_e:
  SEC
  RTS

; CELLVAL: FA = value of cell RC/RR (empty or label = 0). Error cell -> EERR
CELLVAL:
  JSR GETCELL
  BNE .cv_c
  JMP F_ZERO
.cv_c:
  LDY #3
  LDA (CELL),Y
  BMI .cv_e
  CMP #T_LABEL
  BNE .cv_v
  JMP F_ZERO
.cv_v:
  LDX #0
.cv_l:
  INY
  LDA (CELL),Y
  STA FA,X
  INX
  CPX #4
  BNE .cv_l
  RTS
.cv_e:
  JMP EERR

; FUNC: @SUM @AVG @MIN @MAX @COUNT (ranges and values) or @ABS( ) @INT( )
FUNC:
  INC EPOS               ; the @
  LDX #0                 ; function name
.fn_t:
  LDY EPOS
  LDA FNAMES,X
  BEQ .fn_e
  STX T0
.fn_c:
  LDA FNAMES,X
  BEQ .fn_m              ; whole name matched
  CMP (F_PTR),Y
  BEQ .fn_ok
  EOR #$20               ; (also in lower case)
  CMP (F_PTR),Y
  BNE .fn_no
.fn_ok:
  INX
  INY
  BRA .fn_c
.fn_no:
  LDX T0                 ; next name
.fn_s:
  LDA FNAMES,X
  INX
  CMP #0
  BNE .fn_s
  INX                    ; (its number)
  BRA .fn_t
.fn_m:
  STY EPOS
  LDA FNAMES+1,X
  STA AFN
  JSR PEEK
  CMP #'('
  BNE .fn_e
  INC EPOS
  LDA AFN
  CMP #5
  BCC .fn_agg
  JSR EXPR               ; @ABS / @INT
  JSR CLOSEP
  LDA AFN
  CMP #5
  BNE .fn_int
  LDA FA+3
  BPL .fn_x
  JMP F_NEG
.fn_int:
  JSR F_INT
  BCS .fn_e
.fn_x:
  RTS
.fn_e:
  JMP EERR
.fn_agg:
  STZ ACNT
  STZ ACNT+1
  JSR AGG0
.fn_i:
  LDA AFN
  PHA
  LDA EPOS               ; an argument: a range, or an expression
  PHA
  JSR PARSEREF
  BCS .fn_ex
  JSR PEEK
  CMP #':'
  BEQ .fn_rg
  CMP #'.'
  BEQ .fn_rg
.fn_ex:
  PLA                    ; back to the start of the argument
  STA EPOS
  LDX #3                 ; AGG and ACNT kept on the stack (AFN is under them):
.fn_sv:                  ; the argument can hold another @function
  LDA AGG,X
  PHA
  DEX
  BPL .fn_sv
  LDA ACNT
  PHA
  LDA ACNT+1
  PHA
  JSR EXPR
  PLA
  STA ACNT+1
  PLA
  STA ACNT
  LDX #0
.fn_rs:
  PLA
  STA AGG,X
  INX
  CPX #4
  BNE .fn_rs
  PLA
  STA AFN
  JSR AGGADD
  BRA .fn_nx
.fn_rg:
  PLA                    ; (EPOS no longer needed)
  PLA
  STA AFN
  LDA RC
  STA SC0
  LDA RR
  STA SR0
.fn_dots:
  INC EPOS               ; ':' or one or more '.'
  JSR PEEK
  CMP #'.'
  BEQ .fn_dots
  JSR PARSEREF
  BCS .fn_e
  JSR RANGEORDER
  JSR AGGRANGE
.fn_nx:
  JSR PEEK
  CMP #','
  BNE .fn_end
  INC EPOS
  BRA .fn_i
.fn_end:
  JSR CLOSEP
  LDA AFN                ; result
  CMP #1
  BEQ .fn_avg
  CMP #4
  BEQ .fn_cnt
  LDX #3
.fn_r:
  LDA AGG,X
  STA FA,X
  DEX
  BPL .fn_r
  RTS
.fn_avg:
  LDA ACNT
  ORA ACNT+1
  BEQ .fn_e2
  JSR ACNTFB
  LDX #3
.fn_ra:
  LDA AGG,X
  STA FA,X
  DEX
  BPL .fn_ra
  JSR F_DIV
  BCS .fn_e2
  RTS
.fn_cnt:
  JSR ACNTFB
  LDX #3
.fn_rc:
  LDA FB,X
  STA FA,X
  DEX
  BPL .fn_rc
  RTS
.fn_e2:
  JMP EERR

; ACNTFB: FB = ACNT as a number (ACNT * 100)
ACNTFB:
  LDA ACNT
  STA FA
  LDA ACNT+1
  STA FA+1
  STZ FA+2
  STZ FA+3
  LDA #100
  STA FB
  STZ FB+1
  STZ FB+2
  STZ FB+3
  JSR MUL32
  LDX #3
.ac_l:
  LDA FP,X
  STA FB,X
  DEX
  BPL .ac_l
  RTS

; AGG0: AGG = 0
AGG0:
  STZ AGG
  STZ AGG+1
  STZ AGG+2
  STZ AGG+3
  RTS

; AGGADD: one more value FA for the @function AFN
AGGADD:
  INC ACNT
  BNE .ag_a
  INC ACNT+1
.ag_a:
  LDA AFN
  CMP #2
  BCS .ag_mm
  LDX #3                 ; SUM, AVG (and COUNT keeps the sum too)
.ag_s:
  LDA AGG,X
  STA FB,X
  DEX
  BPL .ag_s
  JSR F_ADD
  BCS .ag_e
.ag_put:
  LDX #3
.ag_p:
  LDA FA,X
  STA AGG,X
  DEX
  BPL .ag_p
  RTS
.ag_mm:
  CMP #4
  BCS .ag_x              ; COUNT
  LDA ACNT+1             ; the first value is the min and the max
  BNE .ag_c
  LDA ACNT
  CMP #1
  BEQ .ag_put
.ag_c:
  LDX #3
.ag_b:
  LDA AGG,X
  STA FB,X
  DEX
  BPL .ag_b
  LDA AFN
  CMP #2
  BEQ .ag_min
  JSR F_CMP              ; MAX: FA >= AGG
  BCS .ag_put
  RTS
.ag_min:
  JSR F_CMP              ; MIN: FA < AGG
  BCC .ag_put
.ag_x:
  RTS
.ag_e:
  JMP EERR

; RANGEORDER: SC0/SR0 .. RC/RR -> SC0 <= SC1, SR0 <= SR1
RANGEORDER:
  LDA RC
  STA SC1
  LDA RR
  STA SR1
  LDA SC1
  CMP SC0
  BCS .ro_r
  LDX SC0
  STA SC0
  STX SC1
.ro_r:
  LDA SR1
  CMP SR0
  BCS .ro_x
  LDX SR0
  STA SR0
  STX SR1
.ro_x:
  RTS

; AGGRANGE: every number in SC0/SR0 .. SC1/SR1 into the @function (empty and label cells skipped)
AGGRANGE:
  LDA SR0
  STA RR
.ar_r:
  LDA SC0
  STA RC
.ar_c:
  JSR GETCELL
  BEQ .ar_n
  LDY #3
  LDA (CELL),Y
  BMI .ar_e
  CMP #T_LABEL
  BEQ .ar_n
  LDX #0
.ar_v:
  INY
  LDA (CELL),Y
  STA FA,X
  INX
  CPX #4
  BNE .ar_v
  JSR AGGADD
.ar_n:
  LDA RC
  CMP SC1
  INC RC
  BCC .ar_c
  JSR KB_POLL
  LDA RR
  CMP SR1
  INC RR
  BCC .ar_r
  RTS
.ar_e:
  JMP EERR

FNAMES:
  .byte "SUM",0,0
  .byte "AVG",0,1
  .byte "MIN",0,2
  .byte "MAX",0,3
  .byte "COUNT",0,4
  .byte "ABS",0,5
  .byte "INT",0,6
  .byte 0

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; screen

; FITVIEW: the cursor cell on the screen
FITVIEW:
  LDA CX
  CMP LCOL
  BCS .fv_r
  STA LCOL
  BRA .fv_d1
.fv_r:
  SEC
  SBC NVIS
  BCC .fv_y
  CMP LCOL
  BCC .fv_y
  INC A
  STA LCOL
.fv_d1:
  LDA #1
  STA DIRTY
.fv_y:
  LDA CY
  CMP TROW
  BCS .fv_b
  STA TROW
  BRA .fv_d2
.fv_b:
  SEC
  SBC #GROWS
  BCC .fv_x
  CMP TROW
  BCC .fv_x
  INC A
  STA TROW
.fv_d2:
  LDA #1
  STA DIRTY
.fv_x:
  RTS

; DRAWALL: column letters (row 2) and the grid (rows 3-22)
DRAWALL:
  LDA #2
  JSR VT_ROW
  LDA #' '+$80
  LDX #HDRW
  JSR VT_REP
  STZ GC
.da_h:
  LDA CW                 ; letter in the middle of the column
  LSR
  TAX
  LDA #' '+$80
  JSR VT_REP
  LDA GC
  CLC
  ADC LCOL
  ADC #'A'+$80
  CMP #'Z'+$80+1
  BCC .da_l
  LDA #' '+$80
.da_l:
  STA VDP_DATA
  LDA CW
  LSR
  EOR #$FF
  SEC
  ADC CW                 ; CW - CW/2 - 1
  TAX
  DEX
  LDA #' '+$80
  JSR VT_REP
  INC GC
  LDA GC
  CMP NVIS
  BNE .da_h
  LDA NVIS               ; the rest of the row
  LDX CW
  JSR MULAX
  CLC
  ADC #HDRW
  EOR #$FF
  SEC
  ADC #40
  TAX
  LDA #' '+$80
  JSR VT_REP
  STZ GR
.da_r:
  JSR DRAWROW
  INC GR
  LDA GR
  CMP #GROWS
  BNE .da_r
  LDA CX
  STA PCX
  LDA CY
  STA PCY
  RTS

; MULAX: A = A * X (small numbers)
MULAX:
  STA T0
  LDA #0
  CPX #0
  BEQ .mx_x
.mx_l:
  CLC
  ADC T0
  DEX
  BNE .mx_l
.mx_x:
  RTS

; DRAWROW: screen row GR (sheet row TROW + GR)
DRAWROW:
  LDA GR
  CLC
  ADC #3
  JSR VT_ROW
  LDA GR                 ; row number, 2 digits + space, inverse
  CLC
  ADC TROW
  INC A
  LDX #'0'-1
.dr_t:
  INX
  SEC
  SBC #10
  BCS .dr_t
  ADC #10+'0'+$80
  PHA
  TXA
  CMP #'0'
  BNE .dr_tt
  LDA #' '
.dr_tt:
  ORA #$80
  STA VDP_DATA
  PLA
  STA VDP_DATA
  LDA #' '+$80
  STA VDP_DATA
  STZ GC
.dr_c:
  LDA GC
  CLC
  ADC LCOL
  STA RC
  LDA GR
  CLC
  ADC TROW
  STA RR
  STZ INV
  LDA RC
  CMP CX
  BNE .dr_i
  LDA RR
  CMP CY
  BNE .dr_i
  LDA #$80
  STA INV
.dr_i:
  JSR CELLTEXT
  JSR PUTFIELD
  INC GC
  LDA GC
  CMP NVIS
  BNE .dr_c
  LDA NVIS
  LDX CW
  JSR MULAX
  CLC
  ADC #HDRW
  EOR #$FF
  SEC
  ADC #40
  TAX
  LDA #' '
  JMP VT_REP

; DRAWCUR: the cell left by the cursor in normal video, the new one in inverse
DRAWCUR:
  LDA PCX
  CMP CX
  BNE .dc_d
  LDA PCY
  CMP CY
  BEQ .dc_x
.dc_d:
  LDA PCX
  STA RC
  LDA PCY
  STA RR
  STZ INV
  JSR DRAWONE
  LDA CX
  STA RC
  STA PCX
  LDA CY
  STA RR
  STA PCY
  LDA #$80
  STA INV
  JMP DRAWONE
.dc_x:
  RTS

; DRAWONE: cell RC/RR at its place on the screen (if it is on the screen)
DRAWONE:
  LDA RC
  SEC
  SBC LCOL
  BCC .do_x
  CMP NVIS
  BCS .do_x
  LDX CW
  JSR MULAX
  CLC
  ADC #HDRW
  TAX
  LDA RR
  SEC
  SBC TROW
  BCC .do_x
  CMP #GROWS
  BCS .do_x
  CLC
  ADC #3
  JSR VT_AT
  JSR CELLTEXT
  JMP PUTFIELD
.do_x:
  RTS

; CELLTEXT: FIELD = cell RC/RR as shown: CW characters
CELLTEXT:
  LDX CW
  DEX
  LDA #' '
.ce_b:
  STA FIELD,X
  DEX
  BPL .ce_b
  LDA RC                 ; past column Z: blank
  CMP #NCOLS
  BCS .ce_x
  JSR GETCELL
  BEQ .ce_x
  LDY #3
  LDA (CELL),Y
  BMI .ce_err
  CMP #T_LABEL
  BEQ .ce_lab
  LDX #0                 ; a number, right aligned in CW-1
.ce_v:
  INY
  LDA (CELL),Y
  STA FA,X
  INX
  CPX #4
  BNE .ce_v
  JSR F_FMT
  STA T0
  LDX CW
  DEX
  CPX T0
  BCS .ce_fit
  DEX                    ; too long: '>' marks
  LDA #'>'
.ce_g:
  STA FIELD,X
  DEX
  BPL .ce_g
  RTS
.ce_fit:
  TXA                    ; start column = CW - 1 - length
  SEC
  SBC T0
  TAX
  LDY #0
.ce_n:
  LDA F_OUT,Y
  BEQ .ce_x
  STA FIELD,X
  INX
  INY
  BRA .ce_n
.ce_lab:
  LDY #8
  LDX #0
.ce_ll:
  LDA (CELL),Y
  BEQ .ce_x
  STA FIELD,X
  INY
  INX
  CPX CW
  BNE .ce_ll
.ce_x:
  RTS
.ce_err:
  LDX CW
  DEX
  DEX
  LDY #4
.ce_el:
  LDA M_ERRF,Y
  STA FIELD,X
  DEX
  DEY
  BMI .ce_x
  CPX #$FF
  BNE .ce_el
  RTS

; PUTFIELD: FIELD (CW characters) to the VDP, ORA INV
PUTFIELD:
  LDX #0
.pf_l:
  LDA FIELD,X
  ORA INV
  STA VDP_DATA
  INX
  CPX CW
  BNE .pf_l
  JMP KB_POLL

; CELLNAME: name of RC/RR at UI_LINE+X ("A1".."Z99"), X after it
CELLNAME:
  LDA RC
  CLC
  ADC #'A'
  STA UI_LINE,X
  INX
  LDA RR
  INC A
  LDY #'0'-1
.cn_t:
  INY
  SEC
  SBC #10
  BCS .cn_t
  ADC #10+'0'
  CPY #'0'
  BEQ .cn_u
  PHA
  TYA
  STA UI_LINE,X
  INX
  PLA
.cn_u:
  STA UI_LINE,X
  INX
  RTS

; STATUS: row 0: cell name, kind and contents; free bytes
STATUS:
  LDX #39
  LDA #' '
.st_b:
  STA UI_LINE,X
  DEX
  BPL .st_b
  LDA CX
  STA RC
  LDA CY
  STA RR
  LDX #1
  JSR CELLNAME
  JSR GETCELL
  BEQ .st_f
  LDY #3
  LDA (CELL),Y
  AND #$7F
  TAY
  LDA M_KIND-1,Y
  STA UI_LINE+6
  LDA #'('
  STA UI_LINE+5
  LDA #')'
  STA UI_LINE+7
  LDY #8                 ; contents
  LDX #9
.st_t:
  LDA (CELL),Y
  BEQ .st_f
  STA UI_LINE,X
  INY
  INX
  CPX #32
  BNE .st_t
.st_f:
  SEC                    ; free bytes = TABLE - HTOP
  LDA #<TABLE
  SBC HTOP
  STA NUM
  LDA #>TABLE
  SBC HTOP+1
  STA NUM+1
  LDA #<UI_LINE
  STA VT_P
  LDA #>UI_LINE
  STA VT_P+1
  LDY #34
  JSR NUMSTR
  LDA #0
  JSR VT_ROW
  LDX #0
.st_o:
  LDA UI_LINE,X
  ORA #$80
  STA VDP_DATA
  INX
  CPX #40
  BNE .st_o
  RTS

; EDITLINE: row 1: the entry being typed
EDITLINE:
  LDA #1
  JSR VT_ROW
  LDA EDIT
  BNE .el_e
  LDA #' '
  LDX #40
  JMP VT_REP
.el_e:
  LDA #'>'
  STA VDP_DATA
  LDA #' '
  STA VDP_DATA
  LDX #0
.el_l:
  CPX ELEN
  BEQ .el_c
  LDA EBUF,X
  STA VDP_DATA
  INX
  BRA .el_l
.el_c:
  LDA #' '+$80
  STA VDP_DATA
  TXA
  EOR #$FF
  SEC
  ADC #40-3
  TAX
  LDA #' '
  JMP VT_REP

; MSGLINE: row 23: message or hint
MSGLINE:
  LDA #23
  JSR VT_ROW
  STZ VT_INV
  LDA MSGP
  LDX MSGP+1
  BNE .ml_o
  LDA #<M_HINT
  LDX #>M_HINT
.ml_o:
  LDY #0
  JMP VT_LINE

SETMSG:
  STA MSGP
  STX MSGP+1
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; commands

CMD_EDIT:
  LDA CX                 ; F2: the cell contents in the entry line
  STA RC
  LDA CY
  STA RR
  STZ ELEN
  JSR GETCELL
  BEQ .ed_go
  LDY #3
  LDX #0
  LDA (CELL),Y
  AND #$7F
  CMP #T_LABEL
  BNE .ed_c
  LDY #8                 ; a label that does not start with a letter gets its "
  LDA (CELL),Y
  JSR ISLETTER
  BCC .ed_c
  LDA #'"'
  STA EBUF
  INX
.ed_c:
  LDY #8
.ed_l:
  LDA (CELL),Y
  STA EBUF,X
  BEQ .ed_e
  INY
  INX
  CPX #TXTMAX
  BNE .ed_l
.ed_e:
  STX ELEN
.ed_go:
  LDA #1
  STA EDIT
  RTS

CMD_BLANK:
  LDA CX
  STA RC
  LDA CY
  STA RR
  JSR CLRCELL
  JSR RECALC
  LDA #1
  STA DIRTY
  STA MODF
  RTS

; CMD_SLASH: / then a letter
CMD_SLASH:
  LDA #23
  JSR VT_ROW
  STZ VT_INV
  LDA #<M_SLASH
  LDX #>M_SLASH
  LDY #0
  JSR VT_LINE
  JSR WAITKEY
  JSR UI_UPC
  LDX #0
.sl_l:
  LDY SLTAB,X
  BEQ .sl_x
  CMP SLTAB,X
  BEQ .sl_go
  INX
  INX
  INX
  BRA .sl_l
.sl_go:
  LDA SLTAB+1,X
  STA P0
  LDA SLTAB+2,X
  STA P0+1
  JMP (P0)
.sl_x:
  RTS

SLTAB:
  .byte 'B'
  .word CMD_BLANK
  .byte 'C'
  .word CMD_CLEAR
  .byte 'R'
  .word CMD_REPL
  .byte 'W'
  .word CMD_WIDTH
  .byte 'S'
  .word CMD_SAVE
  .byte 'L'
  .word CMD_LOAD
  .byte 'Q'
  .word CMD_QUIT
  .byte 0

CMD_CLEAR:
  JSR CHKMOD
  BCS .cl_x
  JSR SHEETNEW
.cl_x:
  RTS

CMD_QUIT:
  JSR CHKMOD
  BCS .cq_x
  JSR KB_EXIT
  JMP JT_SHOW_MENU
.cq_x:
  RTS

; CHKMOD: C=1 keep the sheet (changed and the answer was not Y)
CHKMOD:
  LDA MODF
  BEQ .ck_x
  LDA #<Q_ABANDON
  LDX #>Q_ABANDON
  JMP YESNO
.ck_x:
  CLC
  RTS

CMD_WIDTH:
  STZ UI_BUF
  LDA #2
  STA UI_PMAX
  LDA #<P_WIDTH
  LDX #>P_WIDTH
  JSR PROMPT
  BCS .cw_x
  LDA #<UI_BUF
  STA F_PTR
  LDA #>UI_BUF
  STA F_PTR+1
  LDY #0
  JSR F_PARSE            ; (width * 100)
  BCS .cw_x
  JSR HUND
  CMP #4
  BCC .cw_x
  CMP #19
  BCS .cw_x
  JSR SETWIDTH
  LDA #1
  STA MODF
.cw_x:
  LDA #1
  STA DIRTY
  RTS

; HUND: A = FA / 100 (FA small and positive)
HUND:
  JSR F_TOFP
  LDA #100
  STA FT
  JSR DIVP8
  LDA FP
  RTS

; CMD_GOTO: > then a cell name
CMD_GOTO:
  STZ UI_BUF
  LDA #3
  STA UI_PMAX
  LDA #1
  STA UI_PUPC
  LDA #<P_GOTO
  LDX #>P_GOTO
  JSR PROMPT
  BCS .gt_x
  JSR PROMPTREF
  BCS .gt_x
  LDA RC
  STA CX
  LDA RR
  STA CY
.gt_x:
  RTS

; PROMPTREF: UI_BUF holds a cell (or a range): RC/RR (and SC0..SC1 / SR0..SR1). C=1 bad
PROMPTREF:
  LDA #<UI_BUF
  STA F_PTR
  LDA #>UI_BUF
  STA F_PTR+1
  STZ EPOS
  JSR PARSEREF
  BCS .pf_x
  LDA RC
  STA SC0
  STA SC1
  LDA RR
  STA SR0
  STA SR1
  STZ RANGE
  JSR PEEK
  BEQ .pf_ok
  CMP #':'
  BEQ .pf_r
  CMP #'.'
  BNE .pf_bad
.pf_r:
  INC EPOS
  JSR PEEK
  CMP #'.'
  BEQ .pf_r
  LDA RC
  PHA
  LDA RR
  PHA
  JSR PARSEREF
  BCS .pf_bad2
  JSR RANGEORDER
  PLA
  STA RR
  PLA
  STA RC
  LDA #1
  STA RANGE
  JSR PEEK
  BNE .pf_bad
.pf_ok:
  CLC
.pf_x:
  RTS
.pf_bad2:
  PLA
  PLA
.pf_bad:
  SEC
  RTS

; CMD_REPL: /R copy FROM (a cell or a range) TO (a range for one cell, the top left cell
; for a range). Cell references move with the copy, except the parts with $ before them
CMD_REPL:
  LDA CX                 ; FROM, the cursor cell is offered
  STA RC
  LDA CY
  STA RR
  LDX #0
  JSR CELLNAME
  STZ UI_LINE,X
  LDX #0
.rp_c:
  LDA UI_LINE,X
  STA UI_BUF,X
  BEQ .rp_p
  INX
  BRA .rp_c
.rp_p:
  LDA #9
  STA UI_PMAX
  LDA #1
  STA UI_PUPC
  LDA #<P_FROM
  LDX #>P_FROM
  JSR PROMPT
  BCC .fb5
  JMP .rp_x
.fb5:
  JSR PROMPTREF
  BCC .fb4
  JMP .rp_bad
.fb4:
  LDA SC0                ; keep the source
  PHA
  LDA SR0
  PHA
  LDA SC1
  PHA
  LDA SR1
  PHA
  STZ UI_BUF
  LDA #<P_TO
  LDX #>P_TO
  JSR PROMPT
  BCC .fb3
  JMP .rp_x4
.fb3:
  JSR PROMPTREF
  BCC .fb2
  JMP .rp_bad4
.fb2:
  LDA SC0
  STA TC0
  LDA SR0
  STA TR0
  LDA SC1
  STA TC1
  LDA SR1
  STA TR1
  PLA
  STA SR1
  PLA
  STA SC1
  PLA
  STA SR0
  PLA
  STA SC0
  LDA SC0                ; one source cell: to every target cell
  CMP SC1
  BNE .rp_blk
  LDA SR0
  CMP SR1
  BNE .rp_blk
  LDA TR0
  STA XR
.rp_1r:
  LDA TC0
  STA XC
.rp_1c:
  LDA SC0
  STA RC
  LDA SR0
  STA RR
  JSR COPYONE
  BCC .fb1
  JMP .rp_full
.fb1:
  LDA XC
  CMP TC1
  INC XC
  BCC .rp_1c
  LDA XR
  CMP TR1
  INC XR
  BCC .rp_1r
  JMP .rp_done
.rp_blk:
  STZ DIRC               ; a range: the block to the target cell. When the target is
  STZ DIRR               ; after the source, backwards (an overlap reads cells not yet changed)
  LDA SC0
  STA LC
  LDA TC0
  CMP SC0
  BEQ .rp_r0
  BCC .rp_r0
  INC DIRC
  LDA SC1
  STA LC
.rp_r0:
  LDA SR0
  STA LR
  LDA TR0
  CMP SR0
  BEQ .rp_br
  BCC .rp_br
  INC DIRR
  LDA SR1
  STA LR
.rp_br:
  LDA DIRC               ; first column of this row
  BEQ .rp_bf
  LDA SC1
  BRA .rp_bs
.rp_bf:
  LDA SC0
.rp_bs:
  STA LC
.rp_bc:
  LDA LC                 ; target = TC0/TR0 + (source - SC0/SR0)
  SEC
  SBC SC0
  CLC
  ADC TC0
  STA XC
  LDA LR
  SEC
  SBC SR0
  CLC
  ADC TR0
  STA XR
  LDA XC
  CMP #NCOLS
  BCS .rp_bn
  LDA XR
  CMP #NROWS
  BCS .rp_bn
  LDA LC
  STA RC
  LDA LR
  STA RR
  JSR COPYONE
  BCS .rp_full
.rp_bn:
  LDA DIRC               ; next column
  BEQ .rp_cf
  LDA LC
  CMP SC0
  BEQ .rp_nr
  DEC LC
  BRA .rp_bc
.rp_cf:
  LDA LC
  CMP SC1
  BEQ .rp_nr
  INC LC
  BRA .rp_bc
.rp_nr:
  LDA DIRR               ; next row
  BEQ .rp_rf
  LDA LR
  CMP SR0
  BEQ .rp_done
  DEC LR
  BRA .rp_br
.rp_rf:
  LDA LR
  CMP SR1
  BEQ .rp_done
  INC LR
  BRA .rp_br
.rp_done:
  JSR RECALC
  LDA #1
  STA MODF
  STA DIRTY
.rp_x:
  RTS
.rp_x4:
  PLA
  PLA
  PLA
  PLA
  RTS
.rp_bad4:
  PLA
  PLA
  PLA
  PLA
.rp_bad:
  LDA #<M_BADREF
  LDX #>M_BADREF
  JMP SETMSG
.rp_full:
  JSR RECALC
  LDA #1
  STA DIRTY
  RTS

; COPYONE: cell RC/RR to the cell XC/XR, references moved by the difference.
; C=1 memory full
COPYONE:
  LDA XC
  SEC
  SBC RC
  STA DC
  LDA XR
  SEC
  SBC RR
  STA DR
  JSR GETCELL
  BNE .co_c
  LDA XC
  STA RC
  LDA XR
  STA RR
  JMP CLRCELL
.co_c:
  LDY #3
  LDA (CELL),Y
  AND #$7F
  STA KIND
  LDX #0
.co_v:
  INY
  LDA (CELL),Y
  STA FA,X
  INX
  CPX #4
  BNE .co_v
  LDA KIND
  CMP #T_FORM
  BEQ .co_f
  LDY #8                 ; label or number: the text as it is
  LDX #0
.co_t:
  LDA (CELL),Y
  STA EBUF,X
  BEQ .co_s
  INY
  INX
  BRA .co_t
.co_f:
  JSR MOVEREFS
.co_s:
  LDA XC
  STA RC
  LDA XR
  STA RR
  LDA KIND
  JMP SETCELL

; MOVEREFS: formula of CELL -> EBUF with the cell references moved by DC / DR
; (a part with $ before it stays); a reference pushed out of the sheet becomes "#"
MOVEREFS:
  LDY #8
  LDX #0
.mr_l:
  LDA (CELL),Y
  BNE .mr_g
  JMP .mr_x
.mr_g:
  CMP #'@'               ; a function name is copied as it is
  BNE .mr_r
.mr_fn:
  JSR .mr_put
  INY
  LDA (CELL),Y
  JSR ISLETTER
  BCS .mr_l
  LDA (CELL),Y
  BRA .mr_fn
.mr_r:
  CMP #'$'
  BEQ .mr_ref
  JSR ISLETTER
  BCC .mr_ref
  LDA (CELL),Y
  JSR .mr_put
  INY
  BRA .mr_l
.mr_ref:
  STZ T0                 ; T0 bit 0: column absolute, bit 1: row absolute
  LDA (CELL),Y
  CMP #'$'
  BNE .mr_c
  INC T0
  INY
  LDA (CELL),Y
.mr_c:
  AND #$DF               ; column
  SEC
  SBC #'A'
  STA T1
  LDA T0
  AND #1
  BNE .mr_ca
  LDA T1
  CLC
  ADC DC
  STA T1
.mr_ca:
  INY
  LDA (CELL),Y
  CMP #'$'
  BNE .mr_rw
  LDA T0
  ORA #2
  STA T0
  INY
.mr_rw:
  STZ RREF               ; row digits
  STZ T2                 ; (count)
.mr_d:
  LDA (CELL),Y
  CMP #'0'
  BCC .mr_de
  CMP #'9'+1
  BCS .mr_de
  AND #$0F
  PHA
  LDA RREF
  ASL
  ASL
  ADC RREF
  ASL
  STA RREF
  PLA
  ADC RREF
  STA RREF
  INY
  INC T2
  LDA T2
  CMP #3
  BCC .mr_d
.mr_de:
  DEC RREF               ; 0-based
  LDA T0
  AND #2
  BNE .mr_ra
  LDA RREF
  CLC
  ADC DR
  STA RREF
.mr_ra:
  LDA T1
  CMP #NCOLS
  BCS .mr_bad
  LDA RREF
  CMP #NROWS
  BCS .mr_bad
  LDA T0
  AND #1
  BEQ .mr_o1
  LDA #'$'
  JSR .mr_put
.mr_o1:
  LDA T1
  CLC
  ADC #'A'
  JSR .mr_put
  LDA T0
  AND #2
  BEQ .mr_o2
  LDA #'$'
  JSR .mr_put
.mr_o2:
  LDA RREF
  INC A
  PHY
  LDY #'0'-1
.mr_t:
  INY
  SEC
  SBC #10
  BCS .mr_t
  ADC #10+'0'
  CPY #'0'
  BEQ .mr_u
  PHA
  TYA
  JSR .mr_put
  PLA
.mr_u:
  JSR .mr_put
  PLY
  JMP .mr_l
.mr_bad:
  LDA #'#'
  JSR .mr_put
  JMP .mr_l
.mr_x:
  STZ EBUF,X
  RTS
.mr_put:
  CPX #TXTMAX
  BCS .mp_x
  STA EBUF,X
  INX
.mp_x:
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; save / load

; CMD_SAVE: /S name, then the sheet as text: "/W9" then one "A1 text" line per cell
; (labels as "A1 "text)
CMD_SAVE:
  LDX #NAMELEN
.sv_c:
  LDA DOCNAME,X
  STA UI_BUF,X
  DEX
  BPL .sv_c
  LDA #NAMELEN
  STA UI_PMAX
  LDA #1
  STA UI_PUPC
  LDA #<P_SAVE
  LDX #>P_SAVE
  JSR PROMPT
  BCC .fb8
  JMP .sv_x
.fb8:
  CMP #0
  BNE .fb7
  JMP .sv_x
.fb7:
  LDX #0
.sv_n:
  LDA UI_BUF,X
  STA DOCNAME,X
  BEQ .sv_z
  INX
  CPX #NAMELEN
  BNE .sv_n
  BRA .sv_go
.sv_z:
  STZ DOCNAME,X
  INX
  CPX #NAMELEN+1
  BNE .sv_z
.sv_go:
  JSR DOC_RDIDX
  BCC .fb6
  JMP .sv_err
.fb6:
  LDA #<DOCNAME
  STA DOC_P
  LDA #>DOCNAME
  STA DOC_P+1
  JSR DOC_FIND
  BCC .sv_k
  JSR DOC_FREE
  BCC .sv_k
  LDA #<M_NOSLOT
  LDX #>M_NOSLOT
  JMP SETMSG
.sv_k:
  STA DOCSLOT
  STA DOC_K
  STZ SECN
  STZ SPOS
  STZ SPOS+1
  LDA #'/'               ; width
  JSR EMIT
  LDA #'W'
  JSR EMIT
  LDA CW
  JSR EMITNUM
  LDA #CR
  JSR EMIT
  STZ RR
.sv_r:
  STZ RC
.sv_cl:
  JSR GETCELL
  BEQ .sv_nx
  LDX #0
  JSR CELLNAME
  STX T0
  LDX #0
.sv_nm:
  LDA UI_LINE,X
  JSR EMIT
  INX
  CPX T0
  BNE .sv_nm
  LDA #' '
  JSR EMIT
  LDY #3
  LDA (CELL),Y
  AND #$7F
  CMP #T_LABEL
  BNE .sv_t
  LDA #'"'
  JSR EMIT
.sv_t:
  LDY #8
.sv_tl:
  LDA (CELL),Y
  BEQ .sv_te
  JSR EMIT
  INY
  BRA .sv_tl
.sv_te:
  LDA #CR
  JSR EMIT
.sv_nx:
  INC RC
  LDA RC
  CMP #NCOLS
  BNE .sv_cl
  INC RR
  LDA RR
  CMP #NROWS
  BNE .sv_r
  LDA SECN               ; length = sectors * 512 + position
  ASL
  CLC
  ADC SPOS+1
  STA DOC_LEN+1
  LDA SPOS
  STA DOC_LEN
  JSR FLUSH              ; the last part
  LDA SECN
  CMP #DOC_SECTS+1
  BCS .sv_big
  LDA #<DOCNAME
  STA DOC_P
  LDA #>DOCNAME
  STA DOC_P+1
  LDA DOCSLOT
  JSR DOC_SETENT
  JSR DOC_WRIDX
  BCS .sv_err
  STZ MODF
  LDA #<M_SAVED
  LDX #>M_SAVED
  JMP SETMSG
.sv_x:
  RTS
.sv_big:
  LDA #<M_BIG
  LDX #>M_BIG
  JMP SETMSG
.sv_err:
  LDA #<M_SDERR
  LDX #>M_SDERR
  JMP SETMSG

; EMIT: A into the sector buffer; a full sector goes to the SD. Keeps X, Y
EMIT:
  PHX
  PHY
  PHA
  LDA SPOS
  STA P0
  LDA SPOS+1
  CLC
  ADC #>SECBUF
  STA P0+1
  PLA
  STA (P0)
  INC SPOS
  BNE .em_x
  INC SPOS+1
  LDA SPOS+1
  CMP #2
  BNE .em_x
  JSR FLUSH
.em_x:
  PLY
  PLX
  RTS

; FLUSH: the sector buffer to sector SECN of the document (if SPOS > 0), then SPOS = 0
FLUSH:
  LDA SPOS
  ORA SPOS+1
  BEQ .fl_x
  LDA SECN
  CMP #DOC_SECTS
  BCS .fl_n              ; too big: nothing more is written (CMD_SAVE says so)
  STA DOC_I
  JSR DOC_SECT
  LDX #<SECBUF
  LDY #>SECBUF
  JSR JT_SD_WRITE
.fl_n:
  INC SECN
  STZ SPOS
  STZ SPOS+1
.fl_x:
  RTS

; EMITNUM: A (0-99) in decimal
EMITNUM:
  LDX #'0'-1
.en_t:
  INX
  SEC
  SBC #10
  BCS .en_t
  ADC #10+'0'
  PHA
  CPX #'0'
  BEQ .en_u
  TXA
  JSR EMIT
.en_u:
  PLA
  JMP EMIT

; CMD_LOAD: /L the list of the sheets, then the one chosen
CMD_LOAD:
  STZ UI_ANY
  LDA #<M_LOAD
  LDX #>M_LOAD
  JSR DOC_PICK
  PHA
  LDA #1
  STA DIRTY
  PLA
  BCC .ld_go
  CMP #0
  BEQ .ld_x
.ld_err:
  LDA #<M_SDERR
  LDX #>M_SDERR
  JMP SETMSG
.ld_x:
  RTS
.ld_go:
  PHA
  JSR CHKMOD
  PLA
  BCS .ld_x
  PHA
  JSR SHEETNEW
  PLA
  STA DOCSLOT
  STA DOC_K
  JSR DOC_ENTRY
  LDY #1
  LDA (DOC_E),Y
  STA SLEN
  INY
  LDA (DOC_E),Y
  STA SLEN+1
  LDY #4
  LDX #0
.ld_nm:
  LDA (DOC_E),Y
  STA DOCNAME,X
  INY
  INX
  CPX #NAMELEN
  BNE .ld_nm
  STZ SECN
  STZ LNL
.ld_s:
  LDA SLEN
  ORA SLEN+1
  BEQ .ld_end
  LDA SECN
  STA DOC_I
  JSR DOC_SECT
  LDX #<SECBUF
  LDY #>SECBUF
  JSR JT_SD_READ
  BCS .ld_e2
  INC SECN
  LDA #<SECBUF
  STA P2
  LDA #>SECBUF
  STA P2+1
.ld_c:
  LDA SLEN
  ORA SLEN+1
  BEQ .ld_end
  LDA P2+1
  CMP #>(SECBUF+$200)
  BEQ .ld_s              ; this sector is done
  LDA SLEN
  BNE .ld_d
  DEC SLEN+1
.ld_d:
  DEC SLEN
  LDA (P2)
  INC P2
  BNE .ld_p
  INC P2+1
.ld_p:
  CMP #CR
  BEQ .ld_line
  LDX LNL
  CPX #40
  BCS .ld_c
  STA LINEB,X
  INC LNL
  BRA .ld_c
.ld_line:
  JSR LOADLINE
  STZ LNL
  BRA .ld_c
.ld_end:
  LDA LNL
  BEQ .ld_r
  JSR LOADLINE
.ld_r:
  JSR RECALC
  STZ MODF
  LDA #<M_LOADED
  LDX #>M_LOADED
  JMP SETMSG
.ld_e2:
  JSR SHEETNEW
  JMP .ld_err

; LOADLINE: LINEB (LNL characters): "/Wn" or "A1 text"
LOADLINE:
  LDX LNL
  STZ LINEB,X
  LDA #<LINEB
  STA F_PTR
  LDA #>LINEB
  STA F_PTR+1
  STZ EPOS
  LDA LINEB
  CMP #'/'
  BNE .ll_c
  LDY #2                 ; /Wn
  JSR F_PARSE
  BCS .ll_x
  JSR HUND
  CMP #4
  BCC .ll_x
  CMP #19
  BCS .ll_x
  JMP SETWIDTH
.ll_c:
  JSR PARSEREF
  BCS .ll_x
  LDY EPOS               ; one space, then the entry
  LDA (F_PTR),Y
  CMP #' '
  BNE .ll_x
  INY
  LDX #0
.ll_t:
  LDA (F_PTR),Y
  STA EBUF,X
  BEQ .ll_s
  INY
  INX
  CPX #TXTMAX
  BNE .ll_t
  STZ EBUF,X
.ll_s:
  STX ELEN
  JSR STOREENTRY
.ll_x:
  JMP KB_POLL

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; help

CMD_HELP:
  JSR VT_CLS
  LDA #<HELPTXT
  STA P2
  LDA #>HELPTXT
  STA P2+1
  STZ GR
.hp_r:
  LDA (P2)
  CMP #$FF
  BEQ .hp_k
  LDA GR
  JSR VT_ROW
  LDA GR
  BNE .hp_n
  LDA #$80
  BRA .hp_i
.hp_n:
  LDA #0
.hp_i:
  STA VT_INV
  LDA P2
  LDX P2+1
  LDY #0
  JSR VT_LINE
  LDY #0
.hp_s:
  LDA (P2),Y
  INY
  CMP #0
  BNE .hp_s
  TYA
  CLC
  ADC P2
  STA P2
  BCC .hp_c
  INC P2+1
.hp_c:
  INC GR
  BRA .hp_r
.hp_k:
  STZ VT_INV
  JSR WAITKEY
  LDA #1
  STA DIRTY
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; texts

M_HELLO:    .byte "MINIVIC CALC 1.0  -  F1 = HELP",0
M_HINT:     .byte "/ COMMANDS  > GO TO  ! RECALC  F1 HELP",0
M_SLASH:    .byte "/ B BLANK C CLEAR R COPY W WIDTH S L Q",0
M_FULL:     .byte "MEMORY FULL",0
M_SDERR:    .byte "SD CARD ERROR",0
M_SAVED:    .byte "SAVED",0
M_LOADED:   .byte "LOADED",0
M_NOSLOT:   .byte "NO FREE PLACE: DELETE A DOCUMENT FIRST",0
M_BIG:      .byte "TOO BIG FOR ONE DOCUMENT (20 KB)",0
M_BADREF:   .byte "BAD CELL OR RANGE",0
M_LOAD:     .byte " LOAD SHEET",0
M_ERRF:     .byte "ERROR"
M_KIND:     .byte "LVF"
P_WIDTH:    .byte "COLUMN WIDTH (4-18): ",0
P_GOTO:     .byte "GO TO CELL: ",0
P_FROM:     .byte "COPY FROM (A1 OR A1:B5): ",0
P_TO:       .byte "TO: ",0
P_SAVE:     .byte "SAVE AS: ",0
Q_ABANDON:  .byte "ABANDON THE CHANGES (Y/N)?",0

HELPTXT:
  .byte " MINIVIC CALC  -  COMMANDS",0
  .byte "",0
  .byte "MOVE    ARROWS OR ^E ^X ^S ^D, TAB",0
  .byte "        PGUP PGDN (^R ^C), HOME = A1",0
  .byte "ENTRY   TYPE, THEN ENTER OR AN ARROW",0
  .byte "        ESC CANCELS, F2 EDITS THE CELL",0
  .byte "LABEL   STARTS WITH A LETTER OR ",34,0
  .byte "VALUE   12.5   +A1*2   (B2+B3)/2",0
  .byte "        $A$1 STAYS THE SAME IN /R",0
  .byte "FUNCS   @SUM(A1:A9) @AVG @MIN @MAX",0
  .byte "        @COUNT(A1:C3)  @ABS(X) @INT(X)",0
  .byte "",0
  .byte "/B BLANK THE CELL (OR DEL)",0
  .byte "/C CLEAR THE SHEET",0
  .byte "/R COPY (REPLICATE) CELLS",0
  .byte "/W COLUMN WIDTH",0
  .byte "/S SAVE  /L LOAD  /Q QUIT",0
  .byte ">  GO TO A CELL     !  RECALCULATE",0
  .byte "",0
  .byte "NUMBERS: 2 DECIMALS, UP TO 21474836.47",0
  .byte "",0
  .byte "PRESS ANY KEY",0
  .byte $FF

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; libraries

 .include "lib/keys.asm"
 .include "lib/vtext.asm"
 .include "lib/num.asm"
 .include "lib/docs.asm"
 .include "lib/ui.asm"
 .include "lib/fix32.asm"

CODE_END:
HEAP0       = (CODE_END+255) & $FF00
