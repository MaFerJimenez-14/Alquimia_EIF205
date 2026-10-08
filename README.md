# Mastermind · Alquimia

Proyecto II de **EIF205 Arquitectura de Computadores** — Universidad Nacional, Sede Regional Brunca, II Ciclo 2026.
Autora: **María Jiménez**. Profesor: Gabriel Núñez M.

Versión del juego Mastermind (Toros y Vacas) en **ensamblador x86 de 16 bits**, modo gráfico **13h** (320×200, 256 colores), con temática de **alquimia**: las fichas son 8 pociones con frascos de formas distintas, el acierto exacto es una **chispa** y el acierto parcial es una **burbuja**. La mascota es un caldero que hierve.

---

## 1. Requisitos

- **DOSBox 0.74-3** (https://www.dosbox.com)
- **Turbo Assembler 3.2 y Turbo Link 3.01** (paquete TASM del curso: `TASM.EXE`, `TLINK.EXE`)
- Solo para regenerar sprites: **Python 3** (no es necesario para ensamblar ni para jugar)

TASM no se incluye en este repositorio porque es software de Borland. Se usa el paquete que entrega el curso.

---

## 2. Estructura del proyecto

```
C:\ASM\
   SRC\            main.asm y los .inc de cada sprite
   BIN\            MAIN.EXE ya ensamblado y dosbox.conf
   SPRITES\        diseños de los sprites en texto (.txt)
   HERRAMIENTAS\   sprite2db.py (convierte un .txt en tabla db)
   DOC\            documento técnico, hoja de sprites, bitácora
   TASM\           TASM.EXE y TLINK.EXE (no se sube al repositorio)
```

---

## 3. Preparación (una sola vez)

1. Copie la carpeta del proyecto en **`C:\ASM`**.
2. Copie `TASM.EXE` y `TLINK.EXE` del paquete del curso en **`C:\ASM\TASM`**.

---

## 4. Ensamblar, enlazar y ejecutar

Abra DOSBox y escriba estos comandos, uno por línea:

```
mount c c:\asm
c:
set path=c:\tasm
cd \src
tasm main.asm
tlink main.obj
copy main.exe \bin
cd \bin
main
```

`tasm` debe terminar con `Error messages: None` y `Warning messages: None`.

**Atajo:** `BIN\dosbox.conf` ya trae el montaje en su sección `[autoexec]`. Desde la terminal de Windows:

```
"C:\Program Files (x86)\DOSBox-0.74-3\DOSBox.exe" -conf C:\ASM\BIN\dosbox.conf
```

DOSBox abre directamente en `C:\BIN>` y basta con escribir `main`.

---

## 5. Controles

| Pantalla | Tecla | Acción |
|---|---|---|
| Presentación | cualquiera | continuar al menú |
| Menú y niveles | ↑ ↓ | mover la selección |
| | ENTER | elegir |
| | ESC | volver (en la pantalla de niveles) |
| Partida | ← → | cambiar de casilla |
| | ↑ ↓ | cambiar la poción de la casilla |
| | 1 … 6 (1 … 8 en Difícil) | poner esa poción y avanzar |
| | BACKSPACE | borrar la casilla |
| | ENTER | evaluar el intento (solo si está completo) |
| | S (o F2) | **modo prueba:** la fila armada se vuelve el secreto |
| | ESC | abandonar la partida y volver al menú |
| Fin de partida | ENTER | jugar otra partida |
| | M | volver al menú |
| | ESC | salir a DOS |

---

## 6. Niveles

| Nivel | Posiciones | Pociones | Repetición | Intentos |
|---|---|---|---|---|
| Fácil | 4 | 6 | No | 12 |
| Normal | 4 | 6 | Sí | 10 |
| Difícil | 5 | 8 | Sí | 10 |

En Fácil las filas del tablero miden 14 px (en lugar de 16) para que los 12 intentos quepan en los 168 px de la zona B y sigan visibles al mismo tiempo.

---

## 7. Prueba de la Tabla 2 (ingreso manual del secreto)

Correspondencia de letras: **R=1, V=2, A=3, M=4, N=5, B=6**. En una misma partida (nivel Normal):

1. Escriba el secreto en la fila y presione **S**. La barra muestra `SECRETO FIJADO A MANO (PRUEBA)`.
2. Escriba el intento y presione **ENTER**.

| Caso | Secreto + S | Intento + ENTER | Resultado esperado |
|---|---|---|---|
| 1 | 1 2 3 4 | 1 3 2 4 | 2 toros, 2 vacas |
| 2 | 1 1 2 3 | 1 2 1 1 | 1 toro, 2 vacas |
| 3 | 1 2 3 4 | 5 6 5 6 | 0 toros, 0 vacas |
| 4 | 3 3 3 3 | 3 3 1 1 | 2 toros, 0 vacas |

---

## 8. Regenerar un sprite (opcional)

Cada sprite se dibuja en texto en `SPRITES\` (un carácter por píxel, `.` = transparente, líneas `map` = índice de paleta). Para convertirlo, desde `C:\ASM` en la terminal de Windows:

```
python herramientas\sprite2db.py sprites\frasco1.txt frasco1 src\frasco1.inc
```

Después se vuelve a ensamblar como en la sección 4.

---

## 9. Uso de herramientas de IA

Se usó Claude (Anthropic) como asistente para configurar el entorno, explicar conceptos, depurar y revisar código. El detalle de qué se usó, para qué y en qué partes está en el documento técnico (`DOC\`).
