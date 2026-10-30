;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                                              ;
;   DESK  -  miniVIC DESK: calculator, calendar, clock         ;
;   65C02 assembly, TMS9918A text mode 40 x 24                 ;
;   Needs the BIOS 27.10.26 KEYB/SD                            ;
;                                                              ;
;   - three pages: F2 calculator, F3 calendar, F4 clock (Tab   ;
;     goes to the next one), F1 help, Q or F10 back to the menu;
;   - CALCULATOR: an adding machine with a paper tape;         ;
;     + - * / = (Enter), Esc clears, Del clears the entry,     ;
;     S changes the sign, M M+  N M-  R MR  K MC; numbers in   ;
;     fixed point with 2 decimals (lib/fix32.asm)              ;
;   - CALENDAR: one month, Monday first; arrows change month   ;
;     (left / right) and year (up / down), Home = this month   ;
;   - CLOCK: big digits, date, alarm. There is no clock chip:  ;
;     the time is counted with the frame flag of the VDP       ;
;     (status bit 7, 60 per second, set even with the VDP      ;
;     interrupt off) and runs only while DESK runs. S sets     ;
;     date and time, A the alarm, O switches it off           ;
;                                                              ;
;   MEMORY                                                     ;
;   $0050-$007F  zero page (lib $A0-$E3)                       ;
;   $0210-$024F  entry, accumulator, memory                    ;
;   $3000-$30EF  paper tape: 15 rows of 16 characters          ;
;                                                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

 .include "lib/system.inc"

; ---------------- parameters ----------------
FPS         = 60       ; VDP frames per second (TMS9918A)
ENTMAX      = 11
TAPEN       = 15       ; tape rows (screen rows 3-17)
TAPEW       = 16       ; (TAPEN * TAPEW < 256: one index register)
TAPECOL     = 12

; ---------------- zero page ----------------
PAGE        = $50      ; 0 calculator, 1 calendar, 2 clock
MSGP        = $51      ; 2 bytes
DIRTY       = $53      ; 1 = page to redraw
FRM         = $54      ; frames in this second
HH          = $55      ; time
MM          = $56
SS          = $57
DY          = $58      ; 2 bytes: date (year, month, day)
DMO         = $5A
DDA         = $5B
DSET        = $5C      ; 1 = date and time were set
AH          = $5D      ; alarm
AM          = $5E
AON         = $5F
RING        = $60      ; 1 = the alarm rings
CYR         = $61      ; 2 bytes: calendar month shown
CMO         = $63
OPP         = $64      ; pending operation (0 none, + - * /)
ELEN        = $65      ; entry length
NEWE        = $66      ; 1 = an entry is being typed
T0          = $67
T1          = $68
T2          = $69
T3          = $6A
P0          = $6B      ; 2 bytes
ROWI        = $6D
COLI        = $6E
TICK        = $6F      ; 1 = a second went by
CERR        = $70      ; 1 = the calculator shows ERROR
YT          = $71      ; 2 bytes: year for the day of the week
NDAYS       = $73
FRESH       = $74      ; 1 = the entry shown is done (after M+ M-): a digit starts a new one

; ---------------- RAM ----------------
ENT         = $0210    ; entry text (11 + $00)
ACC         = $0220    ; 4 bytes: running total
MEMV        = $0224    ; 4 bytes: memory
TAPE        = $3000    ; 16 x 24

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
  STZ PAGE
  STZ FRM
  STZ HH
  STZ MM
  STZ SS
  STZ DSET
  STZ AON
  STZ RING
  LDA #<2026             ; until it is set: 1 January 2026
  STA DY
  STA CYR
  LDA #>2026
  STA DY+1
  STA CYR+1
  LDA #1
  STA DMO
  STA DDA
  STA CMO
  JSR CALCCLR
  JSR TAPECLR
  LDA #1
  STA DIRTY
MAIN:
  LDA DIRTY
  BEQ .mn_t
  STZ DIRTY
  JSR DRAWPAGE
.mn_t:
  LDA TICK
  BEQ .mn_m
  STZ TICK
  LDA PAGE
  CMP #2
  BNE .mn_m
  JSR CLOCKBODY
.mn_m:
  JSR MSGLINE
IDLE:
  JSR FRAME              ; time
  LDA TICK
  BNE MAIN
  JSR GETKEY
  BCC IDLE
  STZ MSGP+1
  LDX RING               ; a ringing alarm stops with any key
  BEQ .mn_k
  STZ RING
  BRA MAIN
.mn_k:
  JSR DOKEY
  BRA MAIN

; FRAME: one VDP frame more (status bit 7) -> the seconds, the date, the alarm
FRAME:
  LDA VDP_REG
  BPL .fr_x
  INC FRM
  LDA FRM
  CMP #FPS
  BCC .fr_x
  STZ FRM
  LDA #1
  STA TICK
  INC SS
  LDA SS
  CMP #60
  BCC .fr_x
  STZ SS
  INC MM
  LDA MM
  CMP #60
  BCC .fr_al
  STZ MM
  INC HH
  LDA HH
  CMP #24
  BCC .fr_al
  STZ HH
  JSR NEXTDAY
.fr_al:
  LDA AON                ; alarm at hh:mm:00
  BEQ .fr_x
  LDA HH
  CMP AH
  BNE .fr_x
  LDA MM
  CMP AM
  BNE .fr_x
  LDA #1
  STA RING
.fr_x:
  RTS

; NEXTDAY: the date one day on
NEXTDAY:
  LDA DY
  STA YT
  LDA DY+1
  STA YT+1
  LDA DMO
  JSR MDAYS
  INC DDA
  LDA DDA
  CMP NDAYS
  BEQ .nd_x
  BCC .nd_x
  LDA #1
  STA DDA
  INC DMO
  LDA DMO
  CMP #13
  BCC .nd_x
  LDA #1
  STA DMO
  INC DY
  BNE .nd_x
  INC DY+1
.nd_x:
  RTS

; DOKEY: the keys of every page, then those of the page
DOKEY:
  CMP #K_F1+1
  BEQ .dk_p0
  CMP #K_F1+2
  BEQ .dk_p1
  CMP #K_F1+3
  BEQ .dk_p2
  CMP #K_TAB
  BEQ .dk_tab
  CMP #K_F1
  BNE .dk_q
  JMP HELP
.dk_q:
  CMP #K_F1+9            ; F10
  BEQ .dk_exit
  PHA
  JSR UI_UPC
  CMP #'Q'
  BEQ .dk_qq
  PLA
  LDX PAGE
  BEQ .dk_c
  CPX #1
  BEQ .dk_cal
  JMP CLOCKKEY
.dk_c:
  JMP CALCKEY
.dk_cal:
  JMP CALKEY
.dk_qq:
  PLA
.dk_exit:
  JSR KB_EXIT
  JMP JT_SHOW_MENU
.dk_tab:
  LDA PAGE
  INC A
  CMP #3
  BCC .dk_set
  LDA #0
  BRA .dk_set
.dk_p0:
  LDA #0
  BRA .dk_set
.dk_p1:
  LDA #1
  BRA .dk_set
.dk_p2:
  LDA #2
.dk_set:
  STA PAGE
  LDA #1
  STA DIRTY
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; screen

; DRAWPAGE: the page tabs (row 0), the page, the hint (row 22)
DRAWPAGE:
  JSR VT_CLS
  LDA #0
  JSR VT_ROW
  LDX #0
.dp_t:
  LDA M_TABS,X           ; the tab of the page in normal video, the others in inverse
  BEQ .dp_b
  STA T1
  TXA
  JSR TABOF
  CMP PAGE
  PHP
  LDA T1
  PLP
  BEQ .dp_n
  ORA #$80
.dp_n:
  STA VDP_DATA
  INX
  BRA .dp_t
.dp_b:
  LDA PAGE
  BEQ .dp_c
  CMP #1
  BEQ .dp_cal
  JMP CLOCKPAGE
.dp_c:
  JMP CALCPAGE
.dp_cal:
  JMP CALPAGE

; TABOF: A = column 0-39 -> A = its tab (13 columns each)
TABOF:
  LDY #0
.tb_l:
  CMP #13
  BCC .tb_x
  SBC #13
  INY
  BRA .tb_l
.tb_x:
  TYA
  RTS

; MSGLINE: row 23: the alarm, a message or nothing
MSGLINE:
  LDA #23
  JSR VT_ROW
  LDA RING
  BEQ .ms_m
  LDA SS                 ; flashing: inverse every other second
  LSR
  LDA #0
  ROR
  STA VT_INV
  LDA #<M_RING
  LDX #>M_RING
  BRA .ms_o
.ms_m:
  STZ VT_INV
  LDA MSGP
  LDX MSGP+1
  BNE .ms_o
  LDA #<M_EMPTY
  LDX #>M_EMPTY
.ms_o:
  LDY #0
  JSR VT_LINE
  STZ VT_INV
  RTS

SETMSG:
  STA MSGP
  STX MSGP+1
  RTS

; HINT: text A/X on row 22
HINT:
  PHX
  PHA
  LDA #22
  JSR VT_ROW
  PLA
  PLX
  LDY #0
  JMP VT_LINE

; PUTS: text A/X at row T0, column T1
PUTS:
  PHX
  PHA
  LDA T0
  LDX T1
  JSR VT_AT
  PLA
  PLX
  STA VT_P
  STX VT_P+1
  JMP VT_STR

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; calculator

CALCCLR:
  STZ FRESH
  LDX #3
.cc_l:
  STZ ACC,X
  DEX
  BPL .cc_l
  STZ OPP
  STZ ELEN
  STZ ENT
  STZ NEWE
  STZ CERR
  RTS

TAPECLR:
  LDX #0
  LDA #' '
.tc_l:
  STA TAPE,X
  STA TAPE+$100,X
  INX
  BNE .tc_l
  RTS

CALCPAGE:
  LDA #<M_CALCK
  LDX #>M_CALCK
  JSR HINT
  ; (falls into CALCBODY)

; CALCBODY: the tape (rows 3-17), the display (row 20), memory mark
CALCBODY:
  STZ ROWI
.cb_r:
  LDA ROWI
  CLC
  ADC #3
  LDX #TAPECOL
  JSR VT_AT
  LDA ROWI               ; TAPE + ROWI * 16
  ASL
  ASL
  ASL
  ASL
  STA P0
  LDA #>TAPE
  ADC #0
  STA P0+1
  LDY #0
.cb_c:
  LDA (P0),Y
  STA VDP_DATA
  INY
  CPY #TAPEW
  BNE .cb_c
  INC ROWI
  LDA ROWI
  CMP #TAPEN
  BNE .cb_r
  LDA #20                ; display: a box in inverse
  LDX #TAPECOL-1
  JSR VT_AT
  JSR SHOWVAL            ; F_OUT = what to show
  STA T0
  LDA #' '+$80
  STA VDP_DATA
  LDA #TAPEW-1           ; right aligned in 23 columns
  SEC
  SBC T0
  TAX
  LDA #' '+$80
  JSR VT_REP
  LDY #0
.cb_o:
  LDA F_OUT,Y
  BEQ .cb_e
  ORA #$80
  STA VDP_DATA
  INY
  BRA .cb_o
.cb_e:
  LDA #' '+$80
  STA VDP_DATA
  LDA #' '
  STA VDP_DATA
  LDA MEMV               ; M when the memory is not 0
  ORA MEMV+1
  ORA MEMV+2
  ORA MEMV+3
  BEQ .cb_nm
  LDA #'M'
  BRA .cb_mw
.cb_nm:
  LDA #' '
.cb_mw:
  STA VDP_DATA
  LDA OPP                ; and the operation waiting
  BNE .cb_op
  LDA #' '
.cb_op:
  STA VDP_DATA
  RTS

; SHOWVAL: F_OUT = the entry, ERROR or the total; A = length
SHOWVAL:
  LDA CERR
  BEQ .sv_e
  LDX #5
.sv_er:
  LDA M_ERROR,X
  STA F_OUT,X
  DEX
  BPL .sv_er
  LDA #5
  RTS
.sv_e:
  LDA NEWE
  BEQ .sv_a
  LDX #0
.sv_c:
  LDA ENT,X
  STA F_OUT,X
  BEQ .sv_x
  INX
  BRA .sv_c
.sv_x:
  TXA
  RTS
.sv_a:
  JSR ACCFA
  JMP F_FMT

ACCFA:
  LDX #3
.af_l:
  LDA ACC,X
  STA FA,X
  DEX
  BPL .af_l
  RTS
FAACC:
  LDX #3
.fa_l:
  LDA FA,X
  STA ACC,X
  DEX
  BPL .fa_l
  RTS

; CALCKEY: key A on the calculator page
CALCKEY:
  CMP #K_ESC
  BNE .ck_1
  JSR CALCCLR
  LDA #'C'
  JSR TAPEOP0
  BRA .ck_d
.ck_1:
  LDX CERR               ; after an error only Esc
  BNE .ck_x
  CMP #K_DEL
  BNE .ck_2
  STZ ELEN
  STZ ENT
  STZ NEWE
  BRA .ck_d
.ck_2:
  CMP #K_BS
  BNE .ck_3
  LDX ELEN
  BEQ .ck_x
  DEX
  STZ ENT,X
  STX ELEN
  BRA .ck_d
.ck_3:
  CMP #'.'
  BEQ .ck_dig
  CMP #'0'
  BCC .ck_4
  CMP #'9'+1
  BCS .ck_4
.ck_dig:
  LDX FRESH
  BEQ .ck_dn
  STZ FRESH
  STZ NEWE
.ck_dn:
  LDX NEWE               ; a new entry
  BNE .ck_add
  STZ ELEN
  LDX #1
  STX NEWE
.ck_add:
  LDX ELEN
  CPX #ENTMAX
  BCS .ck_x
  STA ENT,X
  INX
  STZ ENT,X
  STX ELEN
.ck_d:
  JMP CALCBODY
.ck_x:
  RTS
.ck_4:
  CMP #K_CR
  BEQ .ck_eq
  CMP #'='
  BEQ .ck_eq
  CMP #'+'
  BEQ .ck_op
  CMP #'-'
  BEQ .ck_op
  CMP #'*'
  BEQ .ck_op
  CMP #'/'
  BEQ .ck_op
  JSR UI_UPC
  CMP #'S'
  BEQ .ck_sign
  CMP #'M'
  BNE .fb1
  JMP .ck_mp
.fb1:
  CMP #'N'
  BNE .fb8
  JMP .ck_mm
.fb8:
  CMP #'R'
  BNE .fb5
  JMP .ck_mr
.fb5:
  CMP #'K'
  BNE .fb4
  JMP .ck_mc
.fb4:
  RTS
.ck_op:
  STZ FRESH
  PHA
  JSR APPLY              ; total op= entry
  PLA
  BCS .ck_err
  STA OPP
  JSR TAPEOP0            ; the number entered and the operation
  BRA .ck_d
.ck_eq:
  STZ FRESH
  JSR APPLY
  BCS .ck_err
  LDA #'='
  JSR TAPEOP0
  STZ OPP
  JSR TAPETOT            ; the result on its own row
  BRA .ck_d
.ck_err:
  LDA #1
  STA CERR
  BRA .ck_d
.ck_sign:
  LDA NEWE               ; the entry, or the total, changes sign
  BEQ .ck_sa
  LDA ENT
  CMP #'-'
  BEQ .ck_sm
  LDX ELEN               ; put a - in front
  CPX #ENTMAX
  BCS .ck_x
.ck_si:
  LDA ENT,X
  STA ENT+1,X
  DEX
  BPL .ck_si
  LDA #'-'
  STA ENT
  INC ELEN
  JMP .ck_d
.ck_sm:
  LDX #0                 ; take it away
.ck_sl:
  LDA ENT+1,X
  STA ENT,X
  BEQ .ck_se
  INX
  BRA .ck_sl
.ck_se:
  DEC ELEN
  JMP .ck_d
.ck_sa:
  JSR ACCFA
  JSR F_NEG
  JSR FAACC
  JMP .ck_d
.ck_mp:
  JSR VALUE              ; memory + the value shown
  BCS .ck_err
  JSR MEMFB
  JSR F_ADD
  BCS .ck_err
  JSR FAMEM
  BRA .ck_fr
.ck_mm:
  JSR VALUE
  BCS .ck_err
  JSR MEMFB              ; memory - value = -(value - memory)
  JSR F_SUB
  BCS .ck_err
  JSR F_NEG
  JSR FAMEM
.ck_fr:
  LDA #1
  STA FRESH
  JMP CALCBODY
.ck_mr:
  LDX #3                 ; the memory becomes the entry
.ck_ml:
  LDA MEMV,X
  STA FA,X
  DEX
  BPL .ck_ml
  JSR F_FMT
  LDX #0
.ck_mt:
  LDA F_OUT,X
  STA ENT,X
  BEQ .ck_me
  INX
  BRA .ck_mt
.ck_me:
  STX ELEN
  LDA #1
  STA NEWE
  JMP CALCBODY
.ck_mc:
  LDX #3
.ck_cl:
  STZ MEMV,X
  DEX
  BPL .ck_cl
  JMP CALCBODY

MEMFB:
  LDX #3
.mf_l:
  LDA MEMV,X
  STA FB,X
  DEX
  BPL .mf_l
  RTS
FAMEM:
  LDX #3
.fm_l:
  LDA FA,X
  STA MEMV,X
  DEX
  BPL .fm_l
  RTS

; VALUE: FA = the value shown (the entry if typed, else the total). C=1 bad entry
VALUE:
  LDA NEWE
  BNE PARSEENT
  JSR ACCFA
  CLC
  RTS

; PARSEENT: FA = ENT (a - in front allowed). C=1 not a number
PARSEENT:
  LDA #<ENT
  STA F_PTR
  LDA #>ENT
  STA F_PTR+1
  LDY #0
  LDA ENT
  CMP #'-'
  BNE .pe_p
  INY
.pe_p:
  JSR F_PARSE
  BCS .pe_x
  LDA ENT,Y              ; nothing after the number
  BNE .pe_bad
  LDA ENT
  CMP #'-'
  BNE .pe_ok
  JSR F_NEG
.pe_ok:
  CLC
.pe_x:
  RTS
.pe_bad:
  SEC
  RTS

; APPLY: total = total OPP value (or total = value if no operation). The value typed
; stays in FB for the tape. C=1 error
APPLY:
  JSR VALUE
  BCS .ap_x
  LDX #3                 ; FB = value, FA = total
.ap_s:
  LDA FA,X
  STA FB,X
  LDA ACC,X
  STA FA,X
  DEX
  BPL .ap_s
  LDA OPP
  BNE .ap_o
  JSR FBFA               ; first number
  BRA .ap_k
.ap_o:
  CMP #'+'
  BNE .ap_1
  JSR F_ADD
  BRA .ap_c
.ap_1:
  CMP #'-'
  BNE .ap_2
  JSR F_SUB
  BRA .ap_c
.ap_2:
  CMP #'*'
  BNE .ap_3
  JSR SAVEFB
  JSR F_MUL
  BRA .ap_r
.ap_3:
  JSR SAVEFB
  JSR F_DIV
.ap_r:
  PHP
  JSR RESTFB             ; (F_MUL / F_DIV change FB)
  PLP
.ap_c:
  BCS .ap_x
.ap_k:
  JSR FAACC
  STZ NEWE
  STZ ELEN
  STZ ENT
  CLC
.ap_x:
  RTS

FBFA:
  LDX #3
.bf_l:
  LDA FB,X
  STA FA,X
  DEX
  BPL .bf_l
  RTS
SAVEFB:
  LDX #3
.sb_l:
  LDA FB,X
  STA MEMV+4,X           ; (4 bytes after the memory)
  DEX
  BPL .sb_l
  RTS
RESTFB:
  LDX #3
.rb_l:
  LDA MEMV+4,X
  STA FB,X
  DEX
  BPL .rb_l
  RTS

; TAPEOP0: a tape row "value op" with the value FB (op = A; 'C' = clear row)
TAPEOP0:
  PHA
  JSR TAPEUP
  PLA
  STA TAPE+(TAPEN-1)*TAPEW+TAPEW-1
  CMP #'C'
  BEQ .to_x
  LDX #3
.to_v:
  LDA FB,X
  STA FA,X
  DEX
  BPL .to_v
  JSR F_FMT
  JMP TAPEPUT
.to_x:
  RTS

; TAPETOT: a tape row with the total and "*"
TAPETOT:
  JSR TAPEUP
  LDA #'*'
  STA TAPE+(TAPEN-1)*TAPEW+TAPEW-1
  JSR ACCFA
  JSR F_FMT
  ; (falls into TAPEPUT)

; TAPEPUT: F_OUT (A characters) right aligned before the last 2 columns of the last row
TAPEPUT:
  STA T0
  LDA #TAPEW-2
  SEC
  SBC T0
  TAX
  LDY #0
.tp_l:
  LDA F_OUT,Y
  BEQ .tp_x
  STA TAPE+(TAPEN-1)*TAPEW,X
  INX
  INY
  BRA .tp_l
.tp_x:
  RTS

; TAPEUP: the tape one row up, the last row blank
TAPEUP:
  LDX #0
.tu_l:
  LDA TAPE+TAPEW,X
  STA TAPE,X
  INX
  CPX #(TAPEN-1)*TAPEW
  BNE .tu_l
  LDA #' '
.tu_b:
  STA TAPE,X
  INX
  CPX #TAPEN*TAPEW
  BNE .tu_b
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; calendar

CALPAGE:
  LDA #<M_CALK
  LDX #>M_CALK
  JSR HINT
  LDA #3                 ; title: month and year, in the middle
  STA T0
  LDA CMO
  JSR MONTHNAME          ; P0 = name, A = length
  STA T2
  LDA #40-5
  SEC
  SBC T2
  LSR
  STA T1
  LDA P0
  LDX P0+1
  JSR PUTS
  LDA #' '
  STA VDP_DATA
  LDA CYR
  STA NUM
  LDA CYR+1
  STA NUM+1
  JSR YEAROUT
  LDA #5                 ; days of the week
  LDX #6
  JSR VT_AT
  LDA #<M_WDAYS
  STA VT_P
  LDA #>M_WDAYS
  STA VT_P+1
  LDA #$80
  STA VT_INV
  JSR VT_STR
  STZ VT_INV
  LDA CYR                ; day of the week of the 1st (0 = Monday)
  STA YT
  LDA CYR+1
  STA YT+1
  LDA CMO
  JSR MDAYS              ; NDAYS
  LDA CMO
  JSR WEEKDAY1           ; A = column of day 1
  STA COLI
  LDA #7
  STA ROWI
  LDA #1
  STA T3                 ; day
.cp_d:
  LDA COLI               ; screen column 6 + 4 * COLI + 1
  ASL
  ASL
  CLC
  ADC #7
  TAX
  LDA ROWI
  JSR VT_AT
  LDA #0                 ; today in inverse
  STA T2
  LDA DSET
  BEQ .cp_n
  LDA T3
  CMP DDA
  BNE .cp_n
  LDA CMO
  CMP DMO
  BNE .cp_n
  LDA CYR
  CMP DY
  BNE .cp_n
  LDA CYR+1
  CMP DY+1
  BNE .cp_n
  LDA #$80
  STA T2
.cp_n:
  LDA T3                 ; two digits
  LDX #'0'-1
.cp_t:
  INX
  SEC
  SBC #10
  BCS .cp_t
  ADC #10+'0'
  PHA
  TXA
  CMP #'0'
  BNE .cp_tt
  LDA #' '
.cp_tt:
  ORA T2
  STA VDP_DATA
  PLA
  ORA T2
  STA VDP_DATA
  INC COLI
  LDA COLI
  CMP #7
  BCC .cp_nx
  STZ COLI
  INC ROWI
  INC ROWI
.cp_nx:
  LDA T3
  CMP NDAYS
  INC T3
  BCC .cp_d
  RTS

; YEAROUT: NUM (a year) in 4 digits at the VDP address
YEAROUT:
  LDA #<UI_LINE
  STA VT_P
  LDA #>UI_LINE
  STA VT_P+1
  LDY #0
  JSR NUMSTR
  LDX #1
.yo_l:
  LDA UI_LINE,X
  STA VDP_DATA
  INX
  CPX #5
  BNE .yo_l
  RTS

; MONTHNAME: A = month 1-12 -> P0 = its name, A = length
MONTHNAME:
  ASL
  TAX
  LDA MNAMES-2,X
  STA P0
  LDA MNAMES-1,X
  STA P0+1
  LDY #0
.mn_l:
  LDA (P0),Y
  BEQ .mn_x
  INY
  BRA .mn_l
.mn_x:
  TYA
  RTS

; MDAYS: NDAYS = days of month A in year YT
MDAYS:
  TAX
  LDA MLEN-1,X
  STA NDAYS
  CPX #2
  BNE .md_x
  JSR LEAP
  BCC .md_x
  INC NDAYS
.md_x:
  RTS

; LEAP: C=1 if YT is a leap year (every 4 years, not every 100, again every 400)
LEAP:
  LDA YT
  AND #3
  BNE .lp_n
  LDA YT                 ; YT mod 100, YT mod 400
  STA P0
  LDA YT+1
  STA P0+1
  LDA #100
  JSR DIV16
  LDA T0                 ; remainder
  BNE .lp_y
  LDA P0                 ; (quotient = YT / 100: leap if it is a multiple of 4)
  AND #3
  BNE .lp_n
.lp_y:
  SEC
  RTS
.lp_n:
  CLC
  RTS

; DIV16: P0 = P0 / A, T0 = remainder (A < 128)
DIV16:
  STA T1
  STZ T0
  LDX #16
.dv_l:
  ASL P0
  ROL P0+1
  ROL T0
  LDA T0
  CMP T1
  BCC .dv_n
  SBC T1
  STA T0
  INC P0
.dv_n:
  DEX
  BNE .dv_l
  RTS

; WEEKDAY1: A = month (year YT) -> A = day of the week of its 1st, 0 = Monday
; (Sakamoto: y + y/4 - y/100 + y/400 + t[m] + 1, mod 7, 0 = Sunday; y - 1 before March)
WEEKDAY1:
  STA T3
  LDA YT
  STA P0
  LDA YT+1
  STA P0+1
  LDA T3
  CMP #3
  BCS .wd_y
  LDA P0
  BNE .wd_d
  DEC P0+1
.wd_d:
  DEC P0
.wd_y:
  LDA P0                 ; keep y
  PHA
  LDA P0+1
  PHA
  LDX T3                 ; sum = t[m] + 1 + y mod 7 ... built mod 7 step by step
  LDA WDT-1,X
  INC A
  STA T2
  LDA #7
  JSR DIV16              ; y mod 7
  LDA T0
  JSR ADD7
  PLA                    ; y / 4
  STA P0+1
  PLA
  STA P0
  PHA
  LDA P0+1
  PHA
  LSR P0+1
  ROR P0
  LSR P0+1
  ROR P0
  LDA #7
  JSR DIV16
  LDA T0
  JSR ADD7
  PLA                    ; - y / 100: + (7 - (y / 100) mod 7)
  STA P0+1
  PLA
  STA P0
  PHA
  LDA P0+1
  PHA
  LDA #100
  JSR DIV16
  LDA #7
  JSR DIV16
  LDA #7
  SEC
  SBC T0
  JSR ADD7
  PLA                    ; + y / 400
  STA P0+1
  PLA
  STA P0
  LDA #100
  JSR DIV16
  LSR P0+1
  ROR P0
  LSR P0+1
  ROR P0
  LDA #7
  JSR DIV16
  LDA T0
  JSR ADD7
  LDA T2                 ; 0 = Sunday -> 0 = Monday
  CLC
  ADC #6
  CMP #7
  BCC .wd_x
  SBC #7
.wd_x:
  RTS

; ADD7: T2 = (T2 + A) mod 7 (A < 7, T2 < 7... up to 13 after the add)
ADD7:
  CLC
  ADC T2
.a7_l:
  CMP #7
  BCC .a7_x
  SBC #7
  BRA .a7_l
.a7_x:
  STA T2
  RTS

; CALKEY: arrows change month / year, Home goes to the month of the date
CALKEY:
  CMP #K_LEFT
  BEQ .ca_pm
  CMP #'S'-$40
  BEQ .ca_pm
  CMP #K_RIGHT
  BEQ .ca_nm
  CMP #'D'-$40
  BEQ .ca_nm
  CMP #K_UP
  BEQ .ca_py
  CMP #'E'-$40
  BEQ .ca_py
  CMP #K_DOWN
  BEQ .ca_ny
  CMP #'X'-$40
  BEQ .ca_ny
  CMP #K_HOME
  BEQ .ca_h
  RTS
.ca_pm:
  DEC CMO
  BNE .ca_d
  LDA #12
  STA CMO
.ca_py:
  LDA CYR                ; (not before year 1583)
  CMP #<1583
  BNE .ca_pd
  LDA CYR+1
  CMP #>1583
  BEQ .ca_d
.ca_pd:
  LDA CYR
  BNE .ca_pd2
  DEC CYR+1
.ca_pd2:
  DEC CYR
  BRA .ca_d
.ca_nm:
  INC CMO
  LDA CMO
  CMP #13
  BCC .ca_d
  LDA #1
  STA CMO
.ca_ny:
  INC CYR
  BNE .ca_d
  INC CYR+1
  BRA .ca_d
.ca_h:
  LDA DMO
  STA CMO
  LDA DY
  STA CYR
  LDA DY+1
  STA CYR+1
.ca_d:
  LDA #1
  STA DIRTY
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; clock

CLOCKPAGE:
  LDA #<M_CLKK
  LDX #>M_CLKK
  JSR HINT
  ; (falls into CLOCKBODY)

; CLOCKBODY: hh:mm:ss in big digits (rows 5-9), the date (row 13), the alarm (row 16)
CLOCKBODY:
  LDA #5
  STA ROWI
.cl_r:
  LDA ROWI
  LDX #6                 ; 6 digits of 4 columns and 2 colons of 2: 28 columns
  JSR VT_AT
  LDA ROWI
  SEC
  SBC #5
  STA T3                 ; row of the big digits
  LDA HH
  JSR BIG2
  JSR BIGCOLON
  LDA MM
  JSR BIG2
  JSR BIGCOLON
  LDA SS
  JSR BIG2
  INC ROWI
  LDA ROWI
  CMP #10
  BNE .cl_r
  LDA #12                ; the date
  LDX #0
  JSR VT_AT
  LDA #' '
  LDX #40
  JSR VT_REP
  LDA DSET
  BNE .cl_dt
  LDA #12
  STA T0
  LDA #8
  STA T1
  LDA #<M_NOSET
  LDX #>M_NOSET
  JSR PUTS
  BRA .cl_al
.cl_dt:
  LDA DY
  STA YT
  LDA DY+1
  STA YT+1
  LDA DMO                ; day of the week = that of the 1st + day - 1
  JSR WEEKDAY1
  CLC
  ADC DDA
  DEC A
.cl_w:
  CMP #7
  BCC .cl_wd
  SBC #7
  BRA .cl_w
.cl_wd:
  ASL
  TAX
  LDA DNAMES,X
  STA P0
  LDA DNAMES+1,X
  STA P0+1
  LDA #12
  LDX #8
  JSR VT_AT
  LDA P0
  STA VT_P
  LDA P0+1
  STA VT_P+1
  JSR VT_STR
  LDA #' '
  STA VDP_DATA
  LDA DDA
  JSR DEC2
  LDA #' '
  STA VDP_DATA
  LDA DMO
  JSR MONTHNAME
  LDA P0
  STA VT_P
  LDA P0+1
  STA VT_P+1
  JSR VT_STR
  LDA #' '
  STA VDP_DATA
  LDA DY
  STA NUM
  LDA DY+1
  STA NUM+1
  JSR YEAROUT
.cl_al:
  LDA #16                ; the alarm
  LDX #12
  JSR VT_AT
  LDA #<M_ALARM
  STA VT_P
  LDA #>M_ALARM
  STA VT_P+1
  JSR VT_STR
  LDA AH
  JSR DEC2
  LDA #':'
  STA VDP_DATA
  LDA AM
  JSR DEC2
  LDA #' '
  STA VDP_DATA
  LDA AON
  BEQ .cl_off
  LDA #'O'
  STA VDP_DATA
  LDA #'N'
  STA VDP_DATA
  LDA #' '
  STA VDP_DATA
  RTS
.cl_off:
  LDA #'O'
  STA VDP_DATA
  LDA #'F'
  STA VDP_DATA
  STA VDP_DATA
  RTS

; DEC2: A (0-99) as 2 digits at the VDP address
DEC2:
  LDX #'0'-1
.d2_t:
  INX
  SEC
  SBC #10
  BCS .d2_t
  ADC #10+'0'
  STX VDP_DATA
  STA VDP_DATA
  RTS

; BIG2: A (0-99) as 2 big digits, row T3 of them (each 3 columns + 1 space)
BIG2:
  LDX #0
.b2_t:
  CMP #10
  BCC .b2_u
  SBC #10
  INX
  BRA .b2_t
.b2_u:
  PHA
  TXA
  JSR BIGDIG
  PLA
  ; (falls into BIGDIG)

; BIGDIG: digit A, row T3: 3 cells (inverse space = on) and a space
BIGDIG:
  STA T0                 ; DIG5 + digit * 5 + row
  ASL
  ASL
  CLC
  ADC T0
  CLC
  ADC T3
  TAX
  LDA DIG5,X
  STA T0
  LDY #3
.bd_l:
  LDA T0                 ; bit 2 is the left cell
  AND #4
  BEQ .bd_off
  LDA #' '+$80
  BRA .bd_w
.bd_off:
  LDA #' '
.bd_w:
  STA VDP_DATA
  ASL T0
  DEY
  BNE .bd_l
  LDA #' '
  STA VDP_DATA
  RTS

; BIGCOLON: the ':' between the big digits (rows 1 and 3)
BIGCOLON:
  LDA T3
  CMP #1
  BEQ .bc_on
  CMP #3
  BEQ .bc_on
  LDA #' '
  BRA .bc_w
.bc_on:
  LDA #' '+$80
.bc_w:
  STA VDP_DATA
  LDA #' '
  STA VDP_DATA
  RTS

; CLOCKKEY: S set date and time, A alarm, O alarm off
CLOCKKEY:
  JSR UI_UPC
  CMP #'S'
  BEQ .ck_set
  CMP #'A'
  BNE .fb11
  JMP .ck_al
.fb11:
  CMP #'O'
  BEQ .fb10
  JMP .ck_x
.fb10:
  STZ AON
  JMP .ck_d
.ck_set:
  STZ UI_BUF             ; date: YYYY MM DD
  LDA #10
  STA UI_PMAX
  LDA #<P_DATE
  LDX #>P_DATE
  JSR PROMPT
  BCC .fb14
  JMP .ck_d
.fb14:
  JSR NUMS               ; up to 3 numbers in NUMV
  CPX #3
  BEQ .fb13
  JMP .ck_bad
.fb13:
  LDA NUMV+2             ; month 1-12, day 1-days of it, year 1583-9999
  BNE .fb12
  JMP .ck_bad
.fb12:
  CMP #13
  BCC .fb15
  JMP .ck_bad
.fb15:
  LDA NUMV+1
  CMP #>1583
  BCC .ck_bad
  BNE .ck_y2
  LDA NUMV
  CMP #<1583
  BCC .ck_bad
.ck_y2:
  LDA NUMV
  STA YT
  LDA NUMV+1
  STA YT+1
  LDA NUMV+2
  JSR MDAYS
  LDA NUMV+4
  BEQ .ck_bad
  CMP NDAYS
  BEQ .ck_dok
  BCS .ck_bad
.ck_dok:
  LDA NUMV
  STA DY
  STA CYR
  LDA NUMV+1
  STA DY+1
  STA CYR+1
  LDA NUMV+2
  STA DMO
  STA CMO
  LDA NUMV+4
  STA DDA
  STZ UI_BUF             ; time: HH MM [SS]
  LDA #8
  STA UI_PMAX
  LDA #<P_TIME
  LDX #>P_TIME
  JSR PROMPT
  BCS .ck_d
  JSR NUMS
  CPX #2
  BCC .ck_bad
  JSR HMCHECK
  BCS .ck_bad
  LDA NUMV
  STA HH
  LDA NUMV+2
  STA MM
  STZ SS
  CPX #3
  BCC .ck_ok
  LDA NUMV+4
  CMP #60
  BCS .ck_bad
  STA SS
.ck_ok:
  STZ FRM
  LDA #1
  STA DSET
.ck_d:
  LDA #1
  STA DIRTY
.ck_x:
  RTS
.ck_bad:
  LDA #<M_BAD
  LDX #>M_BAD
  JSR SETMSG
  BRA .ck_d
.ck_al:
  STZ UI_BUF             ; alarm: HH MM
  LDA #5
  STA UI_PMAX
  LDA #<P_ALARM
  LDX #>P_ALARM
  JSR PROMPT
  BCS .ck_d
  JSR NUMS
  CPX #2
  BNE .ck_bad
  JSR HMCHECK
  BCS .ck_bad
  LDA NUMV
  STA AH
  LDA NUMV+2
  STA AM
  LDA #1
  STA AON
  BRA .ck_d

; HMCHECK: NUMV = hours < 24, NUMV+2 = minutes < 60? C=1 no
HMCHECK:
  LDA NUMV+1
  ORA NUMV+3
  BNE .hm_n
  LDA NUMV
  CMP #24
  BCS .hm_x
  LDA NUMV+2
  CMP #60
.hm_x:
  RTS
.hm_n:
  SEC
  RTS

; NUMS: the numbers in UI_BUF (separated by anything that is not a digit) -> NUMV
; (2 bytes each, up to 3), X = how many
NUMV        = $0230
NUMS:
  LDX #5
.ns_z:
  STZ NUMV,X
  DEX
  BPL .ns_z
  LDX #0                 ; numbers found * 2
  LDY #0
.ns_s:
  LDA UI_BUF,Y           ; skip to a digit
  BEQ .ns_e
  CMP #'0'
  BCC .ns_n
  CMP #'9'+1
  BCC .ns_d
.ns_n:
  INY
  BRA .ns_s
.ns_d:
  CPX #6
  BCS .ns_e
.ns_dl:
  LDA UI_BUF,Y
  CMP #'0'
  BCC .ns_end
  CMP #'9'+1
  BCS .ns_end
  AND #$0F
  PHA
  LDA NUMV,X             ; * 10
  STA T0
  LDA NUMV+1,X
  STA T1
  ASL NUMV,X
  ROL NUMV+1,X
  ASL NUMV,X
  ROL NUMV+1,X
  CLC
  LDA NUMV,X
  ADC T0
  STA NUMV,X
  LDA NUMV+1,X
  ADC T1
  STA NUMV+1,X
  ASL NUMV,X
  ROL NUMV+1,X
  PLA
  CLC
  ADC NUMV,X
  STA NUMV,X
  BCC .ns_c
  INC NUMV+1,X
.ns_c:
  INY
  BRA .ns_dl
.ns_end:
  INX
  INX
  BRA .ns_s
.ns_e:
  TXA
  LSR
  TAX
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; help

HELP:
  JSR VT_CLS
  LDA #<HELPTXT
  STA P0
  LDA #>HELPTXT
  STA P0+1
  STZ ROWI
.hp_r:
  LDA (P0)
  CMP #$FF
  BEQ .hp_k
  LDA ROWI
  JSR VT_ROW
  LDA ROWI
  BNE .hp_n
  LDA #$80
  BRA .hp_i
.hp_n:
  LDA #0
.hp_i:
  STA VT_INV
  LDA P0
  LDX P0+1
  LDY #0
  JSR VT_LINE
  LDY #0
.hp_s:
  LDA (P0),Y
  INY
  CMP #0
  BNE .hp_s
  TYA
  CLC
  ADC P0
  STA P0
  BCC .hp_c
  INC P0+1
.hp_c:
  INC ROWI
  BRA .hp_r
.hp_k:
  STZ VT_INV
.hp_w:
  JSR FRAME              ; (the clock goes on)
  JSR GETKEY
  BCC .hp_w
  LDA #1
  STA DIRTY
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; tables and texts

DIG5:                    ; big digits: 5 rows of 3 bits (bit 2 = left)
  .byte 7,5,5,5,7, 2,6,2,2,7, 7,1,7,4,7, 7,1,7,1,7, 5,5,7,1,1
  .byte 7,4,7,1,7, 7,4,7,5,7, 7,1,1,1,1, 7,5,7,5,7, 7,5,7,1,7
MLEN:       .byte 31,28,31,30,31,30,31,31,30,31,30,31
WDT:        .byte 0,3,2,5,0,3,5,1,4,6,2,4     ; Sakamoto's month table
MNAMES:
  .word MN1, MN2, MN3, MN4, MN5, MN6, MN7, MN8, MN9, MN10, MN11, MN12
MN1:  .byte "JANUARY",0
MN2:  .byte "FEBRUARY",0
MN3:  .byte "MARCH",0
MN4:  .byte "APRIL",0
MN5:  .byte "MAY",0
MN6:  .byte "JUNE",0
MN7:  .byte "JULY",0
MN8:  .byte "AUGUST",0
MN9:  .byte "SEPTEMBER",0
MN10: .byte "OCTOBER",0
MN11: .byte "NOVEMBER",0
MN12: .byte "DECEMBER",0
DNAMES:
  .word DN1, DN2, DN3, DN4, DN5, DN6, DN7
DN1:  .byte "MONDAY",0
DN2:  .byte "TUESDAY",0
DN3:  .byte "WEDNESDAY",0
DN4:  .byte "THURSDAY",0
DN5:  .byte "FRIDAY",0
DN6:  .byte "SATURDAY",0
DN7:  .byte "SUNDAY",0

M_TABS:     .byte "  CALCULATOR ","   CALENDAR  ","    CLOCK    "," ",0
M_WDAYS:    .byte " MO  TU  WE  TH  FR  SA  SU ",0
M_CALCK:    .byte "+-*/= ESC C S +/- M M+ N M- R MR K MC",0
M_CALK:     .byte "ARROWS: MONTH AND YEAR  HOME: TODAY",0
M_CLKK:     .byte "S SET DATE AND TIME  A ALARM  O OFF",0
M_RING:     .byte "        *** ALARM ***  PRESS A KEY",0
M_EMPTY:    .byte "F2 F3 F4 OR TAB: PAGE   F1 HELP  Q EXIT",0
M_ERROR:    .byte "ERROR",0
M_NOSET:    .byte "PRESS S TO SET THE DATE",0
M_ALARM:    .byte "ALARM ",0
M_BAD:      .byte "NOT A VALID DATE OR TIME",0
P_DATE:     .byte "DATE (YYYY MM DD): ",0
P_TIME:     .byte "TIME (HH MM SS): ",0
P_ALARM:    .byte "ALARM (HH MM): ",0

HELPTXT:
  .byte " MINIVIC DESK",0
  .byte "",0
  .byte "F2 CALCULATOR  F3 CALENDAR  F4 CLOCK",0
  .byte "TAB NEXT PAGE  F1 HELP  Q OR F10 EXIT",0
  .byte "",0
  .byte "CALCULATOR (AN ADDING MACHINE)",0
  .byte "  DIGITS . + - * / AND = (OR ENTER)",0
  .byte "  ESC CLEARS ALL, DEL THE ENTRY",0
  .byte "  S +/-  M M+  N M-  R MR  K MC",0
  .byte "  2 DECIMALS, UP TO 21474836.47",0
  .byte "",0
  .byte "CALENDAR",0
  .byte "  LEFT RIGHT MONTH, UP DOWN YEAR",0
  .byte "  HOME THE MONTH OF THE DATE",0
  .byte "",0
  .byte "CLOCK",0
  .byte "  S DATE AND TIME, A ALARM, O OFF",0
  .byte "  IT RUNS ONLY WHILE DESK RUNS",0
  .byte "",0
  .byte "PRESS ANY KEY",0
  .byte $FF

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; libraries

 .include "lib/keys.asm"
 .include "lib/vtext.asm"
 .include "lib/num.asm"
 .include "lib/fix32.asm"
 .include "lib/docs.asm"
 .include "lib/ui.asm"

CODE_END:
