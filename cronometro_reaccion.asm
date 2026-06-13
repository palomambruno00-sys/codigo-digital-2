; ============================================================
; Cronómetro de Reacción - PIC16F887 - 4MHz interno
; UART 9600,8N1
;
; Rangos:
;   Rango 1 – Rojo    (ADC 0-85)    – Joven        – 500ms
;   Rango 2 – Verde   (ADC 86-170)  – Adulto mayor – 1000ms
;   Rango 3 – Amarillo(ADC 171-255) – Paciente ACV – 1500ms
;
; Flujo:
;   1) Ajustar potenciómetro → LED indica categoría
;   2) Mantener rango 1 segundo → cronómetro arranca solo
;   3) Presionar RB0 durante prueba → display congela + UART mensaje
;   4) Presionar RB0 congelado → reset
; ============================================================
    LIST    P=16F887
    INCLUDE <P16F887.INC>

    __CONFIG _CONFIG1, _INTRC_OSC_NOCLKOUT & _WDT_OFF & _PWRTE_OFF & _MCLRE_OFF & _LVP_OFF

; ============================================================
;  VARIABLES RAM
; ============================================================
    ; Banco compartido 0x70-0x7F (16 bytes, acceso universal)
    CBLOCK  0x70
        W_TEMP
        STATUS_TEMP
        PCLATH_TEMP         ; salva PCLATH en ISR
        DISP_DEC
        DISP_UNI
        NUM_DEC
        NUM_UNI
        MUX_FLAG
        JUGANDO
        TERMINADO
        TICK_MUX
        TICK_CENTI
        CENTI_COUNT
        LIMITE
        RANGO_PREV
        ESTABLE_COUNT
    ENDC

    ; Banco 0 GPR 0x20-0x21 (solo acceder desde banco 0)
    CBLOCK  0x20
        TX_IDX
        TX_DATA
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
    BANKSEL OSCCON
    MOVLW   b'01100100'
    MOVWF   OSCCON

    BANKSEL ANSEL
    MOVLW   b'00000100'
    MOVWF   ANSEL
    CLRF    ANSELH

    BANKSEL TRISA
    MOVLW   b'00000100'     ; RA2=entrada(pot)
    MOVWF   TRISA
    BANKSEL TRISB
    MOVLW   b'00000001'     ; RB0=entrada(botón)
    MOVWF   TRISB
    BANKSEL TRISD
    CLRF    TRISD

    BANKSEL TRISC
    BCF     TRISC, 6        ; RC6=TX salida
    BSF     TRISC, 7        ; RC7=RX entrada

    BANKSEL PORTA
    CLRF    PORTA
    BANKSEL PORTB
    CLRF    PORTB
    BANKSEL PORTD
    CLRF    PORTD

    BANKSEL ADCON1
    CLRF    ADCON1
    BANKSEL ADCON0
    MOVLW   b'01001001'     ; Fosc/8, canal AN2, ADC ON
    MOVWF   ADCON0

    ; INTEDG=0 → RB0 flanco bajada; RBPU=0 → pull-ups ON; PS=1:64
    BANKSEL OPTION_REG
    MOVLW   b'00000101'
    MOVWF   OPTION_REG

    BANKSEL TMR0
    MOVLW   d'178'          ; ~5ms
    MOVWF   TMR0

    ; USART 9600,8N1
    BANKSEL SPBRG
    MOVLW   d'25'
    MOVWF   SPBRG
    BANKSEL RCSTA
    MOVLW   b'10000000'     ; SPEN=1
    MOVWF   RCSTA
    BANKSEL TXSTA
    MOVLW   b'00100100'     ; TXEN=1, BRGH=1
    MOVWF   TXSTA

    ; Inicializar variables (banco 0 para TX_IDX/TX_DATA)
    BANKSEL PORTA
    CLRF    TX_IDX
    CLRF    TX_DATA
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
    CLRF    PCLATH_TEMP
    CLRF    PCLATH

    CALL    CONV_DISPLAYS

    BANKSEL INTCON
    MOVLW   b'10110000'     ; GIE=1, T0IE=1, INTE=1
    MOVWF   INTCON

; ============================================================
;  LOOP PRINCIPAL
;  LEER_ADC solo se llama cuando se está esperando (no jugando
;  ni congelado). Así los LEDs no cambian durante la prueba.
; ============================================================
LOOP:
    BTFSC   TERMINADO, 0
    GOTO    LOOP            ; congelado → solo esperar IRQ RB0

    BTFSC   JUGANDO, 0
    GOTO    LOOP            ; jugando  → solo esperar IRQ RB0/T0

    ; ESPERANDO: leer ADC, actualizar LEDs, detectar cambio rango
    CALL    LEER_ADC        ; W = rango (1/2/3), actualiza LEDs
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
;  CARGAR_LIMITE  (unidad = 10ms = 1 centésima de segundo)
;  Display muestra centésimas → valor × 10ms = tiempo real
;  Rojo     25 × 10ms =  250ms  (joven)
;  Verde    50 × 10ms =  500ms  (adulto mayor)
;  Amarillo 75 × 10ms =  750ms  (paciente ACV)
; ============================================================
CARGAR_LIMITE:
    MOVF    RANGO_PREV, W
    SUBLW   d'1'
    BTFSS   STATUS, Z
    GOTO    CL_VERDE
    MOVLW   d'25'           ; 25 × 10ms = 250ms
    MOVWF   LIMITE
    RETURN
CL_VERDE:
    MOVF    RANGO_PREV, W
    SUBLW   d'2'
    BTFSS   STATUS, Z
    GOTO    CL_AMARILLO
    MOVLW   d'50'           ; 50 × 10ms = 500ms
    MOVWF   LIMITE
    RETURN
CL_AMARILLO:
    MOVLW   d'75'           ; 75 × 10ms = 750ms
    MOVWF   LIMITE
    RETURN

; ============================================================
;  CONV_DISPLAYS
; ============================================================
CONV_DISPLAYS:
    CLRF    PCLATH          ; TABLA está en página 0
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
    ; Rango estabilizado: avisar al operador antes de arrancar
    MOVLW   'L'
    CALL    TX_BYTE
    MOVLW   'I'
    CALL    TX_BYTE
    MOVLW   'S'
    CALL    TX_BYTE
    MOVLW   'T'
    CALL    TX_BYTE
    MOVLW   'O'
    CALL    TX_BYTE
    MOVLW   0x0D
    CALL    TX_BYTE
    MOVLW   0x0A
    CALL    TX_BYTE
    BSF     JUGANDO, 0
    RETURN

; ============================================================
;  TX_DIGITOS_CRLF  – envía NUM_DEC y NUM_UNI como ASCII + \r\n
; ============================================================
TX_DIGITOS_CRLF:
    CLRF    PCLATH
    MOVF    NUM_DEC, W
    ADDLW   '0'
    CALL    TX_BYTE
    MOVF    NUM_UNI, W
    ADDLW   '0'
    CALL    TX_BYTE
    MOVLW   0x0D
    CALL    TX_BYTE
    MOVLW   0x0A
    CALL    TX_BYTE
    RETURN

; ============================================================
;  TX_BYTE  (banco 0 al entrar y al salir)
; ============================================================
TX_BYTE:
    MOVWF   TX_DATA         ; TX_DATA en banco 0 (0x21)
TX_BYTE_WAIT:
    BANKSEL TXSTA
    BTFSS   TXSTA, TRMT
    GOTO    TX_BYTE_WAIT
    BANKSEL TXREG           ; vuelve a banco 0
    MOVF    TX_DATA, W
    MOVWF   TXREG
    RETURN

; ============================================================
;  TX_NORMAL_POR_RANGO / TX_EXCEDIDO_POR_RANGO
; ============================================================
TX_NORMAL_POR_RANGO:
    MOVF    RANGO_PREV, W
    SUBLW   d'1'
    BTFSS   STATUS, Z
    GOTO    TNR_R2
    CALL    TX_JOVEN_NORMAL
    CALL    TX_DIGITOS_CRLF
    RETURN
TNR_R2:
    MOVF    RANGO_PREV, W
    SUBLW   d'2'
    BTFSS   STATUS, Z
    GOTO    TNR_R3
    CALL    TX_ADULTO_NORMAL
    CALL    TX_DIGITOS_CRLF
    RETURN
TNR_R3:
    CALL    TX_ACV_NORMAL
    CALL    TX_DIGITOS_CRLF
    RETURN

TX_EXCEDIDO_POR_RANGO:
    MOVF    RANGO_PREV, W
    SUBLW   d'1'
    BTFSS   STATUS, Z
    GOTO    TER_R2
    CALL    TX_JOVEN_EXCEDIDO
    CALL    TX_DIGITOS_CRLF
    RETURN
TER_R2:
    MOVF    RANGO_PREV, W
    SUBLW   d'2'
    BTFSS   STATUS, Z
    GOTO    TER_R3
    CALL    TX_ADULTO_EXCEDIDO
    CALL    TX_DIGITOS_CRLF
    RETURN
TER_R3:
    CALL    TX_ACV_EXCEDIDO
    CALL    TX_DIGITOS_CRLF
    RETURN

; ============================================================
;  Rutinas TX por cadena (PCLATH se configura en cada una)
; ============================================================
TX_JOVEN_NORMAL:
    CLRF    TX_IDX
    MOVLW   0x02
    MOVWF   PCLATH
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
    MOVLW   0x02
    MOVWF   PCLATH
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
    MOVLW   0x02
    MOVWF   PCLATH
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
    MOVLW   0x02
    MOVWF   PCLATH
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
    MOVLW   0x03
    MOVWF   PCLATH
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
    MOVLW   0x03
    MOVWF   PCLATH
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
    MOVF    PCLATH, W       ; guardar PCLATH
    MOVWF   PCLATH_TEMP
    CLRF    PCLATH          ; asegurar página 0 al inicio de ISR

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
WAIT_REL_RST:
    BANKSEL PORTB
    BTFSS   PORTB, 0        ; esperar liberación (evita rebote)
    GOTO    WAIT_REL_RST
    GOTO    CLEAR_INTF

CONGELAR_TIEMPO:
    CLRF    JUGANDO
    BSF     TERMINADO, 0
    BANKSEL PORTB
    BSF     PORTB, 1        ; RB1 fijo encendido
    CALL    TX_NORMAL_POR_RANGO
WAIT_REL_JUG:
    BANKSEL PORTB
    BTFSS   PORTB, 0        ; esperar liberación (evita rebote)
    GOTO    WAIT_REL_JUG

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

    ; A) Multiplexado de displays
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

    ; B) Estabilidad ADC (solo en espera)
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

    ; C) Lógica de juego
LOGICA_JUEGO:
    BTFSS   JUGANDO, 0
    GOTO    CLEAR_T0IF

    ; Parpadeo RB1 cada 4×5ms = 20ms
    INCF    TICK_MUX, F
    MOVLW   d'4'
    SUBWF   TICK_MUX, W
    BTFSS   STATUS, Z
    GOTO    LOGICA_CENTI
    CLRF    TICK_MUX
    BANKSEL PORTB
    MOVLW   b'00000010'
    XORWF   PORTB, F

    ; Unidad display cada 2×5ms = 10ms (1 centésima de segundo)
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

    ; Tiempo agotado: congelar y enviar desaprobado
    CLRF    JUGANDO
    BSF     TERMINADO, 0
    BANKSEL PORTB
    BSF     PORTB, 1
    CALL    TX_EXCEDIDO_POR_RANGO

ACT_DISPLAYS:
    CALL    CONV_DISPLAYS

CLEAR_T0IF:
    BANKSEL INTCON
    BCF     INTCON, T0IF

FIN_ISR:
    MOVF    PCLATH_TEMP, W  ; restaurar PCLATH
    MOVWF   PCLATH
    SWAPF   STATUS_TEMP, W
    MOVWF   STATUS
    SWAPF   W_TEMP, F
    SWAPF   W_TEMP, W
    RETFIE

; ============================================================
;  TABLAS DE CADENAS (ORG alineados a 64 palabras)
; ============================================================

    ORG     0x200
STR_JOVEN_NORMAL:
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
    RETLW   ' '
    RETLW   '|'
    RETLW   ' '
    RETLW   0x00

    ORG     0x240
STR_JOVEN_EXCEDIDO:
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
    RETLW   ' '
    RETLW   '|'
    RETLW   ' '
    RETLW   0x00

    ORG     0x280
STR_ADULTO_NORMAL:
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
    RETLW   ' '
    RETLW   '|'
    RETLW   ' '
    RETLW   0x00

    ORG     0x2C0
STR_ADULTO_EXCEDIDO:
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
    RETLW   ' '
    RETLW   '|'
    RETLW   ' '
    RETLW   0x00

    ORG     0x300
STR_ACV_NORMAL:
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
    RETLW   ' '
    RETLW   '|'
    RETLW   ' '
    RETLW   0x00

    ORG     0x340
STR_ACV_EXCEDIDO:
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
    RETLW   ' '
    RETLW   '|'
    RETLW   ' '
    RETLW   0x00

    END
