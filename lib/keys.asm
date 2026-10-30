;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                                              ;
;   KEYS.ASM  -  key queue on top of the BIOS                  ;
;                                                              ;
;   The PS/2 board keeps one byte: a byte not read within      ;
;   ~1 ms is lost (a lost $F0 turns a release into a second    ;
;   press). Two ways in, both on: the CA1 interrupt of the     ;
;   keyboard VIA (IRQ -> BIOS -> JMP KB_IRQ at $0FA0) reads    ;
;   every byte at once; KB_POLL, called by the long loops,     ;
;   does the same if the IRQ line is not there. Assembled      ;
;   with -DKB_NOIRQ=1 only the polling is left.                ;
;   The keys decoded by the BIOS go into a 32-key queue,       ;
;   GETKEY takes them out. KB_EXIT before leaving the app.     ;
;   An app that uses the serial line itself defines KB_SERBUF  ;
;   (256-byte ring): the received bytes go there, not among    ;
;   the keys (JT_CHRIN reads the serial line first: a byte it  ;
;   returns while CA1 is still set came from the serial line). ;
;   Uses: zp $A0-$A1 ($F0-$F1 with KB_SERBUF), RAM $05C0-$05DF ;
;                                                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

KQ          = $05C0    ; 32-key ring
KQ_MASK     = $1F
KQR         = $A0      ; read index
KQW         = $A1      ; write index
KB_IFR      = $D18D    ; keyboard VIA: interrupt flags (bit 1 = CA1)
KB_IER      = $D18E    ;               interrupt enable
KB_SRR      = $F0      ; serial ring (KB_SERBUF): read index
KB_SRW      = $F1      ;                          write index

; KB_INIT: extended keyboard, empty queue, CA1 interrupt on
KB_INIT:
  SEI
  LDA #1
  JSR JT_KB_MODE
  STZ KQR
  STZ KQW
  STZ KB_SRR
  STZ KB_SRW
 .ifndef KB_NOIRQ
  LDA #$4C               ; JMP KB_IRQ in the RAM vector of the BIOS
  STA IRQ_VEC
  LDA #<KB_IRQ
  STA IRQ_VEC+1
  LDA #>KB_IRQ
  STA IRQ_VEC+2
  LDA #$82               ; CA1 interrupt enabled
  STA KB_IER
  CLI
 .endif
  RTS

; KB_EXIT: interrupt off again (the BIOS menu works by polling)
KB_EXIT:
  SEI
  LDA #$02
  STA KB_IER
  LDA #$60               ; RTS
  STA IRQ_VEC
  RTS

; KB_IRQ: called by the BIOS IRQ handler (A, X, Y already saved)
KB_IRQ:
 .ifdef KB_SERBUF
  JMP KB_TAKE            ; the keyboard or the serial line
 .else
  LDA KB_IFR
  AND #$02
  BEQ .ki_x
  JSR KB_TAKE
.ki_x:
  RTS
 .endif

; KB_POLL: one BIOS poll with the interrupt held off. Keeps A, X, Y and the I flag
KB_POLL:
  PHP
  SEI
  PHA
  PHX
  PHY
  JSR KB_TAKE
  PLY
  PLX
  PLA
  PLP
  RTS

; KB_TAKE: a key from the BIOS goes into the queue (full queue: dropped)
KB_TAKE:
 .ifdef KB_SERBUF
.kt_rx:
  LDA ACIA_STATUS        ; received bytes first, into their ring
  AND #$08
  BEQ .kt_kb
  LDA ACIA_DATA
  JSR KB_SERPUT
  BRA .kt_rx
.kt_kb:
  LDA KB_IFR
  AND #$02
  BEQ .kt_x
  JSR JT_CHRIN
  BCC .kt_x
  PHA
  LDA KB_IFR             ; CA1 still set: the BIOS took a serial byte, not the key
  AND #$02
  BEQ .kt_key
  PLA
  JSR KB_SERPUT
  BRA .kt_rx
.kt_key:
  PLA
 .else
  JSR JT_CHRIN
  BCC .kt_x
 .endif
  LDX KQW
  STA KQ,X
  TXA
  INC A
  AND #KQ_MASK
  CMP KQR
  BEQ .kt_x              ; full
  STA KQW
.kt_x:
  RTS

 .ifdef KB_SERBUF
; KB_SERPUT: A into the serial ring (full: dropped)
KB_SERPUT:
  LDX KB_SRW
  STA KB_SERBUF,X
  INX
  CPX KB_SRR
  BEQ .ks_x
  STX KB_SRW
.ks_x:
  RTS

; SERGET: C=1 and A = next received byte, C=0 none
SERGET:
  JSR KB_POLL
  LDX KB_SRR
  CPX KB_SRW
  BEQ .sg_n
  LDA KB_SERBUF,X
  INC KB_SRR
  SEC
  RTS
.sg_n:
  CLC
  RTS
 .endif

; GETKEY: C=1 and A = key, C=0 queue empty (after one poll). Keeps X, Y
GETKEY:
  JSR KB_POLL
  LDA KQR
  CMP KQW
  BEQ .gk_n
  PHX
  TAX
  LDA KQ,X
  PHA
  TXA
  INC A
  AND #KQ_MASK
  STA KQR
  PLA
  PLX
  SEC
  RTS
.gk_n:
  CLC
  RTS

; WAITKEY: A = next key
WAITKEY:
  JSR GETKEY
  BCC WAITKEY
  RTS

; KEYREADY: C=1 if a key is waiting in the queue
KEYREADY:
  JSR KB_POLL
  LDA KQR
  CMP KQW
  CLC
  BEQ .kr_x
  SEC
.kr_x:
  RTS
