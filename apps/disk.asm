;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                                              ;
;   DISK  -  miniVIC DISK, the SD card manager (a small DOS)   ;
;   65C02 assembly, TMS9918A text mode 40 x 24                 ;
;   Needs the BIOS 27.10.26 KEYB/SD                            ;
;                                                              ;
;   - F2 the programs of the SD (directory pages of make_sd),  ;
;     Enter runs one (JT_LOAD_RUN_SLOT, as the BIOS menu does) ;
;   - F3 the documents (WRITE, CALC, FILE, MON, TERM):         ;
;     V view (text, or hex for code), R rename, C copy,        ;
;     Del delete, F empty the whole document index             ;
;   - arrows / ^E ^X, PgUp PgDn choose; Tab the other list;    ;
;     Q or F10 back to the BIOS menu                           ;
;                                                              ;
;   MEMORY                                                     ;
;   $0050-$006F  zero page (lib $A0-$F1)                       ;
;   $0210-$021F  name                                          ;
;   $0600-$09FF  document index, sector buffer                 ;
;   $3000-$57FF  the programs: 40 bytes each (255 at most)     ;
;                                                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

 .include "lib/system.inc"

PROGTAB     = $3000    ; per program: name (32), load, length, entry (2 each), type, run flag
PE          = 40
LROWS       = 20       ; list rows (screen rows 2-21)
NAMELEN     = 12

; ---------------- zero page ----------------
VIEW        = $50      ; 0 programs, 1 documents
SEL         = $51      ; selected row (program 0-254, or document slot 1-15)
TOPI        = $52      ; first row on the screen (programs)
NPROG       = $53
CTYPE       = $54      ; SD card type (0 none)
T0          = $55
T1          = $56
T2          = $57
T3          = $58
P0          = $59      ; 2 bytes
P1          = $5B      ; 2 bytes
MSGP        = $5D      ; 2 bytes
ROWI        = $5F
PG          = $60      ; directory page being read
NDOC        = $61      ; documents in use
HEXV        = $62      ; view: 1 = hex
VCOL        = $63      ; view: column
VOFF        = $64      ; view: 2 bytes, offset (hex)

NAMEB       = $0210

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
  STZ VIEW
  STZ SEL
  STZ TOPI
  STZ MSGP+1
  JSR JT_SD_INIT         ; card type
  BCC .rs_t
  LDA #0
.rs_t:
  STA CTYPE
  JSR READDIR
  JSR DOC_RDIDX
  BCC MAIN
  LDA #<M_SDERR
  LDX #>M_SDERR
  JSR SETMSG
MAIN:
  JSR DRAW
IDLE:
  JSR GETKEY
  BCC IDLE
  STZ MSGP+1
  JSR DOKEY
  BRA MAIN

; READDIR: the program directory pages into PROGTAB
READDIR:
  STZ NPROG
  STZ PG
  LDA #<PROGTAB
  STA P1
  LDA #>PROGTAB
  STA P1+1
.rd_p:
  LDA PG                 ; sector = page * 64
  ASL
  ASL
  ASL
  ASL
  ASL
  ASL
  STA SD_LBA
  LDA PG
  LSR
  LSR
  STA SD_LBA+1
  STZ SD_LBA+2
  STZ SD_LBA+3
  LDX #<ST_BUF
  LDY #>ST_BUF
  JSR JT_SD_READ
  BCC .fb4
  JMP .rd_x
.fb4:
  LDX #3                 ; "BOGS"
.rd_m:
  LDA ST_BUF,X
  CMP M_BOGS,X
  BNE .rd_x
  DEX
  BPL .rd_m
  LDA ST_BUF+5           ; programs on this page
  BEQ .rd_x
  STA T3
  STZ T2                 ; entry in the page
.rd_e:
  LDA T2                 ; name: page + 96 + entry * 32
  ASL
  ASL
  ASL
  ASL
  ASL
  STA P0
  LDA T2
  LSR
  LSR
  LSR
  CLC
  ADC #>ST_BUF
  STA P0+1
  CLC
  LDA P0
  ADC #96
  STA P0
  BCC .rd_n
  INC P0+1
.rd_n:
  LDY #31
.rd_nl:
  LDA (P0),Y
  STA (P1),Y
  DEY
  BPL .rd_nl
  LDA T2                 ; parameters: page + 16 + entry * 8
  ASL
  ASL
  ASL
  TAX
  LDY #32
.rd_pl:
  LDA ST_BUF+16,X
  STA (P1),Y
  INX
  INY
  CPY #38
  BNE .rd_pl
  LDA ST_BUF+16,X        ; type
  STA (P1),Y
  INY
  LDX T2                 ; run flag
  LDA ST_BUF+6,X
  STA (P1),Y
  CLC
  LDA P1
  ADC #PE
  STA P1
  BCC .rd_c
  INC P1+1
.rd_c:
  INC NPROG
  LDA NPROG
  CMP #255
  BEQ .rd_x
  INC T2
  LDA T2
  CMP T3
  BNE .rd_e
  JSR KB_POLL
  LDA T3                 ; a full page: there may be another
  CMP #9
  BNE .rd_x
  INC PG
  JMP .rd_p
.rd_x:
  RTS

; DOKEY: key A
DOKEY:
  CMP #K_F1+9
  BEQ .dk_q
  CMP #K_TAB
  BEQ .dk_tab
  CMP #K_F1+1
  BEQ .dk_p
  CMP #K_F1+2
  BEQ .dk_d
  CMP #K_UP
  BEQ .dk_up
  CMP #'E'-$40
  BEQ .dk_up
  CMP #K_DOWN
  BEQ .dk_dn
  CMP #'X'-$40
  BEQ .dk_dn
  CMP #K_PGUP
  BEQ .dk_pu
  CMP #K_PGDN
  BEQ .dk_pd
  CMP #K_CR
  BNE .dk_o
  JMP ENTER
.dk_o:
  LDX VIEW
  BEQ .dk_l
  CMP #K_DEL
  BNE .dk_l
  JMP DOCDEL
.dk_l:
  JSR UI_UPC
  CMP #'Q'
  BEQ .dk_q
  LDX VIEW
  BEQ .dk_x
  CMP #'V'
  BNE .dk_r
  JMP DOCVIEW
.dk_r:
  CMP #'R'
  BNE .dk_c
  JMP DOCREN
.dk_c:
  CMP #'C'
  BNE .dk_f
  JMP DOCCOPY
.dk_f:
  CMP #'F'
  BNE .dk_x
  JMP DOCFMT
.dk_x:
  RTS
.dk_q:
  JSR KB_EXIT
  JMP JT_SHOW_MENU
.dk_tab:
  LDA VIEW
  EOR #1
  BRA .dk_v
.dk_p:
  LDA #0
  BRA .dk_v
.dk_d:
  LDA #1
.dk_v:
  STA VIEW
  STZ TOPI
  STA SEL                ; (programs from 0, documents from slot 1)
  RTS
.dk_up:
  LDA SEL
  CMP FIRSTSEL
  BEQ .dk_x
  DEC SEL
  BRA .dk_fit
.dk_dn:
  LDA SEL
  CMP LASTSEL
  BCS .dk_x
  INC SEL
  BRA .dk_fit
.dk_pu:
  LDA SEL
  SEC
  SBC #LROWS
  BCC .dk_pf
  CMP FIRSTSEL
  BCS .dk_ps
.dk_pf:
  LDA FIRSTSEL
.dk_ps:
  STA SEL
  BRA .dk_fit
.dk_pd:
  LDA SEL
  CLC
  ADC #LROWS
  BCS .dk_pl
  CMP LASTSEL
  BCC .dk_ps
.dk_pl:
  LDA LASTSEL
  BRA .dk_ps
.dk_fit:
  LDA SEL                ; programs: the selected row on the screen
  CMP TOPI
  BCS .dk_f2
  STA TOPI
.dk_f2:
  SEC
  SBC TOPI
  CMP #LROWS
  BCC .dk_fx
  LDA SEL
  SEC
  SBC #LROWS-1
  STA TOPI
.dk_fx:
  RTS

; FIRSTSEL / LASTSEL: first and last row of the list shown
FIRSTSEL:   .byte 0
LASTSEL:    .byte 0

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; screen

DRAW:
  LDA VIEW
  BNE .dw_d
  STZ FIRSTSEL
  LDA NPROG
  BEQ .dw_p0
  DEC A
.dw_p0:
  STA LASTSEL
  BRA .dw_s
.dw_d:
  LDA #1
  STA FIRSTSEL
  LDA #DOC_SLOTS
  STA LASTSEL
  STZ TOPI
.dw_s:
  JSR STATUS
  LDA #1                 ; column titles
  JSR VT_ROW
  STZ VT_INV
  LDA #<M_PHEAD
  LDX #>M_PHEAD
  LDY VIEW
  BEQ .dw_h
  LDA #<M_DHEAD
  LDX #>M_DHEAD
.dw_h:
  LDY #0
  JSR VT_LINE
  STZ ROWI
.dw_r:
  LDA ROWI
  CLC
  ADC #2
  JSR VT_ROW
  LDA VIEW
  BNE .dw_dr
  JSR PROGROW
  BRA .dw_n
.dw_dr:
  JSR DOCROW
.dw_n:
  INC ROWI
  LDA ROWI
  CMP #LROWS
  BNE .dw_r
  LDA #22
  JSR VT_ROW
  LDA #<M_PKEYS
  LDX #>M_PKEYS
  LDY VIEW
  BEQ .dw_k
  LDA #<M_DKEYS
  LDX #>M_DKEYS
.dw_k:
  LDY #0
  JSR VT_LINE
  ; (falls into MSGLINE)

MSGLINE:
  LDA #23
  JSR VT_ROW
  STZ VT_INV
  LDA MSGP
  LDX MSGP+1
  BNE .ms_o
  LDA #<M_HINT
  LDX #>M_HINT
.ms_o:
  LDY #0
  JMP VT_LINE

SETMSG:
  STA MSGP
  STX MSGP+1
  RTS

; STATUS: row 0: card type, programs, documents in use
STATUS:
  LDX #39
  LDA #' '
.st_b:
  STA UI_LINE,X
  DEX
  BPL .st_b
  LDX #M_STAT_L-1
.st_t:
  LDA M_STAT,X
  STA UI_LINE,X
  DEX
  BPL .st_t
  LDA CTYPE              ; card type
  ASL
  ASL
  ASL
  TAX
  LDY #0
.st_c:
  LDA M_CARDS,X
  STA UI_LINE+6,Y
  INX
  INY
  CPY #7
  BNE .st_c
  LDA #<UI_LINE
  STA VT_P
  LDA #>UI_LINE
  STA VT_P+1
  LDA NPROG
  STA NUM
  STZ NUM+1
  LDY #14                ; programs 14-18, "PROGS" 20
  JSR NUMSTR
  JSR COUNTDOC
  STA NUM
  STZ NUM+1
  LDY #26                ; documents 26-30, "DOCS" 32
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

; COUNTDOC: A = documents in use
COUNTDOC:
  STZ NDOC
  LDA #1
.cd_l:
  PHA
  JSR DOC_ENTRY
  LDA (DOC_E)
  BEQ .cd_n
  INC NDOC
.cd_n:
  PLA
  INC A
  CMP #DOC_SLOTS+1
  BNE .cd_l
  LDA NDOC
  RTS

; ROWINV: VT_INV = $80 if row ROWI is the selected one (A = its number)
ROWINV:
  STZ VT_INV
  CMP SEL
  BNE .ri_x
  LDA #$80
  STA VT_INV
.ri_x:
  RTS

; PROGROW: program TOPI + ROWI: number, name, length
PROGROW:
  LDA ROWI
  CLC
  ADC TOPI
  CMP NPROG
  BCC .pr_y
  STZ VT_INV
  LDA #' '
  LDX #40
  JMP VT_REP
.pr_y:
  STA T0
  JSR ROWINV
  JSR PROGPTR            ; P0 = its entry
  JSR BLANKLINE
  LDA T0                 ; number (1-based), 3 digits
  INC A
  STA NUM
  STZ NUM+1
  LDY #0
  JSR NUMSTR             ; (5 characters: "  123")
  LDY #0                 ; name, 28 characters at most, from column 6
.pr_n:
  LDA (P0),Y
  BEQ .pr_l
  STA UI_LINE+6,Y
  INY
  CPY #27
  BNE .pr_n
.pr_l:
  LDY #34                ; length
  LDA (P0),Y
  STA NUM
  INY
  LDA (P0),Y
  STA NUM+1
  LDY #34
  JSR NUMSTR
  JMP PUTLINE

; PROGPTR: P0 = PROGTAB + T0 * 40
PROGPTR:
  LDA T0
  STA P0
  STZ P0+1
  ASL P0                 ; * 8
  ROL P0+1
  ASL P0
  ROL P0+1
  ASL P0
  ROL P0+1
  LDA P0                 ; * 40 = * 8 * 5
  STA T1
  LDA P0+1
  STA T2
  ASL P0
  ROL P0+1
  ASL P0
  ROL P0+1
  CLC
  LDA P0
  ADC T1
  STA P0
  LDA P0+1
  ADC T2
  ADC #>PROGTAB
  STA P0+1
  RTS

; BLANKLINE: UI_LINE all spaces, VT_P = UI_LINE
BLANKLINE:
  LDX #39
  LDA #' '
.bl_l:
  STA UI_LINE,X
  DEX
  BPL .bl_l
  LDA #<UI_LINE
  STA VT_P
  LDA #>UI_LINE
  STA VT_P+1
  RTS

; PUTLINE: UI_LINE to the VDP, ORA VT_INV
PUTLINE:
  LDX #0
.pl_l:
  LDA UI_LINE,X
  ORA VT_INV
  STA VDP_DATA
  INX
  CPX #40
  BNE .pl_l
  STZ VT_INV
  JMP KB_POLL

; DOCROW: document slot ROWI + 1: slot, name, type, length
DOCROW:
  LDA ROWI
  INC A
  CMP #DOC_SLOTS+1
  BCC .dr_y
  STZ VT_INV
  LDA #' '
  LDX #40
  JMP VT_REP
.dr_y:
  STA T0
  JSR ROWINV
  JSR BLANKLINE
  LDA T0
  STA NUM
  STZ NUM+1
  LDY #0
  JSR NUMSTR
  LDA T0
  JSR DOC_ENTRY
  LDA (DOC_E)
  BNE .dr_u
  LDX #6
.dr_e:
  LDA M_FREE,X
  STA UI_LINE+6,X
  DEX
  BPL .dr_e
  JMP PUTLINE
.dr_u:
  ASL                    ; type (the names of lib/ui)
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
  STA UI_LINE+20,Y
  INX
  INY
  CPY #5
  BNE .dr_tl
  LDY #4                 ; name
  LDX #0
.dr_n:
  LDA (DOC_E),Y
  BEQ .dr_l
  STA UI_LINE+6,X
  INY
  INX
  CPX #NAMELEN
  BNE .dr_n
.dr_l:
  LDY #1
  LDA (DOC_E),Y
  STA NUM
  INY
  LDA (DOC_E),Y
  STA NUM+1
  LDY #29
  JSR NUMSTR
  JMP PUTLINE

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; programs

; ENTER: programs: run the selected one (after a question); documents: view
ENTER:
  LDA VIEW
  BEQ .en_p
  JMP DOCVIEW
.en_p:
  LDA NPROG
  BEQ .en_x
  LDA #<Q_RUN
  LDX #>Q_RUN
  JSR YESNO
  BCS .en_x
  JSR KB_EXIT
  LDA #0                 ; the program finds the keyboard as the menu leaves it
  JSR JT_KB_MODE
  LDA SEL
  JMP JT_LOAD_RUN_SLOT   ; (never returns; on an error the BIOS menu)
.en_x:
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; documents

; DOCSEL: DOC_E = entry of the selected slot; C=1 (and a message) if it is free
DOCSEL:
  LDA SEL
  JSR DOC_ENTRY
  LDA (DOC_E)
  BNE .ds_ok
  LDA #<M_EMPTY
  LDX #>M_EMPTY
  JSR SETMSG
  SEC
  RTS
.ds_ok:
  CLC
  RTS

DOCDEL:
  JSR DOCSEL
  BCS .dd_x
  LDA #<DP_QDEL
  LDX #>DP_QDEL
  JSR YESNO
  BCS .dd_x
  LDA SEL
  JSR DOC_ENTRY
  LDA #0
  STA (DOC_E)
  JMP WRIDX
.dd_x:
  RTS

; WRIDX: the index to the SD (message on an error)
WRIDX:
  JSR DOC_WRIDX
  BCC .wi_x
  LDA #<M_SDERR
  LDX #>M_SDERR
  JMP SETMSG
.wi_x:
  RTS

; ASKNAME: a document name -> NAMEB (12, $00 padded). C=1 cancelled or empty
ASKNAME:
  STZ UI_BUF
  LDX #NAMELEN
  STX UI_PMAX
  LDX #1
  STX UI_PUPC
  JSR PROMPT
  BCS .an_x
  CMP #0
  BEQ .an_no
  LDX #NAMELEN
.an_z:
  STZ NAMEB,X
  DEX
  BPL .an_z
  LDX #0
.an_c:
  LDA UI_BUF,X
  BEQ .an_ok
  STA NAMEB,X
  INX
  CPX #NAMELEN
  BNE .an_c
.an_ok:
  CLC
  RTS
.an_no:
  SEC
.an_x:
  RTS

; NAMEFREE: C=0 if no other document of the type of the selected one has the name NAMEB
NAMEFREE:
  LDA (DOC_E)
  STA DOC_T
  LDA #<NAMEB
  STA DOC_P
  LDA #>NAMEB
  STA DOC_P+1
  LDA SEL                ; (DOC_FIND moves DOC_E)
  PHA
  JSR DOC_FIND
  PLA
  PHP
  JSR DOC_ENTRY
  PLP
  BCS .nf_ok
  LDA #<M_SAME
  LDX #>M_SAME
  JSR SETMSG
  CLC                    ; (found: not free)
  RTS
.nf_ok:
  SEC
  RTS

DOCREN:
  JSR DOCSEL
  BCS .dr_x
  LDA #<P_REN
  LDX #>P_REN
  JSR ASKNAME
  BCS .dr_x
  JSR NAMEFREE
  BCC .dr_x
  LDY #4                 ; the new name
  LDX #0
.dr_c:
  LDA NAMEB,X
  STA (DOC_E),Y
  INY
  INX
  CPX #NAMELEN
  BNE .dr_c
  JMP WRIDX
.dr_x:
  RTS

; DOCCOPY: C a copy of the selected document in a free slot, with a new name
DOCCOPY:
  JSR DOCSEL
  BCC .fb2
  JMP .dc_x
.fb2:
  LDA #<P_COPY
  LDX #>P_COPY
  JSR ASKNAME
  BCS .dc_x
  JSR NAMEFREE
  BCC .dc_x
  LDY #1                 ; type and length of the copy
  LDA (DOC_E),Y
  STA DOC_LEN
  INY
  LDA (DOC_E),Y
  STA DOC_LEN+1
  LDA SEL
  STA T3                 ; source slot
  JSR DOC_FREE
  BCC .dc_f
  LDA #<M_FULL
  LDX #>M_FULL
  JMP SETMSG
.dc_f:
  STA T2                 ; target slot
  LDA DOC_LEN            ; sectors = (length + 511) / 512
  CLC
  ADC #$FF
  LDA DOC_LEN+1
  ADC #1
  LSR
  STA T1
  STZ DOC_I
.dc_s:
  LDA DOC_I
  CMP T1
  BCS .dc_e
  LDA T3
  STA DOC_K
  JSR DOC_SECT
  LDX #<ST_BUF
  LDY #>ST_BUF
  JSR JT_SD_READ
  BCS .dc_err
  LDA T2
  STA DOC_K
  JSR DOC_SECT
  LDX #<ST_BUF
  LDY #>ST_BUF
  JSR JT_SD_WRITE
  BCS .dc_err
  INC DOC_I
  BRA .dc_s
.dc_e:
  LDA #<NAMEB
  STA DOC_P
  LDA #>NAMEB
  STA DOC_P+1
  LDA T2
  JSR DOC_SETENT         ; (DOC_T: the type of the source, from NAMEFREE)
  JSR WRIDX
  LDA #<M_COPIED
  LDX #>M_COPIED
  JMP SETMSG
.dc_err:
  LDA #<M_SDERR
  LDX #>M_SDERR
  JMP SETMSG
.dc_x:
  RTS

; DOCFMT: F an empty document index (every document is lost)
DOCFMT:
  LDA #<Q_FMT
  LDX #>Q_FMT
  JSR YESNO
  BCS .df_x
  LDX #0
.df_z:
  STZ DOC_IDX,X
  STZ DOC_IDX+$100,X
  INX
  BNE .df_z
  LDX #5
.df_h:
  LDA DOC_MAGIC,X
  STA DOC_IDX,X
  DEX
  BPL .df_h
  JMP WRIDX
.df_x:
  RTS

; DOCVIEW: V the document, a screen at a time: text (CR = new row), or hex for code (type 4);
; any key the next screen, Esc back
DOCVIEW:
  JSR DOCSEL
  BCC .fb1
  JMP .dv_x
.fb1:
  STZ HEXV
  LDA (DOC_E)
  CMP #4
  BNE .dv_t
  INC HEXV
.dv_t:
  LDA SEL
  STA DOC_K
  LDY #1
  LDA (DOC_E),Y
  STA DOC_LEN
  INY
  LDA (DOC_E),Y
  STA DOC_LEN+1
  JSR ST_ROPEN
  STZ VOFF
  STZ VOFF+1
.dv_pg:
  JSR VT_CLS
  STZ ROWI
  STZ VCOL
.dv_r:
  LDA ROWI
  JSR VT_ROW
  LDA HEXV
  BNE .dv_hex
.dv_c:
  JSR ST_GET             ; text
  BCS .dv_end
  CMP #K_CR
  BEQ .dv_nl
  CMP #' '
  BCC .dv_dot
  CMP #$7F
  BCC .dv_p
.dv_dot:
  LDA #'.'
.dv_p:
  STA VDP_DATA
  INC VCOL
  LDA VCOL
  CMP #40
  BCC .dv_c
.dv_nl:
  STZ VCOL
  INC ROWI
  LDA ROWI
  CMP #23
  BCC .dv_r
  BRA .dv_more
.dv_hex:
  LDA VOFF+1             ; "0000  xx xx xx xx xx xx xx xx"
  JSR HEXOUT
  LDA VOFF
  JSR HEXOUT
  LDA #' '
  STA VDP_DATA
  LDA #8
  STA VCOL
.dv_hb:
  JSR ST_GET
  BCS .dv_end
  PHA
  LDA #' '
  STA VDP_DATA
  PLA
  JSR HEXOUT
  INC VOFF
  BNE .dv_hn
  INC VOFF+1
.dv_hn:
  DEC VCOL
  BNE .dv_hb
  INC ROWI
  LDA ROWI
  CMP #23
  BCC .dv_r
.dv_more:
  JSR VIEWKEY
  BCC .dv_pg
  BRA .dv_back
.dv_end:
  LDA ST_ERR
  BEQ .dv_k
  LDA #<M_SDERR
  LDX #>M_SDERR
  JSR SETMSG
.dv_k:
  JSR VIEWKEY
.dv_back:
  JMP VT_CLS
.dv_x:
  RTS

; VIEWKEY: the hint on row 23, then a key: C=1 Esc
VIEWKEY:
  LDA #23
  JSR VT_ROW
  LDA #$80
  STA VT_INV
  LDA #<M_VIEWK
  LDX #>M_VIEWK
  LDY #0
  JSR VT_LINE
  STZ VT_INV
  JSR WAITKEY
  CMP #K_ESC
  BEQ .vk_e
  CLC
  RTS
.vk_e:
  SEC
  RTS

; HEXOUT: A as 2 hex digits to the VDP
HEXOUT:
  PHA
  LSR
  LSR
  LSR
  LSR
  JSR .ho_d
  PLA
  AND #$0F
.ho_d:
  CMP #10
  BCC .ho_n
  ADC #'A'-10-1-'0'
.ho_n:
  ADC #'0'
  STA VDP_DATA
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; texts

M_BOGS:     .byte "BOGS"
M_STAT:     .byte " DISK               PROGS       DOCS    "
M_STAT_L    = 40
M_CARDS:    .byte "NONE    SDSC V1 SDSC V2 SDHC    "
M_PHEAD:    .byte "    N PROGRAM                     BYTES",0
M_DHEAD:    .byte "SLOT  NAME          TYPE     BYTES",0
M_PKEYS:    .byte "ENTER RUN   TAB/F3 DOCUMENTS   Q EXIT",0
M_DKEYS:    .byte "V VIEW R RENAME C COPY DEL F FORMAT",0
M_HINT:     .byte "F2 PROGRAMS  F3 DOCUMENTS  Q EXIT",0
M_FREE:     .byte "(FREE) "
M_EMPTY:    .byte "THIS SLOT IS FREE",0
M_SAME:     .byte "THERE IS ALREADY ONE WITH THAT NAME",0
M_FULL:     .byte "NO FREE SLOT FOR THE COPY",0
M_COPIED:   .byte "COPIED",0
M_SDERR:    .byte "SD CARD ERROR",0
M_VIEWK:    .byte "ANY KEY: MORE      ESC: BACK",0
P_REN:      .byte "NEW NAME: ",0
P_COPY:     .byte "NAME OF THE COPY: ",0
Q_RUN:      .byte "RUN THIS PROGRAM (Y/N)?",0
Q_FMT:      .byte "DELETE ALL THE DOCUMENTS (Y/N)?",0

 .include "lib/keys.asm"
 .include "lib/vtext.asm"
 .include "lib/num.asm"
 .include "lib/docs.asm"
 .include "lib/stream.asm"
 .include "lib/ui.asm"

CODE_END:
