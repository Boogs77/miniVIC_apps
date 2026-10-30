;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                                              ;
;   FIX32.ASM  -  fixed point numbers: 32-bit signed x 100     ;
;                                                              ;
;   A number is an integer of hundredths: 1234 = 12.34, range  ;
;   -21474836.47 .. 21474836.47. No floating point: + - * /    ;
;   with shift and add, results truncated. Every routine that  ;
;   can fail returns C=1 (overflow, division by zero, bad      ;
;   number). The accumulator is FA, the operand FB.            ;
;   Uses: zp $C0-$E3, RAM $05F0-$05FF (F_OUT)                  ;
;                                                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

FA          = $C0      ; 4 bytes, little endian
FB          = $C4      ; 4 bytes
FP          = $C8      ; 8 bytes: product / dividend, then quotient
FR          = $D0      ; 4 bytes: remainder
FS          = $D4      ; sign of the result (1 = negative)
FD          = $D5      ; decimals read by F_PARSE ($FF = no point)
FT          = $D6      ; 8-bit divisor
F_PTR       = $D7      ; 2 bytes: text read by F_PARSE
FX          = $D9      ; 4 bytes: temporary
FBCD        = $DD      ; 5 bytes: BCD digits of F_FMT ($DD = lowest 2)
FY          = $E2      ; 2 bytes (plus FX): saved divisor
F_OUT       = $05F0    ; F_FMT result (up to 13 characters + $00)

; F_ZERO: FA = 0
F_ZERO:
  STZ FA
  STZ FA+1
  STZ FA+2
  STZ FA+3
  RTS

; F_ISZ: Z=1 if FA = 0
F_ISZ:
  LDA FA
  ORA FA+1
  ORA FA+2
  ORA FA+3
  RTS

; F_NEG / F_NEGB: FA = -FA / FB = -FB
F_NEG:
  SEC
  LDA #0
  SBC FA
  STA FA
  LDA #0
  SBC FA+1
  STA FA+1
  LDA #0
  SBC FA+2
  STA FA+2
  LDA #0
  SBC FA+3
  STA FA+3
  RTS
F_NEGB:
  SEC
  LDA #0
  SBC FB
  STA FB
  LDA #0
  SBC FB+1
  STA FB+1
  LDA #0
  SBC FB+2
  STA FB+2
  LDA #0
  SBC FB+3
  STA FB+3
  RTS

; F_ADD / F_SUB: FA = FA + FB / FA - FB. C=1 overflow
F_ADD:
  CLC
  LDA FA
  ADC FB
  STA FA
  LDA FA+1
  ADC FB+1
  STA FA+1
  LDA FA+2
  ADC FB+2
  STA FA+2
  LDA FA+3
  ADC FB+3
  STA FA+3
  BVS F_ERR
  CLC
  RTS
F_SUB:
  SEC
  LDA FA
  SBC FB
  STA FA
  LDA FA+1
  SBC FB+1
  STA FA+1
  LDA FA+2
  SBC FB+2
  STA FA+2
  LDA FA+3
  SBC FB+3
  STA FA+3
  BVS F_ERR
  CLC
  RTS
F_ERR:
  SEC
  RTS

; F_CMP: compares FA with FB (signed). C=1 if FA >= FB, Z=1 if equal
F_CMP:
  LDA FA
  CMP FB
  BNE .fc_ne
  LDA FA+1
  CMP FB+1
  BNE .fc_ne
  LDA FA+2
  CMP FB+2
  BNE .fc_ne
  LDA FA+3
  CMP FB+3
  BEQ .fc_x              ; equal: Z=1, C=1
.fc_ne:
  SEC                    ; signed compare of the whole numbers
  LDA FA
  SBC FB
  LDA FA+1
  SBC FB+1
  LDA FA+2
  SBC FB+2
  LDA FA+3
  SBC FB+3
  BVC .fc_v
  EOR #$80
.fc_v:
  ASL                    ; C = sign of the difference
  LDA #1                 ; Z=0
  BCC .fc_ge
  CLC                    ; negative: FA < FB
  RTS
.fc_ge:
  SEC
.fc_x:
  RTS

; F_SIGNS: FA and FB made positive, FS = 1 if exactly one was negative
F_SIGNS:
  STZ FS
  LDA FA+3
  BPL .fs_b
  JSR F_NEG
  INC FS
.fs_b:
  LDA FB+3
  BPL .fs_x
  JSR F_NEGB
  LDA FS
  EOR #1
  STA FS
.fs_x:
  RTS

; F_SIGNR: FA = FP (low 32 bits) with the sign FS; C=1 if FP does not fit in 31 bits
F_SIGNR:
  LDA FP+4
  ORA FP+5
  ORA FP+6
  ORA FP+7
  BNE F_ERR
  LDA FP+3
  BMI F_ERR
  STA FA+3
  LDA FP+2
  STA FA+2
  LDA FP+1
  STA FA+1
  LDA FP
  STA FA
  LDA FS
  BEQ .sr_x
  JSR F_NEG
.sr_x:
  CLC
  RTS

; MUL32: FP = FA * FB (unsigned, 64 bits)
MUL32:
  LDA FA
  STA FP
  LDA FA+1
  STA FP+1
  LDA FA+2
  STA FP+2
  LDA FA+3
  STA FP+3
  STZ FP+4
  STZ FP+5
  STZ FP+6
  STZ FP+7
  LDX #32
.m_l:
  LDA FP
  LSR
  BCC .m_r
  CLC
  LDA FP+4
  ADC FB
  STA FP+4
  LDA FP+5
  ADC FB+1
  STA FP+5
  LDA FP+6
  ADC FB+2
  STA FP+6
  LDA FP+7
  ADC FB+3
  STA FP+7
.m_r:
  ROR FP+7
  ROR FP+6
  ROR FP+5
  ROR FP+4
  ROR FP+3
  ROR FP+2
  ROR FP+1
  ROR FP
  DEX
  BNE .m_l
  RTS

; DIVP8: FP = FP / FT (FT < 128), FR = remainder
DIVP8:
  STZ FR
  LDX #64
.d8_l:
  ASL FP
  ROL FP+1
  ROL FP+2
  ROL FP+3
  ROL FP+4
  ROL FP+5
  ROL FP+6
  ROL FP+7
  ROL FR
  LDA FR
  CMP FT
  BCC .d8_n
  SBC FT
  STA FR
  INC FP
.d8_n:
  DEX
  BNE .d8_l
  RTS

; DIV64: FP = FP / FB (FB > 0, < 2^31), FR = remainder
DIV64:
  STZ FR
  STZ FR+1
  STZ FR+2
  STZ FR+3
  LDX #64
.dv_l:
  ASL FP
  ROL FP+1
  ROL FP+2
  ROL FP+3
  ROL FP+4
  ROL FP+5
  ROL FP+6
  ROL FP+7
  ROL FR
  ROL FR+1
  ROL FR+2
  ROL FR+3
  SEC
  LDA FR
  SBC FB
  STA FX
  LDA FR+1
  SBC FB+1
  STA FX+1
  LDA FR+2
  SBC FB+2
  STA FX+2
  LDA FR+3
  SBC FB+3
  BCC .dv_n
  STA FR+3
  LDA FX+2
  STA FR+2
  LDA FX+1
  STA FR+1
  LDA FX
  STA FR
  INC FP
.dv_n:
  DEX
  BNE .dv_l
  RTS

; F_MUL: FA = FA * FB / 100. C=1 overflow
F_MUL:
  JSR F_SIGNS
  JSR MUL32
  LDA #100
  STA FT
  JSR DIVP8
  JMP F_SIGNR

; F_DIV: FA = FA * 100 / FB. C=1 division by zero or overflow
F_DIV:
  LDA FB
  ORA FB+1
  ORA FB+2
  ORA FB+3
  BNE .fb9
  JMP F_ERR
.fb9:
  JSR F_SIGNS
  LDA FB                 ; keep the divisor, FA * 100 first
  STA FX
  LDA FB+1
  STA FX+1
  LDA FB+2
  STA FY
  LDA FB+3
  STA FY+1
  LDA #100
  STA FB
  STZ FB+1
  STZ FB+2
  STZ FB+3
  JSR MUL32
  LDA FX
  STA FB
  LDA FX+1
  STA FB+1
  LDA FY
  STA FB+2
  LDA FY+1
  STA FB+3
  JSR DIV64
  JMP F_SIGNR

; F_INT: FA without the decimals (towards zero)
F_INT:
  STZ FS
  LDA FA+3
  BPL .fi_p
  JSR F_NEG
  INC FS
.fi_p:
  JSR F_TOFP
  LDA #100
  STA FT
  JSR DIVP8
  LDA #100               ; then x 100 again
  STA FB
  STZ FB+1
  STZ FB+2
  STZ FB+3
  LDA FP
  STA FA
  LDA FP+1
  STA FA+1
  LDA FP+2
  STA FA+2
  LDA FP+3
  STA FA+3
  JSR MUL32
  JMP F_SIGNR

; F_TOFP: FP = FA (64 bits)
F_TOFP:
  LDA FA
  STA FP
  LDA FA+1
  STA FP+1
  LDA FA+2
  STA FP+2
  LDA FA+3
  STA FP+3
  STZ FP+4
  STZ FP+5
  STZ FP+6
  STZ FP+7
  RTS

; MUL10: FA = FA * 10 (FA >= 0). C=1 overflow
MUL10:
  ASL FA
  ROL FA+1
  ROL FA+2
  ROL FA+3
  BMI .m10_e
  LDA FA
  STA FX
  LDA FA+1
  STA FX+1
  LDA FA+2
  STA FX+2
  LDA FA+3
  STA FX+3
  ASL FA
  ROL FA+1
  ROL FA+2
  ROL FA+3
  BMI .m10_e
  ASL FA
  ROL FA+1
  ROL FA+2
  ROL FA+3
  BMI .m10_e
  CLC
  LDA FA
  ADC FX
  STA FA
  LDA FA+1
  ADC FX+1
  STA FA+1
  LDA FA+2
  ADC FX+2
  STA FA+2
  LDA FA+3
  ADC FX+3
  STA FA+3
  BMI .m10_e
  CLC
  RTS
.m10_e:
  SEC
  RTS

; F_PARSE: number at (F_PTR),Y (digits, optional point, up to 2 decimals; more are
; dropped) -> FA, Y after it. C=1 no digit or overflow
F_PARSE:
  JSR F_ZERO
  LDA #$FF
  STA FD
  STZ FS                 ; digits seen
.fp_l:
  LDA (F_PTR),Y
  CMP #'.'
  BEQ .fp_pt
  CMP #'0'
  BCC .fp_e
  CMP #'9'+1
  BCS .fp_e
  INC FS
  LDX FD
  CPX #2
  BEQ .fp_n              ; a third decimal: dropped
  AND #$0F
  PHA
  JSR MUL10
  PLA
  BCS .fp_x
  CLC
  ADC FA
  STA FA
  BCC .fp_d
  INC FA+1
  BNE .fp_d
  INC FA+2
  BNE .fp_d
  INC FA+3
  BMI .fp_o
.fp_d:
  LDX FD
  BMI .fp_n
  INC FD
.fp_n:
  INY
  BRA .fp_l
.fp_pt:
  LDX FD
  BPL .fp_e              ; a second point ends the number
  STZ FD
  INY
  BRA .fp_l
.fp_e:
  LDA FS
  BEQ .fp_o
  LDA FD                 ; scale to hundredths
  CMP #2
  BEQ .fp_ok
  CMP #1
  BEQ .fp_1
  JSR MUL10
  BCS .fp_x
.fp_1:
  JSR MUL10
  BCS .fp_x
.fp_ok:
  CLC
.fp_x:
  RTS
.fp_o:
  SEC
  RTS

; F_FMT: FA -> F_OUT (text, $00 at the end), A = length. "1234", "-12.5" is "-12.50"
F_FMT:
  STZ FS
  LDA FA+3
  BPL .ff_p
  JSR F_NEG
  INC FS
.ff_p:
  JSR F_TOFP
  LDA FS
  BEQ .ff_a
  JSR F_NEG              ; FA back as it was
.ff_a:
  LDA #100
  STA FT
  JSR DIVP8              ; FP = integer part, FR = hundredths
  STZ FBCD
  STZ FBCD+1
  STZ FBCD+2
  STZ FBCD+3
  STZ FBCD+4
  LDX #32
  SED
.ff_b:
  ASL FP
  ROL FP+1
  ROL FP+2
  ROL FP+3
  LDA FBCD
  ADC FBCD
  STA FBCD
  LDA FBCD+1
  ADC FBCD+1
  STA FBCD+1
  LDA FBCD+2
  ADC FBCD+2
  STA FBCD+2
  LDA FBCD+3
  ADC FBCD+3
  STA FBCD+3
  LDA FBCD+4
  ADC FBCD+4
  STA FBCD+4
  DEX
  BNE .ff_b
  CLD
  LDY #0
  LDA FS
  BEQ .ff_d
  LDA #'-'
  STA F_OUT
  INY
.ff_d:
  STZ FD                 ; 1 once a digit is written
  LDX #4
.ff_dl:
  LDA FBCD,X
  LSR
  LSR
  LSR
  LSR
  JSR .ff_dig
  LDA FBCD,X
  AND #$0F
  CPX #0
  BNE .ff_dn
  INC FD                 ; the units digit is always written
.ff_dn:
  JSR .ff_dig
  DEX
  BPL .ff_dl
  LDA FR
  BEQ .ff_z
  LDA #'.'
  STA F_OUT,Y
  INY
  LDA FR                 ; two decimals
  LDX #'0'
.ff_t:
  CMP #10
  BCC .ff_u
  SBC #10
  INX
  BRA .ff_t
.ff_u:
  ORA #'0'
  PHA
  TXA
  STA F_OUT,Y
  INY
  PLA
  STA F_OUT,Y
  INY
.ff_z:
  LDA #0
  STA F_OUT,Y
  TYA
  RTS
.ff_dig:
  CMP #0
  BNE .ff_w
  LDA FD
  BEQ .ff_s
  LDA #0
.ff_w:
  ORA #'0'
  STA F_OUT,Y
  INY
  LDA #1
  STA FD
.ff_s:
  RTS
