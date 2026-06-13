; ============================================================
; Cronómetro de Reacción - PIC16F887 - 4MHz interno
; Con transmisión serie asíncrona (UART 9600,8,N,1)
; ============================================================
    LIST    P=16F887
    INCLUDE <P16F887.INC>

    __CONFIG _CONFIG1, _INTRC_OSC_NOCLKOUT & _WDT_OFF & _PWRTE_OFF & _MCLRE_ON & _LVP_OFF

; ============================================================
;  VARIABLES RAM (banco compartido 0x70 – acceso universal)
; ============================================================
    CBLOCK  0x70
        W_TEMP          ; salva W en ISR
        STATUS_TEMP     ; salva STATUS en ISR

        ; --- Display ---
        DISP_DEC        ; patrón 7seg decenas (ya convertido)
        DISP_UNI        ; patrón 7seg unidades (ya convertido)
        NUM_DEC         ; valor numérico decenas (0-9)
        NUM_UNI         ; valor numérico unidades (0-9)
        MUX_FLAG        ; bit0: 0=mostrar decenas, 1=mostrar unidades

        ; --- Flags de control ---
        ; JUGANDO:   0=esperando/terminado  1=cronómetro activo
        ; TERMINADO: 0=en curso             1=resultado congelado
        JUGANDO
        TERMINADO

        ; --- Temporización interna ISR ---
        TICK_MUX        ; ticks para parpadeo RB1  (umbral 4 = 20ms)
        TICK_CENTI      ; ticks para centésima     (umbral 2 = 10ms)

        ; --- Cronómetro ---
        CENTI_COUNT     ; centésimas acumuladas (compara contra LIMITE)
        LIMITE          ; límite de centésimas del rango elegido

        ; --- Estabilidad ADC ---
        RANGO_PREV      ; rango de la lectura anterior (1/2/3)
        ESTABLE_COUNT   ; ticks consecutivos con mismo rango (0–200)

        ; --- UART ---
        ; ENVIAR_MSG: 0=nada  1=normal (reaccionó a tiempo)
        ;             2=excedido (tiempo agotado)
        ENVIAR_MSG
        TX_IDX          ; índice para recorrer tabla de cadena
        TX_DATA         ; byte temporal de transmisión
    ENDC

; ============================================================
;  VECTORES
; ============================================================
    ORG     0x0000
    GOTO    INICIO

    ORG     0x0004
    GOTO    ISR

; ============================================================
;  TABLA 7 SEGMENTOS (cátodo común)
;  Segmentos: bit0=a  bit1=b  bit2=c  bit3=d
;             bit4=e  bit5=f  bit6=g
; ============================================================
TABLA:
    ANDLW   0x0F
    ADDWF   PCL, F
    RETLW   b'00111111'     ; 0  – abcdef
    RETLW   b'00000110'     ; 1  – bc
    RETLW   b'01011011'     ; 2  – abdeg
    RETLW   b'01001111'     ; 3  – abcdg
    RETLW   b'01100110'     ; 4  – bcfg
    RETLW   b'01101101'     ; 5  – acdfg
    RETLW   b'01111101'     ; 6  – acdefg
    RETLW   b'00000111'     ; 7  – abc
    RETLW   b'01111111'     ; 8  – abcdefg
    RETLW   b'01101111'     ; 9  – abcdfg

; ============================================================
;  INICIO
; ============================================================
INICIO:
    ; Oscilador interno 4MHz
    BANKSEL OSCCON
    MOVLW   b'01100100'
    MOVWF   OSCCON

    ; Solo AN2 analógico, resto digital
    BANKSEL ANSEL
    MOVLW   b'00000100'
    MOVWF   ANSEL
    CLRF    ANSELH

    ; Dirección de puertos
    BANKSEL TRISA
    MOVLW   b'00000100'     ; RA2=entrada(pot), RA0/1/3/4/5=salida
    MOVWF   TRISA
    BANKSEL TRISB
    MOVLW   b'00000001'     ; RB0=entrada(botón), RB1=salida
    MOVWF   TRISB
    BANKSEL TRISD
    CLRF    TRISD           ; PORTD todo salida (segmentos)

    ; RC6=TX salida (USART), RC7=RX entrada (no usada)
    BANKSEL TRISC
    BCF     TRISC, 6
    BSF     TRISC, 7

    ; Limpiar salidas
    BANKSEL PORTA
    CLRF    PORTA
    BANKSEL PORTB
    CLRF    PORTB
    BANKSEL PORTD
    CLRF    PORTD

    ; ADC: Vref=VDD, resultado justificado a la izquierda
    ; (ADRESH contiene los 8 bits útiles)
    BANKSEL ADCON1
    CLRF    ADCON1
    BANKSEL ADCON0
    MOVLW   b'01001001'     ; Fosc/8, canal AN2, ADC ON
    MOVWF   ADCON0

    ; Timer0: clock interno, prescaler 1:64
    BANKSEL OPTION_REG
    MOVLW   b'00000101'
    MOVWF   OPTION_REG

    ; Interrupción externa RB0: flanco de bajada
    ; (INTEDG=0 en OPTION_REG, bit 6 ya vale 0 con la config anterior)

    BANKSEL TMR0
    MOVLW   d'178'          ; (256-178)×64µs ≈ 5ms
    MOVWF   TMR0

    ; -------------------------------------------------------
    ; Inicialización USART – 9600 baud, 8 bits, sin paridad
    ; Fosc=4MHz, BRGH=1: SPBRG = (4.000.000/16/9600)-1 = 25
    ; -------------------------------------------------------
    BANKSEL SPBRG
    MOVLW   d'25'
    MOVWF   SPBRG
    BANKSEL TXSTA
    MOVLW   b'00100100'     ; TXEN=1, BRGH=1, async, 8 bits
    MOVWF   TXSTA
    BANKSEL RCSTA
    MOVLW   b'10000000'     ; SPEN=1 (habilita módulo serie)
    MOVWF   RCSTA

    ; Inicializar variables
    CLRF    NUM_DEC
    CLRF    NUM_UNI
    CLRF    MUX_FLAG
    CLRF    JUGANDO
    CLRF    TERMINADO
    CLRF    TICK_MUX
    CLRF    TICK_CENTI
    CLRF    CENTI_COUNT
    CLRF    LIMITE
    CLRF    RANGO_PREV
    CLRF    ESTABLE_COUNT
    CLRF    ENVIAR_MSG

    ; Calcular patrones iniciales (muestra 00)
    CALL    CONV_DISPLAYS

    ; Habilitar interrupciones: T0IE + INTE + GIE
    BANKSEL INTCON
    MOVLW   b'10110000'     ; GIE=1, T0IE=1, INTE=1
    MOVWF   INTCON

; ============================================================
;  LOOP PRINCIPAL
; ============================================================
LOOP:
    ; -------------------------------------------------------
    ; Verificar si hay un mensaje UART pendiente de enviar
    ; (se activa desde la ISR; se procesa aquí para no bloquear
    ;  la ISR con la espera del registro de desplazamiento TX)
    ; -------------------------------------------------------
    MOVF    ENVIAR_MSG, F
    BTFSC   STATUS, Z
    GOTO    LOOP_CONTINUA       ; ENVIAR_MSG=0 → nada que enviar

    MOVF    ENVIAR_MSG, W
    SUBLW   d'1'
    BTFSS   STATUS, Z
    GOTO    MSG_EXCEDIDO

    ; ENVIAR_MSG=1 → reaccionó a tiempo
    CALL    TX_MSG_NORMAL
    CLRF    ENVIAR_MSG
    GOTO    LOOP_CONTINUA

MSG_EXCEDIDO:
    ; ENVIAR_MSG=2 → tiempo agotado
    CALL    TX_MSG_EXCEDIDO
    CLRF    ENVIAR_MSG

LOOP_CONTINUA:
    ; Leer ADC → encender LED → W = rango actual (1/2/3)
    CALL    LEER_ADC

    ; ¿Terminado? → solo esperar RB0 (ISR lo resetea)
    BTFSC   TERMINADO, 0
    GOTO    LOOP

    ; ¿Jugando? → ISR maneja todo
    BTFSC   JUGANDO, 0
    GOTO    LOOP

    ; -------------------------------------------------------
    ; ESPERANDO: verificar estabilidad del rango
    ; -------------------------------------------------------
    SUBWF   RANGO_PREV, W       ; W = RANGO_PREV - rango_actual
    BTFSS   STATUS, Z
    GOTO    RANGO_CAMBIO

    GOTO    LOOP

RANGO_CAMBIO:
    CALL    LEER_ADC
    MOVWF   RANGO_PREV
    CLRF    ESTABLE_COUNT
    GOTO    LOOP

; ============================================================
;  LEER_ADC
;  Dispara conversión ADC, espera resultado, enciende LED
;  Retorna rango en W: 1=Rojo  2=Verde  3=Amarillo
; ============================================================
LEER_ADC:
    BANKSEL ADCON0
    BSF     ADCON0, GO
WAIT_ADC:
    BTFSC   ADCON0, GO
    GOTO    WAIT_ADC

    MOVF    ADRESH, W

    SUBLW   d'85'               ; C=1 si W ≤ 85
    BTFSS   STATUS, C
    GOTO    ADC_VERDE

    BANKSEL PORTA
    BSF     PORTA, 3
    BCF     PORTA, 4
    BCF     PORTA, 5
    MOVLW   d'1'
    RETURN

ADC_VERDE:
    MOVF    ADRESH, W
    SUBLW   d'170'              ; C=1 si W ≤ 170
    BTFSS   STATUS, C
    GOTO    ADC_AMARILLO

    BANKSEL PORTA
    BCF     PORTA, 3
    BSF     PORTA, 4
    BCF     PORTA, 5
    MOVLW   d'2'
    RETURN

ADC_AMARILLO:
    BANKSEL PORTA
    BCF     PORTA, 3
    BCF     PORTA, 4
    BSF     PORTA, 5
    MOVLW   d'3'
    RETURN

; ============================================================
;  CARGAR_LIMITE
;  Rojo    →  50 centésimas =  500 ms
;  Verde   → 100 centésimas = 1000 ms
;  Amarillo→ 150 centésimas = 1500 ms
; ============================================================
CARGAR_LIMITE:
    MOVF    RANGO_PREV, W
    SUBLW   d'1'
    BTFSS   STATUS, Z
    GOTO    CL_VERDE

    MOVLW   d'50'
    MOVWF   LIMITE
    RETURN

CL_VERDE:
    MOVF    RANGO_PREV, W
    SUBLW   d'2'
    BTFSS   STATUS, Z
    GOTO    CL_AMARILLO

    MOVLW   d'100'
    MOVWF   LIMITE
    RETURN

CL_AMARILLO:
    MOVLW   d'150'
    MOVWF   LIMITE
    RETURN

; ============================================================
;  CONV_DISPLAYS
; ============================================================
CONV_DISPLAYS:
    MOVF    NUM_DEC, W
    CALL    TABLA
    MOVWF   DISP_DEC
    MOVF    NUM_UNI, W
    CALL    TABLA
    MOVWF   DISP_UNI
    RETURN

; ============================================================
;  RESET_TOTAL
; ============================================================
RESET_TOTAL:
    CLRF    JUGANDO
    CLRF    TERMINADO
    CLRF    NUM_DEC
    CLRF    NUM_UNI
    CLRF    CENTI_COUNT
    CLRF    TICK_CENTI
    CLRF    TICK_MUX
    CLRF    ESTABLE_COUNT
    CLRF    LIMITE
    CLRF    RANGO_PREV
    CLRF    ENVIAR_MSG
    BANKSEL PORTB
    BCF     PORTB, 1
    BANKSEL PORTD
    CLRF    PORTD
    BANKSEL PORTA
    BCF     PORTA, 0
    BCF     PORTA, 1
    CALL    CONV_DISPLAYS
    RETURN

; ============================================================
;  ARRANCAR_PRUEBA
; ============================================================
ARRANCAR_PRUEBA:
    CALL    CARGAR_LIMITE
    CLRF    NUM_DEC
    CLRF    NUM_UNI
    CLRF    CENTI_COUNT
    CLRF    TICK_CENTI
    CLRF    TICK_MUX
    CALL    CONV_DISPLAYS
    BSF     JUGANDO, 0
    RETURN

; ============================================================
;  TX_BYTE  –  Envía el byte en W por UART
;  Espera a que el registro de desplazamiento esté libre
;  (llamar siempre con GIE=1 en segundo plano no importa
;   porque el módulo USART es independiente del CPU)
; ============================================================
TX_BYTE:
    MOVWF   TX_DATA
TX_BYTE_WAIT:
    BANKSEL TXSTA
    BTFSS   TXSTA, TRMT         ; 1 = registro vacío → listo
    GOTO    TX_BYTE_WAIT
    BANKSEL TXREG
    MOVF    TX_DATA, W
    MOVWF   TXREG
    RETURN

; ============================================================
;  TX_MSG_NORMAL
;  Envía: "Rango psicomotriz normal\r\n"
; ============================================================
TX_MSG_NORMAL:
    CLRF    TX_IDX
TX_NRM_LOOP:
    MOVF    TX_IDX, W
    CALL    STR_NORMAL          ; W = carácter en posición TX_IDX
    ANDLW   0xFF                ; afecta Z
    BTFSC   STATUS, Z
    RETURN                      ; null terminator → fin
    CALL    TX_BYTE
    INCF    TX_IDX, F
    GOTO    TX_NRM_LOOP

; ============================================================
;  TX_MSG_EXCEDIDO
;  Envía: "Rango psicomotriz excedido de tiempo\r\n"
; ============================================================
TX_MSG_EXCEDIDO:
    CLRF    TX_IDX
TX_EXC_LOOP:
    MOVF    TX_IDX, W
    CALL    STR_EXCEDIDO
    ANDLW   0xFF
    BTFSC   STATUS, Z
    RETURN
    CALL    TX_BYTE
    INCF    TX_IDX, F
    GOTO    TX_EXC_LOOP

; ============================================================
;  ISR - Rutina de Servicio de Interrupción
; ============================================================
ISR:
    MOVWF   W_TEMP
    SWAPF   STATUS, W
    MOVWF   STATUS_TEMP

    ; ===========================================================
    ; 1. INTERRUPCIÓN EXTERNA RB0
    ; ===========================================================
    BANKSEL INTCON
    BTFSS   INTCON, INTF
    GOTO    CHECK_TMR0

    BTFSC   TERMINADO, 0
    GOTO    HACER_RESET

    BTFSC   JUGANDO, 0
    GOTO    CONGELAR_TIEMPO

    GOTO    CLEAR_INTF

HACER_RESET:
    CALL    RESET_TOTAL
    GOTO    CLEAR_INTF

CONGELAR_TIEMPO:
    ; El usuario reaccionó a tiempo: detener cronómetro
    CLRF    JUGANDO
    BSF     TERMINADO, 0
    BANKSEL PORTB
    BSF     PORTB, 1            ; RB1 fijo encendido
    ; Marcar mensaje "normal" para que el loop lo envíe
    MOVLW   d'1'
    MOVWF   ENVIAR_MSG

CLEAR_INTF:
    BANKSEL INTCON
    BCF     INTCON, INTF
    GOTO    FIN_ISR

    ; ===========================================================
    ; 2. INTERRUPCIÓN TIMER0 (~5ms)
    ; ===========================================================
CHECK_TMR0:
    BTFSS   INTCON, T0IF
    GOTO    FIN_ISR

    BANKSEL TMR0
    MOVLW   d'178'
    MOVWF   TMR0

    ; -----------------------------------------------------------
    ; A) MULTIPLEXADO DE DISPLAYS
    ; -----------------------------------------------------------
    BANKSEL PORTA
    BCF     PORTA, 0
    BCF     PORTA, 1

    MOVF    JUGANDO, F
    BTFSS   STATUS, Z
    GOTO    HACER_MUX
    MOVF    TERMINADO, F
    BTFSS   STATUS, Z
    GOTO    HACER_MUX
    GOTO    LOGICA_ESTABILIDAD

HACER_MUX:
    BTFSC   MUX_FLAG, 0
    GOTO    MUX_UNI

MUX_DEC:
    BANKSEL PORTD
    MOVF    DISP_DEC, W
    MOVWF   PORTD
    BANKSEL PORTA
    BSF     PORTA, 0
    BSF     MUX_FLAG, 0
    GOTO    LOGICA_ESTABILIDAD

MUX_UNI:
    BANKSEL PORTD
    MOVF    DISP_UNI, W
    MOVWF   PORTD
    BANKSEL PORTA
    BSF     PORTA, 1
    BCF     MUX_FLAG, 0

    ; -----------------------------------------------------------
    ; B) ESTABILIDAD ADC (solo en espera)
    ; -----------------------------------------------------------
LOGICA_ESTABILIDAD:
    MOVF    JUGANDO, F
    BTFSS   STATUS, Z
    GOTO    LOGICA_JUEGO
    MOVF    TERMINADO, F
    BTFSS   STATUS, Z
    GOTO    LOGICA_JUEGO

    MOVF    RANGO_PREV, F
    BTFSC   STATUS, Z
    GOTO    LOGICA_JUEGO

    INCF    ESTABLE_COUNT, F

    MOVLW   d'200'
    SUBWF   ESTABLE_COUNT, W
    BTFSS   STATUS, Z
    GOTO    LOGICA_JUEGO

    CALL    ARRANCAR_PRUEBA
    GOTO    CLEAR_T0IF

    ; -----------------------------------------------------------
    ; C) LÓGICA DE JUEGO (solo si JUGANDO=1)
    ; -----------------------------------------------------------
LOGICA_JUEGO:
    BTFSS   JUGANDO, 0
    GOTO    CLEAR_T0IF

    ; C1) Parpadeo RB1 cada 4 ticks × 5ms = 20ms
    INCF    TICK_MUX, F
    MOVLW   d'4'
    SUBWF   TICK_MUX, W
    BTFSS   STATUS, Z
    GOTO    LOGICA_CENTI

    CLRF    TICK_MUX
    BANKSEL PORTB
    MOVLW   b'00000010'
    XORWF   PORTB, F

    ; C2) Centésima cada 2 ticks × 5ms = 10ms
LOGICA_CENTI:
    INCF    TICK_CENTI, F
    MOVLW   d'2'
    SUBWF   TICK_CENTI, W
    BTFSS   STATUS, Z
    GOTO    CLEAR_T0IF

    CLRF    TICK_CENTI

    INCF    CENTI_COUNT, F

    INCF    NUM_UNI, F
    MOVLW   d'10'
    SUBWF   NUM_UNI, W
    BTFSS   STATUS, Z
    GOTO    CHK_LIMITE

    CLRF    NUM_UNI
    INCF    NUM_DEC, F
    MOVLW   d'10'
    SUBWF   NUM_DEC, W
    BTFSS   STATUS, Z
    GOTO    CHK_LIMITE

    CLRF    NUM_DEC

CHK_LIMITE:
    MOVF    LIMITE, W
    SUBWF   CENTI_COUNT, W
    BTFSS   STATUS, Z
    GOTO    ACT_DISPLAYS

    ; Tiempo agotado → mostrar "28" y marcar mensaje "excedido"
    MOVLW   d'2'
    MOVWF   NUM_DEC
    MOVLW   d'8'
    MOVWF   NUM_UNI
    CLRF    JUGANDO
    BSF     TERMINADO, 0
    BANKSEL PORTB
    BSF     PORTB, 1
    ; Marcar mensaje "excedido" para que el loop lo envíe
    MOVLW   d'2'
    MOVWF   ENVIAR_MSG

ACT_DISPLAYS:
    CALL    CONV_DISPLAYS

CLEAR_T0IF:
    BANKSEL INTCON
    BCF     INTCON, T0IF

FIN_ISR:
    SWAPF   STATUS_TEMP, W
    MOVWF   STATUS
    SWAPF   W_TEMP, F
    SWAPF   W_TEMP, W
    RETFIE

; ============================================================
;  TABLAS DE CADENAS (alineadas a página 0x200)
;  Cada tabla retorna el carácter en la posición W.
;  Un 0x00 indica fin de cadena.
;
;  IMPORTANTE: ambas tablas deben caber dentro de una misma
;  página de 256 palabras (bits PC<7:0>). ORG 0x200 garantiza
;  que empiecen al inicio de una página limpia.
; ============================================================
    ORG     0x200

; "Rango psicomotriz normal\r\n" (27 bytes + null)
STR_NORMAL:
    ANDLW   0x3F
    ADDWF   PCL, F
    RETLW   'R'
    RETLW   'a'
    RETLW   'n'
    RETLW   'g'
    RETLW   'o'
    RETLW   ' '
    RETLW   'p'
    RETLW   's'
    RETLW   'i'
    RETLW   'c'
    RETLW   'o'
    RETLW   'm'
    RETLW   'o'
    RETLW   't'
    RETLW   'r'
    RETLW   'i'
    RETLW   'z'
    RETLW   ' '
    RETLW   'n'
    RETLW   'o'
    RETLW   'r'
    RETLW   'm'
    RETLW   'a'
    RETLW   'l'
    RETLW   0x0D        ; \r
    RETLW   0x0A        ; \n
    RETLW   0x00        ; fin

; "Rango psicomotriz excedido de tiempo\r\n" (39 bytes + null)
STR_EXCEDIDO:
    ANDLW   0x3F
    ADDWF   PCL, F
    RETLW   'R'
    RETLW   'a'
    RETLW   'n'
    RETLW   'g'
    RETLW   'o'
    RETLW   ' '
    RETLW   'p'
    RETLW   's'
    RETLW   'i'
    RETLW   'c'
    RETLW   'o'
    RETLW   'm'
    RETLW   'o'
    RETLW   't'
    RETLW   'r'
    RETLW   'i'
    RETLW   'z'
    RETLW   ' '
    RETLW   'e'
    RETLW   'x'
    RETLW   'c'
    RETLW   'e'
    RETLW   'd'
    RETLW   'i'
    RETLW   'd'
    RETLW   'o'
    RETLW   ' '
    RETLW   'd'
    RETLW   'e'
    RETLW   ' '
    RETLW   't'
    RETLW   'i'
    RETLW   'e'
    RETLW   'm'
    RETLW   'p'
    RETLW   'o'
    RETLW   0x0D        ; \r
    RETLW   0x0A        ; \n
    RETLW   0x00        ; fin

    END
