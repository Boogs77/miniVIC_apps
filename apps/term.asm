;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                                              ;
;   TERM  -  miniVIC TERM, serial terminal (VicTerm style)     ;
;   65C02 assembly, W65C51 at $C000, TMS9918A text 40 x 24     ;
;   Needs the BIOS 27.10.26 KEYB/SD                            ;
;                                                              ;
;   - rows 1-23 show what arrives on the serial line (CR, LF,  ;
;     BS, TAB, FF, ANSI ESC[ ... J H K A B C D); row 0 status  ;
;   - typed keys go out (arrows as ESC[A..D, Del as $7F);      ;
;     F2 local echo, F3 Enter sends CR LF, F7 speed            ;
;   - F4 capture on/off (up to 20 KB of text), F5 saves it as  ;
;     a text document (WRITE opens it), F6 sends a document    ;
;   - received bytes: ACIA receive interrupt into a 256-byte   ;
;     ring (lib/keys with KB_SERBUF), polled too               ;
;   - the only program that talks on the serial line: the      ;
;     others send only the "[TYPE] Name" line (user's choice)  ;
;                                                              ;
;   MEMORY                                                     ;
;   $0050-$006F  zero page (lib $A0-$F1)                       ;
;   $3000-$30FF  receive ring                                  ;
;   $3100-$7FFF  capture buffer (20224 bytes)                  ;
;                                                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

 .include "lib/system.inc"

KB_SERBUF   = $3000    ; (before lib/keys: received bytes go here)
CAPBUF      = $3100
CAPEND      = $8000
NAMELEN     = 12
CR          = $0D
LF          = $0A

; ---------------- zero page ----------------
TROW        = $50      ; cursor (0-22: screen rows 1-23)
TCOL        = $51
ECHO        = $52
CRLF        = $53
CAPT        = $54      ; 1 = capture on
CPTR        = $55      ; 2 bytes: end of the captured text
BAUDI       = $57      ; speed 0-5
ESCST       = $58      ; 0 text, 1 after ESC, 2 inside ESC[
PARAM       = $59      ; first number of ESC[
CURON       = $5A      ; 1 = the cursor is drawn
CURCH       = $5B      ; character under it
T0          = $5C
T1          = $5D
P0          = $5E      ; 2 bytes
TXN         = $60      ; delay units per byte sent
LASTC       = $61      ; last byte captured

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
  LDA #1                 ; type 1 = text (capture and send)
  STA DOC_T
  STZ ECHO
  STZ CRLF
  STZ CAPT
  STZ ESCST
  STZ CURON
  LDA #<CAPBUF
  STA CPTR
  LDA #>CAPBUF
  STA CPTR+1
  LDA #5                 ; 19200, as the BIOS set it
  JSR SETBAUD
  LDA #$89               ; DTR on, receive interrupt on, no parity
  STA ACIA_CMD
  JSR KB_INIT            ; (CLI)
  JSR TCLS
  JSR STATUS
MAIN:
  JSR SERGET             ; what arrived first
  BCC IDLE
  PHA
  JSR CUROFF
  PLA
  PHA
  JSR TOUT
  PLA
  JSR CAPTURE
  BRA MAIN
IDLE:
  JSR CURDRAW
  JSR GETKEY
  BCC MAIN
  PHA
  JSR CUROFF
  PLA
  JSR DOKEY
  BRA MAIN

; DOKEY: local commands (F keys), else the key goes out
DOKEY:
  CMP #K_F1
  BEQ .dk_help
  CMP #K_F1+1
  BEQ .dk_echo
  CMP #K_F1+2
  BEQ .dk_lf
  CMP #K_F1+3
  BEQ .dk_cap
  CMP #K_F1+4
  BNE .dk_6
  JMP CAPSAVE
.dk_6:
  CMP #K_F1+5
  BNE .dk_7
  JMP SENDDOC
.dk_7:
  CMP #K_F1+6
  BEQ .dk_baud
  CMP #K_F1+9
  BEQ .dk_exit
  CMP #K_UP              ; arrows: ESC [ A B C D
  BCC .dk_send
  CMP #K_RIGHT+1
  BCS .dk_del
  SEC
  SBC #K_UP
  TAX
  LDA ARROWS,X           ; (SEND uses X)
  PHA
  LDA #K_ESC
  JSR SEND
  LDA #'['
  JSR SEND
  PLA
  BRA .dk_send
.dk_del:
  CMP #K_DEL
  BNE .dk_x
  LDA #$7F
.dk_send:
  CMP #K_CR
  BNE .dk_s1
  JSR SENDE
  LDA CRLF
  BEQ .dk_x
  LDA #LF
.dk_s1:
  JMP SENDE
.dk_x:
  RTS
.dk_help:
  JMP HELP
.dk_echo:
  LDA ECHO
  EOR #1
  STA ECHO
  JMP STATUS
.dk_lf:
  LDA CRLF
  EOR #1
  STA CRLF
  JMP STATUS
.dk_cap:
  LDA CAPT
  EOR #1
  STA CAPT
  JMP STATUS
.dk_baud:
  LDA BAUDI
  INC A
  CMP #6
  BCC .dk_b
  LDA #0
.dk_b:
  JSR SETBAUD
  JMP STATUS
.dk_exit:
  SEI
  LDA #$8B               ; the serial line as the BIOS wants it
  STA ACIA_CMD
  LDA #$1F
  STA ACIA_CTRL
  JSR KB_EXIT
  JMP JT_SHOW_MENU

ARROWS:     .byte "ABDC"   ; K_UP K_DOWN K_LEFT K_RIGHT

; SENDE: A out, and on the screen too with the local echo
SENDE:
  JSR SEND
  LDX ECHO
  BEQ .se_x
  JMP TOUT
.se_x:
  RTS

; SEND: A to the serial line. The W65C51 does not say when a byte is gone: a fixed
; wait of TXN x ~1.3 ms, as long as a byte at the speed chosen. Keeps A
SEND:
  STA ACIA_DATA
  PHA
  LDX TXN
.sd_o:
  LDA #$FF
.sd_l:
  DEC
  BNE .sd_l
  DEX
  BNE .sd_o
  PLA
  RTS

; SETBAUD: speed A (0-5): 300 1200 2400 4800 9600 19200
SETBAUD:
  STA BAUDI
  TAX
  LDA BAUDCTL,X
  STA ACIA_CTRL
  LDA BAUDTX,X
  STA TXN
  RTS

BAUDCTL:    .byte $16, $18, $1A, $1C, $1E, $1F
BAUDTX:     .byte 28, 8, 4, 2, 1, 1
BAUDTXT:    .byte "  300 1200 2400 4800 960019200"

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; screen

; STATUS: row 0 in inverse: speed, echo, CR LF, capture
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
  LDA BAUDI              ; speed: 5 characters
  ASL
  ASL
  CLC
  ADC BAUDI
  TAX
  LDY #6
.st_s:
  LDA BAUDTXT,X
  STA UI_LINE,Y
  INX
  INY
  CPY #11
  BNE .st_s
.st_e:
  LDY #21                ; ECHO
  LDA ECHO
  JSR ONOFF
  LDY #27                ; LF
  LDA CRLF
  JSR ONOFF
  LDA CAPT               ; CAP: OFF, or the bytes captured
  BNE .st_c
  LDY #35
  LDA #0
  JSR ONOFF
  BRA .st_o
.st_c:
  SEC
  LDA CPTR
  SBC #<CAPBUF
  STA NUM
  LDA CPTR+1
  SBC #>CAPBUF
  STA NUM+1
  LDA #<UI_LINE
  STA VT_P
  LDA #>UI_LINE
  STA VT_P+1
  LDY #35                ; (5 digits: 35-39)
  JSR NUMSTR
.st_o:
  LDA #0
  JSR VT_ROW
  LDX #0
.st_w:
  LDA UI_LINE,X
  ORA #$80
  STA VDP_DATA
  INX
  CPX #40
  BNE .st_w
  RTS

; ONOFF: "ON " or "OFF" at UI_LINE+Y (A = 0 off)
ONOFF:
  LDX #0
  CMP #0
  BEQ .oo_s
  LDX #3
.oo_s:
  LDA #3
  STA T0
.oo_l:
  LDA M_ONOFF,X
  STA UI_LINE,Y
  INX
  INY
  DEC T0
  BNE .oo_l
  RTS

; TCLS: rows 1-23 blank, cursor home
TCLS:
  LDA #1
  JSR VT_ROW
  LDY #23
.tc_r:
  LDA #' '
  LDX #40
  JSR VT_REP
  DEY
  BNE .tc_r
  STZ TROW
  STZ TCOL
  RTS

; TOUT: a received byte on the screen (CR LF BS TAB FF, ESC[ sequences, text)
TOUT:
  LDX ESCST
  BEQ .to_t
  CPX #1
  BEQ .to_esc
  CMP #'0'               ; inside ESC[: digits make the first number
  BCC .to_fin
  CMP #'9'+1
  BCS .to_semi
  AND #$0F
  PHA
  LDA PARAM
  ASL
  ASL
  ADC PARAM
  ASL
  STA PARAM
  PLA
  ADC PARAM
  STA PARAM
  RTS
.to_semi:
  CMP #';'
  BEQ .to_sx
  CMP #'?'               ; (private sequences ESC[? ...: the number is ignored too)
  BNE .to_fin
.to_sx:
  RTS                    ; (only the first number counts)
.to_esc:
  STZ ESCST
  CMP #'['
  BNE .to_x
  LDA #2
  STA ESCST
  STZ PARAM
.to_x:
  RTS
.to_fin:
  STZ ESCST
  JMP ANSI
.to_t:
  CMP #K_ESC
  BNE .to_cr
  LDA #1
  STA ESCST
  RTS
.to_cr:
  CMP #CR
  BNE .to_lf
  STZ TCOL
  RTS
.to_lf:
  CMP #LF
  BNE .to_bs
  JMP NEWLINE
.to_bs:
  CMP #K_BS
  BNE .to_tab
  LDA TCOL
  BEQ .to_x
  DEC TCOL
  RTS
.to_tab:
  CMP #K_TAB
  BNE .to_ff
  LDA TCOL
  ORA #7
  INC A
  CMP #40
  BCC .to_ts
  LDA #39
.to_ts:
  STA TCOL
  RTS
.to_ff:
  CMP #12
  BNE .to_p
  JMP TCLS
.to_p:
  CMP #' '
  BCC .to_x
  CMP #$7F
  BCS .to_x
  PHA
  JSR CURADDR
  PLA
  STA VDP_DATA
  INC TCOL
  LDA TCOL
  CMP #40
  BCC .to_x
  STZ TCOL               ; wrap
  ; (falls into NEWLINE)

; NEWLINE: next row, the text scrolls up at the bottom
NEWLINE:
  LDA TROW
  CMP #22
  BCS .nl_s
  INC TROW
  RTS
.nl_s:
  LDY #2                 ; rows 2-23 one row up (copied in VRAM)
.nl_r:
  TYA
  JSR VT_ROWAD
  JSR VT_RADDR
  LDX #0
.nl_rd:
  LDA VDP_DATA
  STA UI_LINE,X
  INX
  CPX #40
  BNE .nl_rd
  TYA
  DEC A
  JSR VT_ROW
  LDX #0
.nl_wr:
  LDA UI_LINE,X
  STA VDP_DATA
  INX
  CPX #40
  BNE .nl_wr
  INY
  CPY #24
  BNE .nl_r
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

; ANSI: final letter A of ESC[ n: J clear (2 = all), H home, K clear to the end of the
; row, A B C D cursor up / down / right / left by n (at least 1)
ANSI:
  LDX PARAM
  BNE .an_n
  INX
.an_n:
  CMP #'J'
  BNE .an_h
  JMP TCLS
.an_h:
  CMP #'H'
  BNE .an_k
  STZ TROW
  STZ TCOL
  RTS
.an_k:
  CMP #'K'
  BNE .an_a
  JSR CURADDR
  LDA #40
  SEC
  SBC TCOL
  TAX
  LDA #' '
  JMP VT_REP
.an_a:
  CMP #'A'
  BNE .an_b
.an_al:
  LDA TROW
  BEQ .an_x
  DEC TROW
  DEX
  BNE .an_al
  RTS
.an_b:
  CMP #'B'
  BNE .an_c
.an_bl:
  LDA TROW
  CMP #22
  BCS .an_x
  INC TROW
  DEX
  BNE .an_bl
  RTS
.an_c:
  CMP #'C'
  BNE .an_d
.an_cl:
  LDA TCOL
  CMP #39
  BCS .an_x
  INC TCOL
  DEX
  BNE .an_cl
  RTS
.an_d:
  CMP #'D'
  BNE .an_x
.an_dl:
  LDA TCOL
  BEQ .an_x
  DEC TCOL
  DEX
  BNE .an_dl
.an_x:
  RTS

; CURADDR: VRAM write address of the cursor
CURADDR:
  LDA TROW
  INC A
  LDX TCOL
  JMP VT_AT

; CURDRAW: the cursor (the character under it in inverse), if not there yet
CURDRAW:
  LDA CURON
  BNE .cd_x
  LDA TROW               ; read the character
  INC A
  JSR VT_ROWAD
  CLC
  ADC TCOL
  BCC .cd_r
  INX
.cd_r:
  JSR VT_RADDR
  LDA VDP_DATA
  STA CURCH
  JSR CURADDR
  LDA CURCH
  ORA #$80
  STA VDP_DATA
  LDA #1
  STA CURON
.cd_x:
  RTS

; CUROFF: the character under the cursor back as it was
CUROFF:
  LDA CURON
  BEQ .co_x
  STZ CURON
  JSR CURADDR
  LDA CURCH
  STA VDP_DATA
.co_x:
  RTS

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; capture, save, send

; CAPTURE: a received byte into the capture buffer: text and CR (an LF alone becomes
; CR, an LF after a CR goes away)
CAPTURE:
  LDX CAPT
  BEQ .cp_x
  CMP #LF
  BNE .cp_c
  LDX LASTC
  STA LASTC
  CPX #CR
  BEQ .cp_x
  LDA #CR
  BRA .cp_s
.cp_c:
  STA LASTC
  CMP #CR
  BEQ .cp_s
  CMP #' '
  BCC .cp_x
  CMP #$7F
  BCS .cp_x
.cp_s:
  LDX CPTR+1
  CPX #>CAPEND
  BCS .cp_full
  STA (CPTR)
  INC CPTR
  BNE .cp_st
  INC CPTR+1
.cp_st:
  LDA CPTR               ; the status every 64 bytes
  AND #$3F
  BNE .cp_x
  JMP STATUS
.cp_full:
  STZ CAPT
  JMP STATUS
.cp_x:
  RTS

; CAPSAVE: F5 the captured text as a text document, then the buffer is empty
CAPSAVE:
  STZ UI_BUF
  LDA #NAMELEN
  STA UI_PMAX
  LDA #1
  STA UI_PUPC
  LDA #<P_SAVE
  LDX #>P_SAVE
  JSR PROMPT
  PHP
  JSR CLR23
  PLP
  BCS .cs_x
  CMP #0
  BEQ .cs_x
  LDX #NAMELEN           ; name, $00 padded
.cs_z:
  STZ UI_LINE,X
  DEX
  BPL .cs_z
  LDX #0
.cs_n:
  LDA UI_BUF,X
  BEQ .cs_i
  STA UI_LINE,X
  INX
  CPX #NAMELEN
  BNE .cs_n
.cs_i:
  JSR DOC_RDIDX
  BCS .cs_err
  LDA #<UI_LINE
  STA DOC_P
  LDA #>UI_LINE
  STA DOC_P+1
  JSR DOC_FIND
  BCC .cs_k
  JSR DOC_FREE
  BCS .cs_err
.cs_k:
  STA DOC_K
  PHA
  SEC                    ; length
  LDA CPTR
  SBC #<CAPBUF
  STA DOC_LEN
  TAX
  LDA CPTR+1
  SBC #>CAPBUF
  STA DOC_LEN+1
  TAY
  LDA #>CAPBUF
  SEC
  JSR DOC_XFER
  PLA
  BCS .cs_err
  JSR DOC_SETENT
  JSR DOC_WRIDX
  BCS .cs_err
  LDA #<CAPBUF           ; saved: empty buffer
  STA CPTR
  LDA #>CAPBUF
  STA CPTR+1
  JSR STATUS
  LDA #<M_SAVED
  LDX #>M_SAVED
  JMP NOTE
.cs_err:
  LDA #<M_SDERR
  LDX #>M_SDERR
  JMP NOTE
.cs_x:
  RTS

; SENDDOC: F6 a document of the SD goes out, CR as CR (CR LF with F3); what arrives
; meanwhile is shown
SENDDOC:
  LDA #1
  STA UI_ANY
  LDA #<M_SEND
  LDX #>M_SEND
  JSR DOC_PICK
  PHP
  PHA
  JSR TCLS               ; (the list used the whole screen)
  JSR STATUS
  PLA
  PLP
  BCC .sn_go
  CMP #0
  BEQ .sn_x
  LDA #<M_SDERR
  LDX #>M_SDERR
  JMP NOTE
.sn_x:
  RTS
.sn_go:
  STA DOC_K
  JSR DOC_ENTRY
  LDY #1
  LDA (DOC_E),Y
  STA DOC_LEN
  INY
  LDA (DOC_E),Y
  STA DOC_LEN+1
  JSR ST_ROPEN
.sn_l:
  JSR SERGET             ; show what came back
  BCC .sn_g
  JSR TOUT
  BRA .sn_l
.sn_g:
  JSR GETKEY             ; Esc stops
  BCC .sn_b
  CMP #K_ESC
  BEQ .sn_x
.sn_b:
  JSR ST_GET
  BCS .sn_x
  JSR SEND
  CMP #CR
  BNE .sn_l
  LDA CRLF
  BEQ .sn_l
  LDA #LF
  JSR SEND
  BRA .sn_l

; NOTE: a message on the terminal rows, as if it had arrived
NOTE:
  STA P0
  STX P0+1
  LDY #0
.nt_l:
  LDA (P0),Y
  BEQ .nt_x
  PHY
  JSR TOUT
  PLY
  INY
  BRA .nt_l
.nt_x:
  RTS

; CLR23: row 23 back to what the terminal had there is lost: blank it
CLR23:
  LDA #23
  JSR VT_ROW
  LDA #' '
  LDX #40
  JMP VT_REP

; HELP: F1
HELP:
  JSR TCLS
  LDA #<HELPTXT
  LDX #>HELPTXT
  JMP NOTE

M_STAT:     .byte " TERM       8N1 ECHO    LF     CAP"
M_STAT_L    = 34
M_ONOFF:    .byte "OFFON "
M_SAVED:    .byte CR,LF,"[CAPTURE SAVED]",CR,LF,0
M_SDERR:    .byte CR,LF,"[SD CARD ERROR]",CR,LF,0
M_SEND:     .byte " SEND A DOCUMENT",0
P_SAVE:     .byte "SAVE THE CAPTURE AS: ",0
HELPTXT:
  .byte "MINIVIC TERM - SERIAL TERMINAL",CR,LF,CR,LF
  .byte "F2  LOCAL ECHO ON / OFF",CR,LF
  .byte "F3  ENTER SENDS CR LF / CR",CR,LF
  .byte "F4  CAPTURE ON / OFF (20 KB)",CR,LF
  .byte "F5  SAVE THE CAPTURE (TEXT)",CR,LF
  .byte "F6  SEND A DOCUMENT (ESC STOPS)",CR,LF
  .byte "F7  SPEED 300 ... 19200",CR,LF
  .byte "F10 BACK TO THE MENU",CR,LF,CR,LF
  .byte "ARROWS SEND ESC[A B C D, DEL $7F",CR,LF,0

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; libraries

 .include "lib/keys.asm"
 .include "lib/vtext.asm"
 .include "lib/num.asm"
 .include "lib/docs.asm"
 .include "lib/stream.asm"
 .include "lib/ui.asm"

CODE_END:
