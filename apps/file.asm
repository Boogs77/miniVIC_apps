;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                                              ;
;   FILE  -  miniVIC FILE, card file (PFS:File style)          ;
;   65C02 assembly, TMS9918A text mode 40 x 24                 ;
;   Needs the BIOS 27.10.26 KEYB/SD                            ;
;                                                              ;
;   - a form of up to 8 fields (name 10 chars, width 1-28);    ;
;     at the start an address book form, ^KN designs another   ;
;   - one card on the screen: arrows / Tab change field,       ;
;     typing overwrites, PgUp PgDn change card, F3 new card,   ;
;     F8 deletes it; F2 the list (one card per row)            ;
;   - F4 find (any field, any case), F5 find again, F6 sort    ;
;     by the field under the cursor (Shell sort of the order   ;
;     table, the cards themselves do not move)                 ;
;   - ^KS save, ^KA save as, ^KO open, ^KN new file, ^KX save  ;
;     and exit, ^KQ quit: SD document of type 3                ;
;                                                              ;
;   MEMORY                                                     ;
;   $0050-$009F  zero page (lib $A0-$EB)                       ;
;   $0210-$029F  form: names, widths, offsets; name; find      ;
;   $0600-$07FF  SD document index                             ;
;   $0800-$09FF  sector buffer (lib/stream)                    ;
;   $1000-...    code                                          ;
;   $3000-$30FF  order of the cards (slot numbers)             ;
;   $3100-$7FFF  cards: slot * record size (20224 bytes)       ;
;                                                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

 .include "lib/system.inc"

; ---------------- parameters ----------------
MAXF        = 8        ; fields
NAMEW       = 10       ; field name
MAXW        = 28       ; field width
ORDER       = $3000
DATA        = $3100
DATA_END    = $8000
MAXSLOTS    = 250
NAMELEN     = 12
FINDMAX     = 20
LROWS       = 20       ; list rows (screen rows 2-21)

; ---------------- zero page ----------------
NF          = $50      ; fields
RS          = $51      ; record size
NREC        = $52      ; cards
CUR         = $53      ; card shown (position in ORDER)
FLD         = $54      ; field under the cursor
FPOS        = $55      ; cursor in the field
MODF        = $56
MAXREC      = $57
MSGP        = $58      ; 2 bytes
PREFIX      = $5A
RP          = $5B      ; 2 bytes: card
T0          = $5D
T1          = $5E
T2          = $5F
T3          = $60
P0          = $61      ; 2 bytes
P1          = $63      ; 2 bytes
FLEN        = $65
DOCSLOT     = $66
ROWI        = $67
LTOP        = $68      ; list: first row, selected card
LSEL        = $69
GAP         = $6A      ; sort
SI          = $6B
SJ          = $6C
STMP        = $6D
GI          = $6E
SFLD        = $6F
COLS        = $70      ; list: columns left in the row
SPT         = $71      ; SLOTPTR

; ---------------- RAM ----------------
FNAME       = $0210    ; 8 x 10: field names
FWID        = $0260    ; 8 widths
FOFF        = $0268    ; 8 offsets in the card
DOCNAME     = $0270    ; 12 + $00
FINDBUF     = $0280    ; find string (upper case, 20 + $00)
FORMBAK     = $0900    ; copy of the form while a new one is typed (in the sector buffer)

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
  LDA #3                 ; type 3 = card file
  STA DOC_T
  STZ FLEN
  STZ PREFIX
  LDX #DEFFORM_L-1       ; the address book form
.rs_f:
  LDA DEFFORM,X
  STA FNAME,X
  DEX
  BPL .rs_f
  LDA #DEFNF
  STA NF
  JSR FORMSET
  JSR FILENEW
  LDA #<M_HELLO
  LDX #>M_HELLO
  JSR SETMSG
MAIN:
  JSR DRAWCARD
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
  LDX PREFIX
  BEQ .dk_n
  STZ PREFIX
  JSR UI_UPC
  CMP #$1B               ; (Ctrl+letter as the letter)
  BCS .dk_kl
  ORA #$40
.dk_kl:
  LDX #0
.dk_kt:
  LDY KTAB,X
  BEQ .dk_x
  CMP KTAB,X
  BEQ .dk_kg
  INX
  INX
  INX
  BRA .dk_kt
.dk_kg:
  LDA KTAB+1,X
  STA P0
  LDA KTAB+2,X
  STA P0+1
  JMP (P0)
.dk_n:
  CMP #' '
  BCC .dk_c
  CMP #$7F
  BCS .dk_e
  JMP TYPECH
.dk_c:
  ASL
  TAX
  JMP (CTRLTAB,X)
.dk_e:
  CMP #K_UP
  BCC .dk_x
  CMP #K_F1+12
  BCS .dk_x
  SEC
  SBC #K_UP
  ASL
  TAX
  JMP (EXTTAB,X)
.dk_x:
  RTS

NOP_CMD:
  RTS

CMD_PFXK:
  LDA #'K'
  STA PREFIX
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; form and cards

; FORMSET: offsets, record size, how many cards fit
FORMSET:
  LDX #0
  LDA #0
.fs_l:
  STA FOFF,X
  CLC
  ADC FWID,X
  INX
  CPX NF
  BNE .fs_l
  STA RS
  LDA #<(DATA_END-DATA)  ; MAXREC = space / RS (250 at most)
  STA P0
  LDA #>(DATA_END-DATA)
  STA P0+1
  LDX #0
.fs_m:
  SEC
  LDA P0
  SBC RS
  STA P0
  LDA P0+1
  SBC #0
  STA P0+1
  BCC .fs_x
  INX
  CPX #MAXSLOTS
  BNE .fs_m
.fs_x:
  STX MAXREC
  RTS

; FILENEW: no cards but one blank, no name
FILENEW:
  STZ NREC
  STZ CUR
  STZ FLD
  STZ FPOS
  STZ DOCSLOT
  LDX #NAMELEN
.fn_n:
  STZ DOCNAME,X
  DEX
  BPL .fn_n
  JSR ADDREC
  STZ MODF
  RTS

; SLOTPTR: RP = DATA + A * RS
SLOTPTR:
  STA SPT
  STZ RP
  STZ RP+1
  LDX #8
.sp_l:
  ASL RP
  ROL RP+1
  ASL SPT
  BCC .sp_n
  CLC
  LDA RP
  ADC RS
  STA RP
  BCC .sp_n
  INC RP+1
.sp_n:
  DEX
  BNE .sp_l
  CLC
  LDA RP
  ADC #<DATA
  STA RP
  LDA RP+1
  ADC #>DATA
  STA RP+1
  RTS

; CURPTR: RP = card shown
CURPTR:
  LDX CUR
  LDA ORDER,X
  JMP SLOTPTR

; ADDREC: a blank card after the one shown (or the first). C=1 full
ADDREC:
  LDA NREC
  CMP MAXREC
  BCC .ar_ok
  LDA #<M_FULL
  LDX #>M_FULL
  JSR SETMSG
  SEC
  RTS
.ar_ok:
  LDA NREC               ; where it goes in the order
  BEQ .ar_p
  LDA CUR
  INC A
.ar_p:
  STA T1
  LDX NREC               ; move the order up from there
.ar_m:
  CPX T1
  BEQ .ar_s
  LDA ORDER-1,X
  STA ORDER,X
  DEX
  BRA .ar_m
.ar_s:
  LDA NREC               ; its slot is the first free one: NREC
  STA ORDER,X
  JSR SLOTPTR
  LDY RS
  LDA #' '
.ar_b:
  DEY
  STA (RP),Y
  BNE .ar_b
  INC NREC
  LDA T1
  STA CUR
  STZ FLD
  STZ FPOS
  LDA #1
  STA MODF
  CLC
  RTS

; DELREC: deletes the card shown; the last slot moves into its place
DELREC:
  LDX CUR
  LDA ORDER,X
  STA T2                 ; its slot
.dr_m:
  LDA ORDER+1,X          ; order down from CUR
  STA ORDER,X
  INX
  CPX NREC
  BCC .dr_m
  DEC NREC
  LDA T2
  CMP NREC
  BEQ .dr_d              ; it was the last slot
  LDA NREC               ; card of the last slot -> slot T2
  JSR SLOTPTR
  LDA RP
  STA P0
  LDA RP+1
  STA P0+1
  LDA T2
  JSR SLOTPTR
  LDY #0
.dr_c:
  LDA (P0),Y
  STA (RP),Y
  INY
  CPY RS
  BNE .dr_c
  LDX #0                 ; and the order points to its new slot
.dr_f:
  LDA ORDER,X
  CMP NREC
  BEQ .dr_o
  INX
  BRA .dr_f
.dr_o:
  LDA T2
  STA ORDER,X
.dr_d:
  LDA #1
  STA MODF
  LDA NREC
  BNE .dr_c2
  JSR ADDREC             ; never without a card
  RTS
.dr_c2:
  LDA CUR
  CMP NREC
  BCC .dr_x
  LDA NREC
  DEC A
  STA CUR
.dr_x:
  STZ FPOS
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; card screen

; DRAWCARD: status, the fields of the card, the hint
DRAWCARD:
  JSR STATUS
  LDA #1
  JSR VT_ROW
  LDA #' '
  LDX #40
  JSR VT_REP
  JSR CURPTR
  STZ ROWI
.dc_r:
  LDA ROWI               ; screen rows 2, 4, 6 ...: field ROWI
  ASL
  CLC
  ADC #2
  JSR VT_ROW
  LDA ROWI
  CMP NF
  BCC .dc_f
  LDA #' '               ; no field: two blank rows
  LDX #80
  JSR VT_REP
  BRA .dc_n
.dc_f:
  JSR FNAMEP             ; name (10) and ": "
  LDY #0
.dc_nm:
  LDA (P0),Y
  STA VDP_DATA
  INY
  CPY #NAMEW
  BNE .dc_nm
  LDA #':'
  STA VDP_DATA
  LDA #' '
  STA VDP_DATA
  LDX ROWI
  LDA FOFF,X
  TAY
  LDA FWID,X
  STA T1
  STZ T0                 ; character of the field
.dc_v:
  LDA (RP),Y
  LDX ROWI
  CPX FLD
  BNE .dc_o
  ORA #$80               ; field under the cursor: inverse,
  LDX T0
  CPX FPOS
  BNE .dc_o
  EOR #$80               ; the cursor itself normal
.dc_o:
  STA VDP_DATA
  INY
  INC T0
  LDA T0
  CMP T1
  BNE .dc_v
  LDA #40-NAMEW-2        ; rest of the row and the blank row
  SEC
  SBC T1
  CLC
  ADC #40
  TAX
  LDA #' '
  JSR VT_REP
.dc_n:
  INC ROWI
  LDA ROWI
  CMP #MAXF
  BNE .dc_r
  LDA #18
  JSR VT_ROW
  LDA #' '
  LDX #120
  JSR VT_REP
  LDA #21
  JSR VT_ROW
  STZ VT_INV
  LDA #<M_KEYS
  LDX #>M_KEYS
  LDY #0
  JSR VT_LINE
  LDA #22
  JSR VT_ROW
  LDA #<M_KEYS2
  LDX #>M_KEYS2
  LDY #0
  JMP VT_LINE

; FNAMEP: P0 = name of field ROWI
FNAMEP:
  LDA ROWI
  ASL                    ; * 10 = * 8 + * 2
  STA T0
  ASL
  ASL
  CLC
  ADC T0
  CLC
  ADC #<FNAME
  STA P0
  LDA #>FNAME
  ADC #0
  STA P0+1
  RTS

; STATUS: row 0: file name, *, card n / cards, cards that still fit
STATUS:
  LDX #39
  LDA #' '
.st_b:
  STA UI_LINE,X
  DEX
  BPL .st_b
  LDX #0
.st_n:
  LDA DOCNAME,X
  BEQ .st_nn
  STA UI_LINE+1,X
  INX
  CPX #NAMELEN
  BNE .st_n
.st_nn:
  CPX #0
  BNE .st_m
  LDX #6
.st_no:
  LDA M_NONAME,X
  STA UI_LINE+1,X
  DEX
  BPL .st_no
.st_m:
  LDA MODF
  BEQ .st_c
  LDA #'*'
  STA UI_LINE+13
.st_c:
  LDX #3
.st_cl:
  LDA M_CARD,X
  STA UI_LINE+15,X
  DEX
  BPL .st_cl
  LDA #<UI_LINE
  STA VT_P
  LDA #>UI_LINE
  STA VT_P+1
  LDA CUR                ; "CARD" 15-18, number 19-23, "/" 24, cards 25-29
  INC A
  STA NUM
  STZ NUM+1
  LDY #19
  JSR NUMSTR
  LDA #'/'
  STA UI_LINE+24
  LDA NREC
  STA NUM
  STZ NUM+1
  LDY #25
  JSR NUMSTR
  LDA PREFIX
  BEQ .st_f
  STA UI_LINE+31
  LDA #'^'
  STA UI_LINE+30
.st_f:
  SEC                    ; cards that still fit
  LDA MAXREC
  SBC NREC
  STA NUM
  STZ NUM+1
  LDY #32                ; (32-36; a prefix shows over its first digits)
  JSR NUMSTR
  LDA PREFIX
  BEQ .st_f2
  STA UI_LINE+31
  LDA #'^'
  STA UI_LINE+30
  LDA #' '
  STA UI_LINE+32
.st_f2:
  LDX #2
.st_fl:
  LDA M_FREE,X
  STA UI_LINE+37,X
  DEX
  BPL .st_fl
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

; MSGLINE: row 23: prefix hint, message or the default hint
MSGLINE:
  LDA #23
  JSR VT_ROW
  STZ VT_INV
  LDA PREFIX
  BEQ .ml_m
  LDA #<M_HK
  LDX #>M_HK
  BRA .ml_o
.ml_m:
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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; editing

; FLDPTR: P0 = field FLD of the card shown, T1 = its width
FLDPTR:
  JSR CURPTR
  LDX FLD
  CLC
  LDA RP
  ADC FOFF,X
  STA P0
  LDA RP+1
  ADC #0
  STA P0+1
  LDA FWID,X
  STA T1
  RTS

TYPECH:
  PHA
  JSR FLDPTR
  PLA
  LDY FPOS
  STA (P0),Y
  INY
  CPY T1
  BCS .tc_m
  STY FPOS
.tc_m:
  LDA #1
  STA MODF
  RTS

CMD_BKSP:
  LDA FPOS
  BEQ .bk_x
  DEC FPOS
  JMP CMD_DEL
.bk_x:
  RTS

CMD_DEL:
  JSR FLDPTR             ; the rest of the field moves left
  LDY FPOS
.de_l:
  INY
  CPY T1
  BCS .de_e
  LDA (P0),Y
  DEY
  STA (P0),Y
  INY
  BRA .de_l
.de_e:
  DEY
  LDA #' '
  STA (P0),Y
  LDA #1
  STA MODF
  RTS

CMD_LEFT:
  LDA FPOS
  BEQ .lf_x
  DEC FPOS
.lf_x:
  RTS

CMD_RIGHT:
  JSR FLDPTR
  LDA FPOS
  INC A
  CMP T1
  BCS .rt_x
  STA FPOS
.rt_x:
  RTS

CMD_HOME:
  STZ FPOS
  RTS

CMD_END:
  JSR FLDPTR             ; after the last character that is not a space
  LDY T1
.en_l:
  DEY
  BMI .en_z
  LDA (P0),Y
  CMP #' '
  BEQ .en_l
.en_z:
  INY
  CPY T1
  BCC .en_s
  LDY T1
  DEY
.en_s:
  STY FPOS
  RTS

CMD_UP:
  STZ FPOS
  LDA FLD
  BNE .up_d
  LDA NF
.up_d:
  DEC A
  STA FLD
  RTS

CMD_DOWN:
  STZ FPOS
  LDA FLD
  INC A
  CMP NF
  BCC .dn_s
  LDA #0
.dn_s:
  STA FLD
  RTS

CMD_PGUP:
  LDA CUR
  BEQ .pu_x
  DEC CUR
  STZ FPOS
.pu_x:
  RTS

CMD_PGDN:
  LDA CUR
  INC A
  CMP NREC
  BCS .pd_x
  STA CUR
  STZ FPOS
.pd_x:
  RTS

CMD_FIRST:
  STZ CUR
  STZ FPOS
  RTS

CMD_LAST:
  LDA NREC
  DEC A
  STA CUR
  STZ FPOS
  RTS

CMD_NEWREC:
  JMP ADDREC

CMD_DELREC:
  LDA #<Q_DELREC
  LDX #>Q_DELREC
  JSR YESNO
  BCS .dl_x
  JMP DELREC
.dl_x:
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; find and sort

CMD_FIND:
  LDX #FINDMAX           ; the last string is offered
.fd_c:
  LDA FINDBUF,X
  STA UI_BUF,X
  DEX
  BPL .fd_c
  LDX FLEN
  STZ UI_BUF,X
  LDA #FINDMAX
  STA UI_PMAX
  LDA #1
  STA UI_PUPC
  LDA #<P_FIND
  LDX #>P_FIND
  JSR PROMPT
  BCS .fd_x
  STA FLEN
  TAX
.fd_s:
  LDA UI_BUF,X
  STA FINDBUF,X
  DEX
  BPL .fd_s
  JMP CMD_FINDAG
.fd_x:
  RTS

; CMD_FINDAG: the next card (after the one shown, then from the first) holding FINDBUF
CMD_FINDAG:
  LDA FLEN
  BEQ .fa_x
  LDA CUR
  STA GI
.fa_l:
  INC GI                 ; next position, around the end
  LDA GI
  CMP NREC
  BCC .fa_t
  STZ GI
.fa_t:
  LDX GI
  LDA ORDER,X
  JSR SLOTPTR
  JSR MATCH
  BCC .fa_f
  JSR KB_POLL
  LDA GI
  CMP CUR
  BNE .fa_l
  LDA #<M_NF             ; back to the card shown: not elsewhere
  LDX #>M_NF
  JMP SETMSG
.fa_f:
  LDA GI
  STA CUR
  STZ FPOS
.fa_x:
  RTS

; MATCH: C=0 if the card at RP holds FINDBUF (any case)
MATCH:
  LDA RS
  SEC
  SBC FLEN
  BCC .mt_n
  STA T2                 ; last start position
  STZ T3
.mt_s:
  LDY T3
  LDX #0
.mt_c:
  LDA (RP),Y
  JSR UI_UPC
  CMP FINDBUF,X
  BNE .mt_nx
  INY
  INX
  CPX FLEN
  BNE .mt_c
  CLC
  RTS
.mt_nx:
  LDA T3
  CMP T2
  INC T3
  BCC .mt_s
.mt_n:
  SEC
  RTS

; CMD_SORT: cards in the order of the field under the cursor (Shell sort of ORDER)
CMD_SORT:
  LDA FLD
  STA SFLD
  LDX #0
.so_g:
  LDA GAPS,X
  BEQ .so_x
  STA GAP
  PHX
  CMP NREC
  BCS .so_ng             ; gap too large for this file
  STA SI                 ; i = gap .. NREC-1
.so_i:
  LDX SI
  LDA ORDER,X
  STA STMP
  STX SJ
.so_j:
  LDA SJ                 ; j >= gap and ORDER[j-gap] > tmp ?
  SEC
  SBC GAP
  BCC .so_put
  TAX
  LDA ORDER,X
  STA T0
  LDA STMP
  STA T1
  PHX
  JSR CMPREC
  PLX
  BCC .so_put
  LDA ORDER,X            ; ORDER[j] = ORDER[j-gap], j -= gap
  LDY SJ
  STA ORDER,Y
  STX SJ
  BRA .so_j
.so_put:
  LDX SJ
  LDA STMP
  STA ORDER,X
  JSR KB_POLL
  INC SI
  LDA SI
  CMP NREC
  BCC .so_i
.so_ng:
  PLX
  INX
  BRA .so_g
.so_x:
  STZ CUR
  STZ FPOS
  LDA #1
  STA MODF
  LDA #<M_SORTED
  LDX #>M_SORTED
  JMP SETMSG

; CMPREC: field SFLD of slot T0 against slot T1: C=1 if T0 comes after T1 (any case)
CMPREC:
  LDA T1
  JSR SLOTPTR
  LDX SFLD
  CLC
  LDA RP
  ADC FOFF,X
  STA P1
  LDA RP+1
  ADC #0
  STA P1+1
  LDA T0
  JSR SLOTPTR
  LDX SFLD
  CLC
  LDA RP
  ADC FOFF,X
  STA P0
  LDA RP+1
  ADC #0
  STA P0+1
  LDA FWID,X
  STA T2
  LDY #0
.cr_l:
  LDA (P1),Y
  JSR UI_UPC
  STA T3
  LDA (P0),Y
  JSR UI_UPC
  CMP T3
  BNE .cr_d
  INY
  CPY T2
  BNE .cr_l
  CLC                    ; equal: not after
  RTS
.cr_d:
  RTS                    ; (C from the CMP: 1 = after)

GAPS:       .byte 121, 40, 13, 4, 1, 0

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; list

; CMD_LIST: one card per row; arrows / PgUp PgDn choose, Enter or Esc back to that card
CMD_LIST:
  LDA CUR
  STA LSEL
  STZ LTOP
.li_d:
  LDA LSEL               ; the selected row on the screen
  CMP LTOP
  BCS .li_b
  STA LTOP
.li_b:
  SEC
  SBC LTOP
  CMP #LROWS
  BCC .li_draw
  LDA LSEL
  SEC
  SBC #LROWS-1
  STA LTOP
.li_draw:
  JSR STATUS
  JSR LISTHEAD
  STZ ROWI
.li_r:
  JSR LISTROW
  INC ROWI
  LDA ROWI
  CMP #LROWS
  BNE .li_r
  LDA #22
  JSR VT_ROW
  STZ VT_INV
  LDA #<M_LISTK
  LDX #>M_LISTK
  LDY #0
  JSR VT_LINE
  LDA #23
  JSR VT_ROW
  LDA #' '
  LDX #40
  JSR VT_REP
.li_k:
  JSR WAITKEY
  CMP #K_UP
  BEQ .li_u
  CMP #'E'-$40
  BEQ .li_u
  CMP #K_DOWN
  BEQ .li_dn
  CMP #'X'-$40
  BEQ .li_dn
  CMP #K_PGUP
  BEQ .li_pu
  CMP #K_PGDN
  BEQ .li_pd
  CMP #K_CR
  BEQ .li_x
  CMP #K_ESC
  BEQ .li_x
  BRA .li_k
.li_u:
  LDA LSEL
  BEQ .li_k
  DEC LSEL
  BRA .li_d
.li_dn:
  LDA LSEL
  INC A
  CMP NREC
  BCS .li_k
  STA LSEL
  BRA .li_d
.li_pu:
  LDA LSEL
  SEC
  SBC #LROWS
  BCS .li_ps
  LDA #0
.li_ps:
  STA LSEL
  JMP .li_d
.li_pd:
  LDA LSEL
  CLC
  ADC #LROWS
  CMP NREC
  BCC .li_ps
  LDA NREC
  DEC A
  BRA .li_ps
.li_x:
  LDA LSEL
  STA CUR
  STZ FPOS
  RTS

; LISTHEAD: row 1: field names in their columns (inverse)
LISTHEAD:
  LDA #1
  JSR VT_ROW
  LDA #' '+$80
  STA VDP_DATA
  STA VDP_DATA
  STA VDP_DATA
  STA VDP_DATA
  LDA #36
  STA COLS
  STZ ROWI
.lh_f:
  LDA ROWI
  CMP NF
  BCS .lh_e
  LDX ROWI
  LDA FWID,X
  CMP COLS
  BCC .lh_w
  LDA COLS
.lh_w:
  STA T1                 ; characters of this column
  JSR FNAMEP
  LDY #0
.lh_c:
  CPY T1
  BCS .lh_n
  LDA #' '
  CPY #NAMEW
  BCS .lh_s
  LDA (P0),Y
.lh_s:
  ORA #$80
  STA VDP_DATA
  INY
  BRA .lh_c
.lh_n:
  SEC
  LDA COLS
  SBC T1
  STA COLS
  BEQ .lh_e
  LDA #' '+$80
  STA VDP_DATA
  DEC COLS
  BEQ .lh_e
  INC ROWI
  BRA .lh_f
.lh_e:
  LDX COLS
  LDA #' '+$80
  JMP VT_REP

; LISTROW: screen row ROWI+2 = card LTOP+ROWI
LISTROW:
  LDA ROWI
  CLC
  ADC #2
  JSR VT_ROW
  LDA ROWI
  CLC
  ADC LTOP
  STA GI
  CMP NREC
  BCC .lr_c
  LDA #' '
  LDX #40
  JMP VT_REP
.lr_c:
  STZ T3                 ; inverse for the selected card
  CMP LSEL
  BNE .lr_n
  LDA #$80
  STA T3
.lr_n:
  LDA GI                 ; number: 3 digits and a space
  INC A
  STA NUM
  STZ NUM+1
  LDA #<UI_LINE
  STA VT_P
  LDA #>UI_LINE
  STA VT_P+1
  LDY #0
  JSR NUMSTR             ; (5 characters, the last 3 are used)
  LDX #2
.lr_nm:
  LDA UI_LINE,X
  ORA T3
  STA VDP_DATA
  INX
  CPX #5
  BNE .lr_nm
  LDA #' '
  ORA T3
  STA VDP_DATA
  LDX GI
  LDA ORDER,X
  JSR SLOTPTR
  LDA #36
  STA COLS
  STZ GAP                ; (field counter)
.lr_f:
  LDA GAP
  CMP NF
  BCS .lr_e
  TAX
  LDA FWID,X
  CMP COLS
  BCC .lr_w
  LDA COLS
.lr_w:
  STA T1
  LDA FOFF,X
  TAY
  LDX #0
.lr_v:
  CPX T1
  BCS .lr_vn
  LDA (RP),Y
  ORA T3
  STA VDP_DATA
  INY
  INX
  BRA .lr_v
.lr_vn:
  SEC
  LDA COLS
  SBC T1
  STA COLS
  BEQ .lr_e
  LDA #' '
  ORA T3
  STA VDP_DATA
  DEC COLS
  BEQ .lr_e
  INC GAP
  BRA .lr_f
.lr_e:
  LDX COLS
  LDA #' '
  ORA T3
  JSR VT_REP
  JMP KB_POLL

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; files

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
  LDX #0
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

; DOSAVE: "BOFL", 1, NF, NF x (name, width), NREC, the cards in their order. C=1 error
DOSAVE:
  JSR DOC_RDIDX
  BCC .fb4
  JMP .ds_err
.fb4:
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
  STA DOC_K
  JSR ST_WOPEN
  LDX #0
.ds_h:
  LDA F_MAGIC,X
  JSR ST_PUT
  INX
  CPX #5
  BNE .ds_h
  LDA NF
  JSR ST_PUT
  STZ ROWI
.ds_f:
  JSR FNAMEP
  LDY #0
.ds_fn:
  LDA (P0),Y
  JSR ST_PUT
  INY
  CPY #NAMEW
  BNE .ds_fn
  LDX ROWI
  LDA FWID,X
  JSR ST_PUT
  INC ROWI
  LDA ROWI
  CMP NF
  BNE .ds_f
  LDA NREC
  JSR ST_PUT
  STZ GI
.ds_r:
  LDX GI
  LDA ORDER,X
  JSR SLOTPTR
  LDY #0
.ds_rb:
  LDA (RP),Y
  JSR ST_PUT
  INY
  CPY RS
  BNE .ds_rb
  INC GI
  LDA GI
  CMP NREC
  BNE .ds_r
  JSR ST_WCLOSE
  BCS .ds_err
  LDA DOCSLOT
  JSR DOC_SETENT
  JSR DOC_WRIDX
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

; CHKMOD: C=1 keep the file (changed and the answer was not Y)
CHKMOD:
  LDA MODF
  BEQ .ck_x
  LDA #<Q_ABANDON
  LDX #>Q_ABANDON
  JMP YESNO
.ck_x:
  CLC
  RTS

CMD_OPEN:
  STZ UI_ANY
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
  LDA DOCSLOT
  STA DOC_K
  JSR DOC_ENTRY
  LDY #1
  LDA (DOC_E),Y
  STA DOC_LEN
  INY
  LDA (DOC_E),Y
  STA DOC_LEN+1
  JSR ST_ROPEN
  LDX #0                 ; magic and version
.op_h:
  JSR ST_GET
  BCC .fb3
  JMP .op_bad
.fb3:
  CMP F_MAGIC,X
  BEQ .fb2
  JMP .op_bad
.fb2:
  INX
  CPX #5
  BNE .op_h
  JSR ST_GET
  BCC .fb1
  JMP .op_bad
.fb1:
  CMP #1
  BCS .fb8
  JMP .op_bad
.fb8:
  CMP #MAXF+1
  BCC .fb7
  JMP .op_bad
.fb7:
  STA NF
  LDX #0                 ; names and widths
.op_f:
  STX ROWI
  JSR FNAMEP
  LDY #0
.op_fn:
  JSR ST_GET
  BCS .op_bad
  STA (P0),Y
  INY
  CPY #NAMEW
  BNE .op_fn
  JSR ST_GET
  BCS .op_bad
  LDX ROWI
  STA FWID,X
  INX
  CPX NF
  BNE .op_f
  JSR FORMSET
  JSR ST_GET
  BCS .op_bad
  CMP MAXREC
  BCC .op_n
  LDA MAXREC
.op_n:
  STA NREC
  STZ GI
.op_r:
  LDA GI
  CMP NREC
  BEQ .op_ok
  LDX GI
  TXA
  STA ORDER,X
  JSR SLOTPTR
  LDY #0
.op_rb:
  JSR ST_GET
  BCS .op_bad
  STA (RP),Y
  INY
  CPY RS
  BNE .op_rb
  JSR KB_POLL
  INC GI
  BRA .op_r
.op_ok:
  LDX #0                 ; the name from the index
  LDA DOCSLOT
  JSR DOC_ENTRY
  LDY #4
.op_nm:
  LDA (DOC_E),Y
  STA DOCNAME,X
  INY
  INX
  CPX #NAMELEN
  BNE .op_nm
  STZ DOCNAME,X
  STZ CUR
  STZ FLD
  STZ FPOS
  STZ MODF
  LDA NREC
  BNE .op_l
  JSR ADDREC
  STZ MODF
.op_l:
  LDA #<M_LOADED
  LDX #>M_LOADED
  JMP SETMSG
.op_bad:
  JSR FORMDEF
  JSR FILENEW
  JMP .op_err

; FORMDEF: the address book form again
FORMDEF:
  LDX #DEFFORM_L-1
.fd_f:
  LDA DEFFORM,X
  STA FNAME,X
  DEX
  BPL .fd_f
  LDA #DEFNF
  STA NF
  JMP FORMSET

; CMD_NEWFILE: ^KN a new form: up to 8 fields, name and width each
CMD_NEWFILE:
  JSR CHKMOD
  BCC .fb6
  JMP .nf_x
.fb6:
  LDX #DEFFORM_L-1       ; a copy of the form, back if Esc
.nf_b:
  LDA FNAME,X
  STA FORMBAK,X
  DEX
  BPL .nf_b
  STZ ROWI
.nf_f:
  JSR FNAMEP             ; field name
  STZ UI_BUF
  LDA #NAMEW
  STA UI_PMAX
  LDA #1
  STA UI_PUPC
  LDA ROWI
  CLC
  ADC #'1'
  STA P_FNAME+6
  LDA #<P_FNAME
  LDX #>P_FNAME
  JSR PROMPT
  BCS .nf_esc            ; Esc: the old form stays
  CMP #0
  BEQ .nf_end
  LDY #0                 ; name, padded with spaces
.nf_n:
  LDA UI_BUF,Y
  BEQ .nf_pad
  STA (P0),Y
  INY
  CPY #NAMEW
  BNE .nf_n
  BRA .nf_w
.nf_pad:
  LDA #' '
.nf_pl:
  STA (P0),Y
  INY
  CPY #NAMEW
  BNE .nf_pl
.nf_w:
  STZ UI_BUF             ; width
  LDA #2
  STA UI_PMAX
  LDA #<P_FWIDTH
  LDX #>P_FWIDTH
  JSR PROMPT
  BCS .nf_esc
  JSR SMALLNUM
  BCS .nf_w
  CMP #1
  BCC .nf_w
  CMP #MAXW+1
  BCS .nf_w
  LDX ROWI
  STA FWID,X
  INC ROWI
  LDA ROWI
  CMP #MAXF
  BNE .nf_f
.nf_end:
  LDA ROWI
  BEQ .nf_esc            ; no field: nothing changes
  STA NF
  JSR FORMSET
  JMP FILENEW
.nf_esc:
  LDX #DEFFORM_L-1
.nf_r:
  LDA FORMBAK,X
  STA FNAME,X
  DEX
  BPL .nf_r
.nf_x:
  RTS

; SMALLNUM: UI_BUF (digits) -> A (0-99). C=1 not a number
SMALLNUM:
  LDA UI_BUF
  BEQ .sn_e
  LDX #0
  STZ T0
.sn_l:
  LDA UI_BUF,X
  BEQ .sn_x
  CMP #'0'
  BCC .sn_e
  CMP #'9'+1
  BCS .sn_e
  AND #$0F
  PHA
  LDA T0
  ASL
  ASL
  ADC T0
  ASL
  STA T0
  PLA
  ADC T0
  STA T0
  INX
  BRA .sn_l
.sn_x:
  LDA T0
  CLC
  RTS
.sn_e:
  SEC
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; help

CMD_HELP:
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
  JSR WAITKEY
  JMP VT_CLS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; tables and texts

CTRLTAB:
  .word NOP_CMD, CMD_HOME, NOP_CMD, CMD_PGDN           ; ^@ ^A ^B ^C
  .word CMD_RIGHT, CMD_UP, CMD_END, CMD_DEL            ; ^D ^E ^F ^G
  .word CMD_BKSP, CMD_DOWN, CMD_HELP, CMD_PFXK         ; ^H ^I ^J ^K
  .word CMD_FINDAG, CMD_DOWN, CMD_NEWREC, NOP_CMD      ; ^L ^M ^N ^O
  .word NOP_CMD, NOP_CMD, CMD_PGUP, CMD_LEFT           ; ^P ^Q ^R ^S
  .word CMD_FIRST, NOP_CMD, NOP_CMD, NOP_CMD           ; ^T ^U ^V ^W
  .word CMD_DOWN, CMD_DELREC, CMD_LAST, NOP_CMD        ; ^X ^Y ^Z Esc
  .word NOP_CMD, NOP_CMD, NOP_CMD, NOP_CMD
EXTTAB:
  .word CMD_UP, CMD_DOWN, CMD_LEFT, CMD_RIGHT          ; arrows
  .word CMD_HOME, CMD_END, CMD_PGUP, CMD_PGDN          ; Home End PgUp PgDn
  .word NOP_CMD, CMD_DEL, NOP_CMD, NOP_CMD             ; Ins Del
  .word NOP_CMD, NOP_CMD, NOP_CMD, NOP_CMD
  .word CMD_HELP, CMD_LIST, CMD_NEWREC, CMD_FIND       ; F1-F4
  .word CMD_FINDAG, CMD_SORT, NOP_CMD, CMD_DELREC      ; F5-F8
  .word NOP_CMD, CMD_QUIT, NOP_CMD, NOP_CMD            ; F9-F12
KTAB:
  .byte 'S'
  .word CMD_SAVE
  .byte 'A'
  .word CMD_SAVEAS
  .byte 'O'
  .word CMD_OPEN
  .byte 'N'
  .word CMD_NEWFILE
  .byte 'X'
  .word CMD_SAVEX
  .byte 'D'
  .word CMD_SAVEX
  .byte 'Q'
  .word CMD_QUIT
  .byte 0

DEFNF       = 7
DEFFORM:                 ; names (10 each) then widths
  .byte "NAME      ADDRESS   CITY      PHONE     EMAIL     BIRTHDAY  NOTES     "
  .byte "          "
DEFWID:     .byte 24, 28, 20, 16, 28, 10, 28, 1
DEFFORM_L   = DEFWID+8-DEFFORM
F_MAGIC:    .byte "BOFL",1

M_HELLO:    .byte "MINIVIC FILE 1.0  -  ^J OR F1 = HELP",0
M_HINT:     .byte "^J HELP ^KS SAVE ^KO OPEN ^KN NEW FORM",0
M_HK:       .byte "^K  S SAVE  A SAVE AS  O OPEN  N NEW  X Q",0
M_KEYS:     .byte "PGUP PGDN CARD  F3 NEW  F8 DEL  F2 LIST",0
M_KEYS2:    .byte "F4 FIND  F5 AGAIN  F6 SORT BY THIS FIELD",0
M_LISTK:    .byte "ARROWS PGUP PGDN, ENTER = THIS CARD",0
M_FULL:     .byte "NO ROOM FOR MORE CARDS",0
M_NF:       .byte "NOT FOUND",0
M_SORTED:   .byte "SORTED",0
M_SDERR:    .byte "SD CARD ERROR OR NOT A CARD FILE",0
M_SAVED:    .byte "SAVED",0
M_LOADED:   .byte "LOADED",0
M_NOSLOT:   .byte "NO FREE PLACE: DELETE A DOCUMENT FIRST",0
M_OPEN:     .byte " OPEN CARD FILE",0
M_NONAME:   .byte "NO NAME"
M_CARD:     .byte "CARD"
M_FREE:     .byte "FIT"
P_FIND:     .byte "FIND: ",0
P_SAVE:     .byte "SAVE AS: ",0
P_FNAME:    .byte "FIELD 1 NAME (ENTER=END): ",0
P_FWIDTH:   .byte "WIDTH (1-28): ",0
Q_ABANDON:  .byte "ABANDON THE CHANGES (Y/N)?",0
Q_DELREC:   .byte "DELETE THIS CARD (Y/N)?",0

HELPTXT:
  .byte " MINIVIC FILE  -  COMMANDS",0
  .byte "",0
  .byte "FIELD   UP DOWN TAB ENTER  (^E ^X)",0
  .byte "        LEFT RIGHT HOME END (^S ^D ^A ^F)",0
  .byte "        TYPE OVER, BKSP, DEL (^G)",0
  .byte "CARD    PGUP PGDN (^R ^C)",0
  .byte "        ^T FIRST  ^Z LAST",0
  .byte "        F3 NEW CARD (^N)",0
  .byte "        F8 DELETE THE CARD (^Y)",0
  .byte "LIST    F2: ONE CARD PER ROW",0
  .byte "FIND    F4 TEXT IN ANY FIELD, F5 AGAIN",0
  .byte "SORT    F6 BY THE FIELD OF THE CURSOR",0
  .byte "FILE    ^KS SAVE  ^KA SAVE AS",0
  .byte "        ^KO OPEN  ^KN NEW FORM",0
  .byte "        ^KX SAVE AND EXIT",0
  .byte "        ^KQ EXIT WITHOUT SAVING F10",0
  .byte "",0
  .byte "UP TO 8 FIELDS OF 1-28 CHARACTERS",0
  .byte "",0
  .byte "PRESS ANY KEY",0
  .byte $FF

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; libraries

 .include "lib/keys.asm"
 .include "lib/vtext.asm"
 .include "lib/num.asm"
 .include "lib/docs.asm"
 .include "lib/ui.asm"
 .include "lib/stream.asm"

CODE_END:
