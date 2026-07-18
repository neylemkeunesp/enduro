;===============================================================================
; NIGHT HIGHWAY
; Jogo de corrida/resistencia para Atari 2600 - NTSC, ROM de 4KB, sem bankswitch
;
; Codigo, graficos e sons originais escritos para este projeto (2025).
; Montador: DASM 2.20+ (https://dasm-assembler.github.io/)
;
;-------------------------------------------------------------------------------
; ARQUITETURA GERAL
;
; CPU 6507 @ 1.19 MHz, 128 bytes de RAM, video TIA.
; Frame NTSC: 262 scanlines = 3 VSYNC + 37 VBLANK + 192 visiveis + 30 overscan.
;
;   VSYNC    ( 3 SL)  sincronismo vertical (macro VERTICAL_SYNC)
;   VBLANK   (37 SL)  TIM64T: controles, fisica, curvas, audio, posicionamento
;   Visivel  (192 SL) kernel: HUD (24) + ceu (54) + transicao (2) + pista (112)
;   Overscan (30 SL)  TIM64T: reconstrucao da pista, IA, colisoes, progressao
;
; A pista usa playfield ASSIMETRICO atualizado a cada linha logica
; (28 linhas x 4 scanlines). Os seis registradores de playfield sao escritos
; numa ordem que respeita as janelas de desenho do TIA (ver SL2 do kernel).
; Curvas deslocam as bordas L/R de cada linha a partir de tabelas em ROM.
;
; Multiplexacao de objetos SEM flicker:
;   P0 = adversario B (parte alta) e jogador (base) - regioes disjuntas
;   P1 = adversario A (o mais proximo)
;   M0 = faixa central tracejada (segue o centro da pista via HMM0 por linha)
;   BL = sol/lua no ceu
; Como no maximo 2 adversarios sao visiveis por frame, nao ha flicker.
;
; Regioes criticas de temporizacao (kernel da pista, 4 scanlines por linha):
;   SL1  GRP0/GRP1 escritos durante o HBLANK (sprites sem rasgo)
;   SL2  HMOVE + 6 stores de playfield dentro das janelas do TIA
;   SL3  cor do asfalto + delta da faixa central (HMM0) + tracejado
;   SL4  pipeline dos bytes de sprite da proxima linha + loop
;===============================================================================

        processor 6502
        include "vcs.h"
        include "macro.h"

;===============================================================================
; 1. CONSTANTES E CONFIGURACOES
;===============================================================================

;--- Video ---------------------------------------------------------------------
; Para uma versao PAL seria preciso redefinir estas constantes, redistribuir as
; 192 linhas visiveis do kernel (PAL tem ~228) e revisar a paleta de cores.
SCAN_VBLANK     = 37                  ; NTSC; PAL usaria ~45
SCAN_OVERSCAN   = 30                  ; NTSC; PAL usaria ~36

;--- Layout vertical da area visivel -------------------------------------------
HUD_LINES       = 24                  ; 1 margem + 18 texto + 4 barra + 1 gap
SKY_LINES       = 54                  ; gradiente + montanhas + horizonte
PRE_ROAD        = 2                   ; transicao ceu->pista (setup do kernel)
ROAD_LINES      = 28                  ; linhas logicas da pista (0 = horizonte)
; 24 + 54 + 2 + 28*4 = 192 scanlines visiveis (conferido por ECHO no fim)

;--- Linhas logicas especiais ---------------------------------------------------
POS_LINE        = 21        ; linha em que P0 e reposicionado para o jogador
PLAYER_TOP      = 22        ; primeira linha do sprite do jogador (22..27)

;--- Estados -------------------------------------------------------------------
ST_TITLE        = 0
ST_INTRO        = 1
ST_PLAY         = 2
ST_CLEAR        = 3
ST_WIN          = 4
ST_OVER         = 5

;--- Periodos do dia -----------------------------------------------------------
PD_DAY          = 0
PD_DUSK         = 1
PD_NIGHT        = 2
PD_DAWN         = 3

;--- Jogabilidade --------------------------------------------------------------
SPEED_MAX       = 255
ACCEL           = 96          ; aceleracao por frame com botao (1/256 de unidade)
DECEL           = 40          ; desaceleracao natural
DECEL_OFF       = 160         ; desaceleracao fora da pista
PLAYER_X_MIN    = 16
PLAYER_X_MAX    = 132         ; mantem k <= 9 na rotina de posicionamento!
CRASH_FRAMES    = 75          ; invencibilidade/penalidade apos colisao
SPAWN_Z         = 235         ; distancia de surgimento dos adversarios
NO_CAR          = 3           ; slot vazio
COLLIDE_Z       = 70          ; z abaixo do qual ha risco de colisao
COLLIDE_X       = 10          ; distancia lateral de colisao (pixels)

;--- Offsets dos sprites dentro da pagina SpriteData ---------------------------
SPR_SEDAN_P     = 0
SPR_VAN_P       = 5
SPR_SEDAN_G     = 10
SPR_VAN_G       = 20
SPR_PLAYER      = 30
SPR_SMALL_H     = 5
SPR_BIG_H       = 10

;===============================================================================
; 2. VARIAVEIS DE RAM (128 bytes; unions temporais documentadas)
;===============================================================================

        SEG.U variables
        ORG $80

gameState       ds 1    ; estado atual (ST_*)
frameCount      ds 1    ; contador de frames
rnd             ds 1    ; LFSR pseudo-aleatorio (nunca 0)
playerX         ds 1    ; X do jogador em pixels (16..132)
curveLevel      ds 1    ; curva atual 0..4 (2 = reta)
curveTarget     ds 1    ; curva alvo
curveTimer      ds 1    ; frames ate o proximo passo de curva
scrollPhase     ds 1    ; odometro do tracejado central
stage           ds 1    ; etapa 1..3
carsLeft        ds 1    ; adversarios restantes na meta
score           ds 1    ; ultrapassagens totais (0..99)
timeSec         ds 1    ; segundos restantes
timeMax         ds 1    ; tempo total da etapa (referencia da barra)
sfxTimer        ds 1    ; duracao restante do efeito do canal 1
sfxMode         ds 1    ; 0=off 1=blip 2=crash 3=jingle 4=jingle over
sfxIndex        ds 1    ; indice dentro do jingle
lastCenter      ds 1    ; centro da pista da linha anterior (celulas)
visA            ds 1    ; adversario em P1 (NO_CAR = nenhum)
                        ; UNION: etapa inicial escolhida no titulo
visB            ds 1    ; adversario em P0
xPosPlayer      ds 1    ; copia de playerX para o kernel
gfxBufA         ds 1    ; byte de sprite da proxima linha (P1)
                        ; UNION: hudPF1L
gfxBufB         ds 1    ; byte de sprite da proxima linha (P0)
                        ; UNION: hudPF2L
digOfs          ds 6    ; indices dos 6 glifos da linha de texto 1
                        ; UNION: digOfs+4/+5 = textPtr/tempJ (par temporario)
barPF1          ds 1    ; byte PF1 da barra de tempo
                        ; UNION: brightBase na pista
spawnTimer      ds 1    ; frames ate o proximo surgimento
tempC           ds 1    ; scratch (UNION: hudPF2R / tempLo)
temp1           ds 1    ; scratch (UNION: FontPtr lo, par com temp2)
temp2           ds 1    ; scratch (UNION: FontPtr hi)

;--- ZeroBlk: 24 bytes zerados em loop no inicio de cada etapa -----------------
ZeroBlk:
speedHi         ds 1    ; velocidade 0..255
speedLo         ds 1    ; fracao da velocidade
playerVX        ds 1    ; velocidade lateral com inercia (signed)
offRoad         ds 1    ; != 0 quando fora da pista (UNION: tempW/scratch)
crashTimer      ds 1    ; invencibilidade apos colisao
                        ; UNION: debounce de SELECT fora de PLAY
timeTick        ds 1    ; divisor frames->segundos / timer de estado
carZ            ds 3    ; distancia z (0 = inativo)
carLo           ds 3    ; fracao do deslocamento em z
;--- descritores de slot de renderizacao (mesmo layout: base + 0/6) ------------
;   +0 linhas restantes (0 = inativo)  +1 indice vertical/countdown
;   +2 primeira linha (255 = fora)     +3 X em pixels na tela
;   +4/5 ponteiro do sprite (par ZP)
linesLeftA      ds 1
yA              ds 1
topA            ds 1
xPosA           ds 1
ptrA            ds 2
linesLeftB      ds 1
yB              ds 1
topB            ds 1
xPosB           ds 1
ptrB            ds 2
ZEROBLK_END     = ZeroBlk+23
;--- fora do bloco --------------------------------------------------------------
carX            ds 3    ; posicao lateral na pista (-8..+7 signed)
carSpd          ds 3    ; velocidade propria; bit7 = tipo (1 = van)

; Aliases de unions
hudPF1L         = gfxBufA       ; byte PF1L montado pela rotina de texto
hudPF2L         = gfxBufB       ; byte PF2L
hudPF2R         = tempC         ; byte PF2R
FontPtr         = temp1         ; par (temp1/temp2) - livre durante o HUD
textPtr         = digOfs+4      ; par temporario (digOfs+4/+5)
tempJ           = digOfs+4      ; ponteiro do jmp indireto de despacho
brightBase      = barPF1        ; reutilizado apos a barra
titleOpt        = visA          ; etapa inicial (1..3) no titulo
selectDeb       = crashTimer    ; debounce da chave Select
msg2Ofs         = roadL         ; indices dos 6 glifos da linha de texto 2
msg3Ofs         = roadL+6       ; linha de texto 3 (titulo)
msg4Ofs         = roadL+12      ; linha de texto 4 (titulo)

VARS_END
roadL           ds ROAD_LINES   ; borda esquerda por linha (celulas 0..16)
roadR           ds ROAD_LINES   ; borda direita por linha (celulas 23..39)
RAM_END
        echo "RAM variaveis+arrays:", [RAM_END - $80]d, "de 128 (stack no fim)"
        if RAM_END > $F8
            ERR "RAM estourada"
        endif

;===============================================================================
; 4. CODIGO - RESET E LOOP PRINCIPAL
;===============================================================================

        SEG code
        ORG $F000

        include "data.asm"

Reset:
        CLEAN_START                     ; RAM=0, TIA=0, SP=$FF, A=X=Y=0
        lda #$9C
        sta rnd                         ; semente do LFSR (diferente de zero)
        lda #1
        sta titleOpt
        lda #ST_TITLE
        sta gameState
        jsr SetupTitleText

MainLoop:
        ;--------------------- VSYNC (3 scanlines) ----------------------------
        VERTICAL_SYNC
        ;--------------------- VBLANK (37 scanlines) --------------------------
        TIMER_SETUP SCAN_VBLANK
        jsr VBlankLogic
        TIMER_WAIT
        lda #0
        sta VBLANK                      ; inicio da area visivel
        ;--------------------- KERNEL (192 scanlines) -------------------------
        jsr KernelByState
        ;--------------------- OVERSCAN (30 scanlines) ------------------------
        lda #2
        sta VBLANK                      ; blanking ligado fora da area visivel
        TIMER_SETUP SCAN_OVERSCAN
        jsr OverscanLogic
        TIMER_WAIT
        jmp MainLoop

;===============================================================================
; 5. VBLANK - despacho por estado
;===============================================================================

VBlankLogic:
        SUBROUTINE
        lda #0
        sta CXCLR                       ; colisao por software; limpa latches
        lda SWCHB                       ; chave Reset (bit0, ativa em 0)
        lsr
        bcc .doReset
        inc frameCount
        jsr NextRandom
        ldx gameState                   ; despacho via jmp indireto em ZP
        lda StateVbLo,x
        sta tempJ
        lda StateVbHi,x
        sta tempJ+1
        jmp (tempJ)
.doReset:
        jmp DoResetGame

; Retorno comum dos handlers de estado
VBlankDone:
        SUBROUTINE
        jsr UpdateAudio
        lda gameState                   ; posicionamento horizontal so em PLAY
        cmp #ST_PLAY
        bne .noPos
        lda xPosB
        ldx #RESP0
        ldy #HMP0
        jsr PosObject                   ; adversario B
        lda xPosA
        ldx #RESP1
        ldy #HMP1
        jsr PosObject                   ; adversario A
        lda #77                         ; base da faixa central (celula 20)
        ldx #RESM0
        ldy #HMM0
        jsr PosObject
        jsr GetPeriod
        tax
        lda SunXTbl,x                   ; sol/lua
        ldx #RESBL
        ldy #HMBL
        jsr PosObject
        sta WSYNC
        sta HMOVE                       ; aplica os ajustes finos
        sta HMCLR
.noPos:
        rts

StateVbLo:
        .byte <VbTitle, <VbIntro, <VbPlay, <VbClear, <VbWin, <VbOver
StateVbHi:
        .byte >VbTitle, >VbIntro, >VbPlay, >VbClear, >VbWin, >VbOver

;-------------------------------------------------------------------------------
; TITLE
;-------------------------------------------------------------------------------
VbTitle:
        SUBROUTINE
        lda selectDeb                   ; debounce da chave Select
        beq .canSel
        dec selectDeb
        bne .noSel
.canSel:
        lda SWCHB
        and #$02                        ; Select (bit1, ativa em 0)
        bne .noSel
        ldx titleOpt                    ; varia a etapa inicial 1->2->3->1
        inx
        cpx #4
        bne .optOk
        ldx #1
.optOk: stx titleOpt
        lda #20
        sta selectDeb
        jsr SetupTitleText
.noSel:
        bit INPT4                       ; botao de acao inicia a partida
        bmi .noFire
        jmp StartFromTitle
.noFire:
        jmp VBlankDone

StartFromTitle:
        SUBROUTINE
DoResetGame:
        lda titleOpt
        sta stage
        lda #0
        sta score                       ; partida nova zera a pontuacao
        jsr InitStage
        lda #ST_INTRO
        sta gameState
        jsr SetupStateText
        jmp VBlankDone

;-------------------------------------------------------------------------------
; INTRO - "STAGE n / READY" por ~2 segundos
;-------------------------------------------------------------------------------
VbIntro:
        SUBROUTINE
        inc timeTick
        lda timeTick
        cmp #120
        bne .wait
        lda #0
        sta timeTick
        lda #ST_PLAY
        sta gameState
.wait:  jmp VBlankDone

;-------------------------------------------------------------------------------
; CLEAR - etapa concluida; avanca apos ~3 segundos
;-------------------------------------------------------------------------------
VbClear:
        SUBROUTINE
        inc timeTick
        lda timeTick
        cmp #180
        bne .wait
        lda #0
        sta timeTick
        inc stage
        lda stage
        cmp #4
        bne .next
        lda #ST_WIN                     ; venceu as 3 etapas
        sta gameState
        jsr SetupStateText
        jmp VBlankDone
.next:  jsr InitStage
        lda #ST_INTRO
        sta gameState
        jsr SetupStateText
.wait:  jmp VBlankDone

;-------------------------------------------------------------------------------
; WIN / GAME OVER - botao volta ao titulo
;-------------------------------------------------------------------------------
VbWin:
        SUBROUTINE
VbOver:
        bit INPT4
        bmi .wait
        lda #ST_TITLE
        sta gameState
        jsr SetupTitleText
.wait:  jmp VBlankDone

;-------------------------------------------------------------------------------
; PLAY
;-------------------------------------------------------------------------------
VbPlay:
        SUBROUTINE
        jsr ReadInput
        jsr Physics
        jsr UpdateCurve
        jsr PlayTimers
        jmp VBlankDone

;===============================================================================
; 8. ENTRADA DO JOGADOR
;===============================================================================

ReadInput:
        SUBROUTINE
        ; SWCHA: bit7 = direita, bit6 = esquerda (player 0); 0 = pressionado
        lda SWCHA
        and #$C0
        cmp #$C0
        beq .noDir
        cmp #$80
        beq .goRight
        cmp #$40
        beq .goLeft
.noDir:                                 ; sem entrada: atrito da inercia
        lda playerVX
        beq .apply
        bmi .decNeg
        jsr CoastDelay                  ; dificuldade A atrasa o atrito
        bne .apply
        dec playerVX
        jmp .apply
.decNeg:
        jsr CoastDelay
        bne .apply
        inc playerVX
        jmp .apply
.goRight:
        lda playerVX
        clc
        adc #1
        cmp #5                          ; satura em +4
        bcc .setR
        lda #4
.setR:  sta playerVX
        jmp .apply
.goLeft:
        lda playerVX
        sec
        sbc #1
        cmp #$FC                        ; satura em -4
        bcs .setL
        lda #$FC
.setL:  sta playerVX
.apply:                                 ; playerX += VX/2 (com sinal)
        lda playerVX
        bpl .clrC
        sec
        jmp .shf
.clrC:  clc
.shf:   ror
        clc
        adc playerX
        cmp #PLAYER_X_MIN
        bcs .minOk
        lda #PLAYER_X_MIN
.minOk: cmp #PLAYER_X_MAX+1
        bcc .maxOk
        lda #PLAYER_X_MAX
.maxOk: sta playerX
        sta xPosPlayer
        rts

; CoastDelay: Z=0 quando o atrito deve ser aplicado neste frame.
; Dificuldade A (SWCHB bit6 = 0) aplica o atrito so em frames pares,
; aumentando a inercia lateral (direcao mais "solta").
CoastDelay:
        SUBROUTINE
        lda SWCHB
        and #$40
        beq .diffA
        lda #0
        rts
.diffA: lda frameCount
        and #1
        rts

;===============================================================================
; 9. FISICA E VELOCIDADE
;===============================================================================

Physics:
        SUBROUTINE
        bit INPT4                       ; botao = acelerar
        bmi .coast
        lda speedLo
        clc
        adc #ACCEL
        sta speedLo
        lda speedHi
        adc #0
        cmp #SPEED_MAX
        bcc .spdOk
        lda #SPEED_MAX
.spdOk: sta speedHi
        jmp .odom
.coast:                                 ; desaceleracao gradual
        lda #DECEL
        ldx offRoad                     ; fora da pista: penalidade forte
        beq .dec
        lda #DECEL_OFF
.dec:   sta tempC
        lda speedLo
        sec
        sbc tempC
        sta speedLo
        lda speedHi
        sbc #0
        bcs .spd2
        lda #0
        sta speedLo
.spd2:  sta speedHi
.odom:                                  ; odometro do tracejado central
        lda scrollPhase
        clc
        adc speedHi
        lsr
        lsr
        lsr
        lsr
        sta scrollPhase
        rts

;===============================================================================
; 10. ESTRADA E CURVAS - morph gradual ate o alvo
;===============================================================================

UpdateCurve:
        SUBROUTINE
        dec curveTimer
        bne .done
        lda curveLevel
        cmp curveTarget
        beq .newTarget
        bcc .up
        dec curveLevel
        jmp .morph
.up:    inc curveLevel
.morph: lda #10                         ; suaviza a transicao da curva
        sta curveTimer
        rts
.newTarget:
        ldx stage
        dex
        lda StageCurveMax,x             ; amplitude maxima da curva (1 ou 2)
        asl
        clc
        adc #1                          ; 2*max+1 alvos possiveis
        sta tempC
        jsr NextRandom
        lda rnd
        and #$0F
.mod:   cmp tempC
        bcc .modOk
        sec
        sbc tempC
        jmp .mod
.modOk: sec
        sbc StageCurveMax,x
        clc
        adc #2                          ; recentraliza no indice 2 (reta)
        sta curveTarget
        jsr NextRandom
        lda StageCurveFreq,x
        clc
        adc rnd
        sta curveTimer
.done:  rts

;===============================================================================
; 11. TIMERS DA PARTIDA
;===============================================================================

PlayTimers:
        SUBROUTINE
        lda crashTimer
        beq .noCrash
        dec crashTimer
.noCrash:
        inc timeTick
        lda timeTick
        cmp #60
        bne .done
        lda #0
        sta timeTick
        lda timeSec
        beq .done
        dec timeSec
        jsr UpdateTimeBar
.done:  rts

; UpdateTimeBar: barPF1 = FillTbl[q], q = min(8, timeSec*8/timeMax).
; Divisao 16 bits por subtracao repetida (roda 1x por segundo).
UpdateTimeBar:
        SUBROUTINE
        lda #0
        sta temp1                       ; hi do numerador
        lda timeSec
        asl
        rol temp1
        asl
        rol temp1
        asl
        rol temp1                       ; A = lo, temp1 = hi (timeSec*8)
        ldy #0
.div:   ldx temp1
        bne .sub                        ; hi != 0: certamente >= timeMax
        cmp timeMax
        bcc .divDone
.sub:   sec
        sbc timeMax
        bcs .noBorrow
        dec temp1
.noBorrow:
        iny
        cpy #9
        bne .div
        ldy #8                          ; satura em 8 (barra cheia)
.divDone:
        lda BarFillTbl,y
        sta barPF1
        rts

;===============================================================================
; 12. AUDIO
;===============================================================================

; StartSfx: A = id (1=blip 2=crash 3=jingle clear 4=jingle over).
; Prioridade: um id maior interrompe o atual.
StartSfx:
        SUBROUTINE
        cmp sfxMode
        bcc .skip
        sta sfxMode
        lda #0
        sta sfxIndex
        tax
        lda SfxLenTbl,x
        sta sfxTimer
.skip:  rts

UpdateAudio:
        SUBROUTINE
        ;---------------- motor (canal 0) -------------------------------------
        lda gameState
        cmp #ST_PLAY
        bne .ch1
        lda #2                          ; tom do motor
        ldx offRoad
        beq .engC
        lda #8                          ; ruido de cascalho fora da pista
.engC:  sta AUDC0
        lda speedHi                     ; frequencia sobe com a velocidade
        lsr
        lsr
        lsr
        lsr
        sta tempC
        lda #28
        sec
        sbc tempC
        sta AUDF0
        lda tempC                       ; volume tambem acompanha
        lsr
        clc
        adc #4
        sta AUDV0
.ch1:   ;---------------- efeitos (canal 1) ----------------------------------
        lda sfxMode
        bne .hasSfx
        sta AUDV1                       ; silencio
        rts
.hasSfx:
        dec sfxTimer
        bne .applySfx
        ldx sfxMode                     ; fim do passo atual
        cpx #3
        bcc .sfxEnd                     ; blip/crash terminam
        inc sfxIndex                    ; jingles avancam para a proxima nota
.applySfx:
        ldx sfxMode
        cpx #1
        beq .blip
        cpx #2
        beq .crash
        jmp .jingle
.blip:                                  ; ultrapassagem: bip curto
        lda #6
        sta AUDC1
        lda #8
        sta AUDF1
        lda #8
        sta AUDV1
        rts
.crash:                                 ; colisao: ruido com volume decaindo
        lda #8
        sta AUDC1
        lda #5
        sta AUDF1
        lda sfxTimer
        lsr
        sta AUDV1
        rts
.jingle:
        ldy sfxIndex
        cpx #3
        beq .jgClear
        lda JgOverF,y                   ; game over
        cmp #$FF
        beq .sfxEnd
        sta AUDF1
        lda JgOverD,y
        jmp .jgSet
.jgClear:
        lda JgClearF,y
        cmp #$FF
        beq .sfxEnd
        sta AUDF1
        lda JgClearD,y
.jgSet: sta sfxTimer                    ; duracao da nota atual
        lda #4
        sta AUDC1
        lda #10
        sta AUDV1
        rts
.sfxEnd:
        lda #0
        sta sfxMode
        sta AUDV1
        rts

;===============================================================================
; 13. POSICIONAMENTO HORIZONTAL (rotina canonica coarse+fine)
;
; Entrada: A = posicao X alvo (0..159), X = offset do registrador RESxx,
;          Y = offset do registrador HMxx.
; O strobe acontece no ciclo 20+5k do scanline (k = iteracoes do loop),
; o que posiciona o objeto em multiplos grossos de 15 pixels; o registrador
; HM cobre o ajuste fino de -8..+7 pixels. Todos os objetos usam esta mesma
; rotina (e o jogador usa uma copia inline de mesma contagem no kernel), o que
; mantem os offsets relativos consistentes. A calibracao absoluta fina pode
; exigir ajuste de +-2 px apos testes em emulador.
;===============================================================================

PosObject:
        SUBROUTINE
        sta WSYNC                       ; alinha no HBLANK
        sec
.d15:   sbc #15
        bcs .d15                        ; 5 ciclos por iteracao = 15 pixels
        eor #7
        asl
        asl
        asl
        asl                             ; A = byte de movimento fino (HM)
        sta $00,y                       ; zpg indexado endereca o registrador
        sta $00,x                       ; strobe de posicionamento
        rts

;===============================================================================
; 14. GERADOR PSEUDO-ALEATORIO (LFSR de 8 bits, periodo 255)
;===============================================================================

NextRandom:
        SUBROUTINE
        lda rnd
        lsr
        bcc .noEor
        eor #$D4
.noEor: sta rnd
        bne .ok
        lda #$9C                        ; LFSR nao pode estacionar em zero
        sta rnd
.ok:    rts

;===============================================================================
; 15. PERIODO DO DIA (retorna A = PD_*)
;===============================================================================

GetPeriod:
        SUBROUTINE
        lda gameState
        cmp #ST_TITLE
        bne .notTitle
        lda #PD_NIGHT                   ; titulo acontece a noite
        rts
.notTitle:
        cmp #ST_WIN
        bne .notWin
        lda #PD_DAWN                    ; vitoria ao amanhecer
        rts
.notWin:
        lda stage                       ; etapas: dia, entardecer, noite
        sec
        sbc #1
        rts

;===============================================================================
; 16. KERNEL - DESPACHO
;===============================================================================

KernelByState:
        SUBROUTINE
        lda gameState
        cmp #ST_PLAY
        bne .notPlay
        jmp KernelPlay
.notPlay:
        cmp #ST_TITLE
        bne .notTitle
        jmp KernelTitle
.notTitle:
        jmp KernelMessage

;===============================================================================
; 17. KERNEL - ROTINA DE TEXTO (6 posicoes, 5 linhas de glifo, 18 scanlines)
;
; Cada posicao tem 4 celulas de playfield; os pares de posicoes dividem um
; registrador: PF1L = pos 0|1, PF2L = pos 2|3, PF2R = pos 4|5. PF0 e PF1R
; ficam zerados (margens). Os indices 0..31 em textPtr usam a metade NORMAL
; da fonte (posicoes 0 e 1) e 32..63 a metade REVERTIDA (posicoes 2..5),
; o que dispensa reversao de bits em tempo de kernel.
;
; Entrada: textPtr (par ZP) -> 6 indices; FontPtr (par ZP) -> FontL0.
; Duracao exata: 18 scanlines (3 de pre-montagem + 5 linhas x 3).
;===============================================================================

MountPF1L:
        SUBROUTINE
        ldy #0                          ; pos 0 -> nibble alto (fonte normal)
        lda (textPtr),y
        tay
        lda (FontPtr),y                 ; %ABCD0000 (baixa ja e zero)
        sta hudPF1L
        ldy #1                          ; pos 1 -> nibble baixo
        lda (textPtr),y
        tay
        lda (FontPtr),y
        lsr
        lsr
        lsr
        lsr
        ora hudPF1L
        sta hudPF1L
        rts

MountPF2L:
        SUBROUTINE
        ldy #2                          ; pos 2 -> bits 0-3 (fonte revertida)
        lda (textPtr),y
        tay
        lda (FontPtr),y                 ; %DCBA0000
        lsr
        lsr
        lsr
        lsr                             ; %0000DCBA
        sta hudPF2L
        ldy #3                          ; pos 3 -> bits 4-7
        lda (textPtr),y
        tay
        lda (FontPtr),y                 ; %DCBA0000 (baixa ja e zero)
        ora hudPF2L
        sta hudPF2L
        rts

MountPF2R:
        SUBROUTINE
        ldy #4                          ; pos 4 -> bits 0-3 (fonte revertida)
        lda (textPtr),y
        tay
        lda (FontPtr),y
        lsr
        lsr
        lsr
        lsr
        sta hudPF2R
        ldy #5                          ; pos 5 -> bits 4-7
        lda (textPtr),y
        tay
        lda (FontPtr),y                 ; %DCBA0000 (baixa ja e zero)
        ora hudPF2R
        sta hudPF2R
        rts

DrawTextLine6:
        SUBROUTINE
        lda #<FontL0                    ; ponteiro da fonte (linha 0)
        sta FontPtr
        lda #>FontL0
        sta FontPtr+1
        jsr MountPF1L                   ; pre-montagem da linha 0 (124 ciclos)
        jsr MountPF2L
        sta WSYNC                       ; -> 152 (2 SL)
        jsr MountPF2R
        lda #<FontL1                    ; FontL1 em $XX40 (mesma pagina de L0)
        sta FontPtr
        lda #>FontL1
        sta FontPtr+1
        ldx #4                          ; 5 linhas de glifo, loop descendente
        sta WSYNC                       ; +69 -> 76 (1 SL)
.dlLoop:
        ;--- SL_a: stores do lado esquerdo + monta PF1L da proxima ---
        lda hudPF1L
        sta PF1                         ; ciclo ~12 (limite 28) OK
        lda hudPF2L
        sta PF2                         ; ciclo ~18 (limite 38.7) OK
        jsr MountPF1L
        sta WSYNC
        ;--- SL_b: store do lado direito + monta PF2L ---
        lda hudPF2R
        sta PF2                         ; ciclo ~9 (limite 49.3) OK
        jsr MountPF2L
        sta WSYNC
        ;--- SL_c: monta PF2R + atualiza ponteiro da fonte ---
        jsr MountPF2R
        lda FontPtrLoTbl,x              ; ponteiro baixo da proxima linha
        sta FontPtr
        cpx #2                          ; FontL4 esta na proxima pagina
        bne .noPage
        inc FontPtr+1
.noPage:
        dex
        sta WSYNC
        beq .dlEnd
        jmp .dlLoop
.dlEnd:
        rts

;===============================================================================
; 18. KERNEL PRINCIPAL (PARTIDA)
;===============================================================================

; ClearTiaRegs: zera playfield, sprites e habilitadores (comum aos kernels)
ClearTiaRegs:
        SUBROUTINE
        lda #0
        sta PF0
        sta PF1
        sta PF2
        sta CTRLPF
        sta GRP0
        sta GRP1
        sta ENAM0
        sta ENABL
        rts

KernelPlay:
        SUBROUTINE
;---------------------------- HUD (24 SL) -------------------------------------
        lda #0
        sta COLUBK                      ; HUD sobre fundo preto
        sta NUSIZ0
        sta NUSIZ1
        jsr ClearTiaRegs
        lda #$0E
        sta COLUPF                      ; texto branco
        sta WSYNC                       ; margem (1 SL)
        lda #<digOfs
        sta textPtr
        lda #0
        sta textPtr+1
        jsr DrawTextLine6               ; 18 SL: TT CC SS
        ;----------------- barra de tempo (4 SL) ----------------
        lda #1
        sta CTRLPF                      ; reflect ON: barra simetrica
        lda barPF1
        sta PF1
        lda #$C8                        ; verde
        ldx timeSec
        cpx #10
        bcs .barOk
        lda frameCount                  ; tempo critico: pisca em vermelho
        and #$20
        beq .barOk
        lda #$46
.barOk: sta COLUPF
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #0
        sta PF1
        sta WSYNC                       ; 4a SL da barra (PF limpo)
        sta WSYNC                       ; gap (1 SL)  -> HUD total = 24
;---------------------------- CEU (54 SL) -------------------------------------
        jsr GetPeriod
        asl
        asl
        asl                             ; periodo * 8 (stride da tabela)
        tay
        lda PerCols,y
        sta COLUBK                      ; primeira faixa do ceu
        lda PerCols+5,y
        sta COLUPF                      ; cor do sol/lua (ball)
        ldx #0
.skyLoop:
        txa                             ; janela vertical do sol/lua (SL 4..11)
        cmp #4
        bcc .ballOff
        cmp #12
        bcs .ballOff
        lda #2
        bne .setBall
.ballOff:
        lda #0
.setBall:
        sta ENABL
        cpx #9                          ; transicoes valem para a PROXIMA linha
        bne .n1
        lda PerCols+1,y
        sta COLUBK
.n1:    cpx #19
        bne .n2
        lda PerCols+2,y
        sta COLUBK
.n2:    cpx #29
        bne .n3
        lda PerCols+3,y
        sta COLUPF                      ; silhueta das montanhas
        lda #$18
        sta PF1                         ; pico
.n3:    cpx #35
        bne .n4
        lda #$3C
        sta PF1                         ; encosta
.n4:    cpx #41
        bne .n5
        lda #$7E
        sta PF1                         ; base
.n5:    cpx #45
        bne .n6
        lda #0
        sta PF1
        lda PerCols+4,y
        sta COLUBK                      ; grama ate o fim do ceu
.n6:    sta WSYNC
        inx
        cpx #SKY_LINES
        bne .skyLoop
;---------------------------- TRANSICAO (2 SL) --------------------------------
        lda #0
        sta CTRLPF                      ; reflect OFF: playfield assimetrico
        sta ENABL                       ; ball nao aparece na pista
        sta NUSIZ1
        lda #$10
        sta NUSIZ0                      ; missil 0 com 2 px = faixa central
        lda #$0E
        sta COLUP0                      ; jogador e faixa: branco
        jsr ComputeColA
        sta COLUP1
        jsr GetPeriod                   ; base de luminosidade do asfalto
        tax
        lda BrightBaseTbl,x
        sta brightBase
        clc
        lda roadL                       ; semente do centro da pista
        adc roadR
        ror
        sta lastCenter
        lda #0
        sta HMM0
        sta WSYNC                       ; SL t1
        jsr SetupSpritesLine0
        lda scrollPhase                 ; fase inicial do tracejado
        and #$04
        sta ENAM0
        ldx #0
        sta WSYNC                       ; SL t2
;---------------------------- PISTA (28 x 4 SL) -------------------------------
.roadLoop:
        ;--- SL1: bytes de sprite durante o HBLANK (sem rasgo) ---
        lda gfxBufB
        sta GRP0                        ; escrita ~ciclo 9
        lda gfxBufA
        sta GRP1                        ; escrita ~ciclo 15 (HBLANK: ok)
        sta WSYNC
        ;--- SL2: HMOVE + playfield assimetrico ---
        ; Janelas do TIA (ciclos CPU): PF0L<22.7 PF1L<28 PF2L<38.7;
        ; lado direito desenhado a partir de 49.3 (PF2), 60 (PF1), 70.7 (PF0).
        sta HMOVE                       ; aplica HMM0/HMP0 (ciclo 3)
        ldy roadL,x
        lda PFMask0L,y
        sta PF0                         ; ciclo 14 OK
        lda PFMask1L,y
        sta PF1                         ; ciclo 21 OK
        lda PFMask2L,y
        sta PF2                         ; ciclo 28 OK
        ldy roadR,x
        lda PFMask1R,y
        sta PF1                         ; ciclo 39: lado esq. ja desenhado
        lda PFMask2R,y
        SLEEP 4                         ; PF2R so apos a leitura do lado esq.
        sta PF2                         ; ciclo 50: celulas 16-23 sempre 1,
                                        ; logo a transicao e invisivel
        lda PFMask0R,y
        sta PF0                         ; ciclo 57 (limite 70.7) OK
        sta WSYNC
        ;--- SL3: cor do asfalto + deslocamento da faixa central ---
        ; Orcamento: 71 ciclos (76 max). Linha 21 toma o caminho .repos.
        cpx #POS_LINE
        beq .repos
        clc                             ; carry limpo p/ os dois ADCs abaixo
        lda BrightX,x                   ; brilho cresce perto do jogador
        adc brightBase                  ; (soma <= 14: carry sai limpo)
        sta COLUPF
        lda roadL,x                     ; (sem CLC: carry ja esta limpo)
        adc roadR,x
        ror                             ; centro da pista em celulas
        tay
        sec
        sbc lastCenter
        asl
        asl                             ; delta em pixels (-8..+8)
        clc
        adc #8
        sty lastCenter
        tay
        lda HMDeltaTbl,y
        sta HMM0                        ; aplicado pelo HMOVE da proxima linha
        txa                             ; tracejado animado pela velocidade
        adc scrollPhase                 ; (carry variavel: fase tolerante)
        and #$04
        sta ENAM0
        jmp .sl4
.repos:                                 ; linha 21: P0 vira o jogador
        lda xPosPlayer                  ; mesma contagem de ciclos da PosObject
        sec
.pl15:  sbc #15
        bcs .pl15
        eor #7
        asl
        asl
        asl
        asl
        sta HMP0                        ; aplicado pelo HMOVE da linha 22
        sta RESP0
        lda #0
        sta HMM0                        ; faixa congela 1 linha (imperceptivel)
.sl4:
        ;--- SL4: pipeline dos sprites da linha X+1 ---
        ; Orcamento: 72 ciclos no pior caso (A e B ativos).
        lda #0
        sta gfxBufA
        sta gfxBufB
        cpx #POS_LINE-1
        bcs .doPlayer                   ; X >= 20: so o jogador
        ;------ adversario A (P1) ------
        lda linesLeftA
        bne .actA
        lda yA                          ; countdown pre-sprite
        beq .doneA
        dec yA
        bne .doneA
        lda ptrA                        ; ativou: altura conforme o sprite
        cmp #SPR_SEDAN_G
        bcc .smA
        lda #SPR_BIG_H
        bne .hA
.smA:   lda #SPR_SMALL_H
.hA:    sta linesLeftA
        ldy #0
        sty yA
.actA:  ldy yA
        lda (ptrA),y
        sta gfxBufA
        inc yA
        dec linesLeftA
.doneA:
        ;------ adversario B (P0) ------
        lda linesLeftB
        bne .actB
        lda yB
        beq .pipeEnd
        dec yB
        bne .pipeEnd
        lda ptrB
        cmp #SPR_SEDAN_G
        bcc .smB
        lda #SPR_BIG_H
        bne .hB
.smB:   lda #SPR_SMALL_H
.hB:    sta linesLeftB
        ldy #0
        sty yB
.actB:  ldy yB
        lda (ptrB),y
        sta gfxBufB
        inc yB
        dec linesLeftB
.pipeEnd:
        inx
        cpx #ROAD_LINES
        sta WSYNC
        beq .roadDone
        jmp .roadLoop
.doPlayer:                              ; jogador ocupa as linhas 22..27
        cpx #POS_LINE+1
        bne .noClr                      ; linha 22: zera HMP0 depois do
        lda #0                          ; HMOVE que aplicou o ajuste fino
        sta HMP0                        ; do reposicionamento do jogador
.noClr:
        cpx #POS_LINE
        bcc .toEnd
        cpx #ROAD_LINES-1
        bcs .toEnd
        txa
        sec
        sbc #POS_LINE
        tay
        lda SpriteData+SPR_PLAYER,y
        sta gfxBufB
        lda crashTimer                  ; invencibilidade: jogador pisca
        beq .toEnd
        lda frameCount
        and #$08
        beq .toEnd
        lda #0
        sta gfxBufB
.toEnd: jmp .pipeEnd
.roadDone:
        rts

; SetupSpritesLine0: prepara os buffers da primeira linha da pista
SetupSpritesLine0:
        SUBROUTINE
        lda #0
        sta gfxBufA
        sta gfxBufB
        ldx topA
        bne .cdA
        lda ptrA                        ; sprite A comeca ja na linha 0
        cmp #SPR_SEDAN_G
        bcc .smA
        lda #SPR_BIG_H
        bne .hA
.smA:   lda #SPR_SMALL_H
.hA:    sta linesLeftA
        ldy #0
        lda (ptrA),y
        sta gfxBufA
        lda #1
        sta yA
        dec linesLeftA
        jmp .setB
.cdA:   stx yA                          ; countdown = topA
        lda #0
        sta linesLeftA
.setB:  ldx topB
        bne .cdB
        lda ptrB
        cmp #SPR_SEDAN_G
        bcc .smB
        lda #SPR_BIG_H
        bne .hB
.smB:   lda #SPR_SMALL_H
.hB:    sta linesLeftB
        ldy #0
        lda (ptrB),y
        sta gfxBufB
        lda #1
        sta yB
        dec linesLeftB
        rts
.cdB:   stx yB
        lda #0
        sta linesLeftB
        rts

; ComputeColA: cor do adversario A (varia por carro; escurece na etapa noturna)
ComputeColA:
        SUBROUTINE
        lda visA
        cmp #NO_CAR
        beq .def
        clc
        adc stage
        and #3
        tax
        lda CarCols,x
        ldx stage                       ; etapa 3 acontece a noite
        cpx #3
        bne .day
        and #$F0                        ; mesma matiz, luminosidade baixa
        ora #$04
.day:   rts
.def:   lda #$34
        rts

;===============================================================================
; 19. KERNEL DO TITULO
;===============================================================================

KernelTitle:
        SUBROUTINE
        lda #$80
        sta COLUBK                      ; ceu noturno
        jsr ClearTiaRegs
        ldx #24                         ; margem superior
.m1:    sta WSYNC
        dex
        bne .m1
        ;---------------- logo (10 linhas x 3 SL) ----------------
        ldy #0                          ; indice de bytes em LogoGfx
        ldx #0                          ; linha 0..9
.logoLoop:
        lda LogoGfx,y                   ; lado esquerdo
        sta PF0
        lda LogoGfx+1,y
        sta PF1
        lda LogoGfx+2,y
        sta PF2
        cpx #5
        bne .colA
        lda #$9E                        ; segunda palavra: azul
        bne .colSet
.colA:  lda #$1E                        ; primeira palavra: amarelo
.colSet:
        sta COLUPF
        sta WSYNC
        lda LogoGfx+3,y                 ; lado direito
        sta PF2
        lda LogoGfx+4,y
        sta PF1
        lda LogoGfx+5,y
        sta PF0
        sta WSYNC
        tya
        clc
        adc #6
        tay
        sta WSYNC
        inx
        cpx #10
        bne .logoLoop
        lda #0                          ; gap (6 SL)
        sta PF0
        sta PF1
        sta PF2
        ldx #6
.g1:    sta WSYNC
        dex
        bne .g1
        ;---------------- 4 linhas de texto (4 x 18 SL) ----------------
        lda frameCount                  ; "PUSH FIRE!" pisca via cor
        and #$20
        beq .blinkOn
        lda #$80                        ; igual ao fundo = invisivel
        jmp .blinkSet
.blinkOn:
        lda #$0E
.blinkSet:
        sta COLUPF
        lda #<digOfs                    ; "PUSH"
        sta textPtr
        lda #0
        sta textPtr+1
        jsr DrawTextLine6
        lda #<msg2Ofs                   ; "FIRE!"
        sta textPtr
        lda #0
        sta textPtr+1
        jsr DrawTextLine6
        lda #$0E                        ; demais linhas sempre visiveis
        sta COLUPF
        lda #<msg3Ofs                   ; "SELECT"
        sta textPtr
        lda #0
        sta textPtr+1
        jsr DrawTextLine6
        lda #<msg4Ofs                   ; "STAGE n"
        sta textPtr
        lda #0
        sta textPtr+1
        jsr DrawTextLine6
        ldx #[192-24-30-6-72]           ; margem final (60 SL)
.m2:    sta WSYNC
        dex
        bne .m2
        rts

;===============================================================================
; 20. KERNEL DE MENSAGENS (INTRO / CLEAR / WIN / GAME OVER)
;===============================================================================

KernelMessage:
        SUBROUTINE
        jsr GetPeriod
        asl
        asl
        asl
        tay
        lda PerCols,y                   ; fundo na cor do ceu do periodo
        sta COLUBK
        jsr ClearTiaRegs
        lda #$0E
        sta COLUPF
        ldx #79
.m1:    sta WSYNC
        dex
        bne .m1
        lda #<digOfs                    ; linha 1 da mensagem
        sta textPtr
        lda #0
        sta textPtr+1
        jsr DrawTextLine6
        lda #<msg2Ofs                   ; linha 2 da mensagem
        sta textPtr
        lda #0
        sta textPtr+1
        jsr DrawTextLine6
        ldx #[192-79-36]
.m2:    sta WSYNC
        dex
        bne .m2
        rts

;--- helpers de ponteiro -------------------------------------------------------
SetTextPtrA:                            ; A = byte baixo do buffer de glifos
        SUBROUTINE
        sta textPtr
        lda #0
        sta textPtr+1
        rts

;===============================================================================
; 21. OVERSCAN
;===============================================================================

OverscanLogic:
        SUBROUTINE
        lda gameState
        cmp #ST_PLAY
        beq OsPlay
        rts

OsPlay:
        SUBROUTINE
        jsr RebuildRoad
        jsr MoveCars
        jsr SpawnLogic
        jsr SelectVisible
        lda visA
        ldx #0
        jsr MapCar
        lda visB
        ldx #6
        jsr MapCar
        jsr CheckCollisions
        jsr UpdateHudDigits
        jsr OffRoadCheck
        jsr Progression
        rts

;-------------------------------------------------------------------------------
; Reconstrucao da pista em RAM: roadL/roadR por linha (curva + perspectiva)
;-------------------------------------------------------------------------------
RebuildRoad:
        SUBROUTINE
        lda curveLevel
        tax
        lda CurvePtrLo,x
        sta tempC
        lda CurvePtrHi,x
        sta temp1
        ldy #ROAD_LINES-1
.rdLoop:
        lda (tempC),y                   ; offset de curva (signed)
        clc
        adc #20                         ; centro da tela = celula 20
        sta temp2
        lda RoadWidthTbl,y
        lsr                             ; W/2
        sta offRoad                     ; UNION tempW
        lda temp2
        sec
        sbc offRoad                     ; borda esquerda
        bpl .lOk
        lda #0                          ; pista sai da tela na curva forte
.lOk:   sta roadL,y
        lda temp2
        clc
        adc offRoad                     ; borda direita
        cmp #40
        bcc .rOk
        lda #39
.rOk:   sta roadR,y
        dey
        bpl .rdLoop
        rts

;-------------------------------------------------------------------------------
; Movimento dos adversarios (z relativo ao jogador)
;-------------------------------------------------------------------------------
MoveCars:
        SUBROUTINE
        ldx #2
.mcLoop:
        lda carZ,x
        beq .next
        lda carSpd,x
        and #$7F
        sta tempC                       ; velocidade propria do adversario
        lda speedHi
        sec
        sbc tempC
        bcc .carFaster
        sta temp2                       ; jogador mais rapido: z diminui
        lsr
        lsr
        lsr
        lsr
        sta temp1                       ; delta inteiro
        lda temp2
        and #$0F                        ; fracao acumulada por carro
        clc
        adc carLo,x
        sta carLo,x
        bcc .noEx
        inc temp1
.noEx:  lda carZ,x
        sec
        sbc temp1
        bcc .passed                     ; underflow = ultrapassagem!
        sta carZ,x
        jmp .next
.carFaster:                             ; jogador mais lento: carro se afasta
        lda tempC
        sec
        sbc speedHi
        lsr
        lsr
        lsr
        lsr
        clc
        adc carZ,x
        bcs .cap
        cmp #241
        bcc .setZ
.cap:   lda #240                        ; limite no horizonte
.setZ:  sta carZ,x
        jmp .next
.passed:
        lda #0
        sta carZ,x
        sta carLo,x
        lda carsLeft
        beq .noDec
        dec carsLeft                    ; meta da etapa
.noDec: lda score
        cmp #99
        bcs .noInc
        inc score                       ; pontuacao acumula entre etapas
.noInc: lda #1
        jsr StartSfx                    ; blip de ultrapassagem
.next:  dex
        bpl .mcLoop
        rts

;-------------------------------------------------------------------------------
; Surgimento de adversarios (com verificacao de faixa livre)
;-------------------------------------------------------------------------------
SpawnLogic:
        SUBROUTINE
        dec spawnTimer
        beq .try
        rts
.try:   ldx #0
.find:  lda carZ,x                      ; procura slot inativo
        beq .found
        inx
        cpx #3
        bne .find
        lda #30                         ; sem slot: nova tentativa em breve
        sta spawnTimer
        rts
.found: stx temp2                       ; slot escolhido
        jsr NextRandom
        lda rnd
        and #$0F
        sec
        sbc #8                          ; faixa lateral -8..+7
        sta tempC
        ldy #0                          ; verifica se nao trava outro carro
.gap:   cpy temp2
        beq .gapNext
        lda carZ,y
        beq .gapNext
        sec
        sbc #SPAWN_Z
        bpl .gz
        eor #$FF
        clc
        adc #1
.gz:    cmp #40                         ; so importa quem esta perto do horizonte
        bcs .gapNext
        lda carX,y
        sec
        sbc tempC
        bpl .gx
        eor #$FF
        clc
        adc #1
.gx:    cmp #10
        bcc .badLane                    ; bloquearia a faixa vizinha
.gapNext:
        iny
        cpy #3
        bne .gap
        jmp .laneOk
.badLane:
        lda tempC                       ; inverte a faixa (pista e larga)
        eor #$FF
        clc
        adc #1
        sta tempC
.laneOk:
        ldx temp2
        lda tempC
        sta carX,x
        lda #SPAWN_Z
        sta carZ,x
        lda #0
        sta carLo,x
        lda stage                       ; velocidade base da etapa
        sec
        sbc #1
        tay
        jsr NextRandom
        lda rnd
        and #$0F
        clc
        adc StageCarBase,y
        bit SWCHB                       ; dificuldade A (bit6=0): -15
        bvs .keepSpd
        sec
        sbc #15
.keepSpd:
        sta temp1
        jsr NextRandom
        lda rnd                         ; tipo visual: bit6 do rnd -> bit7
        and #$40
        asl
        ora temp1
        ldx temp2
        sta carSpd,x
        lda stage                       ; intervalo ate o proximo spawn
        sec
        sbc #1
        tay
        jsr NextRandom
        lda rnd
        and #$1F
        clc
        adc StageSpawn,y
        sta spawnTimer
        rts

;-------------------------------------------------------------------------------
; Selecao dos 2 adversarios visiveis (menores z ativos)
;-------------------------------------------------------------------------------
SelectVisible:
        SUBROUTINE
        lda #NO_CAR
        sta visA
        sta visB
        ldx #0
.svLoop:
        lda carZ,x
        beq .next
        ldy visA
        cpy #NO_CAR
        beq .setA
        lda carZ,x
        cmp carZ,y
        bcc .setA
        ldy visB
        cpy #NO_CAR
        beq .setB
        lda carZ,x
        cmp carZ,y
        bcc .setB
        jmp .next
.setA:  lda visA
        sta visB
        stx visA
        jmp .next
.setB:  stx visB
.next:  inx
        cpx #3
        bne .svLoop
        rts

;-------------------------------------------------------------------------------
; Mapeamento z -> linha/escala/posicao na tela (subrotina unica).
; Entrada: A = indice do adversario (0..2 ou NO_CAR), X = offset do slot (0/6).
; Usa tempC (linha i), temp1 (indice do carro), temp2/offRoad (scratch).
;-------------------------------------------------------------------------------
MapCar:
        SUBROUTINE
        sta temp1                       ; indice do adversario
        cmp #NO_CAR
        bne .map
        lda #0
        sta linesLeftA,x
        sta yA,x
        lda #255
        sta topA,x
        lda #76
        sta xPosA,x
        rts
.map:
        ldy temp1
        lda carZ,y                      ; i = 27 - (z>>3), clamp 0
        lsr
        lsr
        lsr
        sta tempC
        lda #ROAD_LINES-1
        sec
        sbc tempC
        bpl .iOk
        lda #0
.iOk:   sta tempC                       ; i = linha logica
        lda carZ,y                      ; tamanho pela distancia: z>=140 pequeno
        cmp #140
        bcs .small
        lda #SPR_BIG_H
        sta temp2                       ; altura em linhas
        lda carSpd,y                    ; tipo visual: bit7
        and #$80
        beq .bigSedan
        lda #SPR_VAN_G
        bne .setPtr
.bigSedan:
        lda #SPR_SEDAN_G
        jmp .setPtr
.small: lda #SPR_SMALL_H
        sta temp2
        lda carSpd,y
        and #$80
        beq .smSedan
        lda #SPR_VAN_P
        bne .setPtr
.smSedan:
        lda #SPR_SEDAN_P
.setPtr:
        sta ptrA,x
        lda #>SpriteData
        sta ptrA+1,x
        lda tempC                       ; topo = i - altura + 1
        sec
        sbc temp2
        clc
        adc #1
        bmi .offscr
        sta topA,x
        ldy tempC                       ; X = 4*centro + carX*XShift[i] - 4
        clc
        lda roadL,y
        adc roadR,y
        ror
        asl
        asl
        sta temp2                       ; centro * 4 pixels
        ldy tempC
        lda XShiftTbl,y                 ; escala de perspectiva 1..4
        cmp #2
        beq .m2
        cmp #3
        beq .m3
        cmp #4
        beq .m4
        ldy temp1                       ; x1
        lda carX,y
        jmp .mAdd
.m2:    ldy temp1                       ; x2
        lda carX,y
        asl
        jmp .mAdd
.m3:    ldy temp1                       ; x3 = x2 + x1
        lda carX,y
        sta offRoad                     ; UNION: scratch
        asl
        clc
        adc offRoad
        jmp .mAdd
.m4:    ldy temp1                       ; x4
        lda carX,y
        asl
        asl
.mAdd:  clc
        adc temp2
        sec
        sbc #4                          ; sprite de 8px: canto esquerdo
        cmp #12                         ; clamp 12..144
        bcs .xMin
        lda #12
.xMin:  cmp #145
        bcc .xMax
        lda #144
.xMax:  sta xPosA,x
        rts
.offscr:
        lda #0
        sta linesLeftA,x
        sta yA,x
        lda #255
        sta topA,x
        rts

;-------------------------------------------------------------------------------
; Colisoes: adversario proximo (z baixo) + contato lateral
;-------------------------------------------------------------------------------
CheckCollisions:
        SUBROUTINE
        lda crashTimer
        bne .done                       ; invencivel apos batida
        ldx visA
        cpx #NO_CAR
        beq .chkB
        lda carZ,x
        cmp #COLLIDE_Z
        bcs .chkB
        lda xPosA
        sec
        sbc playerX
        bpl .dA
        eor #$FF
        clc
        adc #1
.dA:    cmp #COLLIDE_X
        bcc .hitA
.chkB:  ldx visB
        cpx #NO_CAR
        beq .done
        lda carZ,x
        cmp #COLLIDE_Z
        bcs .done
        lda xPosB
        sec
        sbc playerX
        bpl .dB
        eor #$FF
        clc
        adc #1
.dB:    cmp #COLLIDE_X
        bcc .hitB
.done:  rts
.hitA:  ldx visA
        jmp CrashCar
.hitB:  ldx visB
CrashCar:                               ; X = adversario envolvido
        lda #0
        sta carZ,x                      ; adversario some (sem pontuar)
        sta carLo,x
        lda speedHi                     ; penalidade: perde 3/4 da velocidade
        lsr
        lsr
        sta speedHi
        lda #0
        sta speedLo
        lda #CRASH_FRAMES               ; recuperacao sem reiniciar a etapa
        sta crashTimer
        lda #2
        jsr StartSfx                    ; som de colisao
        rts

;-------------------------------------------------------------------------------
; HUD: digitos de tempo / carros / pontuacao (posicoes 2..5 = fonte revertida)
;-------------------------------------------------------------------------------
UpdateHudDigits:
        SUBROUTINE
        lda timeSec
        jsr Div10
        sta digOfs+0
        txa
        sta digOfs+1
        lda carsLeft
        jsr Div10
        clc
        adc #32
        sta digOfs+2
        txa
        clc
        adc #32
        sta digOfs+3
        lda score
        jsr Div10
        clc
        adc #32
        sta digOfs+4
        txa
        clc
        adc #32
        sta digOfs+5
        rts

Div10:                                  ; entrada A; saida: A = A/10, X = resto
        ldx #$FF
.d:     inx
        sec
        sbc #10
        bcs .d
        adc #10
        sta temp2
        txa
        ldx temp2
        rts

;-------------------------------------------------------------------------------
; Verificacao de saída de pista (jogador x bordas na base)
;-------------------------------------------------------------------------------
OffRoadCheck:
        SUBROUTINE
        lda roadL+ROAD_LINES-1
        asl
        asl                             ; borda esquerda em pixels
        clc
        adc #2                          ; margem interna
        sta tempC
        lda playerX
        cmp tempC
        bcc .off
        lda roadR+ROAD_LINES-1
        asl
        asl
        sec
        sbc #6                          ; largura do carro (8px) + margem
        sta tempC
        lda playerX
        cmp tempC
        bcc .on
.off:   lda #1
        sta offRoad
        rts
.on:    lda #0
        sta offRoad
        rts

;-------------------------------------------------------------------------------
; Progressao: meta cumprida -> CLEAR; tempo esgotado -> GAME OVER
;-------------------------------------------------------------------------------
Progression:
        SUBROUTINE
        lda carsLeft
        bne .chkTime
        lda #ST_CLEAR
        sta gameState
        lda #0
        sta timeTick
        lda #3
        jsr StartSfx                    ; jingle de etapa concluida
        jsr SetupStateText
        rts
.chkTime:
        lda timeSec
        bne .ok
        lda #ST_OVER
        sta gameState
        lda #4
        jsr StartSfx                    ; jingle de game over
        jsr SetupStateText
.ok:    rts

;===============================================================================
; 22. INICIALIZACAO DE ETAPA E TEXTOS
;===============================================================================

InitStage:
        SUBROUTINE
        ldx stage
        dex
        lda StageGoal,x
        sta carsLeft
        lda StageTime,x
        sta timeSec
        sta timeMax
        ldx #24                         ; zera o bloco de estado da partida
        lda #0
.z:     sta ZeroBlk-1,x
        dex
        bne .z
        lda #76
        sta playerX
        sta xPosPlayer
        lda #2                          ; pista reta no inicio da etapa
        sta curveLevel
        sta curveTarget
        lda #60
        sta curveTimer
        lda #30
        sta spawnTimer
        lda #$FF
        sta barPF1                      ; barra de tempo cheia
        lda #NO_CAR
        sta visA
        sta visB
        jsr UpdateHudDigits
        jsr UpdateTimeBar
        jsr RebuildRoad
        rts

; CopyMsgTo: A = offset em MsgTable; textPtr = destino (6 bytes).
; Posicoes 2..5 recebem +32 (metade revertida da fonte).
CopyMsgTo:
        SUBROUTINE
        tax
        ldy #0
.l:     lda MsgTable,x
        cpy #2
        bcc .lo
        clc
        adc #32
.lo:    sta (textPtr),y
        inx
        iny
        cpy #6
        bne .l
        rts

; SetupStateText: carrega as 2 linhas de mensagem conforme o estado atual
; (ST_INTRO/CLEAR/WIN/OVER) usando MsgPairTbl. No INTRO, anexa o digito da etapa.
SetupStateText:
        SUBROUTINE
        lda gameState
        sec
        sbc #ST_INTRO
        asl
        tax
        lda MsgPairTbl,x
        sta tempC
        lda MsgPairTbl+1,x
        sta temp1
        lda #<digOfs
        jsr SetTextPtrA
        lda tempC
        jsr CopyMsgTo
        lda #<msg2Ofs
        jsr SetTextPtrA
        lda temp1
        jsr CopyMsgTo
        lda gameState
        cmp #ST_INTRO
        bne .done
        lda stage                       ; digito da etapa na ultima posicao
        clc
        adc #32
        sta digOfs+5
.done:  rts

SetupTitleText:
        SUBROUTINE
        lda #<digOfs
        jsr SetTextPtrA
        lda #MSG_PUSH
        jsr CopyMsgTo
        lda #<msg2Ofs
        jsr SetTextPtrA
        lda #MSG_FIRE
        jsr CopyMsgTo
        lda #<[roadL+6]
        sta textPtr
        lda #>[roadL+6]
        sta textPtr+1
        lda #MSG_SELECT
        jsr CopyMsgTo
        lda #<[roadL+12]
        sta textPtr
        lda #>[roadL+12]
        sta textPtr+1
        lda #MSG_STAGEN
        jsr CopyMsgTo
        lda titleOpt                    ; digito da etapa na ultima posicao
        clc
        adc #32
        sta roadL+17
        rts

;===============================================================================
; 23. DADOS GRAFICOS - SPRITES (pagina propria: ponteiros de 1 byte)
;===============================================================================

        ALIGN 256
SpriteData:
;--- SprSedanP (offset 0): sedan adversario, versao distante (5 linhas) -------
; ..####..
; ##.##.##
; ########
; ###..###
; ##....##
        .byte $3C,$DB,$FF,$E7,$C3
;--- SprVanP (offset 5): van adversaria, versao distante (5 linhas) -----------
; .######.
; ########
; ##.##.##
; ###..###
; ##....##
        .byte $7E,$FF,$DB,$E7,$C3
;--- SprSedanG (offset 10): sedan adversario, versao proxima (10 linhas) ------
; ..####..
; .######.
; ##.##.##
; ########
; .######.
; ########
; ###..###
; ########
; ##....##
; #......#
        .byte $3C,$7E,$DB,$FF,$7E,$FF,$E7,$FF,$C3,$81
;--- SprVanG (offset 20): van adversaria, versao proxima (10 linhas) ----------
; .######.
; ########
; ##.##.##
; ##.##.##
; ########
; ########
; ###..###
; ########
; ##....##
; #......#
        .byte $7E,$FF,$DB,$DB,$FF,$FF,$E7,$FF,$C3,$81
;--- SprPlayer (offset 30): carro do jogador (6 linhas) -----------------------
; ..####..
; .######.
; ##.##.##
; ########
; ###..###
; ##....##
        .byte $3C,$7E,$DB,$FF,$E7,$C3
        CHECK_PAGE SpriteData, "SpriteData"

;===============================================================================
; 24. TABELAS CRITICAS DO KERNEL (nao podem cruzar pagina: +1 ciclo quebraria
; o SL2 da pista). Geradas por script e verificadas com CHECK_PAGE.
;===============================================================================

        ; (sem ALIGN: CHECK_PAGE abaixo garante que o bloco nao cruza pagina)
;--- Mascaras de playfield para a borda esquerda L = 0..16 --------------------
; PF0: celulas 0-3 (bits 4-7); PF1: celulas 4-11 (bit7 = celula 4);
; PF2: celulas 12-19 (bit0 = celula 12). Celulas 16-19 sao sempre 1.
PFMask0L:
        .byte $F0,$E0,$C0,$80,$00,$00,$00,$00,$00,$00
        .byte $00,$00,$00,$00,$00,$00,$00
PFMask1L:
        .byte $FF,$FF,$FF,$FF,$FF,$7F,$3F,$1F,$0F,$07
        .byte $03,$01,$00,$00,$00,$00,$00
PFMask2L:
        .byte $FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF
        .byte $FF,$FF,$FF,$FE,$FC,$F8,$F0
;--- Mascaras para a borda direita R = 23..39 (indexadas por R-23) ------------
; PF2: celulas 20-27 (bit0 = celula 20); PF1: celulas 28-35 (bit7 = celula 28);
; PF0: celulas 36-39 (bit4 = celula 36). Celulas 20-23 sao sempre 1.
PFMask2R:
        .byte $0F,$1F,$3F,$7F,$FF,$FF,$FF,$FF,$FF,$FF
        .byte $FF,$FF,$FF,$FF,$FF,$FF,$FF
PFMask1R:
        .byte $00,$00,$00,$00,$00,$80,$C0,$E0,$F0,$F8
        .byte $FC,$FE,$FF,$FF,$FF,$FF,$FF
PFMask0R:
        .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        .byte $00,$00,$00,$10,$30,$70,$F0
;--- Brilho do asfalto por linha (somado a brightBase conforme o periodo) -----
BrightX:
        .byte 0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,2,2,2,2,2,2,3,3,3,3,4,4,4
;--- Movimento horizontal da faixa: indice = delta em pixels + 8 --------------
; (HM: nibble 0-7 = direita 0-7, 8-15 = esquerda 8-1; +8 satura em +7)
HMDeltaTbl:
        .byte $80,$90,$A0,$B0,$C0,$D0,$E0,$F0,$00,$10,$20,$30,$40,$50,$60,$70,$70
        CHECK_PAGE PFMask0L, "Tabelas do kernel"

;--- TABELAS DE ETAPA (secao 29; posicionadas aqui, no espaco livre antes do
;    ALIGN da fonte, para nao estourar a ROM sobre os vetores em $FFFA) --------
StageGoal:
        .byte 8,12,16           ; ultrapassagens necessarias
StageTime:
        .byte 60,70,80          ; segundos disponiveis
StageCarBase:
        .byte 150,135,120       ; velocidade base dos adversarios
StageSpawn:
        .byte 100,75,55         ; intervalo base de surgimento (frames)
StageCurveMax:
        .byte 1,2,2             ; amplitude maxima das curvas
StageCurveFreq:
        .byte 200,140,90        ; intervalo base entre mudancas de curva

;===============================================================================
; 25. FONTE 4x5 (32 glifos: 0-9, A C D E F G H I L M N O P R S T U V W Y ! sp)
; Cada linha de glifo: 32 bytes na ordem normal (%ABCD0000) seguidos de
; 32 bytes revertidos (%DCBA0000) para as posicoes servidas por PF2.
; Alinhada a 64: cada bloco de linha fica contido numa pagina; a unica
; transicao de pagina acontece na pre-montagem.
;===============================================================================

        ALIGN 256
;--- FontL0-L3 ficam na mesma pagina; FontL4 na proxima --------------------
FontL0:
        .byte $E0,$40,$E0,$E0,$A0,$E0,$E0,$E0
        .byte $E0,$E0,$40,$60,$C0,$E0,$E0,$60
        .byte $A0,$E0,$80,$A0,$90,$40,$E0,$E0
        .byte $60,$E0,$A0,$A0,$A0,$A0,$40,$00
        .byte $70,$20,$70,$70,$50,$70,$70,$70
        .byte $70,$70,$20,$60,$30,$70,$70,$60
        .byte $50,$70,$10,$50,$90,$20,$70,$70
        .byte $60,$70,$50,$50,$50,$50,$20,$00
FontL1:
        .byte $A0,$C0,$20,$20,$A0,$80,$80,$20
        .byte $A0,$A0,$A0,$80,$A0,$80,$80,$80
        .byte $A0,$40,$80,$E0,$D0,$A0,$A0,$A0
        .byte $80,$40,$A0,$A0,$A0,$A0,$40,$00
        .byte $50,$30,$40,$40,$50,$10,$10,$40
        .byte $50,$50,$50,$10,$50,$10,$10,$10
        .byte $50,$20,$10,$70,$B0,$50,$50,$50
        .byte $10,$20,$50,$50,$50,$50,$20,$00
FontL2:
        .byte $A0,$40,$E0,$60,$E0,$E0,$E0,$40
        .byte $E0,$E0,$E0,$80,$A0,$C0,$C0,$A0
        .byte $E0,$40,$80,$E0,$B0,$A0,$E0,$C0
        .byte $40,$40,$A0,$A0,$E0,$40,$40,$00
        .byte $50,$20,$70,$60,$70,$70,$70,$20
        .byte $70,$70,$70,$10,$50,$30,$30,$50
        .byte $70,$20,$10,$70,$D0,$50,$70,$30
        .byte $20,$20,$50,$50,$70,$20,$20,$00
FontL3:
        .byte $A0,$40,$80,$20,$20,$20,$A0,$40
        .byte $A0,$20,$A0,$80,$A0,$80,$80,$A0
        .byte $A0,$40,$80,$A0,$90,$A0,$80,$A0
        .byte $20,$40,$A0,$A0,$E0,$40,$00,$00
        .byte $50,$20,$10,$40,$40,$40,$50,$20
        .byte $50,$40,$50,$10,$50,$10,$10,$50
        .byte $50,$20,$10,$50,$90,$50,$10,$50
        .byte $40,$20,$50,$50,$70,$20,$00,$00
FontL4:
        .byte $E0,$E0,$E0,$E0,$20,$E0,$E0,$40
        .byte $E0,$E0,$A0,$60,$C0,$E0,$80,$60
        .byte $A0,$E0,$E0,$A0,$90,$40,$80,$A0
        .byte $C0,$40,$E0,$40,$A0,$40,$40,$00
        .byte $70,$70,$70,$70,$40,$70,$70,$20
        .byte $70,$70,$50,$60,$30,$70,$10,$60
        .byte $50,$70,$70,$50,$90,$20,$10,$50
        .byte $30,$20,$70,$20,$50,$20,$20,$00
;--- ponteiro baixo da linha de glifos por iteracao (X = 4,3,2,1,0) ------------
; FontL0 em $XX00, FontL1 em $XX40, FontL2 em $XX80, FontL3 em $XXC0, FontL4 em $YY00
FontPtrLoTbl:
        .byte $00,$00,$00,$C0,$80

;===============================================================================
; 26. LOGO DO TITULO (playfield, pre-montado: 2 palavras x 5 linhas x 6 bytes)
; Renderiza "NIGHT" e "HIGHWAY" em fonte 4x5 original.
;===============================================================================

LogoGfx:
        .byte $00,$09,$8E,$29,$E0,$00   ; NIGHT  linha 0
        .byte $00,$0D,$44,$28,$40,$00   ;        linha 1
        .byte $00,$0B,$44,$39,$40,$00   ;        linha 2
        .byte $00,$09,$44,$29,$40,$00   ;        linha 3
        .byte $00,$09,$8E,$29,$40,$00   ;        linha 4
        .byte $40,$9C,$A6,$14,$8A,$00   ; HIGHWAY linha 0
        .byte $40,$88,$A1,$94,$4A,$00   ;         linha 1
        .byte $C0,$88,$E5,$9C,$C4,$00   ;         linha 2
        .byte $40,$88,$A5,$9C,$44,$00   ;         linha 3
        .byte $40,$9C,$A6,$94,$44,$00   ;         linha 4

;===============================================================================
; 27. TABELAS DE PISTA (perspectiva e curvas; geradas e validadas por script:
; garantem 0 <= L <= 16 e 23 <= R <= 39, ou seja, o centro da pista e sempre
; solido, o que esconde o glitch da escrita dupla de PF2 no kernel)
;===============================================================================

;--- largura da pista por linha (celulas; horizonte -> base) -------------------
RoadWidthTbl:
        .byte $08,$08,$0A,$0A,$0A,$0C,$0C,$0E,$0E,$0E
        .byte $10,$10,$12,$12,$12,$14,$14,$16,$16,$18
        .byte $18,$18,$1A,$1A,$1C,$1C,$1E,$1E
;--- offsets laterais por linha para os 5 niveis de curva (-6,-3,0,+3,+6) -----
CurveTbl_M6:
        .byte $00,$00,$00,$00,$00,$00,$FF,$FF,$FF,$FF
        .byte $FF,$FE,$FE,$FE,$FE,$FE,$FD,$FD,$FD,$FC
        .byte $FC,$FC,$FC,$FB,$FB,$FB,$FA,$FA
CurveTbl_M3:
        .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$FF
        .byte $FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FE,$FE
        .byte $FE,$FE,$FE,$FE,$FD,$FD,$FD,$FD
CurveTbl_P0:
        .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00
CurveTbl_P3:
        .byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$01
        .byte $01,$01,$01,$01,$01,$01,$01,$01,$02,$02
        .byte $02,$02,$02,$02,$03,$03,$03,$03
CurveTbl_P6:
        .byte $00,$00,$00,$00,$00,$00,$01,$01,$01,$01
        .byte $01,$02,$02,$02,$02,$02,$03,$03,$03,$04
        .byte $04,$04,$04,$05,$05,$05,$06,$06
CurvePtrLo:
        .byte <CurveTbl_M6, <CurveTbl_M3, <CurveTbl_P0, <CurveTbl_P3, <CurveTbl_P6
CurvePtrHi:
        .byte >CurveTbl_M6, >CurveTbl_M3, >CurveTbl_P0, >CurveTbl_P3, >CurveTbl_P6
;--- escala horizontal dos adversarios por linha (1..4) ------------------------
XShiftTbl:
        .byte $01,$01,$01,$01,$01,$01,$01,$02,$02,$02
        .byte $02,$02,$02,$02,$02,$02,$03,$03,$03,$03
        .byte $03,$03,$03,$03,$04,$04,$04,$04

;===============================================================================
; 28. TABELAS DE CORES POR PERIODO (NTSC)
; [ceu1, ceu2, ceu3, montanhas, grama, sol/lua, -, -]
;===============================================================================

PerCols:
        .byte $9C,$98,$96,$94,$D8,$1E,$00,$00   ; dia
        .byte $36,$34,$42,$30,$D4,$2E,$00,$00   ; entardecer
        .byte $82,$80,$00,$80,$D2,$0E,$00,$00   ; noite
        .byte $38,$9A,$9C,$34,$D6,$2C,$00,$00   ; amanhecer
SunXTbl:
        .byte 110,120,40,100                    ; X do sol/lua por periodo
CarCols:
        .byte $34,$86,$C6,$1C                   ; adversarios: vermelho, azul,
                                                ; verde, amarelo
;--- brightBase por periodo (luminosidade base do asfalto) ---------------------
BrightBaseTbl:
        .byte $06,$04,$02,$03                   ; dia, entardecer, noite, madrug.

;===============================================================================
; 29. TABELAS DE ETAPA -> movidas para a secao 24 (espaco livre antes do ALIGN
; da fonte) para caber os vetores em $FFFA sem estourar a ROM de 4KB.
;===============================================================================

;===============================================================================
; 30. TABELAS DE AUDIO E MISC
;===============================================================================

BarFillTbl:                             ; barra de tempo (PF1 reflect ON)
        .byte $00,$80,$C0,$E0,$F0,$F8,$FC,$FE,$FF
SfxLenTbl:                              ; duracao inicial por efeito (1..4)
        .byte 0,5,24,8,10
JgClearF:                               ; jingle de etapa concluida (freqs)
        .byte 16,12,8,4,$FF
JgClearD:                               ; duracoes
        .byte 8,8,8,20
JgOverF:                                ; jingle de game over (descendente)
        .byte 20,16,12,8,$FF
JgOverD:
        .byte 10,10,10,24

;===============================================================================
; 31. MENSAGENS (6 indices de glifos; offsets usados no codigo)
; Glifos: 0-9 digitos; 10=A 11=C 12=D 13=E 14=F 15=G 16=H 17=I 18=L 19=M
;         20=N 21=O 22=P 23=R 24=S 25=T 26=U 27=V 28=W 29=Y 30=! 31=espaco
;===============================================================================

MSG_PUSH    = 0
MSG_FIRE    = 6
MSG_SELECT  = 12
MSG_STAGEN  = 18
MSG_READY   = 24
MSG_STAGE   = 30
MSG_CLEAR   = 36
MSG_YOU     = 42
MSG_WIN     = 48
MSG_GAME    = 54
MSG_OVER    = 60

MsgTable:
        .byte 31,22,26,24,16,31         ; " PUSH "
        .byte 31,14,17,23,13,30         ; " FIRE!"
        .byte 24,13,18,13,11,25         ; "SELECT"
        .byte 24,25,10,15,13,1          ; "STAGE"+n
        .byte 23,13,10,12,29,30         ; "READY!"
        .byte 24,25,10,15,13,31         ; "STAGE "
        .byte 11,18,13,10,23,30         ; "CLEAR!"
        .byte 31,29,21,26,31,31         ; " YOU  "
        .byte 31,28,17,20,30,31         ; " WIN! "
        .byte 31,15,10,19,13,31         ; " GAME "
        .byte 31,21,27,13,23,31         ; " OVER "

;--- pares de mensagens por estado (linha 1, linha 2) --------------------------
MsgPairTbl:
        .byte MSG_STAGEN, MSG_READY     ; ST_INTRO
        .byte 0, 0                      ; ST_PLAY (nao usado)
        .byte MSG_STAGE, MSG_CLEAR      ; ST_CLEAR
        .byte MSG_YOU, MSG_WIN          ; ST_WIN
        .byte MSG_GAME, MSG_OVER        ; ST_OVER

;===============================================================================
; 32. RELATORIO DE MONTAGEM E VETORES
;===============================================================================

CODE_END
        echo "ROM usada:", [CODE_END - $F000]d, "de 4096 bytes"
        echo "Livre:", [$FFFA - CODE_END]d, "bytes"

        ORG $FFFA
        .word Reset                     ; NMI
        .word Reset                     ; RESET
        .word Reset                     ; IRQ/BRK


