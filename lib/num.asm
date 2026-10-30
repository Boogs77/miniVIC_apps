;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                                              ;
;   NUM.ASM  -  16-bit numbers to decimal text                 ;
;   Uses: zp $A5-$A9                                           ;
;                                                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

NUM         = $A5      ; 2 bytes: number to convert (destroyed)
BCD         = $A7      ; 3 bytes: BCD result, $A7 = lowest 2 digits

; BIN2BCD: NUM -> BCD (double dabble with decimal mode)
BIN2BCD:
  JSR KB_POLL
  STZ BCD
  STZ BCD+1
  STZ BCD+2
  LDX #16
  SED
.bb_l:
  ASL NUM
  ROL NUM+1
  LDA BCD
  ADC BCD
  STA BCD
  LDA BCD+1
  ADC BCD+1
  STA BCD+1
  LDA BCD+2
  ADC BCD+2
  STA BCD+2
  DEX
  BNE .bb_l
  CLD
  RTS

; NUMSTR: NUM -> 5 characters at (VT_P),Y.. with leading spaces (last digit always shown)
; Y = first position; on exit Y = position after the number
NUMSTR:
  JSR BIN2BCD
  JSR KB_POLL            ; (BIN2BCD takes ~600 cycles)
  LDX #0                 ; X = 1 once a digit is not zero
  LDA BCD+2
  JSR .ns_dig            ; ten thousands
  LDA BCD+1
  LSR
  LSR
  LSR
  LSR
  JSR .ns_dig
  LDA BCD+1
  JSR .ns_dig
  LDA BCD
  LSR
  LSR
  LSR
  LSR
  JSR .ns_dig
  LDA BCD
  LDX #1                 ; the last digit is always written
.ns_dig:
  AND #$0F
  BNE .ns_nz
  CPX #0
  BNE .ns_nz
  LDA #' '
  BRA .ns_put
.ns_nz:
  LDX #1
  ORA #'0'
.ns_put:
  STA (VT_P),Y
  INY
  RTS
