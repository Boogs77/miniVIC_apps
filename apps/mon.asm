;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                                              ;
;   MON  -  miniVIC MON, machine language monitor              ;
;   (Supermon / VICMON style), 65C02 assembly                  ;
;   Needs the BIOS 27.10.26 KEYB/SD                            ;
;                                                              ;
;   Commands (numbers in hex, $ optional):                     ;
;     M [a [b]]   memory dump, 8 bytes and their text per row  ;
;     : a bb ..   writes bytes from a                          ;
;     D [a [b]]   disassembles (W65C02S, also RMB SMB BBR BBS) ;
;     A a instr   assembles one instruction, then offers the   ;
;                 next address (an empty line ends)            ;
;     G a         JSR a; registers shown when it returns       ;
;     R           registers of the last G                      ;
;     F a b v     fills a..b with v                            ;
;     T a b c     copies a..b to c (overlap safe)              ;
;     H a b bb .. finds the bytes in a..b                      ;
;     S name a b  saves a..b on the SD (document type 4)       ;
;     L name [a]  loads it back (at its address, or at a)      ;
;     X           back to the BIOS menu      ?  help           ;
;   Esc stops a long listing.                                  ;
;                                                              ;
;   MEMORY                                                     ;
;   $0050-$007F  zero page (lib $A0-$EF)                       ;
;   $0210-$028F  output row, hunt bytes, name                  ;
;   $0560-$05DF  console row and line, key queue (lib)         ;
;   $0600-$09FF  SD index and sector buffer (S / L only)       ;
;   $1000-...    the monitor; free for programs: $3000-$7FFF   ;
;                                                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

 .include "lib/system.inc"

; ---------------- zero page ----------------
LP          = $50      ; position in the typed line
VAL         = $51      ; 2 bytes: last hex number read
A1          = $53      ; 2 bytes: arguments
A2          = $55
A3          = $57
DPC         = $59      ; 2 bytes: disassembly / assembly address
OPC         = $5B      ; opcode
MD          = $5C      ; addressing mode
MN          = $5D      ; mnemonic number
ILEN        = $5E      ; instruction length
OLEN        = $5F      ; length of OUTB
NEXTM       = $60      ; 2 bytes: where M goes on
NEXTD       = $62      ; 2 bytes: where D goes on
T0          = $64
T1          = $65
T2          = $66
NDIG        = $67      ; digits of the last number
GOVEC       = $68      ; 2 bytes
RA          = $6A      ; registers after G
RX          = $6B
RY          = $6C
RPS         = $6D
CNT         = $6E      ; 2 bytes
HN          = $70      ; hunt: bytes to find
BITN        = $71      ; RMB/SMB/BBR/BBS bit number
AMODE       = $72      ; assembler: mode wanted
AVAL        = $73      ; 2 bytes: operand
AVAL2       = $75      ; 2 bytes: second operand (BBR/BBS target)
DOCSLOT     = $77

; ---------------- RAM ----------------
OUTB        = $0210    ; row being built (40)
HBYTES      = $0240    ; bytes to find (16)
NAMEB       = $0250    ; document name (12 + $00)

 .org $0FD0
  RTS                    ; NMI trampoline (the VDP interrupt is off)
 .org $1000

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; start and command loop

RESET:
  SEI
  CLD
  LDX #$FF
  TXS
  LDA #$60
  STA IRQ_VEC
  JSR VT_INIT
  JSR KB_INIT
  LDA #4                 ; type 4 = memory (code)
  STA DOC_T
  LDA #$00
  STA NEXTM
  STA NEXTD
  LDA #$30
  STA NEXTM+1
  STA NEXTD+1
  JSR CON_CLS
  LDA #<M_HELLO
  LDX #>M_HELLO
  JSR CON_STR
  STZ CON_LEN
LOOP:
  LDX #$FF               ; (a G that did not come back cleanly cannot fill the stack)
  TXS
  LDA #38
  STA CON_MAX
  LDA #'.'
  JSR CON_PUT
  JSR CON_GETS           ; (CON_LEN > 0: a start text from the last command, see A)
  STZ CON_LEN
  STZ LP
  JSR SKIPSP
  BEQ LOOP
  INC LP
  LDX #0
.cl_t:
  LDY CMDTAB,X
  BEQ .cl_bad
  CMP CMDTAB,X
  BEQ .cl_go
  INX
  INX
  INX
  BRA .cl_t
.cl_go:
  LDA CMDTAB+1,X
  STA GOVEC
  LDA CMDTAB+2,X
  STA GOVEC+1
  JSR .cl_jmp
  JMP LOOP
.cl_jmp:
  JMP (GOVEC)
.cl_bad:
  JMP ERROR

; ERROR: "?" under the line
ERROR:
  LDA #<M_ERR
  LDX #>M_ERR
  JSR CON_STR
  JMP LOOP

CMDTAB:
  .byte 'M'
  .word CMD_M
  .byte ':'
  .word CMD_POKE
  .byte 'D'
  .word CMD_D
  .byte 'A'
  .word CMD_A
  .byte 'G'
  .word CMD_G
  .byte 'R'
  .word CMD_R
  .byte 'F'
  .word CMD_F
  .byte 'T'
  .word CMD_T
  .byte 'H'
  .word CMD_H
  .byte 'S'
  .word CMD_S
  .byte 'L'
  .word CMD_L
  .byte 'X'
  .word CMD_X
  .byte '?'
  .word CMD_HELP
  .byte 0

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; reading the line

; SKIPSP: A = next character that is not a space (Z=1 end of the line)
SKIPSP:
  LDY LP
.sk_l:
  LDA CON_LINE,Y
  CMP #' '
  BNE .sk_x
  INY
  STY LP
  BRA .sk_l
.sk_x:
  CMP #0
  RTS

; GETHEX: VAL = hex number at LP ($ allowed before it), NDIG = digits. C=1 none
GETHEX:
  JSR SKIPSP
  CMP #'$'
  BNE .gh_s
  INC LP
.gh_s:
  STZ VAL
  STZ VAL+1
  STZ NDIG
.gh_l:
  LDY LP
  LDA CON_LINE,Y
  JSR HEXDIG
  BCS .gh_e
  LDX #4
.gh_sh:
  ASL VAL
  ROL VAL+1
  DEX
  BNE .gh_sh
  ORA VAL
  STA VAL
  INC LP
  INC NDIG
  BRA .gh_l
.gh_e:
  LDA NDIG
  BEQ .gh_no
  CLC
  RTS
.gh_no:
  SEC
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

; NEEDHEX: VAL = a hex number, or ERROR
NEEDHEX:
  JSR GETHEX
  BCS .nh_e
  RTS
.nh_e:
  PLA                    ; (drop the return address)
  PLA
  JMP ERROR

; ARGS1-3: A1 [A2 [A3]] needed
ARG1:
  JSR NEEDHEX
  LDA VAL
  STA A1
  LDA VAL+1
  STA A1+1
  RTS
ARG2:
  JSR ARG1
  JSR GETHEX
  BCS ARG_ERR
  LDA VAL
  STA A2
  LDA VAL+1
  STA A2+1
  RTS
ARG_ERR:
  PLA
  PLA
  JMP ERROR
ARG3:
  JSR ARG2
  JSR GETHEX
  BCS ARG_ERR
  LDA VAL
  STA A3
  LDA VAL+1
  STA A3+1
  RTS

; A1LEA2: C=1 if A1 <= A2
A1LEA2:
  LDA A2
  CMP A1
  LDA A2+1
  SBC A1+1
  RTS

INCA1:
  INC A1
  BNE .ia_x
  INC A1+1
.ia_x:
  RTS

; STOPKEY: C=1 if Esc was pressed (other keys are dropped)
STOPKEY:
  JSR GETKEY
  BCC .sk_n
  CMP #K_ESC
  BNE STOPKEY
  SEC
  RTS
.sk_n:
  CLC
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; M  :  F  T  H

CMD_M:
  JSR GETHEX
  BCS .m_def
  LDA VAL
  STA A1
  LDA VAL+1
  STA A1+1
  JSR GETHEX
  BCC .m_b
.m_8:
  CLC                    ; 8 rows
  LDA A1
  ADC #$3F
  STA A2
  LDA A1+1
  ADC #0
  STA A2+1
  BRA .m_go
.m_def:
  LDA NEXTM
  STA A1
  LDA NEXTM+1
  STA A1+1
  BRA .m_8
.m_b:
  LDA VAL
  STA A2
  LDA VAL+1
  STA A2+1
.m_go:
  JSR MROW
  JSR STOPKEY
  BCS .m_x
  LDA A1                 ; past A2 (or wrapped)?
  ORA A1+1
  BEQ .m_x
  JSR A1LEA2
  BCS .m_go
.m_x:
  LDA A1
  STA NEXTM
  LDA A1+1
  STA NEXTM+1
  RTS

; MROW: ":aaaa bb bb bb bb bb bb bb bb ........" for A1, A1 moves on by 8
MROW:
  LDA #':'
  JSR CON_PUT
  LDA A1+1
  JSR CON_HEX
  LDA A1
  JSR CON_HEX
  LDY #0
.mr_b:
  JSR CON_SP
  LDA (A1),Y
  JSR CON_HEX
  INY
  CPY #8
  BNE .mr_b
  JSR CON_SP
  LDY #0
.mr_t:
  LDA (A1),Y
  AND #$7F
  CMP #' '
  BCS .mr_p
  LDA #'.'
.mr_p:
  CMP #$7F
  BNE .mr_q
  LDA #'.'
.mr_q:
  JSR CON_PUT
  INY
  CPY #8
  BNE .mr_t
  JSR CON_CR
  CLC
  LDA A1
  ADC #8
  STA A1
  BCC .mr_x
  INC A1+1
.mr_x:
  RTS

; CMD_POKE: ": aaaa bb bb ..." (the rows of M can be typed again as they are)
CMD_POKE:
  JSR ARG1
.pk_l:
  JSR GETHEX
  BCS .pk_x
  LDA VAL
  STA (A1)
  JSR INCA1
  BRA .pk_l
.pk_x:
  RTS

CMD_F:
  JSR ARG3
.f_l:
  LDA A3
  STA (A1)
  LDA A1                 ; up to A2 included
  CMP A2
  BNE .f_n
  LDA A1+1
  CMP A2+1
  BEQ .f_x
.f_n:
  JSR INCA1
  LDA A1
  AND #$3F
  BNE .f_l
  JSR KB_POLL
  BRA .f_l
.f_x:
  RTS

; CMD_T: copy A1..A2 to A3; backwards when the target is after the source
CMD_T:
  JSR ARG3
  SEC                    ; CNT = A2 - A1 (bytes - 1)
  LDA A2
  SBC A1
  STA CNT
  LDA A2+1
  SBC A1+1
  STA CNT+1
  BCC .t_x
  LDA A3                 ; A3 > A1: from the end
  CMP A1
  LDA A3+1
  SBC A1+1
  BCC .t_f
  CLC                    ; A1 and A3 to the last byte
  LDA A1
  ADC CNT
  STA A1
  LDA A1+1
  ADC CNT+1
  STA A1+1
  CLC
  LDA A3
  ADC CNT
  STA A3
  LDA A3+1
  ADC CNT+1
  STA A3+1
.t_b:
  LDA (A1)
  STA (A3)
  LDA CNT
  ORA CNT+1
  BEQ .t_x
  LDA A1
  BNE .t_b1
  DEC A1+1
.t_b1:
  DEC A1
  LDA A3
  BNE .t_b2
  DEC A3+1
.t_b2:
  DEC A3
  JSR DECCNT
  BRA .t_b
.t_f:
  LDA (A1)
  STA (A3)
  LDA CNT
  ORA CNT+1
  BEQ .t_x
  JSR INCA1
  INC A3
  BNE .t_f1
  INC A3+1
.t_f1:
  JSR DECCNT
  BRA .t_f
.t_x:
  RTS

DECCNT:
  LDA CNT
  BNE .dc_d
  DEC CNT+1
.dc_d:
  DEC CNT
  LDA CNT
  AND #$3F
  BNE .dc_x
  JSR KB_POLL
.dc_x:
  RTS

; CMD_H: H a b bb bb ...: the addresses where the bytes are
CMD_H:
  JSR ARG2
  STZ HN
.h_b:
  JSR GETHEX
  BCS .h_go
  LDA VAL
  LDX HN
  STA HBYTES,X
  INC HN
  CPX #15
  BCC .h_b
.h_go:
  LDA HN
  BNE .h_s
  JMP ERROR
.h_s:
  STZ T2                 ; addresses on this row
.h_l:
  LDY #0
.h_c:
  LDA (A1),Y
  CMP HBYTES,Y
  BNE .h_n
  INY
  CPY HN
  BNE .h_c
  LDA A1+1               ; found
  JSR CON_HEX
  LDA A1
  JSR CON_HEX
  JSR CON_SP
  INC T2
  LDA T2
  CMP #8
  BNE .h_n
  STZ T2
  JSR CON_CR
.h_n:
  LDA A1
  CMP A2
  BNE .h_i
  LDA A1+1
  CMP A2+1
  BEQ .h_x
.h_i:
  JSR INCA1
  LDA A1
  AND #$1F
  BNE .h_l
  JSR STOPKEY
  BCC .h_l
.h_x:
  LDA T2
  BEQ .h_r
  JMP CON_CR
.h_r:
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; G  R  X

CMD_G:
  JSR ARG1
  LDA A1
  STA GOVEC
  LDA A1+1
  STA GOVEC+1
  JSR .g_call
  PHP
  STA RA
  STX RX
  STY RY
  PLA
  STA RPS
  CLD
  JMP CMD_R
.g_call:
  JMP (GOVEC)

CMD_R:
  LDX #0
.r_l:
  LDA M_REGS,X
  JSR CON_PUT
  INX
  LDA M_REGS,X
  JSR CON_PUT
  INX
  STX T0
  TXA
  LSR
  TAX
  LDA RA-1,X
  JSR CON_HEX
  JSR CON_SP
  LDX T0
  CPX #8
  BNE .r_l
  JMP CON_CR

M_REGS:     .byte "A=X=Y=P="

CMD_X:
  JSR KB_EXIT
  JMP JT_SHOW_MENU

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; disassembler

CMD_D:
  JSR GETHEX
  BCS .d_def
  LDA VAL
  STA DPC
  LDA VAL+1
  STA DPC+1
  JSR GETHEX
  BCC .d_b
  BRA .d_20
.d_def:
  LDA NEXTD
  STA DPC
  LDA NEXTD+1
  STA DPC+1
.d_20:
  LDA #20                ; 20 instructions
  STA T2
.d_l20:
  JSR DISLINE
  JSR STOPKEY
  BCS .d_x
  DEC T2
  BNE .d_l20
  BRA .d_x
.d_b:
  LDA VAL
  STA A2
  LDA VAL+1
  STA A2+1
.d_lb:
  JSR DISLINE
  JSR STOPKEY
  BCS .d_x
  LDA A2                 ; up to A2
  CMP DPC
  LDA A2+1
  SBC DPC+1
  BCS .d_lb
.d_x:
  LDA DPC
  STA NEXTD
  LDA DPC+1
  STA NEXTD+1
  RTS

; DISLINE: "aaaa  bb bb bb  MNE operand" for DPC; DPC moves to the next instruction
DISLINE:
  STZ OLEN
  LDA DPC+1
  JSR OHEX
  LDA DPC
  JSR OHEX
  JSR OSP
  JSR OSP
  LDA (DPC)
  STA OPC
  TAX
  LDA OP_MN,X
  STA MN
  LDA OP_MD,X
  STA MD
  TAX
  LDA MDLEN,X
  STA ILEN
  LDY #0                 ; the bytes
.dl_b:
  LDA (DPC),Y
  JSR OHEX
  JSR OSP
  INY
  CPY ILEN
  BNE .dl_b
.dl_p:
  LDA OLEN               ; mnemonic at column 16
  CMP #16
  BCS .dl_m
  JSR OSP
  BRA .dl_p
.dl_m:
  LDA MN                 ; 3 letters
  ASL
  CLC
  ADC MN
  TAX
  LDA MN_TXT,X
  JSR OPUT
  LDA MN_TXT+1,X
  JSR OPUT
  LDA MN_TXT+2,X
  JSR OPUT
  JSR BITMN              ; RMB0..BBS7: their bit
  BCS .dl_sp
  ORA #'0'
  JSR OPUT
.dl_sp:
  JSR OSP
  LDA MD                 ; operand by the mode
  ASL
  TAX
  JMP (OPRTAB,X)
DL_END:
  LDY #0                 ; the row
.de_l:
  LDA OUTB,Y
  JSR CON_PUT
  INY
  CPY OLEN
  BNE .de_l
  JSR CON_CR
  CLC                    ; DPC moves on
  LDA DPC
  ADC ILEN
  STA DPC
  BCC .de_x
  INC DPC+1
.de_x:
  RTS

; BITMN: C=0 and A = bit number if MN is RMB SMB BBR BBS
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
  LDA OPC
  LSR
  LSR
  LSR
  LSR
  AND #$07
  CLC
  RTS

OPRTAB:
  .word DL_END, OP_ACC, OP_IMM, OP_ZP, OP_ZPX, OP_ZPY, OP_ABS, OP_ABX
  .word OP_ABY, OP_IND, OP_INX, OP_INY, OP_ZPI, OP_REL, OP_AIX, OP_ZPR
MDLEN:
  .byte 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 2, 2, 2, 2, 3, 3

OP_ACC:
  LDA #'A'
  JSR OPUT
  JMP DL_END
OP_IMM:
  LDA #'#'
  JSR OPUT
OP_ZP:
  JSR OB1
  JMP DL_END
OP_ZPX:
  JSR OB1
  JSR OCX
  JMP DL_END
OP_ZPY:
  JSR OB1
  JSR OCY
  JMP DL_END
OP_ABS:
  JSR OW1
  JMP DL_END
OP_ABX:
  JSR OW1
  JSR OCX
  JMP DL_END
OP_ABY:
  JSR OW1
  JSR OCY
  JMP DL_END
OP_IND:
  JSR OPAR
  JSR OW1
  JSR OCLOSE
  JMP DL_END
OP_INX:
  JSR OPAR
  JSR OB1
  JSR OCX
  JSR OCLOSE
  JMP DL_END
OP_INY:
  JSR OPAR
  JSR OB1
  JSR OCLOSE
  JSR OCY
  JMP DL_END
OP_ZPI:
  JSR OPAR
  JSR OB1
  JSR OCLOSE
  JMP DL_END
OP_AIX:
  JSR OPAR
  JSR OW1
  JSR OCX
  JSR OCLOSE
  JMP DL_END
OP_REL:
  LDY #1                 ; target = DPC + 2 + offset
  LDA #2
  JSR OTARGET
  JMP DL_END
OP_ZPR:
  JSR OB1                ; zp, then target = DPC + 3 + offset (byte 2)
  LDA #','
  JSR OPUT
  LDY #2
  LDA #3
  JSR OTARGET
  JMP DL_END

; OTARGET: "$tttt" = DPC + A + signed byte (DPC),Y
OTARGET:
  CLC
  ADC DPC
  STA T0
  LDA DPC+1
  ADC #0
  STA T1
  LDA (DPC),Y
  BPL .ot_p
  DEC T1
.ot_p:
  CLC
  ADC T0
  STA T0
  BCC .ot_o
  INC T1
.ot_o:
  LDA #'$'
  JSR OPUT
  LDA T1
  JSR OHEX
  LDA T0
  JMP OHEX

OB1:
  LDA #'$'
  JSR OPUT
  LDY #1
  LDA (DPC),Y
  JMP OHEX
OW1:
  LDA #'$'
  JSR OPUT
  LDY #2
  LDA (DPC),Y
  JSR OHEX
  LDY #1
  LDA (DPC),Y
  JMP OHEX
OCX:
  LDA #','
  JSR OPUT
  LDA #'X'
  JMP OPUT
OCY:
  LDA #','
  JSR OPUT
  LDA #'Y'
  JMP OPUT
OPAR:
  LDA #'('
  JMP OPUT
OCLOSE:
  LDA #')'
  JMP OPUT
OSP:
  LDA #' '
OPUT:
  PHX
  LDX OLEN
  STA OUTB,X
  INC OLEN
  PLX
  RTS
OHEX:
  PHA
  LSR
  LSR
  LSR
  LSR
  JSR .oh_d
  PLA
  AND #$0F
.oh_d:
  CMP #10
  BCC .oh_n
  ADC #'A'-10-1-'0'
.oh_n:
  ADC #'0'
  JMP OPUT

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; assembler

; CMD_A: A aaaa MNE operand; then "A next " is offered, an empty instruction ends
CMD_A:
  JSR ARG1
  LDA A1
  STA DPC
  LDA A1+1
  STA DPC+1
  JSR SKIPSP
  BNE .a_m
  RTS                    ; no instruction: the end
.a_m:
  JSR ASM1
  BCC .a_ok
  JMP ERROR
.a_ok:
  JSR DISLINE            ; what went in (DPC moves on)
  LDY #0                 ; "A next " for the next line
  LDA #'A'
  STA CON_LINE,Y
  INY
  LDA #' '
  STA CON_LINE,Y
  INY
  LDA DPC+1
  JSR LHEX
  LDA DPC
  JSR LHEX
  LDA #' '
  STA CON_LINE,Y
  INY
  STY CON_LEN            ; LOOP prints it as the start of the next line
  RTS

; LHEX: A as 2 hex digits into CON_LINE,Y
LHEX:
  PHA
  LSR
  LSR
  LSR
  LSR
  JSR .lh_d
  PLA
  AND #$0F
.lh_d:
  CMP #10
  BCC .lh_n
  ADC #'A'-10-1-'0'
.lh_n:
  ADC #'0'
  STA CON_LINE,Y
  INY
  RTS

; ASM1: the instruction at LP into DPC. C=1 error
ASM1:
  LDX #0                 ; mnemonic: 3 letters
  STZ MN
.as_n:
  LDA MN                 ; compare with MN_TXT entry MN
  ASL
  CLC
  ADC MN
  TAX
  LDY LP
  LDA CON_LINE,Y
  CMP MN_TXT,X
  BNE .as_nx
  LDA CON_LINE+1,Y
  CMP MN_TXT+1,X
  BNE .as_nx
  LDA CON_LINE+2,Y
  CMP MN_TXT+2,X
  BEQ .as_f
.as_nx:
  INC MN
  LDA MN
  CMP #MN_COUNT
  BNE .as_n
.as_err:
  SEC
  RTS
.as_f:
  LDA MN
  BEQ .as_err            ; (???)
  INY
  INY
  INY
  STY LP
  LDA #$FF               ; RMB0..BBS7: the digit after the name
  STA BITN
  JSR BITMN0
  BCS .as_o
  LDY LP
  LDA CON_LINE,Y
  SEC
  SBC #'0'
  CMP #8
  BCS .as_err
  STA BITN
  INC LP
.as_o:
  JSR SKIPSP             ; operand -> AMODE, AVAL
  BNE .as_1
  LDA #M_IMP
  JMP .as_find
.as_1:
  CMP #'#'
  BNE .as_2
  INC LP
  JSR GETHEX
  BCS .as_err
  LDA #M_IMM
  JMP .as_v
.as_2:
  CMP #'('
  BNE .as_3
  INC LP
  JSR GETHEX
  BCS .as_err
  JSR SAVEVAL
  JSR SKIPSP
  CMP #','               ; (zp,X) or (abs,X)
  BNE .as_2p
  JSR XORY
  CMP #'X'
  BNE .as_err
  JSR CLOSEP
  BCS .as_err
  LDA #M_INX
  BRA .as_zw
.as_2p:
  JSR CLOSEP             ; ) then ,Y or nothing
  BCS .as_err
  JSR SKIPSP
  BEQ .as_ind
  CMP #','
  BNE .as_err
  JSR XORY
  CMP #'Y'
  BNE .as_err
  LDA #M_INY
  BRA .as_find
.as_ind:
  LDA #M_ZPI             ; (zp) or (abs)
  BRA .as_zw
.as_3:
  CMP #'A'               ; A alone: accumulator
  BNE .as_4
  LDY LP
  LDA CON_LINE+1,Y
  CMP #' '+1
  BCS .as_4
  LDA #M_ACC
  BRA .as_find
.as_4:
  JSR GETHEX             ; a number, then ,X ,Y or ,target
  BCC .fb3
  JMP .as_err
.fb3:
  JSR SAVEVAL
  JSR SKIPSP
  BEQ .as_zp
  CMP #','
  BEQ .fb2
  JMP .as_err
.fb2:
  JSR SKIPSP2
  CMP #'X'
  BEQ .as_x
  CMP #'Y'
  BEQ .as_y
  JSR GETHEX             ; BBR / BBS: zp,target
  BCC .fb1
  JMP .as_err
.fb1:
  LDA VAL
  STA AVAL2
  LDA VAL+1
  STA AVAL2+1
  LDA #M_ZPR
  BRA .as_find
.as_x:
  INC LP
  LDA #M_ZPX
  BRA .as_zw
.as_y:
  INC LP
  LDA #M_ZPY
  BRA .as_zw
.as_zp:
  LDA #M_ZP
.as_zw:
  LDX NDIG               ; more than 2 digits or a value over $FF: the absolute mode
  CPX #3
  BCS .as_ab
  LDX AVAL+1
  BEQ .as_find
.as_ab:
  CLC
  ADC #ABSOFF            ; (ZP->ABS ZPX->ABX ZPY->ABY INX->AIX ZPI->IND)
  TAX
  LDA ABSMAP-M_ZP,X
  BRA .as_find
.as_v:
  JSR SAVEVAL
  LDA #M_IMM
.as_find:
  STA AMODE
  JSR FINDOP
  BCC .as_put
  LDA AMODE              ; not there: ZP -> ABS, then a branch
  CMP #M_ZP
  BNE .as_r
  LDA #M_ABS
  STA AMODE
  JSR FINDOP
  BCC .as_put
  LDA #M_REL
  STA AMODE
  JSR FINDOP
  BCC .as_put
.as_r:
  LDA AMODE
  CMP #M_ABS
  BNE .as_ix
  LDA #M_REL
  STA AMODE
  JSR FINDOP
  BCC .as_put
.as_ix:
  LDA AMODE              ; (zp,X) not there: (abs,X); (zp): (abs)
  CMP #M_INX
  BNE .as_iz
  LDA #M_AIX
  BRA .as_rt
.as_iz:
  CMP #M_ZPI
  BNE .as_ac
  LDA #M_IND
  BRA .as_rt
.as_ac:
  CMP #M_IMP             ; no operand: maybe the accumulator form (ASL = ASL A)
  BNE .as_bad
  LDA #M_ACC
.as_rt:
  STA AMODE
  JSR FINDOP
  BCC .as_put
.as_bad:
  SEC
  RTS
.as_put:
  PHA
  LDA AMODE              ; an immediate value must fit in a byte
  CMP #M_IMM
  BNE .as_pp
  LDA AVAL+1
  BEQ .as_pp
  PLA
  SEC
  RTS
.as_pp:
  LDA (DPC)              ; (kept: a branch out of range puts it back)
  STA T2
  PLA
  STA (DPC)              ; opcode, then the operand
  LDA AMODE
  CMP #M_REL
  BEQ .as_rel
  CMP #M_ZPR
  BEQ .as_zpr
  TAX
  LDA MDLEN,X
  CMP #2
  BCC .as_ok
  LDA AVAL
  LDY #1
  STA (DPC),Y
  LDA MDLEN,X
  CMP #3
  BCC .as_ok
  LDA AVAL+1
  INY
  STA (DPC),Y
.as_ok:
  CLC
  RTS
.as_rel:
  LDA #2                 ; offset = target - (DPC + 2)
  LDY #1
  JSR RELOFF
  BCS .as_rb
  RTS
.as_rb:
  LDA T2
  STA (DPC)
  SEC
  RTS
.as_zpr:
  LDA AVAL               ; zp, then offset = target - (DPC + 3)
  LDY #1
  STA (DPC),Y
  LDA AVAL2
  STA AVAL
  LDA AVAL2+1
  STA AVAL+1
  LDA #3
  LDY #2
  JSR RELOFF
  BCS .as_rb
  RTS

; RELOFF: (DPC),Y = AVAL - (DPC + A), C=1 out of range
RELOFF:
  CLC
  ADC DPC
  STA T0
  LDA DPC+1
  ADC #0
  STA T1
  SEC
  LDA AVAL
  SBC T0
  STA T0
  LDA AVAL+1
  SBC T1
  BEQ .ro_p              ; 0..$7F
  CMP #$FF
  BNE .ro_e
  LDA T0                 ; -$80..-1
  BPL .ro_e
  BRA .ro_ok
.ro_p:
  LDA T0
  BMI .ro_e
.ro_ok:
  LDA T0
  STA (DPC),Y
  CLC
  RTS
.ro_e:
  SEC
  RTS

ABSOFF      = 0
ABSMAP:                  ; ZP ZPX ZPY ABS ABX ABY IND INX INY ZPI -> absolute form
  .byte M_ABS, M_ABX, M_ABY, M_ABS, M_ABX, M_ABY, M_IND, M_AIX, M_INY, M_IND

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

; BITMN0: C=0 if MN is RMB SMB BBR BBS
BITMN0:
  LDA MN
  CMP #MN_RMB
  BEQ .b0_y
  CMP #MN_SMB
  BEQ .b0_y
  CMP #MN_BBR
  BEQ .b0_y
  CMP #MN_BBS
  BEQ .b0_y
  SEC
  RTS
.b0_y:
  CLC
  RTS

SAVEVAL:
  LDA VAL
  STA AVAL
  LDA VAL+1
  STA AVAL+1
  RTS

; XORY: A = the letter after a ',' (both taken)
XORY:
  JSR SKIPSP2
  PHA
  INC LP
  PLA
  RTS

; SKIPSP2: past the ',', A = the next character that is not a space (not taken)
SKIPSP2:
  INC LP
  JMP SKIPSP

; CLOSEP: a ')' must follow. C=1 not there
CLOSEP:
  JSR SKIPSP
  CMP #')'
  BNE .cp_e
  INC LP
  CLC
  RTS
.cp_e:
  SEC
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; S  L

; GETNAME: NAMEB = next word (12 characters at most, $00 padded). C=1 none
GETNAME:
  LDX #12
.gn_z:
  STZ NAMEB,X
  DEX
  BPL .gn_z
  JSR SKIPSP
  BEQ .gn_e
  LDX #0
.gn_l:
  LDY LP
  LDA CON_LINE,Y
  BEQ .gn_x
  CMP #' '
  BEQ .gn_x
  CPX #12
  BCS .gn_s
  STA NAMEB,X
  INX
.gn_s:
  INC LP
  BRA .gn_l
.gn_x:
  CLC
  RTS
.gn_e:
  SEC
  RTS

; CMD_S: S name a b -> document of type 4: address (2 bytes), then the bytes a..b
CMD_S:
  JSR GETNAME
  BCC .s_n
  JMP ERROR
.s_n:
  JSR ARG2
  SEC                    ; length = b - a + 1 (at most 20 KB - 2)
  LDA A2
  SBC A1
  STA CNT
  LDA A2+1
  SBC A1+1
  STA CNT+1
  BCS .s_ok
  JMP ERROR
.s_ok:
  JSR DOC_RDIDX
  BCS S_ERR
  LDA #<NAMEB
  STA DOC_P
  LDA #>NAMEB
  STA DOC_P+1
  JSR DOC_FIND
  BCC .s_k
  JSR DOC_FREE
  BCC .s_k
  LDA #<M_NOSLOT
  LDX #>M_NOSLOT
  JMP CON_STR
.s_k:
  STA DOCSLOT
  STA DOC_K
  JSR ST_WOPEN
  LDA A1
  JSR ST_PUT
  LDA A1+1
  JSR ST_PUT
.s_l:
  LDA (A1)
  JSR ST_PUT
  LDA CNT
  ORA CNT+1
  BEQ .s_c
  JSR INCA1
  JSR DECCNT
  BRA .s_l
.s_c:
  JSR ST_WCLOSE
  BCS .s_big
  LDA DOCSLOT
  JSR DOC_SETENT
  JSR DOC_WRIDX
  BCS S_ERR
  LDA #<M_SAVED
  LDX #>M_SAVED
  JMP CON_STR
.s_big:
  LDA ST_ERR
S_ERR:
  LDA #<M_SDERR
  LDX #>M_SDERR
  JMP CON_STR

; CMD_L: L name [a]
CMD_L:
  JSR GETNAME
  BCC .l_n
  JMP ERROR
.l_n:
  JSR GETHEX             ; another address?
  ROR T2                 ; bit 7 = 1: no address
  JSR DOC_RDIDX
  BCS S_ERR
  LDA #<NAMEB
  STA DOC_P
  LDA #>NAMEB
  STA DOC_P+1
  JSR DOC_FIND
  BCC .l_k
  LDA #<M_NF
  LDX #>M_NF
  JMP CON_STR
.l_k:
  STA DOC_K
  JSR DOC_ENTRY
  LDY #1
  LDA (DOC_E),Y
  STA DOC_LEN
  INY
  LDA (DOC_E),Y
  STA DOC_LEN+1
  JSR ST_ROPEN
  JSR ST_GET             ; its address
  STA A1
  JSR ST_GET
  STA A1+1
  BIT T2
  BMI .l_a
  LDA VAL
  STA A1
  LDA VAL+1
  STA A1+1
.l_a:
  LDA A1                 ; "aaaa-bbbb" afterwards
  STA A3
  LDA A1+1
  STA A3+1
.l_l:
  JSR ST_GET
  BCS .l_e
  STA (A1)
  JSR INCA1
  BRA .l_l
.l_e:
  LDA ST_ERR
  BNE S_ERR
  LDA A3+1
  JSR CON_HEX
  LDA A3
  JSR CON_HEX
  LDA #'-'
  JSR CON_PUT
  LDA A1                 ; last byte = A1 - 1
  BNE .l_d
  DEC A1+1
.l_d:
  DEC A1
  LDA A1+1
  JSR CON_HEX
  LDA A1
  JSR CON_HEX
  JMP CON_CR

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; help

CMD_HELP:
  LDA #<HELPTXT
  LDX #>HELPTXT
  JMP CON_STR

M_HELLO:    .byte "MINIVIC MON 1.0      ? = HELP",K_CR,0
M_ERR:      .byte "  ?",K_CR,0
M_SAVED:    .byte "SAVED",K_CR,0
M_SDERR:    .byte "SD CARD ERROR",K_CR,0
M_NOSLOT:   .byte "NO FREE PLACE ON THE SD",K_CR,0
M_NF:       .byte "NOT FOUND",K_CR,0
HELPTXT:
  .byte "M A B     MEMORY      : A BB.. WRITE",K_CR
  .byte "D A B     DISASSEMBLE A A INS ASSEMBLE",K_CR
  .byte "G A       CALL (JSR)  R  REGISTERS",K_CR
  .byte "F A B V   FILL        T A B C COPY",K_CR
  .byte "H A B BB  FIND BYTES  X  EXIT",K_CR
  .byte "S NAME A B  SAVE   L NAME [A]  LOAD",K_CR
  .byte "HEX NUMBERS, ESC STOPS A LISTING",K_CR
  .byte "FREE RAM FOR PROGRAMS: $3000-$7FFF",K_CR,0

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; libraries

 .include "lib/opcodes.asm"
 .include "lib/keys.asm"
 .include "lib/vtext.asm"
 .include "lib/console.asm"
 .include "lib/docs.asm"
 .include "lib/stream.asm"
 .include "lib/ui.asm"
 .include "lib/num.asm"

CODE_END:
