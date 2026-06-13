; ============================================================
; Cronómetro de Reacción - PIC16F887 - 4MHz interno
; Con transmisión serie asíncrona (UART 9600,8,E,1 – paridad par)
;
; Rangos del potenciómetro y categoría del paciente:
;   Rango 1 – Rojo    (ADC 0-85)    – Persona joven        – límite 500ms
;   Rango 2 – Verde   (ADC 86-170)  – Adulto mayor/anciano – límite 1000ms
;   Rango 3 – Amarillo(ADC 171-255) – Paciente post-ACV    – límite 1500ms
;
; Mensajes UART al finalizar la prueba:
;   Joven       | Prueba aprobada/desaprobada
;   Adulto mayor| Prueba aprobada/desaprobada
;   Paciente ACV| Prueba aprobada/desaprobada
;
; NOTA: El mensaje se envía desde la ISR en el instante en que
; termina la prueba. Como GIE=0 durante la ISR, no hay rebote
; de botón ni Timer0 que interfiera con la transmisión.
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
        DISP_DEC
        DISP_UNI
        NUM_DEC
        NUM_UNI
        MUX_FLAG        ; bit0: 0=decenas  1=unidades

        ; --- Flags de control ---
        JUGANDO         ; 0=esperando/terminado  1=activo
        TERMINADO       ; 0=en curso             1=resultado congelado

        ; --- Temporización ISR ---
        TICK_MUX        ; ticks parpadeo RB1 (umbral 4 = 20ms)
        TICK_CENTI      ; ticks centésima   (umbral 2 = 10ms)

        ; --- Cronómetro ---
        CENTI_COUNT
        LIMITE

        ; --- Estabilidad ADC ---
        RANGO_PREV
        ESTABLE_COUNT

        ; --- UART ---
        TX_IDX          ; índice para recorrer la cadena
        TX_DATA         ; byte temporal de transmisión
        PAR_TMP         ; acumulador de bits para cálculo de paridad
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
; ============================================================
TABLA:
    ANDLW   0x0F
    ADDWF   PCL, F
    RETLW   b'00111111'     ; 0
    RETLW   b'00000110'     ; 1
    RETLW   b'01011011'     ; 2
    RETLW   b'01001111'     ; 3
    RETLW   b'01100110'     ; 4
    RETLW   b'01101101'     ; 5
    RETLW   b'01111101'     ; 6
    RETLW   b'00000111'     ; 7
    RETLW   b'01111111'     ; 8
    RETLW   b'01101111'     ; 9

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
    MOVLW   b'00000100'     ; RA2=entrada(pot)
    MOVWF   TRISA
    BANKSEL TRISB
    MOVLW   b'00000001'     ; RB0=entrada(botón)
    MOVWF   TRISB
    BANKSEL TRISD
    CLRF    TRISD

    ; RC6=TX salida (USART), RC7=RX entrada
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

    ; ADC: Vref=VDD, resultado izquierda (ADRESH = 8 bits)
    BANKSEL ADCON1
    CLRF    ADCON1
    BANKSEL ADCON0
    MOVLW   b'01001001'     ; Fosc/8, canal AN2, ADC ON
    MOVWF   ADCON0

    ; Timer0: clock interno, prescaler 1:64
    ; INTEDG=0 → RB0 flanco de bajada
    BANKSEL OPTION_REG
    MOVLW   b'00000101'
    MOVWF   OPTION_REG

    BANKSEL TMR0
    MOVLW   d'178'          ; (256-178)×64µs ≈ 5ms
    MOVWF   TMR0

    ; -------------------------------------------------------
    ; USART: 9600 baud, 8E1 (paridad par por software, 9 bits)
    ; Fosc=4MHz, BRGH=1 → SPBRG=(4000000/16/9600)-1=25
    ; TX9=1 habilita el 9° bit (TX9D) usado como bit de paridad
    ; -------------------------------------------------------
    BANKSEL SPBRG
    MOVLW   d'25'
    MOVWF   SPBRG
    BANKSEL TXSTA
    MOVLW   b'01100100'     ; TX9=1, TXEN=1, BRGH=1, async
    MOVWF   TXSTA
    BANKSEL RCSTA
    MOVLW   b'10000000'     ; SPEN=1
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

    CALL    CONV_DISPLAYS

    ; Habilitar interrupciones: T0IE + INTE + GIE
    BANKSEL INTCON
    MOVLW   b'10110000'
    MOVWF   INTCON

; ============================================================
;  LOOP PRINCIPAL
;  Solo lee ADC, enciende LED y espera. Todo lo demás en ISR.
; ============================================================
LOOP:
    CALL    LEER_ADC            ; W = rango (1/2/3), enciende LED

    BTFSC   TERMINADO, 0
    GOTO    LOOP                ; congelado → esperar RB0

    BTFSC   JUGANDO, 0
    GOTO    LOOP                ; jugando → ISR maneja todo

    ; -------------------------------------------------------
    ; ESPERANDO: detectar cambio de rango
    ; -------------------------------------------------------
    SUBWF   RANGO_PREV, W
    BTFSS   STATUS, Z
    GOTO    RANGO_CAMBIO
    GOTO    LOOP

RANGO_CAMBIO:
    CALL    LEER_ADC
    MOVWF   RANGO_PREV
    CLRF    ESTABLE_COUNT
    GOTO    LOOP

; ============================================================
;  LEER_ADC  – retorna rango en W (1/2/3) y enciende LED
; ============================================================
LEER_ADC:
    BANKSEL ADCON0
    BSF     ADCON0, GO
WAIT_ADC:
    BTFSC   ADCON0, GO
    GOTO    WAIT_ADC

    MOVF    ADRESH, W
    SUBLW   d'85'
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
    SUBLW   d'170'
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
;  TX_BYTE  –  Envía el byte en W con paridad par (9 bits)
;
;  Paridad par: el bit TX9D se elige de forma que el total de
;  1s en los 9 bits transmitidos sea siempre par.
;  El PIC16F887 no tiene hardware de paridad; se calcula
;  contando los bits en 1 del byte y cargando TX9D según sea
;  necesario para que la cuenta total resulte par.
;
;  Cálculo: si la cantidad de 1s en el byte es par → TX9D=0
;           si la cantidad de 1s es impar             → TX9D=1
;  Eso se determina con el bit 0 del conteo (LSB).
; ============================================================
TX_BYTE:
    MOVWF   TX_DATA

    ; --- Contar bits en 1 del byte (resultado en PAR_TMP) ---
    CLRF    PAR_TMP
    BTFSC   TX_DATA, 0
    INCF    PAR_TMP, F
    BTFSC   TX_DATA, 1
    INCF    PAR_TMP, F
    BTFSC   TX_DATA, 2
    INCF    PAR_TMP, F
    BTFSC   TX_DATA, 3
    INCF    PAR_TMP, F
    BTFSC   TX_DATA, 4
    INCF    PAR_TMP, F
    BTFSC   TX_DATA, 5
    INCF    PAR_TMP, F
    BTFSC   TX_DATA, 6
    INCF    PAR_TMP, F
    BTFSC   TX_DATA, 7
    INCF    PAR_TMP, F

    ; --- Cargar TX9D: 0 si conteo par, 1 si conteo impar ---
    BANKSEL TXSTA
    BCF     TXSTA, TX9D         ; asumir paridad = 0 (conteo par)
    BTFSC   PAR_TMP, 0          ; ¿LSB del conteo = 1? (conteo impar)
    BSF     TXSTA, TX9D         ;   sí → parity bit = 1 para compensar

    ; --- Esperar shift register vacío y enviar ---
TX_BYTE_WAIT:
    BTFSS   TXSTA, TRMT         ; 1 = shift register vacío → listo
    GOTO    TX_BYTE_WAIT
    BANKSEL TXREG
    MOVF    TX_DATA, W
    MOVWF   TXREG
    RETURN

; ============================================================
;  TX_NORMAL_POR_RANGO
;  Envía "Categoria | Prueba aprobada\r\n" según RANGO_PREV.
;  Llamada desde ISR → GIE=0 → no hay rebote posible.
; ============================================================
TX_NORMAL_POR_RANGO:
    MOVF    RANGO_PREV, W
    SUBLW   d'1'
    BTFSS   STATUS, Z
    GOTO    TNR_R2
    CALL    TX_JOVEN_NORMAL
    RETURN
TNR_R2:
    MOVF    RANGO_PREV, W
    SUBLW   d'2'
    BTFSS   STATUS, Z
    GOTO    TNR_R3
    CALL    TX_ADULTO_NORMAL
    RETURN
TNR_R3:
    CALL    TX_ACV_NORMAL
    RETURN

; ============================================================
;  TX_EXCEDIDO_POR_RANGO
;  Envía "Categoria | Prueba desaprobada\r\n" según RANGO_PREV.
; ============================================================
TX_EXCEDIDO_POR_RANGO:
    MOVF    RANGO_PREV, W
    SUBLW   d'1'
    BTFSS   STATUS, Z
    GOTO    TER_R2
    CALL    TX_JOVEN_EXCEDIDO
    RETURN
TER_R2:
    MOVF    RANGO_PREV, W
    SUBLW   d'2'
    BTFSS   STATUS, Z
    GOTO    TER_R3
    CALL    TX_ADULTO_EXCEDIDO
    RETURN
TER_R3:
    CALL    TX_ACV_EXCEDIDO
    RETURN

; ============================================================
;  Rutinas TX por cadena – recorren la tabla hasta null (0x00)
; ============================================================
TX_JOVEN_NORMAL:
    CLRF    TX_IDX
TXJ_NRM_LP:
    MOVF    TX_IDX, W
    CALL    STR_JOVEN_NORMAL
    ANDLW   0xFF
    BTFSC   STATUS, Z
    RETURN
    CALL    TX_BYTE
    INCF    TX_IDX, F
    GOTO    TXJ_NRM_LP

TX_JOVEN_EXCEDIDO:
    CLRF    TX_IDX
TXJ_EXC_LP:
    MOVF    TX_IDX, W
    CALL    STR_JOVEN_EXCEDIDO
    ANDLW   0xFF
    BTFSC   STATUS, Z
    RETURN
    CALL    TX_BYTE
    INCF    TX_IDX, F
    GOTO    TXJ_EXC_LP

TX_ADULTO_NORMAL:
    CLRF    TX_IDX
TXA_NRM_LP:
    MOVF    TX_IDX, W
    CALL    STR_ADULTO_NORMAL
    ANDLW   0xFF
    BTFSC   STATUS, Z
    RETURN
    CALL    TX_BYTE
    INCF    TX_IDX, F
    GOTO    TXA_NRM_LP

TX_ADULTO_EXCEDIDO:
    CLRF    TX_IDX
TXA_EXC_LP:
    MOVF    TX_IDX, W
    CALL    STR_ADULTO_EXCEDIDO
    ANDLW   0xFF
    BTFSC   STATUS, Z
    RETURN
    CALL    TX_BYTE
    INCF    TX_IDX, F
    GOTO    TXA_EXC_LP

TX_ACV_NORMAL:
    CLRF    TX_IDX
TXACV_NRM_LP:
    MOVF    TX_IDX, W
    CALL    STR_ACV_NORMAL
    ANDLW   0xFF
    BTFSC   STATUS, Z
    RETURN
    CALL    TX_BYTE
    INCF    TX_IDX, F
    GOTO    TXACV_NRM_LP

TX_ACV_EXCEDIDO:
    CLRF    TX_IDX
TXACV_EXC_LP:
    MOVF    TX_IDX, W
    CALL    STR_ACV_EXCEDIDO
    ANDLW   0xFF
    BTFSC   STATUS, Z
    RETURN
    CALL    TX_BYTE
    INCF    TX_IDX, F
    GOTO    TXACV_EXC_LP

; ============================================================
;  ISR
; ============================================================
ISR:
    MOVWF   W_TEMP
    SWAPF   STATUS, W
    MOVWF   STATUS_TEMP

    ; -------------------------------------------------------
    ; 1. INTERRUPCIÓN EXTERNA RB0
    ; -------------------------------------------------------
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
    ; Detener cronómetro y congelar display
    CLRF    JUGANDO
    BSF     TERMINADO, 0
    BANKSEL PORTB
    BSF     PORTB, 1            ; RB1 fijo encendido
    ; Enviar mensaje AHORA, mientras GIE=0 (imposible rebote)
    CALL    TX_NORMAL_POR_RANGO

CLEAR_INTF:
    BANKSEL INTCON
    BCF     INTCON, INTF
    GOTO    FIN_ISR

    ; -------------------------------------------------------
    ; 2. INTERRUPCIÓN TIMER0 (~5ms)
    ; -------------------------------------------------------
CHECK_TMR0:
    BTFSS   INTCON, T0IF
    GOTO    FIN_ISR

    BANKSEL TMR0
    MOVLW   d'178'
    MOVWF   TMR0

    ; A) MULTIPLEXADO DE DISPLAYS ----------------------------
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

    ; B) ESTABILIDAD ADC (solo en espera) -------------------
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

    ; C) LÓGICA DE JUEGO ------------------------------------
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

    ; Tiempo agotado → "28", congelar, enviar desaprobado
    MOVLW   d'2'
    MOVWF   NUM_DEC
    MOVLW   d'8'
    MOVWF   NUM_UNI
    CLRF    JUGANDO
    BSF     TERMINADO, 0
    BANKSEL PORTB
    BSF     PORTB, 1
    ; Enviar mensaje AHORA, mientras GIE=0 (imposible rebote)
    CALL    TX_EXCEDIDO_POR_RANGO

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
;  TABLAS DE CADENAS
;
;  Cada tabla con ADDWF PCL debe estar íntegra dentro de una
;  misma página de 256 palabras. Se usa ORG en múltiplos de
;  0x40 (64 palabras) ya que los mensajes cortos caben en ≤40.
;
;  ORG   Tabla                  Tamaño
;  0x200 STR_JOVEN_NORMAL       ≈28 palabras
;  0x240 STR_JOVEN_EXCEDIDO     ≈30 palabras
;  0x280 STR_ADULTO_NORMAL      ≈32 palabras
;  0x2C0 STR_ADULTO_EXCEDIDO    ≈35 palabras
;  0x300 STR_ACV_NORMAL         ≈32 palabras
;  0x340 STR_ACV_EXCEDIDO       ≈35 palabras
; ============================================================

    ORG     0x200
STR_JOVEN_NORMAL:           ; "Joven | Prueba aprobada\r\n"
    ANDLW   0x1F
    ADDWF   PCL, F
    RETLW   'J'
    RETLW   'o'
    RETLW   'v'
    RETLW   'e'
    RETLW   'n'
    RETLW   ' '
    RETLW   '|'
    RETLW   ' '
    RETLW   'P'
    RETLW   'r'
    RETLW   'u'
    RETLW   'e'
    RETLW   'b'
    RETLW   'a'
    RETLW   ' '
    RETLW   'a'
    RETLW   'p'
    RETLW   'r'
    RETLW   'o'
    RETLW   'b'
    RETLW   'a'
    RETLW   'd'
    RETLW   'a'
    RETLW   0x0D
    RETLW   0x0A
    RETLW   0x00

    ORG     0x240
STR_JOVEN_EXCEDIDO:         ; "Joven | Prueba desaprobada\r\n"
    ANDLW   0x1F
    ADDWF   PCL, F
    RETLW   'J'
    RETLW   'o'
    RETLW   'v'
    RETLW   'e'
    RETLW   'n'
    RETLW   ' '
    RETLW   '|'
    RETLW   ' '
    RETLW   'P'
    RETLW   'r'
    RETLW   'u'
    RETLW   'e'
    RETLW   'b'
    RETLW   'a'
    RETLW   ' '
    RETLW   'd'
    RETLW   'e'
    RETLW   's'
    RETLW   'a'
    RETLW   'p'
    RETLW   'r'
    RETLW   'o'
    RETLW   'b'
    RETLW   'a'
    RETLW   'd'
    RETLW   'a'
    RETLW   0x0D
    RETLW   0x0A
    RETLW   0x00

    ORG     0x280
STR_ADULTO_NORMAL:          ; "Adulto mayor | Prueba aprobada\r\n"
    ANDLW   0x3F
    ADDWF   PCL, F
    RETLW   'A'
    RETLW   'd'
    RETLW   'u'
    RETLW   'l'
    RETLW   't'
    RETLW   'o'
    RETLW   ' '
    RETLW   'm'
    RETLW   'a'
    RETLW   'y'
    RETLW   'o'
    RETLW   'r'
    RETLW   ' '
    RETLW   '|'
    RETLW   ' '
    RETLW   'P'
    RETLW   'r'
    RETLW   'u'
    RETLW   'e'
    RETLW   'b'
    RETLW   'a'
    RETLW   ' '
    RETLW   'a'
    RETLW   'p'
    RETLW   'r'
    RETLW   'o'
    RETLW   'b'
    RETLW   'a'
    RETLW   'd'
    RETLW   'a'
    RETLW   0x0D
    RETLW   0x0A
    RETLW   0x00

    ORG     0x2C0
STR_ADULTO_EXCEDIDO:        ; "Adulto mayor | Prueba desaprobada\r\n"
    ANDLW   0x3F
    ADDWF   PCL, F
    RETLW   'A'
    RETLW   'd'
    RETLW   'u'
    RETLW   'l'
    RETLW   't'
    RETLW   'o'
    RETLW   ' '
    RETLW   'm'
    RETLW   'a'
    RETLW   'y'
    RETLW   'o'
    RETLW   'r'
    RETLW   ' '
    RETLW   '|'
    RETLW   ' '
    RETLW   'P'
    RETLW   'r'
    RETLW   'u'
    RETLW   'e'
    RETLW   'b'
    RETLW   'a'
    RETLW   ' '
    RETLW   'd'
    RETLW   'e'
    RETLW   's'
    RETLW   'a'
    RETLW   'p'
    RETLW   'r'
    RETLW   'o'
    RETLW   'b'
    RETLW   'a'
    RETLW   'd'
    RETLW   'a'
    RETLW   0x0D
    RETLW   0x0A
    RETLW   0x00

    ORG     0x300
STR_ACV_NORMAL:             ; "Paciente ACV | Prueba aprobada\r\n"
    ANDLW   0x3F
    ADDWF   PCL, F
    RETLW   'P'
    RETLW   'a'
    RETLW   'c'
    RETLW   'i'
    RETLW   'e'
    RETLW   'n'
    RETLW   't'
    RETLW   'e'
    RETLW   ' '
    RETLW   'A'
    RETLW   'C'
    RETLW   'V'
    RETLW   ' '
    RETLW   '|'
    RETLW   ' '
    RETLW   'P'
    RETLW   'r'
    RETLW   'u'
    RETLW   'e'
    RETLW   'b'
    RETLW   'a'
    RETLW   ' '
    RETLW   'a'
    RETLW   'p'
    RETLW   'r'
    RETLW   'o'
    RETLW   'b'
    RETLW   'a'
    RETLW   'd'
    RETLW   'a'
    RETLW   0x0D
    RETLW   0x0A
    RETLW   0x00

    ORG     0x340
STR_ACV_EXCEDIDO:           ; "Paciente ACV | Prueba desaprobada\r\n"
    ANDLW   0x3F
    ADDWF   PCL, F
    RETLW   'P'
    RETLW   'a'
    RETLW   'c'
    RETLW   'i'
    RETLW   'e'
    RETLW   'n'
    RETLW   't'
    RETLW   'e'
    RETLW   ' '
    RETLW   'A'
    RETLW   'C'
    RETLW   'V'
    RETLW   ' '
    RETLW   '|'
    RETLW   ' '
    RETLW   'P'
    RETLW   'r'
    RETLW   'u'
    RETLW   'e'
    RETLW   'b'
    RETLW   'a'
    RETLW   ' '
    RETLW   'd'
    RETLW   'e'
    RETLW   's'
    RETLW   'a'
    RETLW   'p'
    RETLW   'r'
    RETLW   'o'
    RETLW   'b'
    RETLW   'a'
    RETLW   'd'
    RETLW   'a'
    RETLW   0x0D
    RETLW   0x0A
    RETLW   0x00

    END
