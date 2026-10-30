;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                                              ;
;   WRITE  -  miniVIC WRITE, text editor (WordStar style)      ;
;   65C02 assembly, TMS9918A text mode 40 x 24                 ;
;   Needs the BIOS 27.10.26 KEYB/SD (extended keyboard,        ;
;   SD sector write)                                           ;
;                                                              ;
;   - gap buffer of 20480 bytes ($3000-$7FFF), the cursor is   ;
;     the start of the gap; CR ($0D) ends a paragraph and the  ;
;     screen wraps the words at 40 columns                     ;
;   - WordStar keys: ^E ^X ^S ^D cursor, ^A ^F word, ^R ^C     ;
;     page, ^G ^H ^T ^Y delete, ^V insert/overwrite, ^N split, ;
;     ^K block and file commands, ^Q quick commands, ^J help;  ;
;     arrows, Home, End, PgUp, PgDn, Ins, Del and F1-F10 too   ;
;   - block: begin, end, hide, copy, move, delete (shown in    ;
;     inverse); find, find again, replace all                  ;
;   - up to 15 documents on the SD (lib/docs.asm), 20 KB each  ;
;   - keys (lib/keys.asm): keyboard CA1 interrupt, and every   ;
;     long loop calls KB_POLL too; the screen is redrawn only  ;
;     when no key waits                                        ;
;                                                              ;
;   MEMORY                                                     ;
;   $0050-$00AF  zero page (editor $50-$9F, lib $A0-$AF)       ;
;   $0210-$02FF  line buffer, row starts, status, name,        ;
;                prompt (lib/ui: $02A0-$02C7, $02D8-)          ;
;   $0500-$0569  find and replace strings, message             ;
;   $05C0-$05DF  key queue (lib/keys)                          ;
;   $0600-$07FF  SD document index                             ;
;   $0800-$0BFF  font copy (start only)                        ;
;   $1000-$2FFF  code (8 KB at most)                           ;
;   $3000-$7FFF  text (gap buffer, 20480 bytes)                ;
;                                                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

 .include "lib/system.inc"

; ---------------- parameters ----------------
BUF         = $3000    ; text buffer
BUF_END     = $8000    ; (first byte after it)
TROWS       = 22       ; text rows (screen rows 1-22)
TCOLS       = 40
CR          = $0D
NAMELEN     = 12
FINDMAX     = 24       ; (the longest prompt + 24 + cursor fit in 40 columns)

; ---------------- zero page ----------------
GS          = $50      ; 2 bytes: gap start (= cursor), physical
GE          = $52      ; 2 bytes: gap end, physical
TOP         = $54      ; 2 bytes: logical position of the first screen row
BB          = $56      ; 2 bytes: block begin (logical)
BK          = $58      ; 2 bytes: block end (BK = BB+2: indexed with X)
BFLAG       = $5A      ; bit 0 begin set, bit 1 end set, bit 7 hidden
LINE        = $5B      ; 2 bytes: paragraph of the cursor (0-based)
MODF        = $5D      ; 1 = changed since the last save
INSM        = $5E      ; 1 = insert, 0 = overwrite
PREFIX      = $5F      ; 0, 'K' or 'Q' after ^K / ^Q
RP          = $60      ; 2 bytes: text reader, physical
Q           = $62      ; 2 bytes: logical position for RD_SET
LS          = $64      ; 2 bytes: start of the screen line being scanned
LLEN        = $66      ; characters of that line (with its CR or wrap space)
LAST        = $67      ; 1 = the line ends at the end of the text
LSP         = $68      ; last space of the line ($FF none)
CC          = $69      ; cursor column in the line ($FF = not in this line)
B0          = $6A      ; block columns [B0, B1) in the line
B1          = $6B
CURL        = $6C      ; 2 bytes: logical cursor
TARGET      = $6E      ; 2 bytes: where MOVETO takes the cursor
CNT         = $70      ; 2 bytes
P0          = $72      ; 2 bytes: logical cursor (CURPOS)
P1          = $74      ; 2 bytes: text length (TXTLEN), VSTART counter
P2          = $76      ; 2 bytes
T0          = $78
T1          = $79
T2          = $7A
T3          = $7B
VX          = $7C      ; 2 bytes: VSTART argument
ROWI        = $7E
DONE        = $7F
CCOL        = $80      ; cursor column on the screen
PGCNT       = $81
DIRTY       = $82      ; 1 = the text rows must be redrawn
MSGP        = $83      ; 2 bytes: message of row 23 (hi = 0: none)
ISVERT      = $85      ; 1 = this command was a vertical move
PREVV       = $86      ; the same for the command before
WANT        = $87      ; column kept by consecutive vertical moves
FLEN        = $88      ; length of the find string
RLEN        = $89      ; length of the replace string
DOCSLOT     = $8A
RCNT        = $8C      ; 2 bytes: replacements
BN          = $91      ; 2 bytes: block length
BO          = $93      ; 2 bytes: block begin before a move
BP          = $95      ; 2 bytes: where the copy of a block starts
SAVECUR     = $99      ; 2 bytes

; ---------------- RAM ----------------
LINEBUF     = $0210    ; 40 characters of the line being scanned
ROWSL       = $0240    ; starts of the screen lines (FIT), 44 + 4
ROWSH       = $0270
STATBUF     = UI_LINE  ; 40 characters: the status bar
DOCNAME     = $02C8    ; 12 characters + $00
FINDBUF     = $0500    ; find string (upper case)
REPLBUF     = $0520    ; replace string
MSGBUF      = $0540    ; message built at run time (40 + $00)

 .org $0FD0
  RTS                    ; NMI trampoline (the VDP interrupt is off)
 .org $1000

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; start and main loop

RESET:
  SEI
  CLD
  LDX #$FF
  TXS
  LDA #$60               ; RTS: no IRQ handler, everything is polled
  STA IRQ_VEC
  JSR VT_INIT
  JSR KB_INIT
  LDA #1
  STA INSM
  STZ FLEN
  STZ RLEN
  STZ PREFIX
  STZ PREVV
  STZ ISVERT
  STZ CCOL
  JSR DOCNEW
  LDA #<M_HELLO
  LDX #>M_HELLO
  JSR SETMSG
MAIN:
  LDA DIRTY
  BEQ .mn_s
  STZ DIRTY
  JSR FIT
  JSR REDRAW
.mn_s:
  JSR STATUS
  JSR MSGLINE
IDLE:
  JSR GETKEY
  BCC IDLE
.mn_k:
  JSR DOKEY
  JSR KEYREADY           ; more keys: no redraw in between
  BCC MAIN
  JSR GETKEY
  BRA .mn_k

; DOKEY: runs the command of key A
DOKEY:
  STZ MSGP+1
  LDX ISVERT
  STX PREVV
  STZ ISVERT
  LDX PREFIX
  BEQ .dk_n
  STZ PREFIX
  JSR KEYLETTER
  STA T0
  LDA #<KTAB
  STA P2
  LDA #>KTAB
  STA P2+1
  CPX #'K'
  BEQ .dk_t
  LDA #<QTAB
  STA P2
  LDA #>QTAB
  STA P2+1
.dk_t:
  LDY #0
.dk_tl:
  LDA (P2),Y
  BEQ .dk_x
  CMP T0
  BEQ .dk_tf
  INY
  INY
  INY
  BRA .dk_tl
.dk_tf:
  INY
  LDA (P2),Y
  STA P0
  INY
  LDA (P2),Y
  STA P0+1
  JMP (P0)
.dk_n:
  CMP #$20
  BCC .dk_c
  CMP #$7F
  BCC .dk_p
  CMP #K_UP
  BCC .dk_x
  CMP #K_F1+12
  BCS .dk_x
  SEC
  SBC #K_UP
  ASL
  TAX
  JMP (EXTTAB,X)
.dk_c:
  ASL
  TAX
  JMP (CTRLTAB,X)
.dk_p:
  JMP TYPECH
.dk_x:
  RTS

; KEYLETTER: Ctrl+letter and lower case -> upper case letter
KEYLETTER:
  CMP #1
  BCC .kl_x
  CMP #27
  BCS .kl_lc
  ORA #$40
  RTS
.kl_lc:
  CMP #'a'
  BCC .kl_x
  CMP #'z'+1
  BCS .kl_x
  AND #$DF
.kl_x:
  RTS

NOP_CMD:
  RTS

CMD_PFXK:
  LDA #'K'
  STA PREFIX
  RTS
CMD_PFXQ:
  LDA #'Q'
  STA PREFIX
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; gap buffer

; CURPOS: P0 = logical cursor. Keeps X, Y
CURPOS:
  SEC
  LDA GS
  SBC #<BUF
  STA P0
  LDA GS+1
  SBC #>BUF
  STA P0+1
  RTS

; TXTLEN: P0 = cursor, P1 = text length
TXTLEN:
  JSR CURPOS
  SEC
  LDA #<BUF_END
  SBC GE
  STA P1
  LDA #>BUF_END
  SBC GE+1
  STA P1+1
  CLC
  LDA P1
  ADC P0
  STA P1
  LDA P1+1
  ADC P0+1
  STA P1+1
  RTS

; ATEND: Z=1 if the cursor is at the end of the text
ATEND:
  LDA GE
  CMP #<BUF_END
  BNE .ae_x
  LDA GE+1
  CMP #>BUF_END
.ae_x:
  RTS

; INSRAW: A at the cursor (no checks)
INSRAW:
  STA (GS)
  CMP #CR
  BNE .ir_n
  INC LINE
  BNE .ir_n
  INC LINE+1
.ir_n:
  INC GS
  BNE .ir_d
  INC GS+1
.ir_d:
  LDA #1
  STA MODF
  STA DIRTY
  RTS

; INSCH: inserts A at the cursor. C=1 memory full
INSCH:
  PHA
  LDA GS
  CMP GE
  BNE .ic_ok
  LDA GS+1
  CMP GE+1
  BNE .ic_ok
  PLA
  LDA #<M_FULL
  LDX #>M_FULL
  JSR SETMSG
  SEC
  RTS
.ic_ok:
  JSR CURPOS
  LDX #0
  JSR ADJINS
  LDX #2
  JSR ADJINS
  PLA
  JSR INSRAW
  CLC
  RTS

; ADJINS: mark BB+X moves on if it is after the cursor P0
ADJINS:
  LDA P0
  CMP BB,X
  LDA P0+1
  SBC BB+1,X
  BCS .ai_x
  INC BB,X
  BNE .ai_x
  INC BB+1,X
.ai_x:
  RTS

; ADJDEL: mark BB+X moves back if it is after P0 (a character at P0 was deleted)
ADJDEL:
  LDA P0
  CMP BB,X
  LDA P0+1
  SBC BB+1,X
  BCS .ad_x
  LDA BB,X
  BNE .ad_d
  DEC BB+1,X
.ad_d:
  DEC BB,X
.ad_x:
  RTS

; BSRAW: deletes the character before the cursor. C=1 at the start
BSRAW:
  LDA GS
  CMP #<BUF
  BNE .bs_ok
  LDA GS+1
  CMP #>BUF
  BNE .bs_ok
  SEC
  RTS
.bs_ok:
  LDA GS
  BNE .bs_d
  DEC GS+1
.bs_d:
  DEC GS
  LDA (GS)
  CMP #CR
  BNE .bs_n
  LDA LINE
  BNE .bs_l
  DEC LINE+1
.bs_l:
  DEC LINE
.bs_n:
  LDA #1
  STA MODF
  STA DIRTY
  CLC
  RTS

; DELRAW: deletes the character at the cursor. C=1 at the end
DELRAW:
  JSR ATEND
  BNE .dr_ok
  SEC
  RTS
.dr_ok:
  INC GE
  BNE .dr_d
  INC GE+1
.dr_d:
  LDA #1
  STA MODF
  STA DIRTY
  CLC
  RTS

; MOVETO: cursor to the logical position TARGET (<= length)
MOVETO:
  JSR CURPOS
  SEC
  LDA TARGET
  SBC P0
  STA CNT
  LDA TARGET+1
  SBC P0+1
  STA CNT+1
  BCS MVRIGHT
  SEC
  LDA #0
  SBC CNT
  STA CNT
  LDA #0
  SBC CNT+1
  STA CNT+1
  ; (falls into MVLEFT)

; MVLEFT: gap CNT bytes to the left: the bytes go from below the gap to its top end,
; copied downwards in pages of 256
MVLEFT:
  LDA #1
  STA DIRTY
.ml_c:
  LDA CNT
  ORA CNT+1
  BEQ .ml_x
  LDA CNT+1
  BEQ .ml_p
  DEC GS+1
  DEC GE+1
  DEC CNT+1
  LDY #$FF
  BRA .ml_l
.ml_p:
  SEC
  LDA GS
  SBC CNT
  STA GS
  BCS .ml_p1
  DEC GS+1
.ml_p1:
  SEC
  LDA GE
  SBC CNT
  STA GE
  BCS .ml_p2
  DEC GE+1
.ml_p2:
  LDY CNT
  DEY
  STZ CNT
.ml_l:
  LDA (GS),Y
  STA (GE),Y
  CMP #CR
  BNE .ml_n
  LDA LINE
  BNE .ml_ld
  DEC LINE+1
.ml_ld:
  DEC LINE
.ml_n:
  TYA
  AND #$0F
  BNE .ml_q
  JSR KB_POLL
.ml_q:
  DEY
  CPY #$FF
  BNE .ml_l
  BRA .ml_c
.ml_x:
  JMP KB_POLL

; MVRIGHT: gap CNT bytes to the right, copied upwards in pages of 256
MVRIGHT:
  LDA #1
  STA DIRTY
.mr_c:
  LDA CNT
  ORA CNT+1
  BEQ .mr_x
  LDA CNT+1
  BEQ .mr_p
  DEC CNT+1
  STZ T3                 ; 0 = 256 bytes
  BRA .mr_go
.mr_p:
  LDA CNT
  STA T3
  STZ CNT
.mr_go:
  LDY #0
.mr_l:
  LDA (GE),Y
  STA (GS),Y
  CMP #CR
  BNE .mr_n
  INC LINE
  BNE .mr_n
  INC LINE+1
.mr_n:
  TYA
  AND #$0F
  BNE .mr_q
  JSR KB_POLL
.mr_q:
  INY
  CPY T3
  BNE .mr_l
  LDA T3
  BNE .mr_a
  INC GS+1
  INC GE+1
  BRA .mr_c
.mr_a:
  CLC
  ADC GS
  STA GS
  BCC .mr_a1
  INC GS+1
.mr_a1:
  CLC
  LDA T3
  ADC GE
  STA GE
  BCC .mr_c
  INC GE+1
  BRA .mr_c
.mr_x:
  JMP KB_POLL

; RD_SET: text reader RP at the logical position Q
RD_SET:
  JSR CURPOS
  LDA Q
  CMP P0
  LDA Q+1
  SBC P0+1
  BCS .rs_a
  CLC
  LDA Q
  ADC #<BUF
  STA RP
  LDA Q+1
  ADC #>BUF
  STA RP+1
  RTS
.rs_a:
  SEC                    ; after the gap: GE + (Q - cursor)
  LDA Q
  SBC P0
  STA RP
  LDA Q+1
  SBC P0+1
  STA RP+1
  CLC
  LDA RP
  ADC GE
  STA RP
  LDA RP+1
  ADC GE+1
  STA RP+1
  RTS

; RD_GET: A = next character, C=1 at the end of the text. Keeps X
RD_GET:
  LDA RP+1
  CMP #>BUF_END
  BCS .rg_e
  LDA (RP)
  INC RP
  BNE .rg_c
  INC RP+1
.rg_c:
  LDY RP
  CPY GS
  BNE .rg_ok
  LDY RP+1
  CPY GS+1
  BNE .rg_ok
  LDY GE                 ; jump over the gap
  STY RP
  LDY GE+1
  STY RP+1
.rg_ok:
  CLC
  RTS
.rg_e:
  SEC
  RTS

; RB_PREV: A = character before RP (RP moves back), C=1 at the start. Keeps X
RB_PREV:
  LDA RP
  CMP GE
  BNE .rb_a
  LDA RP+1
  CMP GE+1
  BNE .rb_a
  LDA GS                 ; jump over the gap
  STA RP
  LDA GS+1
  STA RP+1
.rb_a:
  LDA RP
  CMP #<BUF
  BNE .rb_b
  LDA RP+1
  CMP #>BUF
  BEQ .rb_s
.rb_b:
  LDA RP
  BNE .rb_c
  DEC RP+1
.rb_c:
  DEC RP
  LDA (RP)
  CLC
  RTS
.rb_s:
  SEC
  RTS

; RECOUNT: LINE = CRs before the cursor
RECOUNT:
  STZ LINE
  STZ LINE+1
  LDA #<BUF
  STA P2
  LDA #>BUF
  STA P2+1
.rc_l:
  LDA P2
  CMP GS
  BNE .rc_c
  LDA P2+1
  CMP GS+1
  BEQ .rc_x
.rc_c:
  LDA (P2)
  CMP #CR
  BNE .rc_n
  INC LINE
  BNE .rc_n
  INC LINE+1
.rc_n:
  INC P2
  BNE .rc_l
  INC P2+1
  JSR KB_POLL
  BRA .rc_l
.rc_x:
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; screen lines

; SCANLINE: screen line starting at LS -> LINEBUF, LLEN, LAST
; A line takes up to 40 characters: it ends after a CR, after the last space of 40
; characters (word wrap), after 40 characters without spaces, or at the end of the text
SCANLINE:
  LDA LS
  STA Q
  LDA LS+1
  STA Q+1
  JSR RD_SET
  LDX #0
  LDA #$FF
  STA LSP
.sl_l:
  JSR RD_GET
  BCS .sl_e
  STA LINEBUF,X
  CMP #CR
  BEQ .sl_cr
  CMP #' '
  BNE .sl_ns
  STX LSP
.sl_ns:
  INX
  TXA
  AND #$07
  BNE .sl_np
  JSR KB_POLL
.sl_np:
  CPX #TCOLS
  BNE .sl_l
  STZ LAST
  LDA LSP
  BMI .sl_h
  INC A
  STA LLEN
  RTS
.sl_h:
  LDA #TCOLS
  STA LLEN
  RTS
.sl_cr:
  INX
  STX LLEN
  STZ LAST
  RTS
.sl_e:
  STX LLEN
  LDA #1
  STA LAST
  RTS

; NEXTLS: LS = LS + LLEN
NEXTLS:
  CLC
  LDA LS
  ADC LLEN
  STA LS
  BCC .nl_x
  INC LS+1
.nl_x:
  RTS

; CURCOL: CC = column of CURL in the scanned line, $FF if not in it
CURCOL:
  SEC
  LDA CURL
  SBC LS
  STA T0
  LDA CURL+1
  SBC LS+1
  BCC .cc_n
  BNE .cc_n
  LDA T0
  CMP LLEN
  BCC .cc_y
  BNE .cc_n
  LDA LAST               ; just after the last character of the text
  BEQ .cc_n
.cc_y:
  LDA T0
  STA CC
  RTS
.cc_n:
  LDA #$FF
  STA CC
  RTS

; BLKON: C=0 if the block is shown (begin and end set, not hidden, begin < end)
BLKON:
  LDA BFLAG
  CMP #3
  BNE .bo_n
  LDA BB
  CMP BK
  LDA BB+1
  SBC BK+1
  RTS
.bo_n:
  SEC
  RTS

; BLKCOLS: [B0, B1) = block columns in the scanned line
BLKCOLS:
  STZ B0
  STZ B1
  JSR BLKON
  BCS .bc_x
  SEC
  LDA BB
  SBC LS
  STA T0
  LDA BB+1
  SBC LS+1
  JSR CLAMP
  STA B0
  SEC
  LDA BK
  SBC LS
  STA T0
  LDA BK+1
  SBC LS+1
  JSR CLAMP
  STA B1
.bc_x:
  RTS

; CLAMP: signed 16-bit A (hi) / T0 (lo), C = no borrow -> A = 0..40
CLAMP:
  BCC .cl_0
  BNE .cl_40
  LDA T0
  CMP #TCOLS+1
  BCC .cl_x
.cl_40:
  LDA #TCOLS
.cl_x:
  RTS
.cl_0:
  LDA #0
  RTS

; VSTART: LS = start of the screen line holding the logical position VX
VSTART:
  LDA VX
  STA Q
  STA P1
  LDA VX+1
  STA Q+1
  STA P1+1
  JSR RD_SET
.vs_b:
  JSR RB_PREV            ; back to the start of the paragraph
  BCS .vs_f
  CMP #CR
  BEQ .vs_f
  LDA P1
  BNE .vs_d
  DEC P1+1
.vs_d:
  DEC P1
  LDA P1
  AND #$07
  BNE .vs_b
  JSR KB_POLL
  BRA .vs_b
.vs_f:
  LDA P1
  STA LS
  LDA P1+1
  STA LS+1
.vs_l:
  JSR SCANLINE           ; then forward, line by line
  LDA LAST
  BNE .vs_x
  CLC
  LDA LS
  ADC LLEN
  STA T0
  LDA LS+1
  ADC #0
  STA T1
  LDA VX
  CMP T0
  LDA VX+1
  SBC T1
  BCC .vs_x
  LDA T0
  STA LS
  LDA T1
  STA LS+1
  BRA .vs_l
.vs_x:
  RTS

; FIT: TOP so that the cursor is on the screen (scrolls up to 21 lines, else jumps)
FIT:
  JSR CURPOS
  LDA P0
  STA CURL
  LDA P0+1
  STA CURL+1
  LDA CURL
  CMP TOP
  LDA CURL+1
  SBC TOP+1
  BCS .ft_s
.ft_v:
  LDA CURL
  STA VX
  LDA CURL+1
  STA VX+1
  JSR VSTART
  LDA LS
  STA TOP
  LDA LS+1
  STA TOP+1
  RTS
.ft_s:
  LDA TOP
  STA LS
  LDA TOP+1
  STA LS+1
  STZ ROWI
.ft_l:
  LDX ROWI
  LDA LS
  STA ROWSL,X
  LDA LS+1
  STA ROWSH,X
  JSR SCANLINE
  JSR CURCOL
  LDA CC
  CMP #$FF
  BNE .ft_f
  LDA LAST
  BNE .ft_v
  JSR NEXTLS
  INC ROWI
  LDA ROWI
  CMP #2*TROWS
  BCC .ft_l
  BRA .ft_v
.ft_f:
  LDA ROWI
  CMP #TROWS
  BCC .ft_x
  SEC
  SBC #TROWS-1
  TAX
  LDA ROWSL,X
  STA TOP
  LDA ROWSH,X
  STA TOP+1
.ft_x:
  RTS

; REDRAW: text rows 1-22 from TOP; also CCOL
REDRAW:
  JSR CURPOS
  LDA P0
  STA CURL
  LDA P0+1
  STA CURL+1
  LDA TOP
  STA LS
  LDA TOP+1
  STA LS+1
  STZ DONE
  LDA #1
  STA ROWI
.rd_r:
  JSR KB_POLL
  LDA ROWI
  JSR VT_ROW
  LDA DONE
  BEQ .rd_s
  LDA #' '
  LDX #TCOLS
  JSR VT_REP
  BRA .rd_n
.rd_s:
  JSR SCANLINE
  JSR KB_POLL
  JSR CURCOL
  JSR BLKCOLS
  LDA CC
  CMP #$FF
  BEQ .rd_0
  STA CCOL
.rd_0:
  LDX #0
.rd_c:
  LDA #' '
  CPX LLEN
  BCS .rd_sp
  LDA LINEBUF,X
  CMP #CR
  BNE .rd_sp
  LDA #' '
.rd_sp:
  CPX B0
  BCC .rd_nb
  CPX B1
  BCS .rd_nb
  ORA #$80               ; block in inverse
.rd_nb:
  CPX CC
  BNE .rd_nc
  EOR #$80               ; cursor
.rd_nc:
  STA VDP_DATA
  INX
  TXA
  AND #$07
  BNE .rd_np
  JSR KB_POLL
.rd_np:
  CPX #TCOLS
  BNE .rd_c
  LDA LAST
  BEQ .rd_a
  LDA #1
  STA DONE
.rd_a:
  JSR NEXTLS
.rd_n:
  INC ROWI
  LDA ROWI
  CMP #TROWS+1
  BNE .rd_r
  RTS

; STATUS: row 0 in inverse: name, *, line, column, INS/OVR, prefix, free bytes
STATUS:
  JSR KB_POLL
  LDX #TCOLS-1
  LDA #' '
.st_b:
  STA STATBUF,X
  DEX
  BPL .st_b
  LDA DOCNAME
  BNE .st_nm
  LDX #6
.st_nn:
  LDA M_NONAME,X
  STA STATBUF+1,X
  DEX
  BPL .st_nn
  BRA .st_m
.st_nm:
  LDX #0
.st_n:
  LDA DOCNAME,X
  BEQ .st_m
  STA STATBUF+1,X
  INX
  CPX #NAMELEN
  BNE .st_n
.st_m:
  LDA MODF
  BEQ .st_l
  LDA #'*'
  STA STATBUF+13
.st_l:
  LDA #<STATBUF
  STA VT_P
  LDA #>STATBUF
  STA VT_P+1
  LDA CCOL               ; column first: its 5 digits are at 20-24, the line then
  INC A                  ; writes 16-20 and the 'C' goes at 22
  STA NUM
  STZ NUM+1
  LDY #20
  JSR NUMSTR
  LDA #'L'
  STA STATBUF+15
  CLC
  LDA LINE
  ADC #1
  STA NUM
  LDA LINE+1
  ADC #0
  STA NUM+1
  LDY #16
  JSR NUMSTR
  LDA #'C'
  STA STATBUF+22
  LDX #2
.st_i:
  LDA M_INS,X
  LDY INSM
  BNE .st_i1
  LDA M_OVR,X
.st_i1:
  STA STATBUF+26,X
  DEX
  BPL .st_i
  LDA PREFIX
  BEQ .st_f
  STA STATBUF+31
  LDA #'^'
  STA STATBUF+30
.st_f:
  SEC
  LDA GE
  SBC GS
  STA NUM
  LDA GE+1
  SBC GS+1
  STA NUM+1
  LDY #34
  JSR NUMSTR
  LDA #'F'
  STA STATBUF+33
  LDA #0
  JSR VT_ROW
  LDX #0
.st_o:
  LDA STATBUF,X
  ORA #$80
  STA VDP_DATA
  INX
  TXA
  AND #$0F
  BNE .st_p
  JSR KB_POLL
.st_p:
  CPX #TCOLS
  BNE .st_o
  JMP KB_POLL

; MSGLINE: row 23: prefix hint, message or the default hint
MSGLINE:
  LDA #23
  JSR VT_ROW
  STZ VT_INV
  LDA PREFIX
  BEQ .ms_m
  LDA #<M_HK
  LDX #>M_HK
  LDY PREFIX
  CPY #'K'
  BEQ .ms_o
  LDA #<M_HQ
  LDX #>M_HQ
  BRA .ms_o
.ms_m:
  LDA MSGP
  LDX MSGP+1
  BNE .ms_o
  LDA #<M_HINT
  LDX #>M_HINT
.ms_o:
  LDY #0
  JMP VT_LINE

; SETMSG: message A/X for row 23 until the next key
SETMSG:
  STA MSGP
  STX MSGP+1
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; cursor commands

; CURVS: CURL = cursor, LS = start of its screen line, T2 = its column
CURVS:
  JSR CURPOS
  LDA P0
  STA CURL
  STA VX
  LDA P0+1
  STA CURL+1
  STA VX+1
  JSR VSTART
  SEC
  LDA CURL
  SBC LS
  STA T2
  RTS

; STICKY: consecutive vertical moves keep the column of the first one
STICKY:
  LDA #1
  STA ISVERT
  LDA PREVV
  BEQ .sk_n
  LDA WANT
  STA T2
  RTS
.sk_n:
  LDA T2
  STA WANT
  RTS

; TOCOL: TARGET = LS + min(T2, T0)
TOCOL:
  LDA T2
  CMP T0
  BCC .tc_a
  LDA T0
.tc_a:
  CLC
  ADC LS
  STA TARGET
  LDA LS+1
  ADC #0
  STA TARGET+1
  JMP MOVETO

CMD_LEFT:
  JSR CURPOS
  LDA P0
  ORA P0+1
  BEQ .cl_x
  SEC
  LDA P0
  SBC #1
  STA TARGET
  LDA P0+1
  SBC #0
  STA TARGET+1
  JMP MOVETO
.cl_x:
  RTS

CMD_RIGHT:
  JSR ATEND
  BEQ .cr_x
  STZ CNT+1
  LDA #1
  STA CNT
  JMP MVRIGHT
.cr_x:
  RTS

CMD_UP:
  JSR CURVS
  JSR STICKY
  LDA LS
  ORA LS+1
  BEQ .cu_x
  SEC
  LDA LS
  SBC #1
  STA VX
  LDA LS+1
  SBC #0
  STA VX+1
  JSR VSTART
  JSR SCANLINE
  LDX LLEN
  DEX
  STX T0
  JMP TOCOL
.cu_x:
  RTS

CMD_DOWN:
  JSR CURVS
  JSR STICKY
  JSR SCANLINE
  LDA LAST
  BNE .cd_x
  JSR NEXTLS
  JSR SCANLINE
  LDX LLEN
  LDA LAST
  BNE .cd_l
  DEX
.cd_l:
  STX T0
  JMP TOCOL
.cd_x:
  RTS

CMD_PGUP:
  LDA #TROWS-1
  STA PGCNT
.pu_l:
  JSR CMD_UP
  LDA #1
  STA PREVV
  DEC PGCNT
  BNE .pu_l
  RTS

CMD_PGDN:
  LDA #TROWS-1
  STA PGCNT
.pd_l:
  JSR CMD_DOWN
  LDA #1
  STA PREVV
  DEC PGCNT
  BNE .pd_l
  RTS

CMD_HOME:
  JSR CURVS
  LDA LS
  STA TARGET
  LDA LS+1
  STA TARGET+1
  JMP MOVETO

CMD_END:
  JSR CURVS
  JSR SCANLINE
  LDX LLEN
  LDA LAST
  BNE .ce_l
  DEX
.ce_l:
  STX T0
  LDA #TCOLS
  STA T2
  JMP TOCOL

CMD_TOP:
  STZ TARGET
  STZ TARGET+1
  JMP MOVETO

CMD_BOTTOM:
  JSR TXTLEN
  LDA P1
  STA TARGET
  LDA P1+1
  STA TARGET+1
  JMP MOVETO

; WORDEND: P2 = position after the word right of the cursor and its spaces
WORDEND:
  JSR CURPOS
  LDA P0
  STA Q
  STA P2
  LDA P0+1
  STA Q+1
  STA P2+1
  JSR RD_SET
  STZ T3
.we_l:
  JSR RD_GET
  BCS .we_x
  CMP #'!'
  BCC .we_sp
  LDA T3
  BNE .we_x
  BRA .we_i
.we_sp:
  LDA #1
  STA T3
.we_i:
  INC P2
  BNE .we_p
  INC P2+1
.we_p:
  LDA P2
  AND #$07
  BNE .we_l
  JSR KB_POLL
  BRA .we_l
.we_x:
  RTS

CMD_WORDR:
  JSR WORDEND
  LDA P2
  STA TARGET
  LDA P2+1
  STA TARGET+1
  JMP MOVETO

CMD_WORDL:
  JSR CURPOS
  LDA P0
  STA Q
  STA P2
  LDA P0+1
  STA Q+1
  STA P2+1
  JSR RD_SET
  STZ T3
.wl_l:
  JSR RB_PREV
  BCS .wl_x
  CMP #'!'
  BCC .wl_sp
  LDA #1
  STA T3
  BRA .wl_d
.wl_sp:
  LDA T3
  BNE .wl_x
.wl_d:
  LDA P2
  BNE .wl_dd
  DEC P2+1
.wl_dd:
  DEC P2
  LDA P2
  AND #$07
  BNE .wl_l
  JSR KB_POLL
  BRA .wl_l
.wl_x:
  LDA P2
  STA TARGET
  LDA P2+1
  STA TARGET+1
  JMP MOVETO

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; editing commands

TYPECH:
  PHA
  LDA INSM
  BNE .ty_i
  JSR ATEND              ; overwrite: replaces a character, never a CR
  BEQ .ty_i
  LDA (GE)
  CMP #CR
  BEQ .ty_i
  JSR CMD_DEL
.ty_i:
  PLA
  JMP INSCH

CMD_ENTER:
  LDA #CR
  JMP INSCH

CMD_SPLIT:
  LDA #CR
  JSR INSCH
  BCS .sp_x
  JMP CMD_LEFT
.sp_x:
  RTS

CMD_TAB:
  JSR CURVS              ; spaces up to the next column multiple of 4
  LDA T2
  AND #$03
  EOR #$03
  INC A
  STA PGCNT
.tb_l:
  LDA #' '
  JSR INSCH
  BCS .tb_x
  DEC PGCNT
  BNE .tb_l
.tb_x:
  RTS

CMD_BKSP:
  JSR BSRAW
  BCS .bk_x
  JSR CURPOS
  LDX #0
  JSR ADJDEL
  LDX #2
  JSR ADJDEL
.bk_x:
  RTS

CMD_DEL:
  JSR ATEND
  BEQ .de_x
  JSR CURPOS
  LDX #0
  JSR ADJDEL
  LDX #2
  JSR ADJDEL
  JMP DELRAW
.de_x:
  RTS

; DELN: deletes CNT characters at the cursor
DELN:
  LDA CNT
  ORA CNT+1
  BEQ .dn_x
  JSR CMD_DEL
  LDA CNT
  BNE .dn_d
  DEC CNT+1
.dn_d:
  DEC CNT
  JSR KB_POLL
  BRA DELN
.dn_x:
  RTS

; CNTFROM: CNT = P2 - cursor
CNTFROM:
  JSR CURPOS
  SEC
  LDA P2
  SBC P0
  STA CNT
  LDA P2+1
  SBC P0+1
  STA CNT+1
  RTS

CMD_DELWORD:
  JSR WORDEND
  JSR CNTFROM
  JMP DELN

; LINEEND: P2 = position of the CR that ends the paragraph (or the end of the text)
LINEEND:
  JSR CURPOS
  LDA P0
  STA Q
  STA P2
  LDA P0+1
  STA Q+1
  STA P2+1
  JSR RD_SET
.le_l:
  JSR RD_GET
  BCS .le_x
  CMP #CR
  BEQ .le_x
  INC P2
  BNE .le_p
  INC P2+1
.le_p:
  LDA P2
  AND #$07
  BNE .le_l
  JSR KB_POLL
  BRA .le_l
.le_x:
  RTS

CMD_DELEOL:
  JSR LINEEND
  JSR CNTFROM
  JMP DELN

CMD_DELLINE:
  JSR CURPOS             ; to the start of the paragraph
  LDA P0
  STA Q
  STA P2
  LDA P0+1
  STA Q+1
  STA P2+1
  JSR RD_SET
.dl_b:
  JSR RB_PREV
  BCS .dl_s
  CMP #CR
  BEQ .dl_s
  LDA P2
  BNE .dl_d
  DEC P2+1
.dl_d:
  DEC P2
  BRA .dl_b
.dl_s:
  LDA P2
  STA TARGET
  LDA P2+1
  STA TARGET+1
  JSR MOVETO
  JSR LINEEND            ; then up to its CR, included
  JSR CNTFROM
  LDA P2                 ; (P2 before the end of the text: there is a CR)
  STA T0
  LDA P2+1
  STA T1
  JSR TXTLEN
  LDA T0
  CMP P1
  LDA T1
  SBC P1+1
  BCS .dl_x
  LDA CNT
  CLC
  ADC #1
  STA CNT
  BCC .dl_x
  INC CNT+1
.dl_x:
  JMP DELN

CMD_INS:
  LDA INSM
  EOR #1
  STA INSM
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; block

CMD_MARKB:
  JSR CURPOS
  LDA P0
  STA BB
  LDA P0+1
  STA BB+1
  LDA BFLAG
  ORA #1
  BRA MARKSET
CMD_MARKK:
  JSR CURPOS
  LDA P0
  STA BK
  LDA P0+1
  STA BK+1
  LDA BFLAG
  ORA #2
MARKSET:
  AND #$7F               ; a new mark shows the block
  STA BFLAG
  LDA #1
  STA DIRTY
  RTS

CMD_BHIDE:
  LDA BFLAG
  EOR #$80
  STA BFLAG
  LDA #1
  STA DIRTY
  RTS

; BCHECK: C=0 if a block is marked (BN = its length); with BCHECK2 also the cursor
; must not be inside it
BCHECK:
  LDA BFLAG
  AND #$03
  CMP #$03
  BNE .bk_no
  SEC
  LDA BK
  SBC BB
  STA BN
  LDA BK+1
  SBC BB+1
  STA BN+1
  BCC .bk_no
  ORA BN
  BEQ .bk_no
  CLC
  RTS
.bk_no:
  LDA #<M_NOBLK
  LDX #>M_NOBLK
  JSR SETMSG
  SEC
  RTS
BCHECK2:
  JSR BCHECK
  BCS .b2_x
  JSR CURPOS             ; inside if BB < cursor < BK
  LDA BB
  CMP P0
  LDA BB+1
  SBC P0+1
  BCS .b2_ok
  LDA P0
  CMP BK
  LDA P0+1
  SBC BK+1
  BCS .b2_ok
  LDA #<M_INBLK
  LDX #>M_INBLK
  JSR SETMSG
  SEC
  RTS
.b2_ok:
  CLC
.b2_x:
  RTS

; BCOPYN: copies the block (BB, BN bytes) at the cursor; BP = where the copy starts.
; C=1 memory full
BCOPYN:
  SEC
  LDA GE
  SBC GS
  TAX
  LDA GE+1
  SBC GS+1
  CMP BN+1
  BNE .bn_c
  CPX BN
.bn_c:
  BCS .bn_ok
  LDA #<M_FULL
  LDX #>M_FULL
  JSR SETMSG
  SEC
  RTS
.bn_ok:
  JSR CURPOS
  LDA P0
  STA BP
  LDA P0+1
  STA BP+1
  LDA BB
  STA Q
  LDA BB+1
  STA Q+1
  JSR RD_SET             ; the block is on one side of the gap: contiguous
  LDA BN
  STA CNT
  LDA BN+1
  STA CNT+1
.bn_l:
  LDA CNT
  ORA CNT+1
  BEQ .bn_x
  LDA (RP)
  JSR INSRAW
  INC RP
  BNE .bn_d
  INC RP+1
.bn_d:
  LDA CNT
  BNE .bn_dd
  DEC CNT+1
.bn_dd:
  DEC CNT
  LDA CNT
  AND #$07
  BNE .bn_l
  JSR KB_POLL
  BRA .bn_l
.bn_x:
  CLC
  RTS

; SETBLK: BB = BP + A (0 or -BN, see callers), BK = BB + BN
SETBLK_COPY:
  LDA BP
  STA BB
  LDA BP+1
  STA BB+1
SETBLK_END:
  CLC
  LDA BB
  ADC BN
  STA BK
  LDA BB+1
  ADC BN+1
  STA BK+1
  LDA #3
  STA BFLAG
  LDA #1
  STA DIRTY
  RTS

CMD_BCOPY:
  JSR BCHECK2
  BCS .bcp_x
  JSR BCOPYN
  BCS .bcp_x
  JMP SETBLK_COPY
.bcp_x:
  RTS

CMD_BMOVE:
  JSR BCHECK2
  BCS .bmv_x
  LDA BB
  STA BO
  LDA BB+1
  STA BO+1
  JSR CURPOS             ; T3 = 1 if the block is before the cursor
  STZ T3
  LDA P0
  CMP BB
  LDA P0+1
  SBC BB+1
  BCC .bmv_a
  INC T3
.bmv_a:
  JSR BCOPYN
  BCS .bmv_x
  LDA T3
  BEQ .bmv_after
  ; block before: delete [BO, BO+BN), the copy moves back by BN
  CLC
  LDA BO
  ADC BN
  STA TARGET
  LDA BO+1
  ADC BN+1
  STA TARGET+1
  JSR MOVETO
  JSR BSN
  SEC
  LDA BP
  SBC BN
  STA BB
  LDA BP+1
  SBC BN+1
  STA BB+1
  BRA .bmv_end
.bmv_after:
  ; block after: it is now at BO+BN; delete it there
  CLC
  LDA BO
  ADC BN
  STA TARGET
  LDA BO+1
  ADC BN+1
  STA TARGET+1
  JSR MOVETO
  JSR DELRN
  LDA BP
  STA BB
  LDA BP+1
  STA BB+1
.bmv_end:
  JSR SETBLK_END
  LDA BK                 ; cursor after the moved block
  STA TARGET
  LDA BK+1
  STA TARGET+1
  JMP MOVETO
.bmv_x:
  RTS

CMD_BDEL:
  JSR BCHECK
  BCS .bd_x
  LDA BK
  STA TARGET
  LDA BK+1
  STA TARGET+1
  JSR MOVETO
  JSR BSN
  STZ BFLAG
.bd_x:
  RTS

; BSN / DELRN: BN characters before / at the cursor (no mark changes)
BSN:
  LDA BN
  STA CNT
  LDA BN+1
  STA CNT+1
.bsn_l:
  LDA CNT
  ORA CNT+1
  BEQ .bsn_x
  JSR BSRAW
  JSR DECCNT
  BRA .bsn_l
.bsn_x:
  RTS
DELRN:
  LDA BN
  STA CNT
  LDA BN+1
  STA CNT+1
.drn_l:
  LDA CNT
  ORA CNT+1
  BEQ .drn_x
  JSR DELRAW
  JSR DECCNT
  BRA .drn_l
.drn_x:
  RTS
DECCNT:
  LDA CNT
  BNE .dc_d
  DEC CNT+1
.dc_d:
  DEC CNT
  AND #$07
  BNE .dc_x
  JSR KB_POLL
.dc_x:
  RTS

CMD_GOBB:
  LDA BFLAG
  AND #1
  BEQ .gb_x
  LDA BB
  STA TARGET
  LDA BB+1
  STA TARGET+1
  JMP MOVETO
.gb_x:
  RTS
CMD_GOBK:
  LDA BFLAG
  AND #2
  BEQ .gk_x
  LDA BK
  STA TARGET
  LDA BK+1
  STA TARGET+1
  JMP MOVETO
.gk_x:
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; find and replace

; SEARCH: FINDBUF from the cursor on (letters in any case). C=0 and P2 = match
SEARCH:
  JSR KB_POLL
  JSR CURPOS
  LDA P0
  STA Q
  STA P2
  LDA P0+1
  STA Q+1
  STA P2+1
  JSR RD_SET
.se_s:
  JSR RD_GET
  BCS .se_nf
  JSR UI_UPC
  CMP FINDBUF
  BEQ .se_c
.se_n:
  INC P2
  BNE .se_p
  INC P2+1
.se_p:
  LDA P2
  AND #$07
  BNE .se_s
  JSR KB_POLL
  BRA .se_s
.se_c:
  LDA RP                 ; candidate: compare the rest
  STA VX
  LDA RP+1
  STA VX+1
  LDX #1
.se_cl:
  CPX FLEN
  BEQ .se_f
  JSR RD_GET
  BCS .se_nf
  JSR UI_UPC
  CMP FINDBUF,X
  BNE .se_b
  INX
  BRA .se_cl
.se_b:
  LDA VX
  STA RP
  LDA VX+1
  STA RP+1
  BRA .se_n
.se_f:
  CLC
  RTS
.se_nf:
  SEC
  RTS

; ASKFIND: asks the find string. C=1 cancelled or empty
ASKFIND:
  LDX #0
.af_c:
  LDA FINDBUF,X
  STA UI_BUF,X
  INX
  CPX #FINDMAX+1
  BNE .af_c
  LDX FLEN
  STZ UI_BUF,X
  LDA #FINDMAX
  STA UI_PMAX
  STZ UI_PUPC
  LDA #<P_FIND
  LDX #>P_FIND
  JSR PROMPT
  BCS .af_x
  CMP #0
  BEQ .af_no
  STA FLEN
  LDX #0
.af_u:
  LDA UI_BUF,X
  JSR UI_UPC
  STA FINDBUF,X
  INX
  CPX FLEN
  BNE .af_u
  CLC
  RTS
.af_no:
  SEC
.af_x:
  RTS

CMD_FIND:
  JSR ASKFIND
  BCS .fd_x
  JMP CMD_FINDAG
.fd_x:
  RTS

CMD_FINDAG:
  LDA FLEN
  BEQ .fa_x
  JSR SEARCH
  BCS .fa_nf
  CLC                    ; the cursor goes after the match
  LDA P2
  ADC FLEN
  STA TARGET
  LDA P2+1
  ADC #0
  STA TARGET+1
  JMP MOVETO
.fa_nf:
  LDA #<M_NF
  LDX #>M_NF
  JSR SETMSG
.fa_x:
  RTS

CMD_REPLACE:
  JSR ASKFIND
  BCC .rp_go
  RTS
.rp_go:
  STZ UI_BUF
  LDA #FINDMAX
  STA UI_PMAX
  LDA #<P_REPL
  LDX #>P_REPL
  JSR PROMPT
  BCC .rp_ok
  RTS
.rp_ok:
  STA RLEN
  TAX
.rp_c:
  LDA UI_BUF,X
  STA REPLBUF,X
  DEX
  BPL .rp_c
  STZ RCNT
  STZ RCNT+1
.rp_l:
  JSR SEARCH
  BCS .rp_d
  CLC
  LDA P2
  ADC FLEN
  STA TARGET
  LDA P2+1
  ADC #0
  STA TARGET+1
  JSR MOVETO
  LDX FLEN
.rp_del:
  PHX
  JSR CMD_BKSP
  PLX
  DEX
  BNE .rp_del
  LDX #0
.rp_ins:
  CPX RLEN
  BEQ .rp_n
  LDA REPLBUF,X
  PHX
  JSR INSCH
  PLX
  BCS .rp_d
  INX
  BRA .rp_ins
.rp_n:
  INC RCNT
  BNE .rp_l
  INC RCNT+1
  BRA .rp_l
.rp_d:
  LDX #M_REPL_L-1        ; message "REPLACED: n"
.rp_m:
  LDA M_REPL,X
  STA MSGBUF,X
  DEX
  BPL .rp_m
  LDA #<MSGBUF
  STA VT_P
  LDA #>MSGBUF
  STA VT_P+1
  LDA RCNT
  STA NUM
  LDA RCNT+1
  STA NUM+1
  LDY #M_REPL_L
  JSR NUMSTR
  LDA #0
  STA (VT_P),Y
  LDA #<MSGBUF
  LDX #>MSGBUF
  JMP SETMSG
.rp_x:
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; documents

; CHKMOD: if the text was changed asks to abandon it. C=1 keep it
CHKMOD:
  LDA MODF
  BEQ .ck_x
  LDA #<Q_ABANDON
  LDX #>Q_ABANDON
  JMP YESNO
.ck_x:
  CLC
  RTS



; DOCNEW: empty text without a name
DOCNEW:
  LDA #<BUF
  STA GS
  LDA #>BUF
  STA GS+1
  LDA #<BUF_END
  STA GE
  LDA #>BUF_END
  STA GE+1
  STZ TOP
  STZ TOP+1
  STZ LINE
  STZ LINE+1
  STZ BFLAG
  STZ MODF
  STZ DOCSLOT
  LDX #NAMELEN
.dn_z:
  STZ DOCNAME,X
  DEX
  BPL .dn_z
  LDA #1
  STA DIRTY
  RTS

CMD_NEW:
  JSR CHKMOD
  BCS .nw_x
  JSR DOCNEW
.nw_x:
  RTS

CMD_SAVE:
  LDA DOCNAME
  BNE DOSAVE
CMD_SAVEAS:
  LDX #NAMELEN
.sa_c:
  LDA DOCNAME,X
  STA UI_BUF,X
  DEX
  BPL .sa_c
  LDA #NAMELEN
  STA UI_PMAX
  LDA #1
  STA UI_PUPC
  LDA #<P_SAVE
  LDX #>P_SAVE
  JSR PROMPT
  BCS .sa_x
  CMP #0
  BEQ .sa_no
  LDX #0                 ; the name, $00 padded
.sa_n:
  LDA UI_BUF,X
  STA DOCNAME,X
  BEQ .sa_z
  INX
  CPX #NAMELEN
  BNE .sa_n
  BRA DOSAVE
.sa_z:
  STZ DOCNAME,X
  INX
  CPX #NAMELEN+1
  BNE .sa_z
  BRA DOSAVE
.sa_no:
  SEC
.sa_x:
  RTS

; DOSAVE: writes the text in the slot with the same name (or a free one). C=1 error
DOSAVE:
  LDA #1                 ; type 1 = text
  STA DOC_T
  JSR DOC_RDIDX
  BCC .ds_rd
  JMP .ds_err
.ds_rd:
  LDA #<DOCNAME
  STA DOC_P
  LDA #>DOCNAME
  STA DOC_P+1
  JSR DOC_FIND
  BCC .ds_k
  JSR DOC_FREE
  BCC .ds_k
  LDA #<M_NOSLOT
  LDX #>M_NOSLOT
  JSR SETMSG
  SEC
  RTS
.ds_k:
  STA DOCSLOT
  JSR CURPOS             ; the text in one piece: gap at the end
  LDA P0
  STA SAVECUR
  LDA P0+1
  STA SAVECUR+1
  JSR TXTLEN
  LDA P1
  STA TARGET
  STA BN
  LDA P1+1
  STA TARGET+1
  STA BN+1
  JSR MOVETO
  LDA DOCSLOT
  STA DOC_K
  LDX BN
  LDY BN+1
  LDA #>BUF
  SEC
  JSR DOC_XFER
  BCS .ds_back
  LDA BN
  STA DOC_LEN
  LDA BN+1
  STA DOC_LEN+1
  LDA DOCSLOT
  JSR DOC_SETENT         ; (DOC_P still points to DOCNAME)
  JSR DOC_WRIDX
.ds_back:
  PHP
  LDA SAVECUR
  STA TARGET
  LDA SAVECUR+1
  STA TARGET+1
  JSR MOVETO
  PLP
  BCS .ds_err
  STZ MODF
  LDA #<M_SAVED
  LDX #>M_SAVED
  JSR SETMSG
  CLC
  RTS
.ds_err:
  LDA #<M_SDERR
  LDX #>M_SDERR
  JSR SETMSG
  SEC
  RTS

CMD_SAVEX:
  LDA MODF
  BEQ EXIT
  JSR CMD_SAVE
  BCC EXIT
  RTS

CMD_QUIT:
  JSR CHKMOD
  BCC EXIT
  RTS

EXIT:
  JSR KB_EXIT
  JMP JT_SHOW_MENU

; CMD_OPEN: the list of the documents (lib/ui), then the text chosen (a sheet opens as text)
CMD_OPEN:
  LDA #1
  STA DIRTY
  STA UI_ANY
  LDA #<M_OPEN
  LDX #>M_OPEN
  JSR DOC_PICK
  BCC .op_go
  CMP #0
  BEQ .op_x
.op_err:
  LDA #<M_SDERR
  LDX #>M_SDERR
  JMP SETMSG
.op_x:
  RTS
.op_go:
  STA DOCSLOT
  JSR CHKMOD
  BCS .op_x
  ; load: the text at BUF, the gap after it, then the cursor to the start
  LDA DOCSLOT
  PHA
  JSR DOCNEW
  PLA
  STA DOCSLOT
  JSR DOC_ENTRY
  LDY #1
  LDA (DOC_E),Y
  STA BN
  INY
  LDA (DOC_E),Y
  STA BN+1
  LDY #4
  LDX #0
.op_nm:
  LDA (DOC_E),Y
  STA DOCNAME,X
  INY
  INX
  CPX #NAMELEN
  BNE .op_nm
  LDA BN+1               ; never more than the buffer
  CMP #>(BUF_END-BUF)
  BCC .op_l
  LDA #>(BUF_END-BUF)
  STA BN+1
  STZ BN
.op_l:
  LDA DOCSLOT
  STA DOC_K
  LDX BN
  LDY BN+1
  LDA #>BUF
  CLC
  JSR DOC_XFER
  BCC .op_ok
  JSR DOCNEW
  BRA .op_err
.op_ok:
  CLC
  LDA #<BUF
  ADC BN
  STA GS
  LDA #>BUF
  ADC BN+1
  STA GS+1
  JSR RECOUNT
  JSR CMD_TOP
  STZ MODF
  LDA #<M_LOADED
  LDX #>M_LOADED
  JMP SETMSG

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; help

CMD_HELP:
  JSR VT_CLS
  LDA #<HELPTXT
  STA P2
  LDA #>HELPTXT
  STA P2+1
  STZ ROWI
.hp_r:
  LDA (P2)
  CMP #$FF
  BEQ .hp_k
  LDA ROWI
  JSR VT_ROW
  LDA ROWI
  CMP #1
  BCS .hp_n
  LDA #$80               ; title in inverse
  BRA .hp_i
.hp_n:
  LDA #0
.hp_i:
  STA VT_INV
  LDA P2
  LDX P2+1
  LDY #0
  JSR VT_LINE
  LDY #0                 ; next string
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
  INC ROWI
  BRA .hp_r
.hp_k:
  STZ VT_INV
  JSR WAITKEY
  LDA #1
  STA DIRTY
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; command tables

CTRLTAB:
  .word NOP_CMD, CMD_WORDL, NOP_CMD, CMD_PGDN          ; ^@ ^A ^B ^C
  .word CMD_RIGHT, CMD_UP, CMD_WORDR, CMD_DEL          ; ^D ^E ^F ^G
  .word CMD_BKSP, CMD_TAB, CMD_HELP, CMD_PFXK          ; ^H ^I ^J ^K
  .word CMD_FINDAG, CMD_ENTER, CMD_SPLIT, NOP_CMD      ; ^L ^M ^N ^O
  .word NOP_CMD, CMD_PFXQ, CMD_PGUP, CMD_LEFT          ; ^P ^Q ^R ^S
  .word CMD_DELWORD, NOP_CMD, CMD_INS, NOP_CMD         ; ^T ^U ^V ^W
  .word CMD_DOWN, CMD_DELLINE, NOP_CMD, NOP_CMD        ; ^X ^Y ^Z Esc
  .word NOP_CMD, NOP_CMD, NOP_CMD, NOP_CMD
EXTTAB:
  .word CMD_UP, CMD_DOWN, CMD_LEFT, CMD_RIGHT          ; $80-$83 arrows
  .word CMD_HOME, CMD_END, CMD_PGUP, CMD_PGDN          ; $84-$87
  .word CMD_INS, CMD_DEL, NOP_CMD, NOP_CMD             ; $88-$8B
  .word NOP_CMD, NOP_CMD, NOP_CMD, NOP_CMD             ; $8C-$8F
  .word CMD_HELP, CMD_SAVE, CMD_OPEN, CMD_FIND         ; F1-F4
  .word CMD_FINDAG, CMD_MARKB, CMD_MARKK, CMD_BCOPY    ; F5-F8
  .word CMD_BMOVE, CMD_QUIT, NOP_CMD, NOP_CMD          ; F9-F12
KTAB:
  .byte 'B'
  .word CMD_MARKB
  .byte 'K'
  .word CMD_MARKK
  .byte 'H'
  .word CMD_BHIDE
  .byte 'C'
  .word CMD_BCOPY
  .byte 'V'
  .word CMD_BMOVE
  .byte 'Y'
  .word CMD_BDEL
  .byte 'S'
  .word CMD_SAVE
  .byte 'A'
  .word CMD_SAVEAS
  .byte 'X'
  .word CMD_SAVEX
  .byte 'D'
  .word CMD_SAVEX
  .byte 'Q'
  .word CMD_QUIT
  .byte 'O'
  .word CMD_OPEN
  .byte 'N'
  .word CMD_NEW
  .byte 0
QTAB:
  .byte 'F'
  .word CMD_FIND
  .byte 'A'
  .word CMD_REPLACE
  .byte 'R'
  .word CMD_TOP
  .byte 'C'
  .word CMD_BOTTOM
  .byte 'S'
  .word CMD_HOME
  .byte 'D'
  .word CMD_END
  .byte 'B'
  .word CMD_GOBB
  .byte 'K'
  .word CMD_GOBK
  .byte 'Y'
  .word CMD_DELEOL
  .byte 0

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; texts

M_HELLO:    .byte "MINIVIC WRITE 1.0  -  ^J OR F1 = HELP",0
M_HINT:     .byte "^J HELP  ^KS SAVE  ^KO OPEN  ^KX EXIT",0
M_HK:       .byte "^K BLOCK B K H C V Y  FILE S A X Q O N",0
M_HQ:       .byte "^Q F FIND A REPLACE R C TEXT S D LINE",0
M_FULL:     .byte "MEMORY FULL",0
M_NOBLK:    .byte "NO BLOCK MARKED (^KB AND ^KK)",0
M_INBLK:    .byte "THE CURSOR IS INSIDE THE BLOCK",0
M_NF:       .byte "NOT FOUND",0
M_SDERR:    .byte "SD CARD ERROR",0
M_SAVED:    .byte "SAVED",0
M_LOADED:   .byte "LOADED",0
M_NOSLOT:   .byte "NO FREE PLACE: DELETE A DOCUMENT FIRST",0
M_REPL:     .byte "REPLACED:"
M_REPL_L    = 9
M_NONAME:   .byte "NO NAME"
M_INS:      .byte "INS"
M_OVR:      .byte "OVR"
M_OPEN:     .byte " OPEN DOCUMENT",0
P_FIND:     .byte "FIND: ",0
P_REPL:     .byte "REPLACE WITH: ",0
P_SAVE:     .byte "SAVE AS: ",0
Q_ABANDON:  .byte "ABANDON THE CHANGES (Y/N)?",0

HELPTXT:
  .byte " MINIVIC WRITE  -  COMMANDS",0
  .byte "",0
  .byte "CURSOR ^E ^X ^S ^D OR THE ARROWS",0
  .byte "       ^A ^F WORD    HOME END  ^QS ^QD",0
  .byte "       ^R ^C PAGE    ^QR ^QC TEXT",0
  .byte "DELETE ^G DEL CHAR   ^H BACKSPACE",0
  .byte "       ^T WORD  ^Y LINE  ^QY LINE END",0
  .byte "EDIT   ^N SPLIT LINE  ^V INS OVERWRITE",0
  .byte "BLOCK  ^KB BEGIN F6  ^KK END F7",0
  .byte "       ^KC COPY F8   ^KV MOVE F9",0
  .byte "       ^KY DELETE    ^KH HIDE",0
  .byte "       ^QB ^QK GO TO BEGIN / END",0
  .byte "FIND   ^QF FIND F4   ^L AGAIN F5",0
  .byte "       ^QA REPLACE ALL",0
  .byte "FILE   ^KS SAVE F2   ^KA SAVE AS",0
  .byte "       ^KO OPEN F3   ^KN NEW",0
  .byte "       ^KX SAVE AND EXIT",0
  .byte "       ^KQ EXIT WITHOUT SAVING F10",0
  .byte "",0
  .byte "UP TO 15 DOCUMENTS ON THE SD CARD",0
  .byte "",0
  .byte "PRESS ANY KEY",0
  .byte $FF

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; libraries

 .include "lib/keys.asm"
 .include "lib/vtext.asm"
 .include "lib/num.asm"
 .include "lib/docs.asm"
 .include "lib/ui.asm"

CODE_END:
 .if CODE_END > BUF
 .error "code past $3000"
 .endif
