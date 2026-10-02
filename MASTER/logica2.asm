;==============================================================================
; EIF205 - Proyecto II - Mastermind Alquimia
; File   : logica.asm
; Phase  : 3b - Levels + random secret code, tested in text mode
;
; Standalone test program:
;   1. Choose a level: F (easy), N (normal), D (hard)
;   2. Secret: M = type it by hand (needed for the Table 2 review)
;              A = generate it at random (seeded by the BIOS tick counter)
;   3. Type a guess and see bulls and cows
;
; EvaluateGuess, InitRandom, NextRandom and GenerateSecret will later be
; moved, unchanged, into the real game.
;==============================================================================

.MODEL SMALL
.STACK 100h

MAX_POS     EQU 5               ; hardest level uses 5 positions
MAX_COLOR   EQU 8               ; hardest level uses 8 colors
KEY_ESC     EQU 1Bh

; Linear congruential generator constants: seed = seed * LCG_A + LCG_C
LCG_A       EQU 25173
LCG_C       EQU 13849

;------------------------------------------------------------------------------
; MACRO PRINT_STR - print a '$'-terminated string with DOS
; Preserves every register it touches.
;------------------------------------------------------------------------------
PRINT_STR MACRO msg
    push ax
    push dx
    mov  dx, OFFSET msg
    mov  ah, 09h
    int  21h
    pop  dx
    pop  ax
ENDM

.DATA
; ---- Current level settings (written by ReadLevel) ----
numPos      db 4                    ; positions in play: 4 or 5
numColors   db 6                    ; colors in play: 6 or 8
allowRepeat db 1                    ; 0 = colors may not repeat (easy)

; ---- Level table: positions, colors, repeat flag ----
; One row per level, 3 bytes each, so row = level * 3
levelTable  db 4, 6, 0              ; F - Facil
            db 4, 6, 1              ; N - Normal
            db 5, 8, 1              ; D - Dificil

seed        dw 0                    ; state of the pseudo-random generator

secretCode  db MAX_POS dup(0)       ; secret, one color number per position
guessCode   db MAX_POS dup(0)       ; player's attempt, same layout

; One counter per color. Index = color number, so index 0 is never used.
countSecret db MAX_COLOR+1 dup(0)
countGuess  db MAX_COLOR+1 dup(0)

bulls       db 0                    ; right color, right position
cows        db 0                    ; right color, wrong position

msgTitle    db 'Prueba de logica - ESC para salir',13,10,'$'
msgLevel    db 13,10,'Nivel: [F]acil  [N]ormal  [D]ificil ? $'
msgMode     db 13,10,'Secreto: [M]anual o [A]leatorio ? $'
msgSecret   db 13,10,'Secreto: $'
msgGuess    db 13,10,'Intento: $'
msgBulls    db 13,10,'Toros: $'
msgCows     db '   Vacas: $'
msgNL       db 13,10,'$'

.CODE
;==============================================================================
; main - level, secret, then guesses until ESC
;==============================================================================
main PROC
    mov  ax, @data
    mov  ds, ax                     ; DS must reach our variables

    call InitRandom                 ; seed once, so every game differs
    PRINT_STR msgTitle

NewGame:
    call ReadLevel
    jnc  HaveLevel                  ; Quit is too far for a short jump,
    jmp  Quit                       ; so skip over a near JMP instead
HaveLevel:

    ; ---- Secret: manual or random ----
    PRINT_STR msgMode
AskMode:
    mov  ah, 00h
    int  16h
    cmp  al, KEY_ESC
    jne  NotEscMode                 ; same trick: short jump over a near JMP
    jmp  Quit
NotEscMode:
    or   al, 20h                    ; force lowercase: 'M'->'m', 'A'->'a'
    cmp  al, 'm'
    je   ManualSecret
    cmp  al, 'a'
    jne  AskMode                    ; any other key: keep waiting

    call GenerateSecret
    PRINT_STR msgSecret
    mov  si, OFFSET secretCode
    call PrintCode                  ; shown only because this is a test
    jmp  GuessLoop

ManualSecret:
    PRINT_STR msgSecret
    mov  si, OFFSET secretCode
    call ReadCode
    jc   Quit

    ; ---- Guesses against the same secret ----
GuessLoop:
    PRINT_STR msgGuess
    mov  si, OFFSET guessCode
    call ReadCode
    jc   NewGame                    ; ESC on a guess: start a new game

    call EvaluateGuess

    PRINT_STR msgBulls
    mov  al, bulls
    call PrintDigit
    PRINT_STR msgCows
    mov  al, cows
    call PrintDigit
    PRINT_STR msgNL

    mov  al, bulls
    cmp  al, numPos
    jne  KeepGuessing               ; not cracked yet
    jmp  NewGame                    ; all bulls: code cracked
KeepGuessing:
    jmp  GuessLoop

Quit:
    mov  ax, 4C00h                  ; back to DOS, return code 0
    int  21h
main ENDP

;------------------------------------------------------------------------------
; ReadLevel - ask for F/N/D and load that row of levelTable
; Receives : nothing
; Returns  : numPos, numColors, allowRepeat set for the chosen level
;            CF = 1 if ESC was pressed, CF = 0 otherwise
; Destroys : nothing
;------------------------------------------------------------------------------
ReadLevel PROC
    push ax
    push bx
    push dx

    PRINT_STR msgLevel
RL_Wait:
    mov  ah, 00h
    int  16h
    cmp  al, KEY_ESC
    je   RL_Esc
    mov  dl, al                     ; keep the original key to echo it
    or   al, 20h                    ; lowercase, so 'F' and 'f' both work
    mov  bx, 0                      ; row offset of Facil
    cmp  al, 'f'
    je   RL_Load
    mov  bx, 3                      ; row offset of Normal
    cmp  al, 'n'
    je   RL_Load
    mov  bx, 6                      ; row offset of Dificil
    cmp  al, 'd'
    je   RL_Load
    jmp  RL_Wait                    ; not a level key: ignore it

RL_Load:
    mov  ah, 02h
    int  21h                        ; echo the chosen letter (DL)
    mov  al, levelTable[bx]         ; column 0: positions
    mov  numPos, al
    mov  al, levelTable[bx+1]       ; column 1: colors
    mov  numColors, al
    mov  al, levelTable[bx+2]       ; column 2: repeat allowed?
    mov  allowRepeat, al
    clc
    jmp  RL_Done

RL_Esc:
    stc
RL_Done:
    pop  dx
    pop  bx
    pop  ax
    ret
ReadLevel ENDP

;------------------------------------------------------------------------------
; InitRandom - seed the generator with the BIOS tick counter
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
    int  1Ah                        ; CX:DX = ticks since midnight
    mov  seed, dx                   ; the fast-changing low word
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
    mul  bx                         ; DX:AX = seed * A (we keep only AX)
    add  ax, LCG_C
    mov  seed, ax                   ; new state

    ; The high byte of an LCG is more random than the low byte,
    ; whose lowest bit just alternates 0,1,0,1...
    mov  al, ah
    xor  ah, ah                     ; AX = 0..255
    mov  bl, numColors
    div  bl                         ; AH = AX mod numColors (0..numColors-1)
    mov  al, ah
    inc  al                         ; shift to color range 1..numColors

    pop  dx
    pop  bx
    ret
NextRandom ENDP

;------------------------------------------------------------------------------
; GenerateSecret - fill secretCode with random colors for the current level
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

    xor  si, si                     ; SI = position being filled
GS_NextPos:
    call NextRandom                 ; AL = candidate color
    cmp  allowRepeat, 0
    jne  GS_Store                   ; repeats allowed: take it as is

    ; Look for AL in the positions already filled (0 .. SI-1)
    xor  bx, bx
GS_Check:
    cmp  bx, si
    je   GS_Store                   ; checked all previous: AL is new
    cmp  secretCode[bx], al
    je   GS_NextPos                 ; already used: draw another color
    inc  bx
    jmp  GS_Check

GS_Store:
    mov  secretCode[si], al
    inc  si
    mov  cl, numPos
    xor  ch, ch
    cmp  si, cx
    jb   GS_NextPos                 ; more positions to fill

    pop  si
    pop  cx
    pop  bx
    pop  ax
    ret
GenerateSecret ENDP

;------------------------------------------------------------------------------
; ReadCode - read numPos color digits from the keyboard into an array
; Receives : SI = offset of the destination array
; Returns  : array filled with color numbers 1..numColors
;            CF = 1 if the user pressed ESC (array incomplete), CF = 0 if not
; Destroys : nothing
; Notes    : keys outside '1'..numColors are ignored
;------------------------------------------------------------------------------
ReadCode PROC
    push ax
    push cx
    push dx
    push si

    xor  ch, ch
    mov  cl, numPos                 ; CX = how many digits we still need
    mov  dh, '0'
    add  dh, numColors              ; DH = highest valid key, '6' or '8'

RC_Next:
    mov  ah, 00h
    int  16h                        ; wait for a key: AL = ASCII
    cmp  al, KEY_ESC
    je   RC_Esc
    cmp  al, '1'
    jb   RC_Next                    ; below '1': not a color, ignore it
    cmp  al, dh
    ja   RC_Next                    ; beyond this level's colors: ignore

    mov  dl, al
    mov  ah, 02h
    int  21h                        ; echo the digit so the user sees it

    sub  dl, '0'                    ; ASCII -> color number
    mov  [si], dl                   ; store it in the current position
    inc  si                         ; next position of the array
    loop RC_Next

    clc                             ; complete code: no ESC
    jmp  RC_Done

RC_Esc:
    stc                             ; tell the caller the user quit

RC_Done:
    pop  si                         ; POP does not change the flags,
    pop  dx                         ; so CF survives until RET
    pop  cx
    pop  ax
    ret
ReadCode ENDP

;------------------------------------------------------------------------------
; PrintCode - print numPos color digits of an array
; Receives : SI = offset of the array
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
PrintCode PROC
    push ax
    push cx
    push si

    xor  ch, ch
    mov  cl, numPos
PC_Next:
    mov  al, [si]
    call PrintDigit
    inc  si
    loop PC_Next

    pop  si
    pop  cx
    pop  ax
    ret
PrintCode ENDP

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
    xor  si, si                     ; SI = position index
    xor  ch, ch
    mov  cl, numPos
EG_Pass1:
    mov  al, secretCode[si]         ; AL = secret color at this position
    mov  ah, guessCode[si]          ; AH = guessed color at this position
    cmp  al, ah
    jne  EG_NotBull
    inc  bulls                      ; same color, same place
    jmp  EG_Next1
EG_NotBull:
    xor  bh, bh
    mov  bl, al
    inc  countSecret[bx]            ; secret still has one unmatched 'AL'
    mov  bl, ah
    inc  countGuess[bx]             ; guess still has one unmatched 'AH'
EG_Next1:
    inc  si
    loop EG_Pass1

    ; ---- Pass 2: cows = sum over colors of min(secret, guess) ----
    mov  bx, 1                      ; colors go from 1 to MAX_COLOR
    mov  cx, MAX_COLOR
EG_Pass2:
    mov  al, countSecret[bx]
    mov  ah, countGuess[bx]
    cmp  al, ah
    jbe  EG_HaveMin                 ; AL is already the smaller one
    mov  al, ah                     ; otherwise the guess count is smaller
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

;------------------------------------------------------------------------------
; PrintDigit - print one decimal digit
; Receives : AL = value 0..9
; Returns  : nothing
; Destroys : nothing
;------------------------------------------------------------------------------
PrintDigit PROC
    push ax
    push dx
    mov  dl, al
    add  dl, '0'                    ; value 0..9 -> ASCII '0'..'9'
    mov  ah, 02h
    int  21h
    pop  dx
    pop  ax
    ret
PrintDigit ENDP

END main
