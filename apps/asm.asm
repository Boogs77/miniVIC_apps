;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                                              ;
;   ASM  -  miniVIC ASM, a two-pass 65C02 assembler            ;
;   65C02 assembly, TMS9918A text mode 40 x 24                 ;
;   Needs the BIOS 27.10.26 KEYB/SD                            ;
;                                                              ;
;   - the source is a text document (written with WRITE),      ;
;     read twice from the SD (no copy in RAM)                  ;
;   - a line: [LABEL[:]] [MNEMONIC operand | .DIRECTIVE] [;..] ;
;     or NAME = expression. A label starts in column 1         ;
;   - .ORG .BYTE .WORD .TEXT "..." .RES n; numbers $hex,       ;
;     %binary, decimal, 'c', * = here; + - and < > (low / high);
;     every W65C02S instruction and addressing mode            ;
;   - a symbol defined further down makes the absolute mode    ;
;     (in both passes, so the sizes agree)                     ;
;   - the code goes to a buffer and is saved as a CODE         ;
;     document (address + bytes): MON loads it with L, runs    ;
;     it with G                                                ;
;                                                              ;
;   MEMORY                                                     ;
;   $0050-$007F  zero page (lib $A0-$EF)                       ;
;   $0210-$02A0  line, name                                    ;
;   $3000-$3FFF  symbols: 12 bytes each (340)                  ;
;   $4000-$7FFF  the code assembled (16 KB)                    ;
;                                                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

 .include "lib/system.inc"

SYMTAB      = $3000    ; name (8, space padded), value (2), line of the definition (2)
SYMEND      = $4000
SE          = 12
OUTBUF      = $4000
OUTEND      = $8000
LINEMAX     = 80
NAMELEN     = 12
MAXSHOW     = 15       ; errors shown

; ---------------- zero page ----------------
PASS        = $50
PC          = $51      ; 2 bytes: address of the next byte
BASE        = $53      ; 2 bytes: first .ORG
BASESET     = $55
TOPPC       = $56      ; 2 bytes: highest address written + 1
LNUM        = $58      ; 2 bytes: line number
NERR        = $5A      ; 2 bytes
LP          = $5C      ; position in the line
VAL         = $5D      ; 2 bytes: expression value
FWD         = $5F      ; 1 = the expression uses a symbol not defined above
LONG        = $60      ; 1 = written with more than 2 hex digits (absolute)
NSYM        = $61      ; 2 bytes: symbols
SP0         = $63      ; 2 bytes: symbol pointer
MN          = $65
AMODE       = $66
BITN        = $67
AVAL        = $68      ; 2 bytes: operand
AVAL2       = $6A      ; 2 bytes: BBR / BBS target
AFWD        = $6C
T0          = $6D
T1          = $6E
T2          = $6F
SLOT        = $70      ; source document
ELAST       = $71      ; error code of this line
QUOTE       = $72

; ---------------- RAM ----------------
LINE        = $0210    ; source line (80 + $00)
SNAME       = $0262    ; symbol name being read (8)
DNAME       = $0270    ; document name (12 + $00)

 .org $0FD0
  RTS                    ; NMI trampoline (the VDP interrupt is off)
 .org $1000

RESET:
  SEI
  CLD
  LDX #$FF
  TXS
  LDA #$60
  STA IRQ_VEC
  JSR VT_INIT
  JSR KB_INIT
START:
  LDX #$FF
  TXS
  LDA #1                 ; sources: text documents
  STA DOC_T
  STZ UI_ANY
  LDA #<M_PICK
  LDX #>M_PICK
  JSR DOC_PICK
  BCC .st_go
  CMP #0
  BNE .st_err
  JSR KB_EXIT            ; Esc: back to the menu
  JMP JT_SHOW_MENU
.st_err:
  JSR CON_CLS
  LDA #<M_SDERR
  LDX #>M_SDERR
  JSR CON_STR
  JMP AFTER
.st_go:
  STA SLOT
  JSR DOC_ENTRY          ; source name -> DNAME (offered for the code)
  LDY #4
  LDX #0
.st_n:
  LDA (DOC_E),Y
  STA DNAME,X
  INY
  INX
  CPX #NAMELEN
  BNE .st_n
  STZ DNAME,X
  JSR CON_CLS
  LDA #<M_ASM
  LDX #>M_ASM
  JSR CON_STR
  LDA #<DNAME
  LDX #>DNAME
  JSR CON_STR
  JSR CON_CR
  STZ NSYM
  STZ NSYM+1
  STZ NERR
  STZ NERR+1
  LDA #1
  STA PASS
  JSR ASMPASS
  BCS .st_sd
  INC PASS
  JSR ASMPASS
  BCS .st_sd
  JSR REPORT
  JMP AFTER
.st_sd:
  LDA #<M_SDERR
  LDX #>M_SDERR
  JSR CON_STR
  ; (falls into AFTER)

; AFTER: S save the code, A another source, Q back to the menu
AFTER:
  LDA #<M_AFTER
  LDX #>M_AFTER
  JSR CON_STR
.af_k:
  JSR WAITKEY
  JSR UI_UPC
  CMP #'A'
  BNE .af_s
  JMP START
.af_s:
  CMP #'S'
  BEQ SAVECODE
  CMP #'Q'
  BEQ .af_q
  CMP #K_F1+9
  BNE .af_k
.af_q:
  JSR KB_EXIT
  JMP JT_SHOW_MENU

; SAVECODE: the code as a CODE document: address, then the bytes BASE..TOPPC-1
SAVECODE:
  LDA NERR
  ORA NERR+1
  BEQ .fb5
  JMP .sc_no
.fb5:
  LDA BASESET
  BNE .fb4
  JMP .sc_no
.fb4:
  LDX #NAMELEN
.sc_c:
  LDA DNAME,X
  STA UI_BUF,X
  DEX
  BPL .sc_c
  LDA #NAMELEN
  STA UI_PMAX
  LDA #1
  STA UI_PUPC
  LDA #<P_SAVE
  LDX #>P_SAVE
  JSR PROMPT
  BCC .fb3
  JMP .sc_x
.fb3:
  CMP #0
  BNE .fb2
  JMP .sc_x
.fb2:
  LDX #NAMELEN           ; name, $00 padded
.sc_z:
  STZ DNAME,X
  DEX
  BPL .sc_z
  LDX #0
.sc_n:
  LDA UI_BUF,X
  BEQ .sc_g
  STA DNAME,X
  INX
  CPX #NAMELEN
  BNE .sc_n
.sc_g:
  LDA #4                 ; type 4 = code
  STA DOC_T
  JSR DOC_RDIDX
  BCS .sc_err
  LDA #<DNAME
  STA DOC_P
  LDA #>DNAME
  STA DOC_P+1
  JSR DOC_FIND
  BCC .sc_k
  JSR DOC_FREE
  BCS .sc_err
.sc_k:
  STA SLOT
  STA DOC_K
  JSR ST_WOPEN
  LDA BASE
  JSR ST_PUT
  LDA BASE+1
  JSR ST_PUT
  LDA #<OUTBUF
  STA SP0
  LDA #>OUTBUF
  STA SP0+1
  SEC                    ; T0/T1 = bytes = TOPPC - BASE
  LDA TOPPC
  SBC BASE
  STA T0
  LDA TOPPC+1
  SBC BASE+1
  STA T1
.sc_b:
  LDA T0
  ORA T1
  BEQ .sc_e
  LDA (SP0)
  JSR ST_PUT
  INC SP0
  BNE .sc_d
  INC SP0+1
.sc_d:
  LDA T0
  BNE .sc_d2
  DEC T1
.sc_d2:
  DEC T0
  BRA .sc_b
.sc_e:
  JSR ST_WCLOSE
  BCS .sc_err
  LDA SLOT
  JSR DOC_SETENT
  JSR DOC_WRIDX
  BCS .sc_err
  LDA #<M_SAVED
  LDX #>M_SAVED
  JSR CON_STR
  BRA .sc_x
.sc_err:
  LDA #<M_SDERR
  LDX #>M_SDERR
  JSR CON_STR
  BRA .sc_x
.sc_no:
  LDA #<M_NOSAVE
  LDX #>M_NOSAVE
  JSR CON_STR
.sc_x:
  JMP AFTER

; REPORT: errors, or the address range and the size, and the symbols
REPORT:
  LDA NERR
  ORA NERR+1
  BEQ .rp_ok
  LDA NERR
  STA NUM
  LDA NERR+1
  STA NUM+1
  JSR CON_NUM
  LDA #<M_ERRS
  LDX #>M_ERRS
  JMP CON_STR
.rp_ok:
  LDA #<M_OK
  LDX #>M_OK
  JSR CON_STR
  LDA BASE+1
  JSR CON_HEX
  LDA BASE
  JSR CON_HEX
  LDA #'-'
  JSR CON_PUT
  LDA #'$'
  JSR CON_PUT
  SEC                    ; last address = TOPPC - 1
  LDA TOPPC
  SBC #1
  TAX
  LDA TOPPC+1
  SBC #0
  JSR CON_HEX
  TXA
  JSR CON_HEX
  JSR CON_SP
  SEC
  LDA TOPPC
  SBC BASE
  STA NUM
  LDA TOPPC+1
  SBC BASE+1
  STA NUM+1
  JSR CON_NUM
  LDA #<M_BYTES
  LDX #>M_BYTES
  JSR CON_STR
  LDA NSYM
  STA NUM
  LDA NSYM+1
  STA NUM+1
  JSR CON_NUM
  LDA #<M_SYMS
  LDX #>M_SYMS
  JMP CON_STR

; CON_NUM: NUM in decimal, no leading spaces
CON_NUM:
  LDA #<UI_LINE
  STA VT_P
  LDA #>UI_LINE
  STA VT_P+1
  LDY #0
  JSR NUMSTR
  LDX #0
.cn_s:
  LDA UI_LINE,X
  CMP #' '
  BNE .cn_o
  INX
  BRA .cn_s
.cn_o:
  LDA UI_LINE,X
  JSR CON_PUT
  INX
  CPX #5
  BNE .cn_o
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; one pass

; ASMPASS: the whole source once. C=1 SD error
ASMPASS:
  LDA #<$3000            ; (no .ORG: $3000)
  STA PC
  STA BASE
  STA TOPPC
  LDA #>$3000
  STA PC+1
  STA BASE+1
  STA TOPPC+1
  STZ BASESET
  STZ LNUM
  STZ LNUM+1
  LDA SLOT
  STA DOC_K
  JSR DOC_ENTRY
  LDY #1
  LDA (DOC_E),Y
  STA DOC_LEN
  INY
  LDA (DOC_E),Y
  STA DOC_LEN+1
  JSR ST_ROPEN
.ap_l:
  JSR READLINE
  BCS .ap_e
  INC LNUM
  BNE .ap_d
  INC LNUM+1
.ap_d:
  STZ ELAST
  JSR DOLINE
  LDA ELAST
  BEQ .ap_l
  JSR ERROR
  BRA .ap_l
.ap_e:
  LDA ST_ERR
  CMP #1
  RTS

; READLINE: next source line into LINE (letters in upper case outside quotes).
; C=1 at the end of the text with no line
READLINE:
  LDX #0
  STZ QUOTE
.rl_l:
  JSR ST_GET
  BCS .rl_end
  CMP #K_CR
  BEQ .rl_x
  CMP #$0A
  BEQ .rl_l
  CMP #'"'
  BNE .rl_c
  PHA
  LDA QUOTE
  EOR #1
  STA QUOTE
  PLA
.rl_c:
  LDY QUOTE
  BNE .rl_s
  JSR UI_UPC
.rl_s:
  CPX #LINEMAX
  BCS .rl_l
  STA LINE,X
  INX
  BRA .rl_l
.rl_end:
  CPX #0
  BNE .rl_x
  SEC
  RTS
.rl_x:
  STZ LINE,X
  CLC
  RTS

; ERROR: "LINE n: message" for the error ELAST (only in pass 2, MAXSHOW at most)
ERROR:
  LDA PASS
  CMP #2
  BNE .er_x
  INC NERR
  BNE .er_c
  INC NERR+1
.er_c:
  LDA NERR+1
  BNE .er_x
  LDA NERR
  CMP #MAXSHOW+1
  BCS .er_x
  LDA #<M_LINE
  LDX #>M_LINE
  JSR CON_STR
  LDA LNUM
  STA NUM
  LDA LNUM+1
  STA NUM+1
  JSR CON_NUM
  LDA #':'
  JSR CON_PUT
  JSR CON_SP
  LDA ELAST
  ASL
  TAX
  LDA ERRTXT-2,X
  PHA
  LDA ERRTXT-1,X
  TAX
  PLA
  JSR CON_STR
  JSR CON_CR
.er_x:
  RTS

; FAIL: error A for this line and the rest of the line is dropped (from inside DOLINE)
FAIL:
  STA ELAST
  LDX DLSP               ; back to the caller of DOLINE
  TXS
  RTS
DLSP:       .byte 0

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; a line

E_SYNTAX    = 1
E_UNDEF     = 2
E_DUP       = 3
E_MODE      = 4
E_BRANCH    = 5
E_VALUE     = 6
E_RANGE     = 7
E_FULL      = 8

; DOLINE: label, then instruction or directive
DOLINE:
  TSX
  STX DLSP
  STZ LP
  LDA LINE
  BEQ .dl_x
  CMP #';'
  BEQ .dl_x
  CMP #' '               ; a label in column 1
  BEQ .dl_i
  CMP #K_TAB
  BEQ .dl_i
  JSR GETSYM
  BCC .dl_lab
  LDA #E_SYNTAX
  JMP FAIL
.dl_lab:
  JSR SKIPSP
  CMP #'='
  BNE .dl_pc
  INC LP                 ; NAME = expression
  JSR EXPR
  LDA VAL
  STA AVAL
  LDA VAL+1
  STA AVAL+1
  JSR DEFINE
  JMP ENDLINE
.dl_pc:
  LDA PC
  STA AVAL
  LDA PC+1
  STA AVAL+1
  JSR DEFINE
  JSR SKIPSP
  CMP #':'
  BNE .dl_i
  INC LP
.dl_i:
  JSR SKIPSP
  BEQ .dl_x
  CMP #';'
  BEQ .dl_x
  CMP #'.'
  BNE .dl_m
  JMP DIRECTIVE
.dl_m:
  JMP INSTR
.dl_x:
  RTS

; ENDLINE: nothing but a comment may follow
ENDLINE:
  JSR SKIPSP
  BEQ .el_x
  CMP #';'
  BEQ .el_x
  LDA #E_SYNTAX
  JMP FAIL
.el_x:
  RTS

; SKIPSP: A = next character that is not a space or tab (Z=1 end of the line)
SKIPSP:
  LDY LP
.sk_l:
  LDA LINE,Y
  CMP #' '
  BEQ .sk_n
  CMP #K_TAB
  BNE .sk_x
.sk_n:
  INY
  STY LP
  BRA .sk_l
.sk_x:
  CMP #0
  RTS

; GETSYM: a symbol name at LP (letter or _, then letters, digits, _) -> SNAME
; (8 characters kept, space padded). C=1 not a name
GETSYM:
  LDX #7
  LDA #' '
.gs_b:
  STA SNAME,X
  DEX
  BPL .gs_b
  LDY LP
  LDA LINE,Y
  JSR ISALPHA
  BCS .gs_x
  LDX #0
.gs_l:
  LDA LINE,Y
  JSR ISALNUM
  BCS .gs_e
  CPX #8
  BCS .gs_s
  STA SNAME,X
  INX
.gs_s:
  INY
  BRA .gs_l
.gs_e:
  STY LP
  CLC
.gs_x:
  RTS

ISALPHA:
  CMP #'_'
  BEQ .ia_y
  CMP #'A'
  BCC .ia_n
  CMP #'Z'+1
  BCS .ia_n
.ia_y:
  CLC
  RTS
.ia_n:
  SEC
  RTS
ISALNUM:
  CMP #'0'
  BCC ISALPHA
  CMP #'9'+1
  BCS ISALPHA
  CLC
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; symbols

; FINDSYM: SP0 = the entry of SNAME. C=1 not there
FINDSYM:
  LDA #<SYMTAB
  STA SP0
  LDA #>SYMTAB
  STA SP0+1
  LDA NSYM
  STA T0
  LDA NSYM+1
  STA T1
.fs_l:
  LDA T0
  ORA T1
  BEQ .fs_n
  LDY #7
.fs_c:
  LDA (SP0),Y
  CMP SNAME,Y
  BNE .fs_nx
  DEY
  BPL .fs_c
  CLC
  RTS
.fs_nx:
  CLC
  LDA SP0
  ADC #SE
  STA SP0
  BCC .fs_d
  INC SP0+1
.fs_d:
  LDA T0
  BNE .fs_d2
  DEC T1
.fs_d2:
  DEC T0
  BRA .fs_l
.fs_n:
  SEC
  RTS

; DEFINE: SNAME = AVAL at this line. Pass 1 adds it (a second definition is an error in
; pass 2: its line is not this one)
DEFINE:
  JSR FINDSYM
  BCS .df_new
  LDY #10                ; defined: on this line?
  LDA (SP0),Y
  CMP LNUM
  BNE .df_dup
  INY
  LDA (SP0),Y
  CMP LNUM+1
  BNE .df_dup
  LDY #8                 ; (pass 2: the value again, it may have moved)
  LDA AVAL
  STA (SP0),Y
  INY
  LDA AVAL+1
  STA (SP0),Y
  RTS
.df_dup:
  LDA PASS
  CMP #2
  BNE .df_x
  LDA #E_DUP
  JMP FAIL
.df_new:
  LDA SP0+1              ; room?
  CMP #>(SYMEND-SE)
  BCC .df_ok
  LDA #E_FULL
  JMP FAIL
.df_ok:
  LDY #7
.df_c:
  LDA SNAME,Y
  STA (SP0),Y
  DEY
  BPL .df_c
  LDY #8
  LDA AVAL
  STA (SP0),Y
  INY
  LDA AVAL+1
  STA (SP0),Y
  INY
  LDA LNUM
  STA (SP0),Y
  INY
  LDA LNUM+1
  STA (SP0),Y
  INC NSYM
  BNE .df_x
  INC NSYM+1
.df_x:
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; expressions

; EXPR: [< | >] term { + term | - term } -> VAL, FWD, LONG
EXPR:
  STZ FWD
  STZ LONG
  JSR SKIPSP
  CMP #'<'
  BEQ .ex_lh
  CMP #'>'
  BNE .ex_s
.ex_lh:
  PHA
  INC LP
  JSR .ex_s
  PLA
  STZ LONG
  CMP #'<'
  BEQ .ex_lo
  LDA VAL+1
  STA VAL
.ex_lo:
  STZ VAL+1
  RTS
.ex_s:
  JSR TERM
.ex_l:
  JSR SKIPSP
  CMP #'+'
  BEQ .ex_o
  CMP #'-'
  BEQ .ex_o
  RTS
.ex_o:
  PHA
  INC LP
  LDA VAL+1
  PHA
  LDA VAL
  PHA
  JSR TERM
  PLA
  STA T0
  PLA
  STA T1
  PLA
  CMP #'+'
  BEQ .ex_a
  SEC                    ; T - VAL
  LDA T0
  SBC VAL
  STA VAL
  LDA T1
  SBC VAL+1
  STA VAL+1
  BRA .ex_l
.ex_a:
  CLC
  LDA T0
  ADC VAL
  STA VAL
  LDA T1
  ADC VAL+1
  STA VAL+1
  BRA .ex_l

; TERM: $hex %binary decimal 'c' * symbol, -term -> VAL
TERM:
  STZ VAL
  STZ VAL+1
  JSR SKIPSP
  CMP #'-'               ; -term
  BNE .tm_1
  INC LP
  JSR TERM
  SEC
  LDA #0
  SBC VAL
  STA VAL
  LDA #0
  SBC VAL+1
  STA VAL+1
  RTS
.tm_1:
  CMP #'$'
  BEQ .tm_hex
  CMP #'%'
  BNE .fb1
  JMP .tm_bin
.fb1:
  CMP #'*'
  BEQ .tm_pc
  CMP #$27               ; 'c'
  BEQ .tm_chr
  CMP #'0'
  BCC .tm_sym
  CMP #'9'+1
  BCS .fb6
  JMP .tm_dec
.fb6:
.tm_sym:
  JSR GETSYM
  BCS .tm_e
  JSR FINDSYM
  BCS .tm_und
  LDY #8
  LDA (SP0),Y
  STA VAL
  INY
  LDA (SP0),Y
  STA VAL+1
  INY                    ; defined on a later line (or this one): forward
  LDA (SP0),Y
  CMP LNUM
  INY
  LDA (SP0),Y
  SBC LNUM+1
  BCC .tm_x
  LDA #1
  STA FWD
.tm_x:
  RTS
.tm_und:
  LDA #1
  STA FWD
  LDA PASS
  CMP #2
  BNE .tm_x
  LDA #E_UNDEF
  JMP FAIL
.tm_e:
  LDA #E_SYNTAX
  JMP FAIL
.tm_pc:
  INC LP
  LDA PC
  STA VAL
  LDA PC+1
  STA VAL+1
  RTS
.tm_chr:
  LDY LP
  LDA LINE+1,Y
  STA VAL
  INY
  INY
  LDA LINE,Y
  CMP #$27
  BNE .tm_e
  INY
  STY LP
  RTS
.tm_hex:
  INC LP
  STZ T2                 ; digits
.th_l:
  LDY LP
  LDA LINE,Y
  JSR HEXDIG
  BCS .th_e
  LDX #4
.th_s:
  ASL VAL
  ROL VAL+1
  DEX
  BNE .th_s
  ORA VAL
  STA VAL
  INC LP
  INC T2
  BRA .th_l
.th_e:
  LDA T2
  BEQ .tm_e
  CMP #3
  BCC .th_x
  LDA #1
  STA LONG
.th_x:
  RTS
.tm_bin:
  INC LP
  STZ T2
.tb_l:
  LDY LP
  LDA LINE,Y
  CMP #'0'
  BEQ .tb_d
  CMP #'1'
  BNE .tb_e
.tb_d:
  LSR                    ; C = the bit
  ROL VAL
  ROL VAL+1
  INC LP
  INC T2
  BRA .tb_l
.tb_e:
  LDA T2
  BEQ .tm_e
  RTS
.tm_dec:
  LDY LP
  LDA LINE,Y
  CMP #'0'
  BCC .td_x
  CMP #'9'+1
  BCS .td_x
  AND #$0F
  PHA
  LDA VAL                ; VAL * 10
  STA T0
  LDA VAL+1
  STA T1
  ASL VAL
  ROL VAL+1
  ASL VAL
  ROL VAL+1
  CLC
  LDA VAL
  ADC T0
  STA VAL
  LDA VAL+1
  ADC T1
  STA VAL+1
  ASL VAL
  ROL VAL+1
  PLA
  CLC
  ADC VAL
  STA VAL
  BCC .td_n
  INC VAL+1
.td_n:
  INC LP
  BRA .tm_dec
.td_x:
  LDA VAL+1
  BEQ .td_r
  LDA #1
  STA LONG
.td_r:
  RTS

; HEXDIG: A = value of the hex digit A, C=1 not a digit
HEXDIG:
  CMP #'0'
  BCC .hd_n
  CMP #'9'+1
  BCC .hd_d
  CMP #'A'
  BCC .hd_n
  CMP #'F'+1
  BCS .hd_n
  SBC #'A'-10-1
  CLC
  RTS
.hd_d:
  AND #$0F
  CLC
  RTS
.hd_n:
  SEC
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; output

; EMIT: byte A at PC (pass 2 into the buffer), PC + 1
EMIT:
  LDX PASS
  CPX #2
  BNE .em_n
  PHA
  SEC                    ; buffer + (PC - BASE): inside?
  LDA PC
  SBC BASE
  STA SP0
  LDA PC+1
  SBC BASE+1
  BCC .em_r
  CMP #>(OUTEND-OUTBUF)
  BCS .em_r
  ADC #>OUTBUF
  STA SP0+1
  PLA
  STA (SP0)
  BRA .em_n
.em_r:
  PLA
  LDA #E_RANGE
  JMP FAIL
.em_n:
  INC PC
  BNE .em_t
  INC PC+1
.em_t:
  LDA PC                 ; TOPPC = max(TOPPC, PC)
  CMP TOPPC
  LDA PC+1
  SBC TOPPC+1
  BCC .em_x
  LDA PC
  STA TOPPC
  LDA PC+1
  STA TOPPC+1
.em_x:
  RTS

; EMITW: VAL as a word (low byte first)
EMITW:
  LDA VAL
  JSR EMIT
  LDA VAL+1
  JMP EMIT

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; directives

DIRECTIVE:
  INC LP
  JSR GETSYM
  BCS .di_e
  LDA SNAME+4            ; names of 4 letters at most
  CMP #' '
  BNE .di_e
  LDX #0
.di_t:
  LDA DIRS,X
  BEQ .di_e
  STX T0
  LDY #0
.di_c:
  LDA DIRS,X
  CMP SNAME,Y
  BNE .di_n
  INX
  INY
  CPY #4
  BNE .di_c
  LDA DIRS,X             ; the handler number
  ASL
  TAX
  JMP (DIRTAB,X)
.di_n:
  LDA T0                 ; next entry (5 bytes)
  CLC
  ADC #5
  TAX
  BRA .di_t
.di_e:
  LDA #E_SYNTAX
  JMP FAIL

; DIRS: 5-byte entries, the name (space padded) and the handler number
DIRS:
  .byte "ORG ",0
  .byte "BYTE",1
  .byte "WORD",2
  .byte "TEXT",1
  .byte "RES ",3
  .byte 0
DIRTAB:
  .word D_ORG, D_BYTE, D_WORD, D_RES

D_ORG:
  JSR EXPR
  LDA BASESET
  BNE .do_s
  LDA VAL
  STA BASE
  STA TOPPC
  LDA VAL+1
  STA BASE+1
  STA TOPPC+1
  LDA #1
  STA BASESET
.do_s:
  LDA VAL                ; a later .ORG must not go below the first one
  CMP BASE
  LDA VAL+1
  SBC BASE+1
  BCS .do_ok
  LDA #E_RANGE
  JMP FAIL
.do_ok:
  LDA VAL
  STA PC
  LDA VAL+1
  STA PC+1
  JMP ENDLINE

; D_BYTE: expressions (low byte each) and "strings", separated by commas
D_BYTE:
  JSR ORGSEEN
.db_l:
  JSR SKIPSP
  CMP #'"'
  BEQ .db_s
  JSR EXPR
  LDA VAL+1              ; must fit in a byte (or be -1..-128)
  BEQ .db_ok
  CMP #$FF
  BEQ .db_ok
  LDA FWD
  BNE .db_ok
  LDA #E_VALUE
  JMP FAIL
.db_ok:
  LDA VAL
  JSR EMIT
  BRA .db_nx
.db_s:
  INC LP
.db_sl:
  LDY LP
  LDA LINE,Y
  BEQ .db_bad
  INC LP
  CMP #'"'
  BEQ .db_nx
  JSR EMIT
  BRA .db_sl
.db_bad:
  LDA #E_SYNTAX
  JMP FAIL
.db_nx:
  JSR SKIPSP
  CMP #','
  BNE .db_x
  INC LP
  BRA .db_l
.db_x:
  JMP ENDLINE

D_WORD:
  JSR ORGSEEN
.dw_l:
  JSR EXPR
  JSR EMITW
  JSR SKIPSP
  CMP #','
  BNE .dw_x
  INC LP
  BRA .dw_l
.dw_x:
  JMP ENDLINE

D_RES:
  JSR ORGSEEN
  JSR EXPR
.dr_l:
  LDA VAL
  ORA VAL+1
  BEQ .dr_x
  LDA #0
  JSR EMIT
  LDA VAL
  BNE .dr_d
  DEC VAL+1
.dr_d:
  DEC VAL
  BRA .dr_l
.dr_x:
  JMP ENDLINE

; ORGSEEN: code before any .ORG: the default origin $3000 counts as the first
ORGSEEN:
  LDA #1
  STA BASESET
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; instructions

INSTR:
  JSR ORGSEEN
  STZ MN                 ; mnemonic: 3 letters in MN_TXT
.in_n:
  LDA MN
  ASL
  CLC
  ADC MN
  TAX
  LDY LP
  LDA LINE,Y
  CMP MN_TXT,X
  BNE .in_nx
  LDA LINE+1,Y
  CMP MN_TXT+1,X
  BNE .in_nx
  LDA LINE+2,Y
  CMP MN_TXT+2,X
  BEQ .in_f
.in_nx:
  INC MN
  LDA MN
  CMP #MN_COUNT
  BNE .in_n
.in_bad:
  LDA #E_SYNTAX
  JMP FAIL
.in_f:
  LDA MN
  BEQ .in_bad
  INY
  INY
  INY
  STY LP
  LDA #$FF
  STA BITN
  JSR BITMN
  BCS .in_o
  LDY LP                 ; RMB0..BBS7: the bit number
  LDA LINE,Y
  SEC
  SBC #'0'
  CMP #8
  BCS .in_bad
  STA BITN
  INC LP
.in_o:
  LDY LP                 ; the mnemonic must end here
  LDA LINE,Y
  BEQ .in_op
  CMP #' '
  BEQ .in_op
  CMP #K_TAB
  BEQ .in_op
  CMP #';'
  BNE .in_bad
.in_op:
  STZ AFWD
  STZ AVAL
  STZ AVAL+1
  JSR SKIPSP             ; operand -> AMODE, AVAL
  BEQ .in_imp
  CMP #';'
  BNE .in_1
.in_imp:
  LDA #M_IMP
  JMP ENCODE
.in_1:
  CMP #'#'
  BNE .in_2
  INC LP
  JSR EXPR
  JSR KEEPVAL
  LDA #M_IMM
  JMP ENCODE
.in_2:
  CMP #'('
  BNE .in_3
  INC LP
  JSR EXPR
  JSR KEEPVAL
  JSR SKIPSP
  CMP #','               ; (x,X)
  BNE .in_2p
  JSR COMMAXY
  CMP #'X'
  BNE .in_mode
  JSR CLOSEP
  LDA #M_INX
  JMP SIZED
.in_2p:
  JSR CLOSEP
  JSR SKIPSP
  CMP #','
  BNE .in_ind
  JSR COMMAXY
  CMP #'Y'
  BNE .in_mode
  LDA #M_INY
  JMP ENCODE
.in_ind:
  LDA #M_ZPI
  JMP SIZED
.in_mode:
  LDA #E_MODE
  JMP FAIL
.in_3:
  CMP #'A'               ; A alone: the accumulator
  BNE .in_4
  LDY LP
  LDA LINE+1,Y
  JSR ISALNUM
  BCC .in_4
  INC LP
  LDA #M_ACC
  JMP ENCODE
.in_4:
  JSR EXPR               ; expr [,X | ,Y | ,target]
  JSR KEEPVAL
  JSR SKIPSP
  CMP #','
  BNE .in_zp
  INC LP
  JSR SKIPSP
  CMP #'X'
  BNE .in_y
  LDY LP
  LDA LINE+1,Y
  JSR ISALNUM
  BCC .in_t
  INC LP
  LDA #M_ZPX
  JMP SIZED
.in_y:
  CMP #'Y'
  BNE .in_t
  LDY LP
  LDA LINE+1,Y
  JSR ISALNUM
  BCC .in_t
  INC LP
  LDA #M_ZPY
  JMP SIZED
.in_t:
  JSR EXPR               ; BBR / BBS: zp, target
  LDA VAL
  STA AVAL2
  LDA VAL+1
  STA AVAL2+1
  LDA #M_ZPR
  JMP ENCODE
.in_zp:
  LDA #M_ZP
  ; (falls into SIZED)

; SIZED: mode A is a zero page one: the absolute form when the value is over $FF, written
; long, or not known in pass 1 (a forward symbol)
SIZED:
  LDX AFWD
  BNE .sz_a
  LDX LONG
  BNE .sz_a
  LDX AVAL+1
  BEQ ENCODE
.sz_a:
  TAX
  LDA ABSMAP-M_ZP,X
  ; (falls into ENCODE)

; ENCODE: the opcode of MN in mode A (with the usual fallbacks), then the operand
ENCODE:
  STA AMODE
  JSR FINDOP
  BCC .en_put
  LDA AMODE              ; ZP not there: ABS; ABS not there: a branch
  CMP #M_ZP
  BNE .en_1
  LDA #M_ABS
  STA AMODE
  JSR FINDOP
  BCC .en_put
.en_1:
  LDA AMODE
  CMP #M_ABS
  BNE .en_2
  LDA #M_REL
  STA AMODE
  JSR FINDOP
  BCC .en_put
.en_2:
  LDA AMODE              ; no operand: maybe the accumulator form
  CMP #M_IMP
  BNE .en_bad
  LDA #M_ACC
  STA AMODE
  JSR FINDOP
  BCC .en_put
.en_bad:
  LDA #E_MODE
  JMP FAIL
.en_put:
  JSR EMIT               ; opcode
  LDA AMODE
  CMP #M_REL
  BEQ .en_rel
  CMP #M_ZPR
  BEQ .en_zpr
  CMP #M_IMM
  BNE .en_len
  LDA AVAL+1             ; an immediate fits in a byte (or is -1..-128)
  BEQ .en_len
  CMP #$FF
  BEQ .en_len
  LDA AFWD
  BNE .en_len
  LDA #E_VALUE
  JMP FAIL
.en_len:
  LDX AMODE
  LDA MDLEN,X
  CMP #2
  BCC .en_x
  PHA
  LDA AVAL
  JSR EMIT
  PLA
  CMP #3
  BCC .en_x
  LDA AVAL+1
  JSR EMIT
.en_x:
  JMP ENDLINE
.en_rel:
  JSR RELOFF             ; offset to AVAL from PC + 1
  JSR EMIT
  JMP ENDLINE
.en_zpr:
  LDA AVAL
  JSR EMIT
  LDA AVAL2
  STA AVAL
  LDA AVAL2+1
  STA AVAL+1
  JSR RELOFF
  JSR EMIT
  JMP ENDLINE

; RELOFF: A = AVAL - (PC + 1) (PC is at the offset byte); out of range: error in pass 2
RELOFF:
  CLC
  LDA PC
  ADC #1
  STA T0
  LDA PC+1
  ADC #0
  STA T1
  SEC
  LDA AVAL
  SBC T0
  STA T0
  LDA AVAL+1
  SBC T1
  BEQ .ro_p
  CMP #$FF
  BNE .ro_e
  LDA T0
  BPL .ro_e
  BRA .ro_ok
.ro_p:
  LDA T0
  BMI .ro_e
.ro_ok:
  LDA T0
  RTS
.ro_e:
  LDA PASS
  CMP #2
  BNE .ro_ok
  LDA #E_BRANCH
  JMP FAIL

KEEPVAL:
  LDA VAL
  STA AVAL
  LDA VAL+1
  STA AVAL+1
  LDA FWD
  STA AFWD
  RTS

; COMMAXY: past the ',': A = the X or Y after it (taken)
COMMAXY:
  INC LP
  JSR SKIPSP
  INC LP
  RTS

CLOSEP:
  JSR SKIPSP
  CMP #')'
  BNE .cp_e
  INC LP
  RTS
.cp_e:
  LDA #E_SYNTAX
  JMP FAIL

; FINDOP: C=0 and A = opcode with mnemonic MN, mode AMODE (and bit BITN)
FINDOP:
  LDX #0
.fo_l:
  LDA OP_MN,X
  CMP MN
  BNE .fo_n
  LDA OP_MD,X
  CMP AMODE
  BNE .fo_n
  LDA BITN
  BMI .fo_y
  TXA
  LSR
  LSR
  LSR
  LSR
  AND #$07
  CMP BITN
  BNE .fo_n
.fo_y:
  TXA
  CLC
  RTS
.fo_n:
  INX
  BNE .fo_l
  SEC
  RTS

; BITMN: C=0 if MN is RMB SMB BBR BBS
BITMN:
  LDA MN
  CMP #MN_RMB
  BEQ .bm_y
  CMP #MN_SMB
  BEQ .bm_y
  CMP #MN_BBR
  BEQ .bm_y
  CMP #MN_BBS
  BEQ .bm_y
  SEC
  RTS
.bm_y:
  CLC
  RTS

MDLEN:
  .byte 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 2, 2, 2, 2, 3, 3
ABSMAP:                  ; ZP ZPX ZPY ABS ABX ABY IND INX INY ZPI -> absolute form
  .byte M_ABS, M_ABX, M_ABY, M_ABS, M_ABX, M_ABY, M_IND, M_AIX, M_INY, M_IND

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; texts

ERRTXT:
  .word ET1, ET2, ET3, ET4, ET5, ET6, ET7, ET8
ET1:  .byte "SYNTAX",0
ET2:  .byte "UNDEFINED SYMBOL",0
ET3:  .byte "DEFINED TWICE",0
ET4:  .byte "ADDRESSING MODE",0
ET5:  .byte "BRANCH TOO FAR",0
ET6:  .byte "VALUE OVER $FF",0
ET7:  .byte "OUT OF THE 16 KB AREA",0
ET8:  .byte "TOO MANY SYMBOLS",0
M_PICK:     .byte " ASSEMBLE WHICH TEXT? (ESC = MENU)",0
M_ASM:      .byte "MINIVIC ASM 1.0 - ",0
M_LINE:     .byte "LINE ",0
M_ERRS:     .byte " ERRORS",K_CR,0
M_OK:       .byte "OK: $",0
M_BYTES:    .byte " BYTES",K_CR,0
M_SYMS:     .byte " SYMBOLS",K_CR,0
M_AFTER:    .byte K_CR,"S SAVE THE CODE  A ANOTHER  Q MENU",K_CR,0
M_SAVED:    .byte "SAVED: LOAD IT WITH MON (L NAME)",K_CR,0
M_NOSAVE:   .byte "NOTHING TO SAVE",K_CR,0
M_SDERR:    .byte "SD CARD ERROR",K_CR,0
P_SAVE:     .byte "SAVE THE CODE AS: ",0

 .include "lib/opcodes.asm"
 .include "lib/keys.asm"
 .include "lib/vtext.asm"
 .include "lib/console.asm"
 .include "lib/num.asm"
 .include "lib/docs.asm"
 .include "lib/stream.asm"
 .include "lib/ui.asm"

CODE_END:
 .if CODE_END > SYMTAB
 .error "the code goes past $3000"
 .endif
