;==============================================================================
; EIF205 - Proyecto II - Mastermind Alquimia (16-bit x86, mode 13h)
; File   : main.asm
; Phase  : 1  - Skeleton (video mode, generic sprite routine, clean exit)
;          1b - Theme sprites (potions, icons, frame, cauldron)
;          2a - Text drawn straight into video memory with the BIOS font
;          2b - Game screen: the four zones of the mockup, drawn from data
;          3c - Playable: keyboard, random secret, bulls/cows, win/lose
;          4  - Title screen, menu, levels, instructions, credits and
;               animations timed with the BIOS tick counter
;          4b - Easy level with its 12 attempts: rows of 14 px instead
;               of 16, so 12 rows fill the same 168 px of zone B
;          5  - Own palette: colors 16..31 programmed through the DAC
;               ports 3C8h/3C9h (colors 0..15 keep the VGA defaults)
;          6  - End-of-game screen with different win/lose animations
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
;   ENTER  evaluate the row        S/F2  use the row as secret (test)
;   ESC    back to the menu
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
ROW_LIMIT_16    EQU 10          ; up to 10 attempts fit with 16 px rows
CURSOR_H        EQU 18          ; height of the selection frame sprite
STATUS_Y        EQU 190         ; first line of zone D

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

; ---- BIOS tick counter (~18.2 ticks per second) ----
TICKS_SEG       EQU 0040h       ; BIOS data area
TICKS_OFF       EQU 006Ch       ; low word of ticks since midnight
ANIM_TICKS      EQU 4           ; frame change every 4 ticks (~0.22 s)

; ---- What WaitKeyAnimated animates (bit flags) ----
ANIM_MASCOT     EQU 1           ; the cauldron at mascotX, mascotY
ANIM_CURSOR     EQU 2           ; the selection frame on the board
ANIM_END        EQU 4           ; win / lose animation of the end screen

; ---- End screen layout ----
END_LEFT_X      EQU 40          ; cauldron on the left
END_RIGHT_X     EQU 264         ; cauldron on the right
END_CY          EQU 148         ; y of both cauldrons
END_BOX_W       EQU 48          ; area wiped around each cauldron
END_BOX_H       EQU 48
END_TITLE_X     EQU 128         ; "GANASTE!" / "PERDISTE" (8 chars, centered)
END_TITLE_Y     EQU 40

; ---- PlayGame / EndGame results ----
RESULT_MENU     EQU 0
RESULT_AGAIN    EQU 1
RESULT_QUIT     EQU 2

; ---- Menu lists ----
MENU_ITEMS      EQU 5
LEVEL_ITEMS     EQU 3
LIST_W          EQU 160         ; width of the highlight bar

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
BOARD_Y0        EQU 26          ; y of the first row with 16 px rows
BOARD_Y0_EASY   EQU 23          ; y of the first row with 14 px rows
ROW_H           EQU 16          ; normal row height
ROW_H_EASY      EQU 14          ; 12 rows * 14 px = 168 px = zone B
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

; ---- VGA DAC (color table of the video card) ----
DAC_WRITE       EQU 3C8h        ; OUT here: first color index to change
DAC_DATA        EQU 3C9h        ; OUT here: R, G, B (0..63) per color
PAL_FIRST       EQU 16          ; our colors are 16..31; 0..15 untouched
PAL_COUNT       EQU 16

; ---- Colors of our own palette (see paletteTable) ----
BG_COLOR        EQU 16          ; laboratory night purple background
BAR_COLOR       EQU 17          ; header and status bar fill
FRAME_COLOR     EQU 18          ; zone borders, secondary text
EMPTY_COLOR     EQU 19          ; empty slot boxes
SEL_COLOR       EQU 20          ; menu highlight bar
TITLE_COLOR     EQU 21          ; gold: titles and selected option
TEXT_COLOR      EQU 22          ; parchment: normal text
ACCENT_COLOR    EQU 23          ; teal: level name
WIN_COLOR       EQU 29          ; green: "GANASTE!"
LOSE_COLOR      EQU 30          ; red: "PERDISTE"
HELP_COLOR      EQU TEXT_COLOR  ; normal status bar text
WARN_COLOR      EQU TITLE_COLOR ; status bar warnings

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

; ---- Own palette (RG-07): R, G, B per color, each 0..63 ----
; The VGA DAC uses 6 bits per channel, so 63 is full intensity.
paletteTable    db  6,  3, 10   ; 16 background (night purple)
                db 16,  8, 26   ; 17 header / status bar
                db 36, 30, 46   ; 18 frames (lavender)
                db 20, 15, 28   ; 19 empty slots
                db 26, 12, 40   ; 20 menu highlight
                db 63, 50, 16   ; 21 gold (titles)
                db 58, 54, 46   ; 22 parchment (text)
                db 22, 54, 50   ; 23 teal (accent)
                db 63, 32, 40   ; 24 heart potion liquid (rose)
                db 44, 14, 26   ; 25 heart potion shadow
                db 58, 42,  6   ; 26 star potion liquid (amber)
                db 38, 24,  2   ; 27 star potion shadow
                db  8, 10, 36   ; 28 square potion shadow (navy)
                db 12, 56, 24   ; 29 win green
                db 60, 16, 16   ; 30 lose red
                db 40, 40,  6   ; 31 tall potion shadow (olive)

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
rowH            db ROW_H        ; row height of this level (16 or 14)
rowY0           dw BOARD_Y0     ; y of the first row of this level

; ---- Game state ----
gameState       db STATE_PLAYING
triesUsed       db 0            ; attempts already evaluated
cursorPos       db 0            ; active slot in the row being built
statusDirty     db 0            ; 1 = a warning is covering the key help
lastStatusMsg   dw 0            ; what the status bar shows right now,
lastStatusColor db 0            ; so it can be repainted (RepaintStatus)

; ---- Animation state ----
animFlags       db 0            ; ANIM_MASCOT / ANIM_CURSOR bits
mascotFrame     db 0            ; 0 or 1: which frame is on screen
mascotX         dw 0            ; where the animated cauldron is
mascotY         dw 0
lastTick        dw 0            ; tick count of the last frame change

; ---- Menus ----
menuSel         db 0            ; last option chosen in the main menu
listTable       dw 0            ; SelectFromList parameters
listCount       db 0
listSel         db 0
listX           dw 0
listY           dw 0

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
txtHelp6        db '<> POS 1-6 COLOR ENTER EVALUAR ESC MENU', 0
txtHelp8        db '<> POS 1-8 COLOR ENTER EVALUAR ESC MENU', 0
txtIncomplete   db 'INTENTO INCOMPLETO: LLENA TODAS', 0
txtManual       db 'SECRETO FIJADO A MANO (PRUEBA)', 0
txtEndHelp      db 'ENTER: OTRA   M: MENU   ESC: SALIR', 0
txtFichas       db 'FICHAS', 0
txtTry          db 'INTENTO', 0
txtBoil         db 'HIRVIENDO', 0
txtWon          db 'GANASTE!', 0
txtLost         db 'PERDISTE', 0
txtSecret       db 'SECRETO:', 0
txtCodeLbl      db 'RECETA SECRETA', 0
txtUsed         db 'INTENTOS USADOS: ', 0

; ---- End animation: 3 (dx, dy) offsets from the cauldron per frame ----
; Group = (lost ? 2 : 0) + frame; each group is 3 pairs of words = 12 bytes.
; Win: gold sparks jump around the cauldron. Lose: grey bubbles of smoke.
endOffsets      dw -14, -6,   18,-20,    2,-24  ; win,  frame 0
                dw  20, -8,  -12,-22,  -14,  8  ; win,  frame 1
                dw  -2,-10,    8,-18,   14, -8  ; lose, frame 0
                dw   8,-12,    0,-22,   16,-20  ; lose, frame 1

; ---- Author: write your name here (no accents, capital letters) ----
txtAuthorName   db 'MARIA JIMENEZ', 0

; ---- Title screen ----
txtBigTitle     db 'MASTERMIND', 0
txtSubtitle     db 'ALQUIMIA', 0
txtTagline      db 'LA RECETA SECRETA TE ESPERA', 0
txtCourse       db 'PROYECTO DE ARQUITECTURA DE COMPUTADORES', 0
txtBy           db 'POR:', 0
txtPressKey     db 'PRESIONA UNA TECLA PARA CONTINUAR', 0

; ---- Main menu ----
txtOptPlay      db 'JUGAR', 0
txtOptLevel     db 'NIVEL DE DIFICULTAD', 0
txtOptHelp      db 'INSTRUCCIONES', 0
txtOptCredits   db 'CREDITOS', 0
txtOptQuit      db 'SALIR', 0
menuTable       dw OFFSET txtOptPlay, OFFSET txtOptLevel, OFFSET txtOptHelp
                dw OFFSET txtOptCredits, OFFSET txtOptQuit
txtMenuHelp     db 'FLECHAS MUEVEN   ENTER SELECCIONA', 0

; ---- Level screen ----
txtLevelTitle   db 'NIVEL DE DIFICULTAD', 0
txtOptEasy      db 'FACIL', 0
txtOptNormal    db 'NORMAL', 0
txtOptHard      db 'DIFICIL', 0
levelOptTable   dw OFFSET txtOptEasy, OFFSET txtOptNormal, OFFSET txtOptHard
txtLvlInfo0     db 'FACIL  : 4 POS, 6 POCIONES, SIN REPETIR', 0
txtLvlInfo1     db 'NORMAL : 4 POS, 6 POCIONES, REPITEN', 0
txtLvlInfo2     db 'DIFICIL: 5 POS, 8 POCIONES, REPITEN', 0
txtLvlInfo3     db 'INTENTOS: 12 / 10 / 10', 0
txtLevelHelp    db 'ENTER ELIGE   ESC VUELVE', 0

; ---- Instructions screen ----
txtHelpTitle    db 'INSTRUCCIONES', 0
txtHelp1        db 'DESCUBRE LA RECETA SECRETA: QUE POCION', 0
txtHelp2        db 'VA EN CADA LUGAR, ANTES DE AGOTAR LOS', 0
txtHelp3        db 'INTENTOS. TRAS CADA INTENTO VERAS:', 0
txtHelpBull     db 'POCION CORRECTA EN SU LUGAR', 0
txtHelpCow      db 'POCION CORRECTA, OTRO LUGAR', 0
txtHelpExample  db 'EJEMPLO:', 0
txtHelpRecipe   db 'RECETA', 0
txtHelpGuess    db 'INTENTO', 0
txtHelpOne      db '1', 0
txtHelpTwo      db '2', 0
txtHelpKeys1    db '<> MUEVE   ^v O NUMERO ELIGE POCION', 0
txtHelpKeys2    db 'ENTER PRUEBA  BKSP BORRA  ESC MENU', 0
txtHelpKeys3    db 'S: FIJAR SECRETO A MANO (PRUEBA)', 0
txtBackKey      db 'PRESIONA UNA TECLA PARA VOLVER', 0
; Example shown in the instructions: recipe 1234, attempt 1325
helpRecipe      db 1, 2, 3, 4
helpGuess       db 1, 3, 2, 5

; ---- Credits screen ----
txtCreditsTitle db 'CREDITOS', 0
txtAuthorLbl    db 'AUTOR:', 0
txtCred1        db 'EIF205 ARQUITECTURA DE COMPUTADORES', 0
txtCred2        db 'UNIVERSIDAD NACIONAL - SEDE BRUNCA', 0
txtCred3        db 'II CICLO 2026', 0
txtCred4        db 'PROFESOR:', 0
txtCred6        db 'GABRIEL NUNEZ M.', 0
txtCred7        db 'SPRITES ORIGINALES  -  TASM 3.2', 0

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
    call SetPalette             ; after the mode switch, which resets it
    call InitFont               ; find the BIOS letter shapes once
    call InitRandom             ; seed once, so every game differs

    call TitleScreen            ; RF-01

M_Menu:
    call MenuScreen             ; AL = option chosen
    cmp  al, 0
    je   M_Play
    cmp  al, 1
    jne  M_NotLevel
    call LevelScreen
    jmp  M_Menu
M_NotLevel:
    cmp  al, 2
    jne  M_NotHelp
    call InstructionsScreen
    jmp  M_Menu
M_NotHelp:
    cmp  al, 3
    jne  M_Quit                 ; option 4 = SALIR
    call CreditsScreen
    jmp  M_Menu

M_Play:
    call NewGame
    call PlayGame               ; AL = RESULT_MENU / AGAIN / QUIT
    cmp  al, RESULT_AGAIN
    je   M_Play
    cmp  al, RESULT_QUIT
    jne  M_Menu

M_Quit:
    call RestoreVideoMode       ; RF-14: leave DOS as we found it
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
; SetPalette - program our own colors into the VGA DAC (RG-07)
; Receives : paletteTable (PAL_COUNT colors x 3 bytes)
; Returns  : colors PAL_FIRST .. PAL_FIRST+PAL_COUNT-1 redefined
; Destroys : nothing
; Notes    : one OUT to 3C8h selects the first color; after that the DAC
;            takes R, G, B through 3C9h and moves on to the next color by
;            itself, so the whole table is sent in a single loop.
;            Setting a video mode reloads the default palette, so this
;            runs after SetMode13h, and DOS gets its colors back on exit.
;------------------------------------------------------------------------------
SetPalette PROC
    push ax
    push cx
    push dx
    push si

    mov  dx, DAC_WRITE
    mov  al, PAL_FIRST
    out  dx, al                 ; start writing at color 16

    mov  dx, DAC_DATA
    mov  si, OFFSET paletteTable
    mov  cx, PAL_COUNT * 3      ; 3 bytes (R, G, B) per color
    cld
SPal_Next:
    lodsb                       ; AL = next channel value
    out  dx, al
    loop SPal_Next

    pop  si
    pop  dx
    pop  cx
    pop  ax
    ret
SetPalette ENDP

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
    mov  lastStatusMsg, si      ; remember it for RepaintStatus
    mov  lastStatusColor, cl

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
; RepaintStatus - draw the status bar again with its current message
; Receives : lastStatusMsg, lastStatusColor
; Returns  : nothing (statusDirty keeps its value)
; Destroys : nothing
; Notes    : with 14 px rows the last row and its cursor reach 2-3 px
;            into zone D; repainting the bar keeps zone D clean
;------------------------------------------------------------------------------
RepaintStatus PROC
    push ax
    push cx
    push si
    mov  al, statusDirty        ; ShowStatus sets it to 1, keep the real one
    mov  si, lastStatusMsg
    mov  cl, lastStatusColor
    call ShowStatus
    mov  statusDirty, al
    pop  si
    pop  cx
    pop  ax
    ret
RepaintStatus ENDP

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
; Receives : AL = row index 0..numTries-1
;            rowH, rowY0, triesUsed, numPos, history, historyBulls, historyCows,
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

    ; DX = y of this row = rowY0 + row*rowH  (16 or 14 by level)
    mul  rowH                   ; AX = AL * rowH
    add  ax, rowY0
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
; Receives : AL = row index 0..numTries-1
; Returns  : nothing
; Destroys : nothing
; Notes    : RG-08, only what changes is redrawn. The 18x18 cursor frame
;            sticks out of its row, so the wiped strip is as tall as the
;            frame and the rows above and below are redrawn too.
;------------------------------------------------------------------------------
RefreshRow PROC
    push ax
    push bx
    push dx
    push si
    push di

    call WaitRetrace            ; draw while the beam is off screen

    ; Wipe the strip covered by the cursor: from 1 px above the row,
    ; CURSOR_H px tall
    push ax
    xor  ah, ah
    mul  rowH                   ; AX = row * rowH
    add  ax, rowY0
    dec  ax
    mov  dx, ax                 ; DX = top of the strip
    mov  bx, BOARD_X + 1        ; inside the board frame
    mov  si, BOARD_W - 2
    mov  di, CURSOR_H
    mov  al, BG_COLOR
    call FillRect
    pop  ax
    push dx                     ; checked at the end

    ; Previous row (its bottom line was wiped)
    cmp  al, 0
    je   RR_Self
    dec  al
    call DrawBoardRow
    inc  al
RR_Self:
    call DrawBoardRow
    ; Next row (its top lines were wiped)
    inc  al
    cmp  al, numTries
    jae  RR_Status
    call DrawBoardRow

RR_Status:
    pop  dx                     ; top of the strip
    ; Near the bottom, the strip or the next row's potions (16 px tall
    ; on a rowH step) may reach zone D: repaint the bar in that case
    mov  ax, STATUS_Y - CURSOR_H
    sub  al, rowH               ; AX = last strip top that stays clear
    cmp  dx, ax
    jbe  RR_Done
    call RepaintStatus
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
    DRAW_TEXT 8, 6, TITLE_COLOR, txtTitle

    mov  bl, levelIdx           ; level name comes from a table of
    xor  bh, bh                 ; string offsets, indexed by level
    shl  bx, 1
    mov  si, levelNameTable[bx]
    mov  bx, 200
    mov  dx, 6
    mov  cl, ACCENT_COLOR
    call DrawText

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
    cmp  al, numTries
    jb   DB_Row

    ; ---- Zone D: status bar, after the rows so it stays on top ----
    call DrawHelp

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
    cmp  gameState, STATE_PLAYING
    jne  TC_Show                ; game over: show the attempts really used
    inc  al                     ; the attempt being played now
TC_Show:
    mov  cl, TEXT_COLOR
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
    DRAW_TEXT 212, 28, TITLE_COLOR, txtFichas

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
    mov  cl, TEXT_COLOR
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
; Notes    : the 18x18 frame starts 1 px up and left of the 16x16 slot;
;            mascotFrame picks marco1 or marco2 (RG-05 animation)
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
    mul  rowH                   ; AX = row * rowH
    add  ax, rowY0
    dec  ax
    mov  dx, ax                 ; DX = y of the frame

    cmp  mascotFrame, 0         ; same clock as the mascot:
    jne  CU_Frame2              ; the frame blinks yellow / white
    DRAW_SPRITE bx, dx, marco1_W, marco1_H, marco1
    jmp  CU_Done
CU_Frame2:
    DRAW_SPRITE bx, dx, marco2_W, marco2_H, marco2
CU_Done:
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
; Returns  : numPos, numColors, allowRepeat, numTries, rowH, rowY0
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
    mov  numTries, al

    ; Zone B is 168 px tall: 10 rows of 16 px, or 12 rows of 14 px.
    ; Every attempt stays visible at the same time (RF-09).
    mov  rowH, ROW_H
    mov  rowY0, BOARD_Y0
    cmp  al, ROW_LIMIT_16
    jbe  LL_Done
    mov  rowH, ROW_H_EASY
    mov  rowY0, BOARD_Y0_EASY
LL_Done:
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

    ; While playing, the panel cauldron and the cursor are animated
    mov  animFlags, ANIM_MASCOT OR ANIM_CURSOR
    mov  mascotFrame, 0
    mov  mascotX, 252
    mov  mascotY, 136

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
; Returns  : AL = RESULT_MENU, RESULT_AGAIN or RESULT_QUIT
; Destroys : AH
; Notes    : extended keys (arrows, F2) arrive with AL = 0 or E0h and
;            their identity in the scan code AH; normal keys in AL.
;            Keys are read through WaitKeyAnimated, so the cauldron
;            and the cursor keep moving while the player thinks.
;------------------------------------------------------------------------------
PlayGame PROC
PG_Loop:
    cmp  gameState, STATE_PLAYING
    je   PG_Read
    call EndGame                ; AL = AGAIN / MENU / QUIT
    jmp  PG_Exit

PG_Read:
    call WaitKeyAnimated        ; AL = ASCII, AH = scan code
    call RestoreHelp            ; any warning disappears on a new key

    cmp  al, KEY_ESC
    jne  PG_NotEsc
    mov  al, RESULT_MENU        ; ESC during a game: back to the menu
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
    cmp  al, 's'
    je   PG_Secret
    cmp  al, 'S'
    je   PG_Secret              ; S = use the row as secret (test mode)
    call TypeColor              ; ignores keys that are not colors
    jmp  PG_Loop
PG_Secret:
    call SetManualSecret
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
; EndGame - RF-11/RF-12: end screen, secret revealed, animated result
; Receives : gameState (WON or LOST), secretCode, numPos, bulls, cows,
;            triesUsed
; Returns  : AL = RESULT_AGAIN (ENTER), RESULT_MENU (M), RESULT_QUIT (ESC)
; Destroys : AH
; Notes    : win and lose share the layout but not the animation:
;            winning makes gold sparks jump and the title flash gold/green,
;            losing makes grey smoke rise and the title blink dim red
;------------------------------------------------------------------------------
EndGame PROC
    push bx
    push cx
    push dx
    push si
    push di

    mov  animFlags, 0           ; nothing moves while the screen is built
    mov  al, BG_COLOR
    call ClearScreen
    mov  si, OFFSET txtTitle
    call DrawHeaderBar

    ; ---- The secret, centered: x0 = 162 - numPos*10 ----
    DRAW_TEXT 104, 60, FRAME_COLOR, txtCodeLbl
    mov  al, numPos
    mov  bl, 10
    mul  bl                     ; AX = numPos * 10
    mov  bx, 162
    sub  bx, ax                 ; BX = x of the first potion
    mov  dx, 72
    xor  si, si                 ; SI = position of the secret
EGm_Potion:
    mov  al, secretCode[si]
    call DrawPotion
    add  bx, SLOT_STEP
    inc  si
    mov  al, numPos
    xor  ah, ah
    cmp  si, ax
    jb   EGm_Potion

    ; ---- Result of the last attempt ----
    DRAW_SPRITE 136, 96, chispa_W, chispa_H, chispa
    mov  al, bulls
    add  al, '0'
    mov  bx, 146
    mov  dx, 96
    mov  cl, TITLE_COLOR
    call DrawChar
    DRAW_SPRITE 166, 96, burbuja_W, burbuja_H, burbuja
    mov  al, cows
    add  al, '0'
    mov  bx, 176
    mov  cl, ACCENT_COLOR
    call DrawChar

    ; ---- Attempts used ----
    DRAW_TEXT 84, 112, TEXT_COLOR, txtUsed
    mov  al, triesUsed
    mov  bx, 220
    mov  dx, 112
    mov  cl, TEXT_COLOR
    call DrawNumber2

    mov  si, OFFSET txtEndHelp
    mov  cl, HELP_COLOR
    call ShowStatus

    ; ---- Start the animation (title + both cauldrons) ----
    mov  mascotFrame, 0
    call DrawEndAnim
    mov  animFlags, ANIM_END

EGm_Wait:
    call WaitKeyAnimated        ; animation keeps running meanwhile
    cmp  al, KEY_ENTER
    je   EGm_Again
    cmp  al, KEY_ESC
    je   EGm_Quit
    or   al, 20h                ; lowercase, so 'M' and 'm' both work
    cmp  al, 'm'
    jne  EGm_Wait               ; only ENTER, M or ESC mean something
    mov  al, RESULT_MENU
    jmp  EGm_Done
EGm_Quit:
    mov  al, RESULT_QUIT
    jmp  EGm_Done
EGm_Again:
    mov  al, RESULT_AGAIN
EGm_Done:
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    ret
EndGame ENDP

;------------------------------------------------------------------------------
; DrawEndAnim - draw the current frame of the end screen animation
; Receives : gameState, mascotFrame
; Returns  : nothing
; Destroys : nothing
; Notes    : wipes only the two small boxes around the cauldrons (RG-08);
;            the title is redrawn in place with the other color, its
;            pixels are exactly the same so nothing needs wiping there
;------------------------------------------------------------------------------
DrawEndAnim PROC
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    call WaitRetrace
    mov  dx, END_CY - 24
    mov  si, END_BOX_W
    mov  di, END_BOX_H
    mov  al, BG_COLOR
    mov  bx, END_LEFT_X - 16
    call FillRect
    mov  bx, END_RIGHT_X - 16
    call FillRect

    mov  bx, END_LEFT_X
    call DrawEndSide
    mov  bx, END_RIGHT_X
    call DrawEndSide

    ; ---- Title: win flashes green/gold, lose blinks red/dim ----
    cmp  gameState, STATE_WON
    jne  DEA_Lost
    mov  si, OFFSET txtWon
    mov  cl, WIN_COLOR
    cmp  mascotFrame, 0
    je   DEA_Title
    mov  cl, TITLE_COLOR
    jmp  DEA_Title
DEA_Lost:
    mov  si, OFFSET txtLost
    mov  cl, LOSE_COLOR
    cmp  mascotFrame, 0
    je   DEA_Title
    mov  cl, FRAME_COLOR
DEA_Title:
    mov  bx, END_TITLE_X
    mov  dx, END_TITLE_Y
    call DrawText

    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
DrawEndAnim ENDP

;------------------------------------------------------------------------------
; DrawEndSide - one cauldron with its sparks (win) or smoke (lose)
; Receives : BX = x of the cauldron, gameState, mascotFrame, endOffsets
; Returns  : nothing
; Destroys : nothing
; Notes    : the 3 positions come from endOffsets, a table indexed by
;            result and frame, so the animation is data, not code
;------------------------------------------------------------------------------
DrawEndSide PROC
    push ax
    push cx
    push dx
    push si
    push di

    mov  dx, END_CY
    cmp  mascotFrame, 0
    jne  DES_Frame2
    DRAW_SPRITE bx, dx, caldero1_W, caldero1_H, caldero1
    jmp  DES_Group
DES_Frame2:
    DRAW_SPRITE bx, dx, caldero2_W, caldero2_H, caldero2

DES_Group:
    xor  ax, ax                 ; group 0/1 = win, 2/3 = lose
    cmp  gameState, STATE_WON
    je   DES_AddFrame
    mov  al, 2
DES_AddFrame:
    add  al, mascotFrame
    mov  cl, 12                 ; 3 pairs of words per group
    mul  cl
    mov  si, ax                 ; SI = byte offset of the group

    mov  cx, 3
DES_Next:
    mov  ax, endOffsets[si]     ; dx of this particle
    add  ax, bx
    mov  di, endOffsets[si+2]   ; dy of this particle
    add  di, END_CY
    cmp  gameState, STATE_WON
    jne  DES_Smoke
    DRAW_SPRITE ax, di, chispa_W, chispa_H, chispa
    jmp  DES_Step
DES_Smoke:
    DRAW_SPRITE ax, di, burbuja_W, burbuja_H, burbuja
DES_Step:
    add  si, 4
    loop DES_Next

    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  ax
    ret
DrawEndSide ENDP

;==============================================================================
;                         ANIMATION AND MENUS
;==============================================================================

;------------------------------------------------------------------------------
; GetTicks - read the BIOS tick counter
; Receives : nothing
; Returns  : AX = low word of ticks since midnight (0040h:006Ch)
; Destroys : nothing
; Notes    : the timer chip bumps this word ~18.2 times per second, on
;            any CPU, so animations timed with it run at the same speed
;            on a slow or a fast machine (RG-06)
;------------------------------------------------------------------------------
GetTicks PROC
    push bx
    push es
    mov  ax, TICKS_SEG
    mov  es, ax                 ; ES -> BIOS data area
    mov  bx, TICKS_OFF
    mov  ax, es:[bx]
    pop  es
    pop  bx
    ret
GetTicks ENDP

;------------------------------------------------------------------------------
; DrawMascot - draw the current frame of the cauldron
; Receives : mascotX, mascotY, mascotFrame
; Returns  : nothing
; Destroys : nothing
; Notes    : the two frames differ (bubbles, flames), so the old one is
;            wiped first; WaitRetrace hides the wipe from the eye
;------------------------------------------------------------------------------
DrawMascot PROC
    push ax
    push bx
    push dx
    push si
    push di

    call WaitRetrace
    mov  bx, mascotX
    mov  dx, mascotY
    mov  si, caldero1_W
    mov  di, caldero1_H
    mov  al, BG_COLOR
    call FillRect               ; erase the previous frame

    cmp  mascotFrame, 0
    jne  DM_Frame2
    DRAW_SPRITE bx, dx, caldero1_W, caldero1_H, caldero1
    jmp  DM_Done
DM_Frame2:
    DRAW_SPRITE bx, dx, caldero2_W, caldero2_H, caldero2
DM_Done:
    pop  di
    pop  si
    pop  dx
    pop  bx
    pop  ax
    ret
DrawMascot ENDP

;------------------------------------------------------------------------------
; WaitKeyAnimated - wait for a key while the animations keep running
; Receives : animFlags (what to animate), mascotX/Y
; Returns  : AL = ASCII, AH = scan code of the key pressed
; Destroys : nothing else
; Notes    : INT 16h AH=01h only PEEKS (ZF=1: no key), so the loop never
;            blocks. Every ANIM_TICKS ticks the frame flips and the
;            animated elements are redrawn. The subtraction works even
;            when the 16-bit counter wraps around.
;------------------------------------------------------------------------------
WaitKeyAnimated PROC
    push cx

    call GetTicks
    mov  lastTick, ax

WK_Loop:
    mov  ah, 01h
    int  16h                    ; is a key waiting? (does not remove it)
    jnz  WK_Key

    call GetTicks
    mov  cx, ax
    sub  ax, lastTick           ; ticks since the last frame
    cmp  ax, ANIM_TICKS
    jb   WK_Loop                ; too soon: keep waiting

    mov  lastTick, cx
    xor  mascotFrame, 1         ; 0 <-> 1
    test animFlags, ANIM_MASCOT
    jz   WK_NoMascot
    call DrawMascot
WK_NoMascot:
    test animFlags, ANIM_CURSOR
    jz   WK_NoCursor
    call DrawCursor
WK_NoCursor:
    test animFlags, ANIM_END
    jz   WK_Loop
    call DrawEndAnim
    jmp  WK_Loop

WK_Key:
    mov  ah, 00h
    int  16h                    ; now take the key out of the buffer

    pop  cx
    ret
WaitKeyAnimated ENDP

;------------------------------------------------------------------------------
; DrawHeaderBar - zone A style bar with a title
; Receives : SI = offset of the title
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
DrawHeaderBar PROC
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    push si                     ; FillRect uses SI as width
    xor  bx, bx
    xor  dx, dx
    mov  si, SCREEN_W
    mov  di, 20
    mov  al, BAR_COLOR
    call FillRect
    pop  si

    mov  bx, 8
    mov  dx, 6
    mov  cl, TITLE_COLOR
    call DrawText

    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
DrawHeaderBar ENDP

;------------------------------------------------------------------------------
; DrawPotionRow - the 8 potions in a row, as decoration
; Receives : DX = y
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
DrawPotionRow PROC
    push ax
    push bx
    push cx
    mov  bx, 40
    mov  al, 1                  ; color numbers 1..8
    mov  cx, MAX_COLOR
PR_Next:
    call DrawPotion
    add  bx, 30
    inc  al
    loop PR_Next
    pop  cx
    pop  bx
    pop  ax
    ret
DrawPotionRow ENDP

;------------------------------------------------------------------------------
; DrawList - draw a vertical list of options, highlighting one
; Receives : listTable, listCount, listSel, listX, listY
; Returns  : nothing
; Destroys : nothing
; Notes    : the highlighted option gets a colored bar and yellow text;
;            the others are drawn on the background so an old
;            highlight disappears (only the list area is redrawn)
;------------------------------------------------------------------------------
DrawList PROC
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    call WaitRetrace
    mov  si, listTable          ; SI -> table of string offsets
    mov  dx, listY
    xor  ch, ch                 ; CH = item index (CL is the text color)

DL_Item:
    ; Bar behind the item: highlight color or background
    mov  bx, listX
    sub  bx, 4
    push dx
    sub  dx, 4
    push si
    mov  si, LIST_W
    mov  di, 16
    mov  al, BG_COLOR
    cmp  ch, listSel
    jne  DL_Bar
    mov  al, SEL_COLOR
DL_Bar:
    call FillRect
    pop  si
    pop  dx

    ; Item text
    mov  cl, FRAME_COLOR
    cmp  ch, listSel
    jne  DL_Text
    mov  cl, TITLE_COLOR        ; selected: gold
DL_Text:
    push si
    mov  bx, listX
    mov  si, [si]               ; SI = offset of this item's string
    call DrawText
    pop  si

    add  si, 2                  ; next entry of the table
    add  dx, 16                 ; next line
    inc  ch
    cmp  ch, listCount
    jb   DL_Item

    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
DrawList ENDP

;------------------------------------------------------------------------------
; SelectFromList - let the player pick an option with the arrows
; Receives : SI = table of string offsets, CL = number of options,
;            AL = option highlighted at start, BX = x, DX = y of option 0
; Returns  : AL = chosen option; CF = 0 with ENTER, CF = 1 with ESC
; Destroys : AH
; Notes    : one routine for every menu, the lists are just data
;------------------------------------------------------------------------------
SelectFromList PROC
    mov  listTable, si
    mov  listCount, cl
    mov  listSel, al
    mov  listX, bx
    mov  listY, dx
    call DrawList

SL_Key:
    call WaitKeyAnimated
    cmp  al, KEY_ENTER
    je   SL_Enter
    cmp  al, KEY_ESC
    je   SL_Esc
    cmp  ah, SC_UP
    je   SL_Up
    cmp  ah, SC_DOWN
    jne  SL_Key                 ; any other key: ignore it

    mov  al, listSel            ; DOWN: next option, wrap to the first
    inc  al
    cmp  al, listCount
    jb   SL_Set
    xor  al, al
    jmp  SL_Set
SL_Up:
    mov  al, listSel            ; UP: previous option, wrap to the last
    cmp  al, 0
    jne  SL_Dec
    mov  al, listCount
SL_Dec:
    dec  al
SL_Set:
    mov  listSel, al
    call DrawList               ; only the list is redrawn
    jmp  SL_Key

SL_Enter:
    mov  al, listSel
    clc
    ret
SL_Esc:
    mov  al, listSel
    stc
    ret
SelectFromList ENDP

;------------------------------------------------------------------------------
; TitleScreen - RF-01: name, theme, author, animated mascot, wait a key
; Receives : nothing
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
TitleScreen PROC
    push ax
    push bx
    push cx
    push dx
    push si

    mov  al, BG_COLOR
    call ClearScreen
    mov  si, OFFSET txtBigTitle
    call DrawHeaderBar

    DRAW_TEXT 128,  28, 13, txtSubtitle
    mov  dx, 44
    call DrawPotionRow
    DRAW_TEXT  52, 108, 10, txtTagline
    DRAW_TEXT   0, 128, FRAME_COLOR, txtCourse
    DRAW_TEXT  76, 144, FRAME_COLOR, txtBy
    DRAW_TEXT 116, 144, TEXT_COLOR, txtAuthorName

    mov  si, OFFSET txtPressKey
    mov  cl, HELP_COLOR
    call ShowStatus

    mov  animFlags, ANIM_MASCOT ; the cauldron bubbles until a key
    mov  mascotFrame, 0
    mov  mascotX, 152
    mov  mascotY, 80
    call DrawMascot
    call WaitKeyAnimated

    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
TitleScreen ENDP

;------------------------------------------------------------------------------
; MenuScreen - RF-02: main menu
; Receives : menuSel (option highlighted at start)
; Returns  : AL = 0 play, 1 level, 2 instructions, 3 credits, 4 quit
; Destroys : AH
;------------------------------------------------------------------------------
MenuScreen PROC
    push bx
    push cx
    push dx
    push si

    mov  al, BG_COLOR
    call ClearScreen
    mov  si, OFFSET txtTitle
    call DrawHeaderBar
    mov  dx, 156
    call DrawPotionRow
    mov  si, OFFSET txtMenuHelp
    mov  cl, HELP_COLOR
    call ShowStatus

    mov  animFlags, ANIM_MASCOT
    mov  mascotFrame, 0
    mov  mascotX, 152
    mov  mascotY, 28
    call DrawMascot

MN_Ask:
    mov  si, OFFSET menuTable
    mov  cl, MENU_ITEMS
    mov  al, menuSel
    mov  bx, 84
    mov  dx, 60
    call SelectFromList
    jc   MN_Ask                 ; ESC in the main menu does nothing
    mov  menuSel, al            ; remembered for the next visit

    pop  si
    pop  dx
    pop  cx
    pop  bx
    ret
MenuScreen ENDP

;------------------------------------------------------------------------------
; LevelScreen - choose Facil / Normal / Dificil
; Receives : levelIdx (highlighted at start)
; Returns  : levelIdx changed with ENTER, unchanged with ESC
; Destroys : nothing
;------------------------------------------------------------------------------
LevelScreen PROC
    push ax
    push bx
    push cx
    push dx
    push si

    mov  al, BG_COLOR
    call ClearScreen
    mov  si, OFFSET txtLevelTitle
    call DrawHeaderBar
    DRAW_TEXT 8, 116, FRAME_COLOR, txtLvlInfo0
    DRAW_TEXT 8, 128, FRAME_COLOR, txtLvlInfo1
    DRAW_TEXT 8, 140, FRAME_COLOR, txtLvlInfo2
    DRAW_TEXT 8, 156, TEXT_COLOR, txtLvlInfo3
    mov  si, OFFSET txtLevelHelp
    mov  cl, HELP_COLOR
    call ShowStatus

    mov  animFlags, 0           ; nothing animated on this screen
    mov  si, OFFSET levelOptTable
    mov  cl, LEVEL_ITEMS
    mov  al, levelIdx
    mov  bx, 84
    mov  dx, 44
    call SelectFromList
    jc   LV_Done                ; ESC: keep the old level
    mov  levelIdx, al
LV_Done:
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
LevelScreen ENDP

;------------------------------------------------------------------------------
; InstructionsScreen - RF-03: rules explained with the game's own sprites
; Receives : nothing
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
InstructionsScreen PROC
    push ax
    push bx
    push cx
    push dx
    push si

    mov  al, BG_COLOR
    call ClearScreen
    mov  si, OFFSET txtHelpTitle
    call DrawHeaderBar

    DRAW_TEXT 8, 26, TEXT_COLOR, txtHelp1
    DRAW_TEXT 8, 36, TEXT_COLOR, txtHelp2
    DRAW_TEXT 8, 46, TEXT_COLOR, txtHelp3

    ; What each icon means, shown with the real icons
    DRAW_SPRITE 8, 62, chispa_W, chispa_H, chispa
    DRAW_TEXT  24, 62, 14, txtHelpBull
    DRAW_SPRITE 8, 76, burbuja_W, burbuja_H, burbuja
    DRAW_TEXT  24, 76, 11, txtHelpCow

    ; Worked example: recipe 1234, attempt 1325 -> 1 bull, 2 cows
    DRAW_TEXT 8, 92, FRAME_COLOR, txtHelpExample
    DRAW_TEXT 8, 108, FRAME_COLOR, txtHelpRecipe
    DRAW_TEXT 8, 128, FRAME_COLOR, txtHelpGuess
    xor  si, si
    mov  bx, 80
IN_Potion:
    mov  dx, 104
    mov  al, helpRecipe[si]
    call DrawPotion
    mov  dx, 124
    mov  al, helpGuess[si]
    call DrawPotion
    add  bx, SLOT_STEP
    inc  si
    cmp  si, 4
    jb   IN_Potion
    DRAW_SPRITE 170, 128, chispa_W, chispa_H, chispa
    DRAW_TEXT   180, 128, 14, txtHelpOne
    DRAW_SPRITE 194, 128, burbuja_W, burbuja_H, burbuja
    DRAW_TEXT   204, 128, 11, txtHelpTwo

    DRAW_TEXT 8, 148, 10, txtHelpKeys1
    DRAW_TEXT 8, 160, 10, txtHelpKeys2
    DRAW_TEXT 8, 172, 10, txtHelpKeys3

    mov  si, OFFSET txtBackKey
    mov  cl, HELP_COLOR
    call ShowStatus
    mov  animFlags, 0
    call WaitKeyAnimated

    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
InstructionsScreen ENDP

;------------------------------------------------------------------------------
; CreditsScreen - author, course and teachers
; Receives : nothing
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
CreditsScreen PROC
    push ax
    push bx
    push cx
    push dx
    push si

    mov  al, BG_COLOR
    call ClearScreen
    mov  si, OFFSET txtCreditsTitle
    call DrawHeaderBar

    DRAW_TEXT  76,  40, TITLE_COLOR, txtTitle
    DRAW_TEXT  40,  60, FRAME_COLOR, txtAuthorLbl
    DRAW_TEXT  96,  60, TEXT_COLOR, txtAuthorName
    DRAW_TEXT  20,  84, FRAME_COLOR, txtCred1
    DRAW_TEXT  24,  96, FRAME_COLOR, txtCred2
    DRAW_TEXT 108, 108, FRAME_COLOR, txtCred3
    DRAW_TEXT  40, 128, FRAME_COLOR, txtCred4
    DRAW_TEXT  56, 140, TEXT_COLOR, txtCred6
    DRAW_TEXT  36, 170, 10, txtCred7

    mov  si, OFFSET txtBackKey
    mov  cl, HELP_COLOR
    call ShowStatus

    mov  animFlags, ANIM_MASCOT
    mov  mascotFrame, 0
    mov  mascotX, 280
    mov  mascotY, 36
    call DrawMascot
    call WaitKeyAnimated

    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
CreditsScreen ENDP

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
