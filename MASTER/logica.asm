;==============================================================================
; EIF205 - Proyecto II - Mastermind Alquimia
; File   : logica.asm
; Phase  : 3a - Bulls and cows algorithm, tested in text mode
;
; Standalone test program: the user types a secret code and a guess
; (digits 1..8 = potion colors) and the program prints bulls and cows.
; This is the "manual secret entry" the assignment requires to run the
; four cases of Table 2 during the review.
;
; EvaluateGuess will later be moved, unchanged, into the real game.
;==============================================================================

.MODEL SMALL
.STACK 100h

MAX_POS     EQU 5               ; hardest level uses 5 positions
MAX_COLOR   EQU 8               ; hardest level uses 8 colors
KEY_ESC     EQU 1Bh

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
numPos      db 4                    ; positions in play (4 or 5 by level)

secretCode  db MAX_POS dup(0)       ; secret, one color number per position
guessCode   db MAX_POS dup(0)       ; player's attempt, same layout

; One counter per color. Index = color number, so index 0 is never used.
countSecret db MAX_COLOR+1 dup(0)
countGuess  db MAX_COLOR+1 dup(0)

bulls       db 0                    ; right color, right position
cows        db 0                    ; right color, wrong position

msgTitle    db 'Prueba de toros y vacas - colores 1 a 8, ESC para salir',13,10,'$'
msgSecret   db 13,10,'Secreto: $'
msgGuess    db 13,10,'Intento: $'
msgBulls    db 13,10,'Toros: $'
msgCows     db '   Vacas: $'
msgNL       db 13,10,'$'

.CODE
;==============================================================================
; main - ask for secret and guess forever, print the result each time
;==============================================================================
main PROC
    mov  ax, @data
    mov  ds, ax                     ; DS must reach our variables

    PRINT_STR msgTitle

MainLoop:
    PRINT_STR msgSecret
    mov  si, OFFSET secretCode
    call ReadCode
    jc   Quit                       ; ESC pressed

    PRINT_STR msgGuess
    mov  si, OFFSET guessCode
    call ReadCode
    jc   Quit

    call EvaluateGuess

    PRINT_STR msgBulls
    mov  al, bulls
    call PrintDigit
    PRINT_STR msgCows
    mov  al, cows
    call PrintDigit
    PRINT_STR msgNL
    jmp  MainLoop

Quit:
    mov  ax, 4C00h                  ; back to DOS, return code 0
    int  21h
main ENDP

;------------------------------------------------------------------------------
; ReadCode - read numPos color digits from the keyboard into an array
; Receives : SI = offset of the destination array
; Returns  : array filled with color numbers 1..8
;            CF = 1 if the user pressed ESC (array incomplete), CF = 0 if not
; Destroys : nothing
; Notes    : keys other than '1'..'8' and ESC are ignored
;------------------------------------------------------------------------------
ReadCode PROC
    push ax
    push cx
    push dx
    push si

    xor  ch, ch
    mov  cl, numPos                 ; CX = how many digits we still need

RC_Next:
    mov  ah, 00h
    int  16h                        ; wait for a key: AL = ASCII
    cmp  al, KEY_ESC
    je   RC_Esc
    cmp  al, '1'
    jb   RC_Next                    ; below '1': not a color, ignore it
    cmp  al, '0'+MAX_COLOR
    ja   RC_Next                    ; above '8': not a color, ignore it

    mov  dl, al
    mov  ah, 02h
    int  21h                        ; echo the digit so the user sees it

    sub  dl, '0'                    ; ASCII '1'..'8' -> color number 1..8
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
;   Bulls never reach the counters, so a piece counted as bull can
;   never be counted again as cow. The min() makes sure that extra
;   copies of a color in the guess find nothing to pair with.
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
