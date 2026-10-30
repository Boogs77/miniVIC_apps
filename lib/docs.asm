;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;                                                              ;
;   DOCS.ASM  -  documents in the SD document area             ;
;                                                              ;
;   Sector 16384 ($00800000, after the 255 program blocks)     ;
;   is the index: +0 "DOCS", +4 version 1, +5 slots (15);      ;
;   entry k (1-15) at k*32: +0 type (0 free, 1 text,           ;
;   2 sheet, 3 card file),                                     ;
;   +1/+2 length, +4..+15 name (12 chars, $00 padded).         ;
;   Document k = 40 sectors (20 KB) from sector 16384 + k*40.  ;
;   Sectors go through the BIOS (JT_SD_READ / JT_SD_WRITE).    ;
;   Uses: zp $AA-$AF, $B8-$BA, RAM $0600-$07FF (index sector)  ;
;                                                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

DOC_IDX     = $0600    ; index sector (512 bytes)
DOC_BASE    = $4000    ; sector 16384
DOC_SLOTS   = 15
DOC_SECTS   = 40       ; sectors per document
DOC_NAMELEN = 12
DOC_E       = $AA      ; 2 bytes: pointer to the index entry
DOC_K       = $AC      ; slot
DOC_I       = $AD      ; sector inside the document
DOC_N       = $AE      ; sectors to transfer
DOC_PG      = $AF      ; RAM page of the transfer
DOC_T       = $B8      ; document type of the application (1 text, 2 sheet, 3 card file)
DOC_LEN     = $B9      ; 2 bytes: length for DOC_SETENT

; DOC_RDIDX: reads the index; a sector without "DOCS" becomes an empty index. C=1 SD error
DOC_RDIDX:
  JSR DOC_LBA0
  LDX #<DOC_IDX
  LDY #>DOC_IDX
  JSR JT_SD_READ
  BCS .dr_x
  LDX #3
.dr_m:
  LDA DOC_IDX,X
  CMP DOC_MAGIC,X
  BNE .dr_new
  DEX
  BPL .dr_m
  CLC
.dr_x:
  RTS
.dr_new:
  LDX #0
.dr_z:
  STZ DOC_IDX,X
  STZ DOC_IDX+$100,X
  INX
  BNE .dr_z
  LDX #5
.dr_h:
  LDA DOC_MAGIC,X
  STA DOC_IDX,X
  DEX
  BPL .dr_h
  CLC
  RTS

; DOC_WRIDX: writes the index. C=1 SD error
DOC_WRIDX:
  JSR DOC_LBA0
  LDX #<DOC_IDX
  LDY #>DOC_IDX
  JMP JT_SD_WRITE

; DOC_ENTRY: A = slot (1-15) -> DOC_E = its index entry. Keeps X, Y
DOC_ENTRY:
  STA DOC_K
  LSR
  LSR
  LSR
  CLC
  ADC #>DOC_IDX
  STA DOC_E+1
  LDA DOC_K
  ASL
  ASL
  ASL
  ASL
  ASL
  STA DOC_E              ; (DOC_IDX is page aligned)
  RTS

; DOC_FIND: name of 12 bytes at (DOC_P) and type DOC_T -> C=0 and A = slot, C=1 not found
DOC_P       = VT_P     ; (shares the string pointer)
DOC_FIND:
  LDA #1
.df_k:
  PHA
  JSR DOC_ENTRY
  LDY #0
  LDA (DOC_E),Y
  CMP DOC_T
  BNE .df_n              ; free or another type
  LDY #DOC_NAMELEN-1
.df_c:
  LDA (DOC_P),Y
  STA DOC_I              ; (temporary)
  INY                    ; name in the entry at +4
  INY
  INY
  INY
  LDA (DOC_E),Y
  CMP DOC_I
  BNE .df_n
  DEY                    ; back to the previous character
  DEY
  DEY
  DEY
  DEY
  BPL .df_c
  PLA
  CLC
  RTS
.df_n:
  PLA
  INC A
  CMP #DOC_SLOTS+1
  BNE .df_k
  SEC
  RTS

; DOC_FREE: C=0 and A = first free slot, C=1 index full
DOC_FREE:
  LDA #1
.dfr_k:
  JSR DOC_ENTRY
  LDY #0
  LDA (DOC_E),Y
  BEQ .dfr_y
  LDA DOC_K
  INC A
  CMP #DOC_SLOTS+1
  BNE .dfr_k
  SEC
  RTS
.dfr_y:
  LDA DOC_K
  CLC
  RTS

; DOC_SETENT: entry of slot A = type DOC_T, length DOC_LEN, name (DOC_P) (12 bytes)
DOC_SETENT:
  JSR DOC_ENTRY
  LDY #0
  LDA DOC_T
  STA (DOC_E),Y
  INY
  LDA DOC_LEN
  STA (DOC_E),Y
  INY
  LDA DOC_LEN+1
  STA (DOC_E),Y
  INY
  LDA #0
  STA (DOC_E),Y
  LDY #0                 ; name: (DOC_P)+0..11 -> entry +4..15
.dse_n:
  LDA (DOC_P),Y
  INY
  INY
  INY
  INY
  STA (DOC_E),Y
  DEY
  DEY
  DEY
  CPY #DOC_NAMELEN
  BNE .dse_n
  RTS

; DOC_SECT: SD_LBA = DOC_BASE + DOC_K*40 + DOC_I
DOC_SECT:
  STZ SD_LBA+2
  STZ SD_LBA+3
  LDA DOC_K
  STA SD_LBA
  STZ SD_LBA+1
  ASL SD_LBA             ; k*8
  ROL SD_LBA+1
  ASL SD_LBA
  ROL SD_LBA+1
  ASL SD_LBA
  ROL SD_LBA+1
  LDA SD_LBA+1           ; + k*32 = 4 * (k*8)
  PHA
  LDA SD_LBA
  PHA
  ASL SD_LBA
  ROL SD_LBA+1
  ASL SD_LBA
  ROL SD_LBA+1
  CLC
  PLA
  ADC SD_LBA
  STA SD_LBA
  PLA
  ADC SD_LBA+1
  STA SD_LBA+1
  CLC
  LDA SD_LBA
  ADC DOC_I
  STA SD_LBA
  LDA SD_LBA+1
  ADC #>DOC_BASE
  STA SD_LBA+1
  RTS

DOC_LBA0:
  STZ SD_LBA
  LDA #>DOC_BASE
  STA SD_LBA+1
  STZ SD_LBA+2
  STZ SD_LBA+3
  RTS

; DOC_XFER: DOC_K = slot, A = RAM page of the data, X/Y = length (lo/hi), C=0 read, C=1 write
; Transfers ceil(length / 512) sectors. C=1 SD error
DOC_XFER:
  STA DOC_PG
  PHP
  TXA                    ; sectors = (length + 511) / 512
  CLC
  ADC #$FF
  TYA
  ADC #$01
  LSR
  STA DOC_N
  STZ DOC_I
  PLP
  BCS .dx_w
.dx_r:
  LDA DOC_I
  CMP DOC_N
  BCS .dx_ok
  JSR DOC_SECT
  LDX #0
  LDY DOC_PG
  JSR JT_SD_READ
  BCS .dx_x
  JSR .dx_next
  BRA .dx_r
.dx_w:
  LDA DOC_I
  CMP DOC_N
  BCS .dx_ok
  JSR DOC_SECT
  LDX #0
  LDY DOC_PG
  JSR JT_SD_WRITE
  BCS .dx_x
  JSR .dx_next
  BRA .dx_w
.dx_ok:
  CLC
.dx_x:
  RTS
.dx_next:
  INC DOC_I
  INC DOC_PG
  INC DOC_PG
  JMP KB_POLL

DOC_MAGIC:
  .byte "DOCS",1,DOC_SLOTS
