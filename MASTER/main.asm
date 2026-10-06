;==============================================================================
; EIF205 - Proyecto II - Mastermind Alquimia (16-bit x86, mode 13h)
; File   : main.asm
; Phase  : 1  - Skeleton (video mode, generic sprite routine, clean exit)
;          1b - Theme sprites (potions, icons, frame, cauldron)
;          2a - Text drawn straight into video memory with the BIOS font
;          2b - Game screen: the four zones of the mockup, drawn from data
;
; Screen zones (from the assignment):
;   A. Header     (0,0)     320x20   title and level
;   B. Board      (4,22)    196x168  history: one 16 px row per attempt
;   C. Side panel (204,22)  112x168  potions, attempt counter, mascot
;   D. Status bar (0,190)   320x10   key help and messages
;==============================================================================

.MODEL SMALL
.STACK 200h

;------------------------------------------------------------------------------
; Constants
;------------------------------------------------------------------------------
TRANSPARENT     EQU 0           ; sprite color index that is never written
VIDEO_SEG       EQU 0A000h      ; mode 13h framebuffer segment
SCREEN_W        EQU 320
SCREEN_WORDS    EQU 32000       ; 64000 bytes / 2, for REP STOSW
CHAR_W          EQU 8           ; BIOS font cell: 8x8 pixels
CHAR_H          EQU 8

MAX_POS         EQU 5           ; hardest level: 5 positions
MAX_TRIES       EQU 12          ; easiest level: 12 attempts
ROWS_SHOWN      EQU 10          ; rows that fit on the board (zone B)

POTION_W        EQU 16          ; every potion sprite is 16x16
POTION_H        EQU 16

; ---- Zone B layout ----
BOARD_X         EQU 4
BOARD_Y         EQU 22
BOARD_W         EQU 196
BOARD_H         EQU 168
BOARD_Y0        EQU 26          ; y of the first row
ROW_H           EQU 16          ; one row per attempt
ROWNUM_X        EQU 8           ; "01".."10"
SLOT_X0         EQU 30          ; x of the first potion slot
SLOT_STEP       EQU 20          ; 16 px potion + 4 px gap
CHISPA_X        EQU 134         ; feedback: icon, digit, icon, digit
BULLS_X         EQU 144
BURBUJA_X       EQU 158
COWS_X          EQU 168

; ---- Zone C layout ----
PANEL_X         EQU 204
PANEL_Y         EQU 22
PANEL_W         EQU 112
PANEL_H         EQU 168
PANEL_COLS      EQU 4           ; potions per row in the panel

; ---- Colors (default VGA palette until our own palette exists) ----
BG_COLOR        EQU 0           ; black screen background
BAR_COLOR       EQU 1           ; header and status bar fill
FRAME_COLOR     EQU 7           ; zone borders
EMPTY_COLOR     EQU 8           ; empty slot boxes

;------------------------------------------------------------------------------
; MACRO DRAW_SPRITE
; Pushes the 5 parameters DibujarSprite expects and calls it.
; AX is saved and restored around the call so the caller loses nothing.
; Push order matters: it defines the [bp+n] offsets inside the PROC.
;------------------------------------------------------------------------------
DRAW_SPRITE MACRO px, py, pw, ph, pdata
    push ax
    mov  ax, px
    push ax
    mov  ax, py
    push ax
    mov  ax, pw
    push ax
    mov  ax, ph
    push ax
    mov  ax, OFFSET pdata
    push ax
    call DibujarSprite          ; callee removes the 5 params (RET 10)
    pop  ax
ENDM

;------------------------------------------------------------------------------
; MACRO DRAW_TEXT
; Loads the registers DrawText expects and calls it.
; Every register it touches is saved and restored.
;------------------------------------------------------------------------------
DRAW_TEXT MACRO px, py, pcolor, pmsg
    push bx
    push cx
    push dx
    push si
    mov  bx, px
    mov  dx, py
    mov  cl, pcolor
    mov  si, OFFSET pmsg
    call DrawText
    pop  si
    pop  dx
    pop  cx
    pop  bx
ENDM

;------------------------------------------------------------------------------
; MACRO WAIT_KEY - block until any key is pressed, discard it
;------------------------------------------------------------------------------
WAIT_KEY MACRO
    push ax
    mov  ah, 00h
    int  16h                    ; BIOS keyboard: wait and read key
    pop  ax
ENDM

.DATA
oldVideoMode    db ?            ; mode active before we switched to 13h
targetSeg       dw VIDEO_SEG    ; where drawing goes
fontSeg         dw ?            ; BIOS 8x8 font address (set by InitFont)
fontOff         dw ?

; ---- Game state (demo values until the keyboard phase) ----
levelIdx        db 1            ; 0 easy, 1 normal, 2 hard
numPos          db 4            ; positions per code
numColors       db 6            ; potions in play
numTries        db 10           ; attempts allowed
triesUsed       db 2            ; attempts already evaluated
cursorPos       db 1            ; active slot in the row being built

; History: row r, position p is history[r*MAX_POS + p]; 0 = empty
history         db 1,3,5,6,0
                db 2,2,4,6,0
                db (MAX_TRIES-2)*MAX_POS dup(0)
historyBulls    db 1,0, (MAX_TRIES-2) dup(0)
historyCows     db 2,1, (MAX_TRIES-2) dup(0)
currentGuess    db 4,0,0,0,0    ; row being built; 0 = slot not chosen yet
emptyCode       db MAX_POS dup(0)   ; used for rows not reached yet

; ---- Texts (0-terminated, no accents: the font only has ASCII) ----
txtTitle        db 'MASTERMIND - ALQUIMIA', 0
txtLvl0         db 'NIVEL: FACIL', 0
txtLvl1         db 'NIVEL: NORMAL', 0
txtLvl2         db 'NIVEL: DIFICIL', 0
levelNameTable  dw OFFSET txtLvl0, OFFSET txtLvl1, OFFSET txtLvl2
txtStatus       db '<> POSICION  1-6 COLOR  ENTER EVALUAR', 0
txtFichas       db 'FICHAS', 0
txtTry          db 'INTENTO', 0
txtBoil         db 'HIRVIENDO', 0

; ---- Sprite tables, generated by herramientas/sprite2db.py ----
INCLUDE frasco1.inc             ; round potion
INCLUDE frasco2.inc             ; tall thin potion
INCLUDE frasco3.inc             ; triangular potion
INCLUDE frasco4.inc             ; heart potion
INCLUDE frasco5.inc             ; square potion
INCLUDE frasco6.inc             ; skull potion
INCLUDE frasco7.inc             ; star potion
INCLUDE frasco8.inc             ; hourglass potion
INCLUDE chispa.inc              ; exact-hit icon
INCLUDE burbuja.inc             ; partial-hit icon
INCLUDE marco1.inc              ; selection frame, frame 1
INCLUDE marco2.inc              ; selection frame, frame 2
INCLUDE caldero1.inc            ; mascot, frame 1
INCLUDE caldero2.inc            ; mascot, frame 2

; Color number -> sprite. Entry k is the potion for color k+1.
potionTable     dw OFFSET frasco1, OFFSET frasco2, OFFSET frasco3
                dw OFFSET frasco4, OFFSET frasco5, OFFSET frasco6
                dw OFFSET frasco7, OFFSET frasco8

.CODE
;==============================================================================
; main - draw the game screen from the state variables
;==============================================================================
main PROC
    mov  ax, @data
    mov  ds, ax                 ; DS must reach our variables and tables

    call SaveVideoMode
    call SetMode13h
    call InitFont               ; find the BIOS letter shapes once

    call DrawBoard              ; zones A, B, D and the 10 rows
    call DrawPanel              ; zone C
    call DrawCursor             ; frame around the active slot

    WAIT_KEY

    call RestoreVideoMode
    call ExitToDos
main ENDP

;------------------------------------------------------------------------------
; SaveVideoMode
; Receives : nothing
; Returns  : oldVideoMode = current BIOS video mode
; Destroys : nothing
;------------------------------------------------------------------------------
SaveVideoMode PROC
    push ax
    push bx                     ; INT 10h/0Fh returns active page in BH
    mov  ah, 0Fh
    int  10h                    ; AL = current mode
    mov  oldVideoMode, al
    pop  bx
    pop  ax
    ret
SaveVideoMode ENDP

;------------------------------------------------------------------------------
; SetMode13h - switch to 320x200, 256 colors
; Receives : nothing
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
SetMode13h PROC
    push ax
    mov  ax, 0013h              ; AH=00h set mode, AL=13h
    int  10h
    pop  ax
    ret
SetMode13h ENDP

;------------------------------------------------------------------------------
; RestoreVideoMode - put back whatever mode DOS had before the game
; Receives : oldVideoMode
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
RestoreVideoMode PROC
    push ax
    mov  ah, 00h
    mov  al, oldVideoMode
    int  10h
    pop  ax
    ret
RestoreVideoMode ENDP

;------------------------------------------------------------------------------
; ClearScreen - fill the whole target surface with one color
; Receives : AL = palette index
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
ClearScreen PROC
    push ax
    push cx
    push di
    push es
    mov  es, targetSeg          ; ES -> surface we are drawing on
    xor  di, di                 ; start at pixel (0,0)
    mov  ah, al                 ; same color in both bytes: 2 pixels per STOSW
    mov  cx, SCREEN_WORDS
    cld                         ; DI must move forward
    rep  stosw
    pop  es
    pop  di
    pop  cx
    pop  ax
    ret
ClearScreen ENDP

;------------------------------------------------------------------------------
; FillRect - solid rectangle
; Receives : BX = x, DX = y, SI = width, DI = height, AL = color
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
FillRect PROC
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    mov  es, targetSeg          ; ES -> surface we are drawing on
    push ax                     ; MUL needs AX, keep the color
    mov  ax, dx
    mov  cx, SCREEN_W
    mul  cx                     ; AX = y*320 (DX destroyed, y < 200)
    add  ax, bx
    mov  bx, ax                 ; BX = offset of the top-left pixel
    pop  ax                     ; AL = color again
    mov  dx, di                 ; DX = rows left (DI is needed by STOSB)
    cld

FR_Row:
    mov  di, bx                 ; start of this row
    mov  cx, si                 ; width in pixels
    rep  stosb                  ; paint the whole row at once
    add  bx, SCREEN_W           ; next row, same x
    dec  dx
    jnz  FR_Row

    pop  es
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
FillRect ENDP

;------------------------------------------------------------------------------
; DrawFrame - 1 px rectangle outline, built from four thin FillRects
; Receives : BX = x, DX = y, SI = width, DI = height, AL = color
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
DrawFrame PROC
    push bx
    push dx
    push si
    push di

    ; Top edge: width x 1
    push di
    mov  di, 1
    call FillRect
    pop  di

    ; Bottom edge: same, at y + height - 1
    push dx
    push di
    add  dx, di
    dec  dx
    mov  di, 1
    call FillRect
    pop  di
    pop  dx

    ; Left edge: 1 x height
    push si
    mov  si, 1
    call FillRect
    pop  si

    ; Right edge: same, at x + width - 1
    push bx
    add  bx, si
    dec  bx
    mov  si, 1
    call FillRect
    pop  bx

    pop  di
    pop  si
    pop  dx
    pop  bx
    ret
DrawFrame ENDP

;------------------------------------------------------------------------------
; DibujarSprite - generic sprite blitter with transparency
; Receives (stack, pushed in this order):
;     X, Y, WIDTH, HEIGHT, SPRITE_PTR (offset in DS)
;   Frame after PUSH BP:
;     [bp+12]=X  [bp+10]=Y  [bp+8]=WIDTH  [bp+6]=HEIGHT  [bp+4]=SPRITE_PTR
; Returns  : nothing
; Destroys : nothing (removes its own 10 bytes of params with RET 10)
; Notes    : sprite bytes equal to TRANSPARENT are skipped, so the
;            background shows through. No clipping: caller keeps the
;            sprite inside the screen.
;------------------------------------------------------------------------------
DibujarSprite PROC
    push bp
    mov  bp, sp
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    mov  es, targetSeg          ; ES -> surface we are drawing on

    ; DI = Y*320 + X  (top-left pixel of the sprite)
    mov  ax, [bp+10]
    mov  bx, SCREEN_W
    mul  bx                     ; DX:AX = Y*320; DX is 0 because Y < 200
    add  ax, [bp+12]
    mov  di, ax

    mov  si, [bp+4]             ; SI walks the sprite table byte by byte
    mov  dx, [bp+6]             ; DX = rows still to draw
    cld                         ; LODSB must advance SI

DS_Row:
    mov  cx, [bp+8]             ; CX = pixels left in this row
DS_Col:
    lodsb                       ; AL = sprite pixel, SI moves to the next one
    cmp  al, TRANSPARENT
    je   DS_Skip                ; transparent: leave the background as is
    mov  es:[di], al
DS_Skip:
    inc  di
    loop DS_Col

    ; We are WIDTH pixels to the right of the row start; jump to the
    ; same X one line down.
    add  di, SCREEN_W
    sub  di, [bp+8]
    dec  dx
    jnz  DS_Row

    pop  es
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    pop  bp
    ret  10                     ; discard the 5 word parameters
DibujarSprite ENDP

;------------------------------------------------------------------------------
; DrawPotion - draw the potion sprite of a color number
; Receives : AL = color 1..8, BX = x, DX = y
; Returns  : nothing
; Destroys : nothing
; Notes    : looks the sprite up in potionTable instead of a chain of
;            comparisons, so adding a potion only means adding an entry
;------------------------------------------------------------------------------
DrawPotion PROC
    push ax
    push si

    xor  ah, ah
    dec  ax                     ; colors start at 1, the table at 0
    shl  ax, 1                  ; each entry is a word (2 bytes)
    mov  si, ax

    push bx                     ; X
    push dx                     ; Y
    mov  ax, POTION_W
    push ax                     ; WIDTH
    mov  ax, POTION_H
    push ax                     ; HEIGHT
    push potionTable[si]        ; SPRITE_PTR straight from the table
    call DibujarSprite

    pop  si
    pop  ax
    ret
DrawPotion ENDP

;------------------------------------------------------------------------------
; InitFont - remember where the BIOS keeps its 8x8 letter shapes
; Receives : nothing
; Returns  : fontSeg:fontOff -> 8 bytes per character, chars 0..127
; Destroys : nothing
; Notes    : INT 10h AX=1130h BH=03h only REPORTS the font address;
;            the drawing itself is done by DrawChar into video memory.
;------------------------------------------------------------------------------
InitFont PROC
    push ax
    push bx
    push cx
    push dx
    push bp
    push es
    mov  ax, 1130h              ; get font information
    mov  bh, 03h                ; which font: 8x8, characters 0..127
    int  10h                    ; ES:BP -> font table (also changes CX, DL)
    mov  fontSeg, es
    mov  fontOff, bp
    pop  es
    pop  bp
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
InitFont ENDP

;------------------------------------------------------------------------------
; DrawChar - draw one character with a transparent background
; Receives : AL = ASCII code (0..127), BX = x, DX = y, CL = color
; Returns  : nothing
; Destroys : nothing
; Notes    : each character is 8 bytes, one per row; in every byte
;            bit 7 is the leftmost pixel. A 1 bit gets CL, a 0 bit is
;            skipped, exactly like color 0 in DibujarSprite.
;------------------------------------------------------------------------------
DrawChar PROC
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es

    mov  es, targetSeg          ; ES -> surface we are drawing on

    ; DI = y*320 + x  (top-left pixel of the character cell)
    push ax                     ; MUL needs AX, keep the character
    mov  ax, dx
    mov  di, SCREEN_W
    mul  di                     ; AX = y*320 (DX destroyed, y < 200)
    add  ax, bx
    mov  di, ax
    pop  ax

    ; SI = fontOff + char*8  (first of the character's 8 rows)
    xor  ah, ah
    shl  ax, 1                  ; three single shifts = *8
    shl  ax, 1                  ; (the 8086 cannot SHL by 3 in one go)
    shl  ax, 1
    mov  si, fontOff
    add  si, ax

    mov  ah, cl                 ; AH = text color for the whole char
    mov  ds, fontSeg            ; DS -> font; our variables are not
                                ; needed again until DS is restored
    mov  dl, CHAR_H             ; DL = rows left

DC_Row:
    mov  al, [si]               ; AL = this row's 8 pixel bits
    inc  si
    mov  cx, CHAR_W
DC_Col:
    shl  al, 1                  ; next pixel bit goes into CF
    jnc  DC_Skip                ; bit 0: background stays visible
    mov  es:[di], ah
DC_Skip:
    inc  di
    loop DC_Col
    add  di, SCREEN_W - CHAR_W  ; same x, one line down
    dec  dl
    jnz  DC_Row

    pop  es
    pop  ds                     ; DS back to our data segment
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
DrawChar ENDP

;------------------------------------------------------------------------------
; DrawText - draw a 0-terminated string, left to right
; Receives : SI = offset of the string, BX = x, DX = y, CL = color
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
DrawText PROC
    push ax
    push bx
    push si
DT_Next:
    mov  al, [si]               ; next character
    cmp  al, 0
    je   DT_Done                ; 0 marks the end of the string
    call DrawChar
    add  bx, CHAR_W             ; next cell to the right
    inc  si
    jmp  DT_Next
DT_Done:
    pop  si
    pop  bx
    pop  ax
    ret
DrawText ENDP

;------------------------------------------------------------------------------
; DrawNumber2 - draw a value as two digits ("04", "10")
; Receives : AL = value 0..99, BX = x, DX = y, CL = color
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
DrawNumber2 PROC
    push ax
    push bx
    push cx

    xor  ah, ah
    mov  ch, 10
    div  ch                     ; AL = tens, AH = units
    push ax
    add  al, '0'
    call DrawChar               ; tens digit
    pop  ax
    mov  al, ah
    add  al, '0'
    add  bx, CHAR_W
    call DrawChar               ; units digit

    pop  cx
    pop  bx
    pop  ax
    ret
DrawNumber2 ENDP

;------------------------------------------------------------------------------
; DrawBoardRow - one row of zone B: number, potions or empty slots,
;                and bulls/cows if the row was already evaluated
; Receives : AL = row index 0..ROWS_SHOWN-1
;            triesUsed, numPos, history, historyBulls, historyCows,
;            currentGuess
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
DrawBoardRow PROC
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    xor  ah, ah
    mov  di, ax                 ; DI = row index, kept for the whole PROC

    ; DX = y of this row = BOARD_Y0 + row*16
    mov  cl, 4
    shl  ax, cl                 ; row * ROW_H (16 = 2^4)
    add  ax, BOARD_Y0
    mov  dx, ax

    ; Row number "01".."10" on the left
    mov  ax, di
    inc  al                     ; rows are shown starting at 1
    push dx
    add  dx, 4                  ; center 8 px digits in a 16 px row
    mov  bx, ROWNUM_X
    mov  cl, FRAME_COLOR
    call DrawNumber2
    pop  dx

    ; Choose where this row's colors come from: SI -> MAX_POS bytes
    mov  ax, di
    cmp  al, triesUsed
    jb   BR_FromHistory
    je   BR_FromCurrent
    mov  si, OFFSET emptyCode   ; future row: nothing chosen yet
    jmp  BR_Slots
BR_FromCurrent:
    mov  si, OFFSET currentGuess ; the row being built right now
    jmp  BR_Slots
BR_FromHistory:
    push dx
    mov  dl, MAX_POS
    mul  dl                     ; AX = row * MAX_POS
    pop  dx
    mov  si, OFFSET history
    add  si, ax                 ; SI -> this row inside history

BR_Slots:
    xor  ch, ch
    mov  cl, numPos             ; CX = slots in this level
    mov  bx, SLOT_X0            ; BX = x of the current slot
BR_SlotLoop:
    mov  al, [si]               ; color of this slot, 0 = empty
    cmp  al, 0
    je   BR_EmptySlot
    call DrawPotion
    jmp  BR_NextSlot
BR_EmptySlot:
    push bx                     ; DrawFrame takes its size in SI/DI,
    push dx                     ; which we are using, so keep them
    push si
    push di
    add  bx, 2                  ; small box centered in the 16x16 cell
    add  dx, 2
    mov  si, 12
    mov  di, 12
    mov  al, EMPTY_COLOR
    call DrawFrame
    pop  di
    pop  si
    pop  dx
    pop  bx
BR_NextSlot:
    inc  si
    add  bx, SLOT_STEP
    loop BR_SlotLoop

    ; Bulls and cows only for rows already evaluated
    mov  ax, di
    cmp  al, triesUsed
    jae  BR_Done
    mov  si, di                 ; SI = row index for the result arrays
    add  dx, 4                  ; icons and digits are 8 px tall

    DRAW_SPRITE CHISPA_X, dx, chispa_W, chispa_H, chispa
    mov  al, historyBulls[si]
    add  al, '0'
    mov  bx, BULLS_X
    mov  cl, 14
    call DrawChar

    DRAW_SPRITE BURBUJA_X, dx, burbuja_W, burbuja_H, burbuja
    mov  al, historyCows[si]
    add  al, '0'
    mov  bx, COWS_X
    mov  cl, 11
    call DrawChar

BR_Done:
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
DrawBoardRow ENDP

;------------------------------------------------------------------------------
; DrawBoard - background, header (A), status bar (D) and board (B)
; Receives : levelIdx and everything DrawBoardRow needs
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
DrawBoard PROC
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov  al, BG_COLOR
    call ClearScreen

    ; ---- Zone A: header ----
    xor  bx, bx
    xor  dx, dx
    mov  si, SCREEN_W
    mov  di, 20
    mov  al, BAR_COLOR
    call FillRect
    DRAW_TEXT 8, 6, 14, txtTitle

    mov  bl, levelIdx           ; level name comes from a table of
    xor  bh, bh                 ; string offsets, indexed by level
    shl  bx, 1
    mov  si, levelNameTable[bx]
    mov  bx, 200
    mov  dx, 6
    mov  cl, 11
    call DrawText

    ; ---- Zone D: status bar ----
    xor  bx, bx
    mov  dx, 190
    mov  si, SCREEN_W
    mov  di, 10
    mov  al, BAR_COLOR
    call FillRect
    DRAW_TEXT 4, 191, FRAME_COLOR, txtStatus

    ; ---- Zone B: frame and rows ----
    mov  bx, BOARD_X
    mov  dx, BOARD_Y
    mov  si, BOARD_W
    mov  di, BOARD_H
    mov  al, FRAME_COLOR
    call DrawFrame

    xor  al, al                 ; AL = row index
DB_Row:
    call DrawBoardRow
    inc  al
    cmp  al, ROWS_SHOWN
    jb   DB_Row

    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
DrawBoard ENDP

;------------------------------------------------------------------------------
; DrawPanel - zone C: potions in play, attempt counter, mascot
; Receives : numColors, triesUsed, numTries
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
DrawPanel PROC
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov  bx, PANEL_X
    mov  dx, PANEL_Y
    mov  si, PANEL_W
    mov  di, PANEL_H
    mov  al, FRAME_COLOR
    call DrawFrame
    DRAW_TEXT 212, 28, 14, txtFichas

    ; ---- Potion grid: PANEL_COLS per row, number below each ----
    xor  si, si                 ; SI = potion index 0..numColors-1
DP_Next:
    mov  ax, si
    mov  cl, PANEL_COLS
    div  cl                     ; AL = grid row, AH = grid column

    ; BX = 212 + column*24  (24 = 16 + 8, done with shifts)
    mov  bl, ah
    xor  bh, bh
    shl  bx, 1
    shl  bx, 1
    shl  bx, 1                  ; column*8
    mov  di, bx
    shl  bx, 1                  ; column*16
    add  bx, di                 ; column*24
    add  bx, 212

    ; DX = 40 + row*32
    xor  ah, ah
    mov  cl, 5
    shl  ax, cl                 ; row*32
    add  ax, 40
    mov  dx, ax

    mov  ax, si
    inc  al                     ; color number = index + 1
    call DrawPotion

    add  al, '0'                ; same number as a key hint below it
    add  bx, 4
    add  dx, 18
    mov  cl, 15
    call DrawChar

    inc  si
    mov  al, numColors
    xor  ah, ah
    cmp  si, ax
    jb   DP_Next

    ; ---- Attempt counter: INTENTO 03/10 ----
    DRAW_TEXT 212, 112, FRAME_COLOR, txtTry
    mov  al, triesUsed
    inc  al                     ; the attempt being played now
    mov  bx, 272
    mov  dx, 112
    mov  cl, 15
    call DrawNumber2
    mov  al, '/'
    mov  bx, 288
    call DrawChar
    mov  al, numTries
    mov  bx, 296
    call DrawNumber2

    ; ---- Mascot ----
    DRAW_SPRITE 252, 136, caldero1_W, caldero1_H, caldero1
    DRAW_TEXT 224, 160, 10, txtBoil

    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
DrawPanel ENDP

;------------------------------------------------------------------------------
; DrawCursor - selection frame around the active slot of the current row
; Receives : cursorPos, triesUsed
; Returns  : nothing
; Destroys : nothing
; Notes    : the 18x18 frame starts 1 px up and left of the 16x16 slot
;------------------------------------------------------------------------------
DrawCursor PROC
    push ax
    push bx
    push dx

    mov  al, cursorPos
    mov  bl, SLOT_STEP
    mul  bl                     ; AX = cursorPos * SLOT_STEP
    add  ax, SLOT_X0 - 1
    mov  bx, ax                 ; BX = x of the frame

    mov  al, triesUsed
    mov  dl, ROW_H
    mul  dl                     ; AX = row * ROW_H
    add  ax, BOARD_Y0 - 1
    mov  dx, ax                 ; DX = y of the frame

    DRAW_SPRITE bx, dx, marco1_W, marco1_H, marco1

    pop  dx
    pop  bx
    pop  ax
    ret
DrawCursor ENDP

;------------------------------------------------------------------------------
; ExitToDos - terminate the program with return code 0
; Receives : nothing
; Returns  : does not return
;------------------------------------------------------------------------------
ExitToDos PROC
    mov  ax, 4C00h
    int  21h
ExitToDos ENDP

END main
