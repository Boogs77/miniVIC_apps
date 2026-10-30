;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                                              ;
;   STREAM.ASM  -  a document written / read byte by byte      ;
;                                                              ;
;   Through a 512-byte sector buffer, one sector at a time,    ;
;   in the slot DOC_K of the document area (lib/docs.asm).     ;
;   Uses: zp $E4-$EB, RAM $0800-$09FF (ST_BUF)                 ;
;                                                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

ST_BUF      = $0800    ; sector buffer (page aligned)
ST_POS      = $E4      ; 2 bytes: position in ST_BUF
ST_SEC      = $E6      ; sector of the document
ST_LEFT     = $E7      ; 2 bytes: bytes still to read
ST_ERR      = $E9      ; 1 = SD error or too big
ST_P        = $EA      ; 2 bytes

; ST_WOPEN: start writing the document DOC_K
ST_WOPEN:
  STZ ST_POS
  STZ ST_POS+1
  STZ ST_SEC
  STZ ST_ERR
  RTS

; ST_PUT: A to the document. Keeps A, X, Y
ST_PUT:
  PHA
  PHX
  PHY
  PHA
  LDA ST_POS
  STA ST_P
  LDA ST_POS+1
  CLC
  ADC #>ST_BUF
  STA ST_P+1
  PLA
  STA (ST_P)
  INC ST_POS
  BNE .sp_x
  INC ST_POS+1
  LDA ST_POS+1
  CMP #2
  BNE .sp_x
  JSR ST_FLUSH
.sp_x:
  PLY
  PLX
  PLA
  RTS

; ST_FLUSH: the buffer (ST_POS bytes) to sector ST_SEC, then an empty buffer
ST_FLUSH:
  LDA ST_POS
  ORA ST_POS+1
  BEQ .sf_x
  LDA ST_SEC
  CMP #DOC_SECTS
  BCS .sf_big
  STA DOC_I
  JSR DOC_SECT
  LDX #<ST_BUF
  LDY #>ST_BUF
  JSR JT_SD_WRITE
  BCC .sf_n
.sf_big:
  LDA #1
  STA ST_ERR
.sf_n:
  INC ST_SEC
  STZ ST_POS
  STZ ST_POS+1
.sf_x:
  RTS

; ST_WCLOSE: the last part; DOC_LEN = length. C=1 SD error or more than 20 KB
ST_WCLOSE:
  LDA ST_SEC             ; length = sectors * 512 + position
  ASL
  CLC
  ADC ST_POS+1
  STA DOC_LEN+1
  LDA ST_POS
  STA DOC_LEN
  JSR ST_FLUSH
  LDA ST_ERR
  CMP #1                 ; C=1 if ST_ERR
  RTS

; ST_ROPEN: start reading the document DOC_K of DOC_LEN bytes
ST_ROPEN:
  LDA DOC_LEN
  STA ST_LEFT
  LDA DOC_LEN+1
  STA ST_LEFT+1
  STZ ST_SEC
  STZ ST_ERR
  LDA #2                 ; (buffer empty: the first ST_GET reads a sector)
  STA ST_POS+1
  STZ ST_POS
  RTS

; ST_GET: A = next byte, C=1 at the end (ST_ERR = 1 if the SD failed). Keeps X, Y
ST_GET:
  LDA ST_LEFT
  ORA ST_LEFT+1
  BEQ .sg_end
  PHX
  PHY
  LDA ST_POS+1
  CMP #2
  BCC .sg_b
  LDA ST_SEC             ; next sector
  STA DOC_I
  JSR DOC_SECT
  LDX #<ST_BUF
  LDY #>ST_BUF
  JSR JT_SD_READ
  BCS .sg_err
  INC ST_SEC
  STZ ST_POS
  STZ ST_POS+1
.sg_b:
  LDA ST_POS
  STA ST_P
  LDA ST_POS+1
  CLC
  ADC #>ST_BUF
  STA ST_P+1
  INC ST_POS
  BNE .sg_d
  INC ST_POS+1
.sg_d:
  LDA ST_LEFT
  BNE .sg_l
  DEC ST_LEFT+1
.sg_l:
  DEC ST_LEFT
  LDA (ST_P)
  PLY
  PLX
  CLC
  RTS
.sg_err:
  PLY
  PLX
  LDA #1
  STA ST_ERR
  STZ ST_LEFT
  STZ ST_LEFT+1
.sg_end:
  SEC
  RTS
