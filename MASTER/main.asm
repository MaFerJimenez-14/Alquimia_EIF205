;==============================================================================
; EIF205 - Proyecto II - Mastermind Alquimia (16-bit x86, mode 13h)
; File   : main.asm
; Phase  : 1  - Skeleton (video mode, generic sprite routine, clean exit)
;          1b - Theme sprites (potions, icons, frame, cauldron)
;          2a - Text drawn straight into video memory with the BIOS font
;          2b - Game screen: the four zones of the mockup, drawn from data
;          3c - Playable: keyboard, random secret, bulls/cows, win/lose
;
; Screen zones (from the assignment):
;   A. Header     (0,0)     320x20   title and level
;   B. Board      (4,22)    196x168  history: one 16 px row per attempt
;   C. Side panel (204,22)  112x168  potions, attempt counter, mascot
;   D. Status bar (0,190)   320x10   key help and messages
;
; Keys while playing:
;   <- ->  move between slots      UP/DOWN  change potion in the slot
;   1..N   put potion N            BACKSPACE clear the slot
;   ENTER  evaluate the row        F2  use the row as secret (test mode)
;   ESC    quit
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
VGA_STATUS      EQU 3DAh        ; input status port, bit 3 = vertical retrace

MAX_POS         EQU 5           ; hardest level: 5 positions
MAX_COLOR       EQU 8           ; hardest level: 8 colors
MAX_TRIES       EQU 12          ; easiest level: 12 attempts
ROWS_SHOWN      EQU 10          ; rows that fit on the board (zone B)

POTION_W        EQU 16          ; every potion sprite is 16x16
POTION_H        EQU 16

; ---- Keys: ASCII codes and scan codes of extended keys ----
KEY_ESC         EQU 1Bh
KEY_ENTER       EQU 0Dh
KEY_BACK        EQU 08h
SC_UP           EQU 48h
SC_DOWN         EQU 50h
SC_LEFT         EQU 4Bh
SC_RIGHT        EQU 4Dh
SC_F2           EQU 3Ch

; ---- Game states ----
STATE_PLAYING   EQU 0
STATE_WON       EQU 1
STATE_LOST      EQU 2

; ---- Pseudo-random generator: seed = seed * LCG_A + LCG_C ----
LCG_A           EQU 25173
LCG_C           EQU 13849

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
HELP_COLOR      EQU 7           ; normal status bar text
WARN_COLOR      EQU 14          ; status bar warnings

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

.DATA
oldVideoMode    db ?            ; mode active before we switched to 13h
targetSeg       dw VIDEO_SEG    ; where drawing goes
fontSeg         dw ?            ; BIOS 8x8 font address (set by InitFont)
fontOff         dw ?
seed            dw 0            ; state of the pseudo-random generator

; ---- Level table: positions, colors, repeat allowed, attempts ----
; One row per level, 4 bytes each, so row = level * 4
levelTable      db 4, 6, 0, 12          ; 0 Facil
                db 4, 6, 1, 10          ; 1 Normal
                db 5, 8, 1, 10          ; 2 Dificil

; ---- Current level (loaded from levelTable by LoadLevel) ----
levelIdx        db 1            ; 0 easy, 1 normal, 2 hard
numPos          db 4            ; positions per code
numColors       db 6            ; potions in play
allowRepeat     db 1            ; 0 = the secret never repeats a color
numTries        db 10           ; attempts allowed

; ---- Game state ----
gameState       db STATE_PLAYING
triesUsed       db 0            ; attempts already evaluated
cursorPos       db 0            ; active slot in the row being built
statusDirty     db 0            ; 1 = a warning is covering the key help

secretCode      db MAX_POS dup(0)   ; the code to discover
guessCode       db MAX_POS dup(0)   ; row being built; 0 = slot empty
emptyCode       db MAX_POS dup(0)   ; used for rows not reached yet

; History: row r, position p is history[r*MAX_POS + p]
history         db MAX_TRIES*MAX_POS dup(0)
historyBulls    db MAX_TRIES dup(0)
historyCows     db MAX_TRIES dup(0)

; One counter per color for EvaluateGuess. Index = color, 0 unused.
countSecret     db MAX_COLOR+1 dup(0)
countGuess      db MAX_COLOR+1 dup(0)
bulls           db 0            ; right color, right position
cows            db 0            ; right color, wrong position

; ---- Texts (0-terminated, no accents: the font only has ASCII) ----
txtTitle        db 'MASTERMIND - ALQUIMIA', 0
txtLvl0         db 'NIVEL: FACIL', 0
txtLvl1         db 'NIVEL: NORMAL', 0
txtLvl2         db 'NIVEL: DIFICIL', 0
levelNameTable  dw OFFSET txtLvl0, OFFSET txtLvl1, OFFSET txtLvl2
txtHelp6        db '<> POSICION  1-6 COLOR  ENTER EVALUAR', 0
txtHelp8        db '<> POSICION  1-8 COLOR  ENTER EVALUAR', 0
txtIncomplete   db 'INTENTO INCOMPLETO: LLENA TODAS', 0
txtManual       db 'SECRETO FIJADO A MANO (PRUEBA)', 0
txtEndHelp      db 'ENTER: JUGAR DE NUEVO   ESC: SALIR', 0
txtFichas       db 'FICHAS', 0
txtTry          db 'INTENTO', 0
txtBoil         db 'HIRVIENDO', 0
txtWon          db 'GANASTE!', 0
txtLost         db 'PERDISTE', 0
txtSecret       db 'SECRETO:', 0

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
; main - one game after another until the player quits
;==============================================================================
main PROC
    mov  ax, @data
    mov  ds, ax                 ; DS must reach our variables and tables

    call SaveVideoMode
    call SetMode13h
    call InitFont               ; find the BIOS letter shapes once
    call InitRandom             ; seed once, so every game differs

M_Game:
    call NewGame
    call PlayGame               ; AL = 1 play again, 0 quit
    cmp  al, 1
    je   M_Game

    call RestoreVideoMode
    call ExitToDos
main ENDP

;==============================================================================
;                         VIDEO MODE AND BASIC DRAWING
;==============================================================================

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
; WaitRetrace - wait for the start of the vertical retrace
; Receives : nothing
; Returns  : nothing
; Destroys : nothing
; Notes    : drawing right after the beam leaves the screen avoids tearing
;            and flicker (RG-08). First wait for any retrace in progress
;            to end, then for the next one to begin.
;------------------------------------------------------------------------------
WaitRetrace PROC
    push ax
    push dx
    mov  dx, VGA_STATUS
WR_InRetrace:
    in   al, dx
    test al, 08h
    jnz  WR_InRetrace           ; still inside the previous retrace
WR_NoRetrace:
    in   al, dx
    test al, 08h
    jz   WR_NoRetrace           ; beam still drawing the screen
    pop  dx
    pop  ax
    ret
WaitRetrace ENDP

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

;==============================================================================
;                                   TEXT
;==============================================================================

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
; ShowStatus - replace the status bar (zone D) with a message
; Receives : SI = offset of the message, CL = text color
; Returns  : statusDirty = 1, so the next key restores the help
; Destroys : nothing
;------------------------------------------------------------------------------
ShowStatus PROC
    push ax
    push bx
    push dx
    push si
    push di

    push si                     ; FillRect uses SI as width
    xor  bx, bx
    mov  dx, 190
    mov  si, SCREEN_W
    mov  di, 10
    mov  al, BAR_COLOR
    call FillRect               ; wipe the old text
    pop  si

    mov  bx, 4
    mov  dx, 191
    call DrawText
    mov  statusDirty, 1

    pop  di
    pop  si
    pop  dx
    pop  bx
    pop  ax
    ret
ShowStatus ENDP

;------------------------------------------------------------------------------
; DrawHelp - status bar with the key help of the current level
; Receives : numColors
; Returns  : statusDirty = 0
; Destroys : nothing
;------------------------------------------------------------------------------
DrawHelp PROC
    push cx
    push si
    mov  si, OFFSET txtHelp6
    cmp  numColors, 8
    jne  DH_Show
    mov  si, OFFSET txtHelp8    ; hard level: keys 1-8
DH_Show:
    mov  cl, HELP_COLOR
    call ShowStatus
    mov  statusDirty, 0         ; this IS the normal content
    pop  si
    pop  cx
    ret
DrawHelp ENDP

;------------------------------------------------------------------------------
; RestoreHelp - put the key help back if a warning is showing
; Receives : statusDirty
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
RestoreHelp PROC
    cmp  statusDirty, 0
    je   RH_Done                ; help already visible: nothing to redraw
    call DrawHelp
RH_Done:
    ret
RestoreHelp ENDP

;==============================================================================
;                              GAME SCREEN
;==============================================================================

;------------------------------------------------------------------------------
; DrawBoardRow - one row of zone B: number, potions or empty slots,
;                and bulls/cows if the row was already evaluated
; Receives : AL = row index 0..ROWS_SHOWN-1
;            triesUsed, numPos, history, historyBulls, historyCows,
;            guessCode
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
    mov  si, OFFSET guessCode   ; the row being built right now
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
; RefreshRow - redraw one board row and its neighbors, nothing else
; Receives : AL = row index 0..ROWS_SHOWN-1
; Returns  : nothing
; Destroys : nothing
; Notes    : RG-08, only what changes is redrawn. The 18x18 cursor frame
;            sticks out 1 px above and below its row, so the wiped strip
;            is 18 px tall and the rows above and below are redrawn too.
;------------------------------------------------------------------------------
RefreshRow PROC
    push ax
    push bx
    push dx
    push si
    push di

    call WaitRetrace            ; draw while the beam is off screen

    ; Wipe the strip: from 1 px above the row to 1 px below it
    push ax
    xor  ah, ah
    mov  dl, ROW_H
    mul  dl                     ; AX = row * 16
    add  ax, BOARD_Y0 - 1
    mov  dx, ax
    mov  bx, BOARD_X + 1        ; inside the board frame
    mov  si, BOARD_W - 2
    mov  di, ROW_H + 2
    mov  al, BG_COLOR
    call FillRect
    pop  ax

    ; Previous row (its bottom line was wiped)
    cmp  al, 0
    je   RR_Self
    dec  al
    call DrawBoardRow
    inc  al
RR_Self:
    call DrawBoardRow
    ; Next row (its top line was wiped)
    inc  al
    cmp  al, ROWS_SHOWN
    jae  RR_Done
    call DrawBoardRow

RR_Done:
    pop  di
    pop  si
    pop  dx
    pop  bx
    pop  ax
    ret
RefreshRow ENDP

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
    call DrawHelp

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
; DrawTryCounter - "INTENTO 03/10" in the panel
; Receives : triesUsed, numTries
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
DrawTryCounter PROC
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov  bx, 272                ; wipe the old digits first
    mov  dx, 112
    mov  si, 40
    mov  di, CHAR_H
    mov  al, BG_COLOR
    call FillRect

    mov  al, triesUsed
    cmp  al, numTries
    jae  TC_Show                ; game over: do not count past the limit
    inc  al                     ; the attempt being played now
TC_Show:
    mov  cl, 15
    call DrawNumber2
    mov  al, '/'
    mov  bx, 288
    call DrawChar
    mov  al, numTries
    mov  bx, 296
    call DrawNumber2

    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
DrawTryCounter ENDP

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

    ; ---- Attempt counter ----
    DRAW_TEXT 212, 112, FRAME_COLOR, txtTry
    call DrawTryCounter

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
; RedrawCurrent - refresh the row being built and its cursor
; Receives : triesUsed, cursorPos, guessCode
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
RedrawCurrent PROC
    push ax
    mov  al, triesUsed
    call RefreshRow
    call DrawCursor
    pop  ax
    ret
RedrawCurrent ENDP

;==============================================================================
;                          RANDOM SECRET AND RULES
;==============================================================================

;------------------------------------------------------------------------------
; InitRandom - seed the generator with the BIOS tick counter (RF-04)
; Receives : nothing
; Returns  : seed = low word of ticks since midnight
; Destroys : nothing
; Notes    : the tick counter advances ~18.2 times per second, so the
;            seed depends on the exact moment the program starts
;------------------------------------------------------------------------------
InitRandom PROC
    push ax
    push cx
    push dx
    mov  ah, 00h
    int  1Ah                    ; CX:DX = ticks since midnight
    mov  seed, dx               ; the fast-changing low word
    pop  dx
    pop  cx
    pop  ax
    ret
InitRandom ENDP

;------------------------------------------------------------------------------
; NextRandom - next pseudo-random color
; Receives : seed, numColors
; Returns  : AL = random color 1..numColors; seed updated
; Destroys : AH
;------------------------------------------------------------------------------
NextRandom PROC
    push bx
    push dx

    mov  ax, seed
    mov  bx, LCG_A
    mul  bx                     ; DX:AX = seed * A (we keep only AX)
    add  ax, LCG_C
    mov  seed, ax               ; new state

    ; The high byte of an LCG is more random than the low byte,
    ; whose lowest bit just alternates 0,1,0,1...
    mov  al, ah
    xor  ah, ah                 ; AX = 0..255
    mov  bl, numColors
    div  bl                     ; AH = AX mod numColors (0..numColors-1)
    mov  al, ah
    inc  al                     ; shift to color range 1..numColors

    pop  dx
    pop  bx
    ret
NextRandom ENDP

;------------------------------------------------------------------------------
; GenerateSecret - fill secretCode with random colors for the level
; Receives : numPos, numColors, allowRepeat
; Returns  : secretCode filled
; Destroys : nothing
; Notes    : with allowRepeat = 0 a color already used is drawn again,
;            so the easy level never repeats colors (RF-05)
;------------------------------------------------------------------------------
GenerateSecret PROC
    push ax
    push bx
    push cx
    push si

    xor  si, si                 ; SI = position being filled
GS_NextPos:
    call NextRandom             ; AL = candidate color
    cmp  allowRepeat, 0
    jne  GS_Store               ; repeats allowed: take it as is

    ; Look for AL in the positions already filled (0 .. SI-1)
    xor  bx, bx
GS_Check:
    cmp  bx, si
    je   GS_Store               ; checked all previous: AL is new
    cmp  secretCode[bx], al
    je   GS_NextPos             ; already used: draw another color
    inc  bx
    jmp  GS_Check

GS_Store:
    mov  secretCode[si], al
    inc  si
    mov  cl, numPos
    xor  ch, ch
    cmp  si, cx
    jb   GS_NextPos             ; more positions to fill

    pop  si
    pop  cx
    pop  bx
    pop  ax
    ret
GenerateSecret ENDP

;------------------------------------------------------------------------------
; EvaluateGuess - count bulls and cows of guessCode against secretCode
; Receives : secretCode, guessCode, numPos
; Returns  : bulls, cows
; Destroys : nothing
;
; Algorithm (each secret piece may count only once):
;   Pass 1, for every position i:
;     if secret[i] == guess[i]  -> one more bull
;     else                      -> countSecret[secret[i]]++ and
;                                  countGuess[guess[i]]++
;   Pass 2, for every color c:
;     cows += min(countSecret[c], countGuess[c])
;------------------------------------------------------------------------------
EvaluateGuess PROC
    push ax
    push bx
    push cx
    push si

    ; Counters must start at zero on every evaluation
    xor  bx, bx
    mov  cx, MAX_COLOR+1
EG_Clear:
    mov  countSecret[bx], 0
    mov  countGuess[bx], 0
    inc  bx
    loop EG_Clear
    mov  bulls, 0
    mov  cows, 0

    ; ---- Pass 1: bulls, and count the colors that were not bulls ----
    xor  si, si                 ; SI = position index
    xor  ch, ch
    mov  cl, numPos
EG_Pass1:
    mov  al, secretCode[si]     ; AL = secret color at this position
    mov  ah, guessCode[si]      ; AH = guessed color at this position
    cmp  al, ah
    jne  EG_NotBull
    inc  bulls                  ; same color, same place
    jmp  EG_Next1
EG_NotBull:
    xor  bh, bh
    mov  bl, al
    inc  countSecret[bx]        ; secret still has one unmatched 'AL'
    mov  bl, ah
    inc  countGuess[bx]         ; guess still has one unmatched 'AH'
EG_Next1:
    inc  si
    loop EG_Pass1

    ; ---- Pass 2: cows = sum over colors of min(secret, guess) ----
    mov  bx, 1                  ; colors go from 1 to MAX_COLOR
    mov  cx, MAX_COLOR
EG_Pass2:
    mov  al, countSecret[bx]
    mov  ah, countGuess[bx]
    cmp  al, ah
    jbe  EG_HaveMin             ; AL is already the smaller one
    mov  al, ah                 ; otherwise the guess count is smaller
EG_HaveMin:
    add  cows, al
    inc  bx
    loop EG_Pass2

    pop  si
    pop  cx
    pop  bx
    pop  ax
    ret
EvaluateGuess ENDP

;==============================================================================
;                              GAME FLOW
;==============================================================================

;------------------------------------------------------------------------------
; LoadLevel - copy the levelIdx row of levelTable into the level variables
; Receives : levelIdx
; Returns  : numPos, numColors, allowRepeat, numTries
; Destroys : nothing
;------------------------------------------------------------------------------
LoadLevel PROC
    push ax
    push bx
    mov  bl, levelIdx
    xor  bh, bh
    shl  bx, 1
    shl  bx, 1                  ; BX = level * 4 (row of the table)
    mov  al, levelTable[bx]     ; column 0: positions
    mov  numPos, al
    mov  al, levelTable[bx+1]   ; column 1: colors
    mov  numColors, al
    mov  al, levelTable[bx+2]   ; column 2: repeat allowed?
    mov  allowRepeat, al
    mov  al, levelTable[bx+3]   ; column 3: attempts
    cmp  al, ROWS_SHOWN
    jbe  LL_Tries
    mov  al, ROWS_SHOWN         ; PENDING: the board shows 10 rows only
LL_Tries:
    mov  numTries, al
    pop  bx
    pop  ax
    ret
LoadLevel ENDP

;------------------------------------------------------------------------------
; NewGame - reset every table, pick a secret and draw the whole screen
; Receives : levelIdx
; Returns  : a fresh game ready to play
; Destroys : nothing
;------------------------------------------------------------------------------
NewGame PROC
    push ax
    push cx
    push di
    push es

    call LoadLevel

    ; REP STOSB writes to ES:DI, so point ES at our own data
    mov  ax, ds
    mov  es, ax
    cld
    xor  al, al
    mov  di, OFFSET history
    mov  cx, MAX_TRIES*MAX_POS
    rep  stosb                  ; no attempts in the history
    mov  di, OFFSET historyBulls
    mov  cx, MAX_TRIES
    rep  stosb
    mov  di, OFFSET historyCows
    mov  cx, MAX_TRIES
    rep  stosb
    mov  di, OFFSET guessCode
    mov  cx, MAX_POS
    rep  stosb                  ; current row starts empty

    mov  triesUsed, 0
    mov  cursorPos, 0
    mov  gameState, STATE_PLAYING
    mov  statusDirty, 0

    call GenerateSecret

    call DrawBoard
    call DrawPanel
    call DrawCursor

    pop  es
    pop  di
    pop  cx
    pop  ax
    ret
NewGame ENDP

;------------------------------------------------------------------------------
; PlayGame - read keys and dispatch them until the game ends or ESC
; Receives : a game prepared by NewGame
; Returns  : AL = 1 to play again, AL = 0 to quit
; Destroys : AH
; Notes    : extended keys (arrows, F2) arrive with AL = 0 or E0h and
;            their identity in the scan code AH; normal keys in AL.
;------------------------------------------------------------------------------
PlayGame PROC
PG_Loop:
    cmp  gameState, STATE_PLAYING
    je   PG_Read
    call EndGame                ; AL = 1 again / 0 quit
    jmp  PG_Exit

PG_Read:
    mov  ah, 00h
    int  16h                    ; AL = ASCII, AH = scan code
    call RestoreHelp            ; any warning disappears on a new key

    cmp  al, KEY_ESC
    jne  PG_NotEsc
    xor  al, al                 ; quit
    jmp  PG_Exit
PG_NotEsc:
    cmp  al, 0
    je   PG_Extended
    cmp  al, 0E0h
    je   PG_Extended

    cmp  al, KEY_ENTER
    jne  PG_NotEnter
    call SubmitGuess
    jmp  PG_Loop
PG_NotEnter:
    cmp  al, KEY_BACK
    jne  PG_NotBack
    call ClearSlot
    jmp  PG_Loop
PG_NotBack:
    call TypeColor              ; ignores keys that are not colors
    jmp  PG_Loop

PG_Extended:
    cmp  ah, SC_LEFT
    jne  PG_NotLeft
    call MoveLeft
    jmp  PG_Loop
PG_NotLeft:
    cmp  ah, SC_RIGHT
    jne  PG_NotRight
    call MoveRight
    jmp  PG_Loop
PG_NotRight:
    cmp  ah, SC_UP
    jne  PG_NotUp
    call ColorUp
    jmp  PG_Loop
PG_NotUp:
    cmp  ah, SC_DOWN
    jne  PG_NotDown
    call ColorDown
    jmp  PG_Loop
PG_NotDown:
    cmp  ah, SC_F2
    jne  PG_Ignore
    call SetManualSecret
PG_Ignore:
    jmp  PG_Loop                ; any other key does nothing

PG_Exit:
    ret
PlayGame ENDP

;------------------------------------------------------------------------------
; MoveLeft / MoveRight - move the cursor one slot, stopping at the ends
; Receives : cursorPos, numPos
; Returns  : cursorPos updated and redrawn
; Destroys : nothing
;------------------------------------------------------------------------------
MoveLeft PROC
    cmp  cursorPos, 0
    je   ML_Done                ; already on the first slot
    dec  cursorPos
    call RedrawCurrent
ML_Done:
    ret
MoveLeft ENDP

MoveRight PROC
    push ax
    mov  al, cursorPos
    inc  al
    cmp  al, numPos
    jae  MR_Done                ; already on the last slot
    mov  cursorPos, al
    call RedrawCurrent
MR_Done:
    pop  ax
    ret
MoveRight ENDP

;------------------------------------------------------------------------------
; ColorUp / ColorDown - cycle the potion of the active slot
; Receives : cursorPos, numColors, guessCode
; Returns  : guessCode[cursorPos] updated and redrawn
; Destroys : nothing
; Notes    : up goes 1,2,..,N,1..  down goes N,..,2,1,N..
;            an empty slot (0) starts at 1 going up and at N going down
;------------------------------------------------------------------------------
ColorUp PROC
    push ax
    push bx
    mov  bl, cursorPos
    xor  bh, bh
    mov  al, guessCode[bx]
    inc  al
    cmp  al, numColors
    jbe  CU_Store
    mov  al, 1                  ; past the last potion: wrap to the first
CU_Store:
    mov  guessCode[bx], al
    call RedrawCurrent
    pop  bx
    pop  ax
    ret
ColorUp ENDP

ColorDown PROC
    push ax
    push bx
    mov  bl, cursorPos
    xor  bh, bh
    mov  al, guessCode[bx]
    cmp  al, 1
    jbe  CD_Wrap                ; on 1 or empty: wrap to the last
    dec  al
    jmp  CD_Store
CD_Wrap:
    mov  al, numColors
CD_Store:
    mov  guessCode[bx], al
    call RedrawCurrent
    pop  bx
    pop  ax
    ret
ColorDown ENDP

;------------------------------------------------------------------------------
; TypeColor - put potion N in the active slot when key N is pressed
; Receives : AL = ASCII of the key, cursorPos, numColors, numPos
; Returns  : slot filled and cursor moved one slot right (if possible)
; Destroys : nothing
; Notes    : any key outside '1'..numColors is ignored (robust keyboard)
;------------------------------------------------------------------------------
TypeColor PROC
    push ax
    push bx

    sub  al, '0'                ; ASCII -> number ('1' -> 1)
    cmp  al, 1
    jb   TC_Ignore              ; below '1' (also wraps for other keys)
    cmp  al, numColors
    ja   TC_Ignore              ; beyond this level's potions

    mov  bl, cursorPos
    xor  bh, bh
    mov  guessCode[bx], al

    inc  bl                     ; move on, so a code can be typed in a row
    cmp  bl, numPos
    jae  TC_Redraw
    mov  cursorPos, bl
TC_Redraw:
    call RedrawCurrent
TC_Ignore:
    pop  bx
    pop  ax
    ret
TypeColor ENDP

;------------------------------------------------------------------------------
; ClearSlot - BACKSPACE: empty the active slot
; Receives : cursorPos
; Returns  : guessCode[cursorPos] = 0, redrawn
; Destroys : nothing
;------------------------------------------------------------------------------
ClearSlot PROC
    push bx
    mov  bl, cursorPos
    xor  bh, bh
    mov  guessCode[bx], 0
    call RedrawCurrent
    pop  bx
    ret
ClearSlot ENDP

;------------------------------------------------------------------------------
; IsGuessComplete - check that every slot of the row has a potion
; Receives : guessCode, numPos
; Returns  : CF = 0 complete, CF = 1 some slot is empty
; Destroys : nothing
;------------------------------------------------------------------------------
IsGuessComplete PROC
    push bx
    push cx
    xor  bx, bx
    xor  ch, ch
    mov  cl, numPos
GC_Check:
    cmp  guessCode[bx], 0
    je   GC_Empty
    inc  bx
    loop GC_Check
    clc
    jmp  GC_Done
GC_Empty:
    stc
GC_Done:
    pop  cx                     ; POP keeps the flags, CF reaches RET
    pop  bx
    ret
IsGuessComplete ENDP

;------------------------------------------------------------------------------
; SubmitGuess - ENTER: evaluate the row, store it and check win/lose
; Receives : guessCode, secretCode, triesUsed, numPos, numTries
; Returns  : history updated, triesUsed+1, gameState maybe WON or LOST
; Destroys : nothing
; Notes    : an incomplete row shows a warning and costs no attempt (RF-07)
;------------------------------------------------------------------------------
SubmitGuess PROC
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    call IsGuessComplete
    jnc  SG_Complete
    mov  si, OFFSET txtIncomplete
    mov  cl, WARN_COLOR
    call ShowStatus
    jmp  SG_Done

SG_Complete:
    call EvaluateGuess          ; -> bulls, cows

    ; Copy the row into history[triesUsed*MAX_POS ...] and empty it
    mov  al, triesUsed
    mov  dl, MAX_POS
    mul  dl
    mov  di, ax                 ; DI = first byte of this row in history
    xor  bx, bx
    mov  cx, MAX_POS
SG_Copy:
    mov  al, guessCode[bx]
    mov  history[di], al
    mov  guessCode[bx], 0       ; next row starts empty
    inc  bx
    inc  di
    loop SG_Copy

    mov  bl, triesUsed
    xor  bh, bh
    mov  al, bulls
    mov  historyBulls[bx], al
    mov  al, cows
    mov  historyCows[bx], al

    mov  si, bx                 ; SI = row just evaluated (to redraw)
    inc  triesUsed
    mov  cursorPos, 0

    ; ---- Win: every position is a bull ----
    mov  al, bulls
    cmp  al, numPos
    jne  SG_NotWon
    mov  gameState, STATE_WON
    jmp  SG_Redraw
SG_NotWon:
    ; ---- Lose: no attempts left ----
    mov  al, triesUsed
    cmp  al, numTries
    jb   SG_Redraw
    mov  gameState, STATE_LOST

SG_Redraw:
    mov  ax, si
    call RefreshRow             ; the evaluated row and the next one
    call DrawTryCounter
    cmp  gameState, STATE_PLAYING
    jne  SG_Done
    call DrawCursor             ; cursor now on the new row

SG_Done:
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
SubmitGuess ENDP

;------------------------------------------------------------------------------
; SetManualSecret - F2: the row being built becomes the secret
; Receives : guessCode (complete)
; Returns  : secretCode = guessCode, row emptied again
; Destroys : nothing
; Notes    : test mode required by the assignment to run Table 2 by hand
;------------------------------------------------------------------------------
SetManualSecret PROC
    push ax
    push bx
    push cx
    push si

    call IsGuessComplete
    jnc  MS_Copy
    mov  si, OFFSET txtIncomplete
    mov  cl, WARN_COLOR
    call ShowStatus
    jmp  MS_Done

MS_Copy:
    xor  bx, bx
    mov  cx, MAX_POS
MS_Next:
    mov  al, guessCode[bx]
    mov  secretCode[bx], al
    mov  guessCode[bx], 0
    inc  bx
    loop MS_Next
    mov  cursorPos, 0
    call RedrawCurrent
    mov  si, OFFSET txtManual
    mov  cl, WARN_COLOR
    call ShowStatus

MS_Done:
    pop  si
    pop  cx
    pop  bx
    pop  ax
    ret
SetManualSecret ENDP

;------------------------------------------------------------------------------
; EndGame - show the result, reveal the secret, ask what to do next
; Receives : gameState (WON or LOST), secretCode, numPos
; Returns  : AL = 1 play again (ENTER), AL = 0 quit (ESC)
; Destroys : AH
;------------------------------------------------------------------------------
EndGame PROC
    push bx
    push cx
    push dx
    push si
    push di

    ; Replace the mascot area of the panel with the result
    mov  bx, PANEL_X + 2
    mov  dx, 128
    mov  si, PANEL_W - 4
    mov  di, 60
    mov  al, BG_COLOR
    call FillRect

    cmp  gameState, STATE_WON
    jne  EGm_Lost
    DRAW_TEXT 212, 132, 14, txtWon
    jmp  EGm_Secret
EGm_Lost:
    DRAW_TEXT 212, 132, 12, txtLost

EGm_Secret:
    DRAW_TEXT 212, 146, FRAME_COLOR, txtSecret
    xor  si, si                 ; SI = position of the secret
    mov  bx, 212
    mov  dx, 158
EGm_Potion:
    mov  al, secretCode[si]
    call DrawPotion
    add  bx, SLOT_STEP
    inc  si
    mov  al, numPos
    xor  ah, ah
    cmp  si, ax
    jb   EGm_Potion

    mov  si, OFFSET txtEndHelp
    mov  cl, HELP_COLOR
    call ShowStatus

EGm_Wait:
    mov  ah, 00h
    int  16h
    cmp  al, KEY_ENTER
    je   EGm_Again
    cmp  al, KEY_ESC
    jne  EGm_Wait               ; only ENTER or ESC mean something here
    xor  al, al
    jmp  EGm_Done
EGm_Again:
    mov  al, 1
EGm_Done:
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    ret
EndGame ENDP

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
