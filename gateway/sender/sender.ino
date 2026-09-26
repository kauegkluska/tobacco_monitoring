#include "LoRaWan_APP.h"
#include "Arduino.h"

#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <Adafruit_SHT4x.h>

/* ===============================
   SENDER - NO DA ESTUFA
   Le o SHT40, mostra no LCD e transmite via LoRa. Logo apos cada envio escuta
   o gateway por um instante e aplica nos reles o comando vindo do app/API
   (ex.: ligar as ventoinhas). O estado real dos reles vai no pacote seguinte.
   =============================== */

/* ===============================
   CONFIGURATION
   Os parametros LoRa devem ser IDENTICOS no receiver.
   =============================== */

#define RF_FREQUENCY           915000000
#define TX_OUTPUT_POWER        20
#define LORA_BANDWIDTH         0
#define LORA_SPREADING_FACTOR  7
#define LORA_CODINGRATE        1
#define LORA_PREAMBLE_LENGTH   8
#define LORA_SYMBOL_TIMEOUT    0
#define LORA_FIX_LENGTH        false
#define LORA_IQ_INVERSION      false

// Janela de escuta apos cada envio, para receber o comando dos reles (downlink).
// O receiver responde cerca de 100 ms depois de receber o pacote.
#define JANELA_RX_MS           1200
#define TAMANHO_DOWNLINK       64

#define SDA_PIN 4
#define SCL_PIN 5
#define INTERVALO_ENVIO 2000
#define INTERVALO_TELA 3000

// Identificador único deste controlador ESP32 (use este ID para vincular no app)
#define CONTROLLER_ID          "ESP32-TOBACCO-01"
#define HARDWARE_MODEL         "Heltec WiFi LoRa 32 V3"

/* ===============================
   RELES - COMANDADOS PELO APP
   Rele 1 (GPIO2) = "rele_umidade" da API; rele 2 (GPIO3) = "rele_temperatura".
   O nome de cada saida (ex.: "Ventoinhas"), o modo e a regra automatica sao
   configurados no app. Os reles comecam desligados e mantem o ultimo comando
   recebido se o gateway parar de responder.

   ATENCAO (ESP32-S3 / Heltec V3): GPIO3 e um pino de "strapping" usado na
   selecao do modo de boot, lido no instante do reset. Normalmente funciona
   bem como saida apos o boot, mas se notar instabilidade ao ligar a placa
   com o rele conectado nele, troque para outro GPIO livre (ex: GPIO6).
   =============================== */

#define RELE_UMIDADE_PIN       2
#define RELE_TEMPERATURA_PIN   3

// Muitos modulos de rele baratos (ex: SRD-05VDC) sao ativos em NIVEL BAIXO.
// Se o seu for assim, so trocar as duas linhas abaixo.
#define RELE_LIGADO    HIGH
#define RELE_DESLIGADO LOW

/* ===============================
   DEVICES AND STATE
   =============================== */

LiquidCrystal_I2C lcd(0x27, 20, 4);
Adafruit_SHT4x sht40;

bool sht40_ok = false;
long numero_pacote = 0;
bool lora_idle = true;
static RadioEvents_t RadioEvents;
unsigned long ultimo_envio = 0;
unsigned long ultima_troca_tela = 0;
bool rele_umidade_ligado = false;
bool rele_temperatura_ligado = false;
bool comando_recebido = false;          // ja chegou algum comando do gateway?
volatile bool abrir_janela_rx = false;  // TX terminou: escutar o downlink
char downlink[TAMANHO_DOWNLINK];
volatile bool downlink_pendente = false;
float ultima_temperatura = 0.0;
float ultima_umidade = 0.0;
bool mostrar_temperatura = true;

void OnTxDone(void);
void OnTxTimeout(void);
void OnRxDone(uint8_t *payload, uint16_t size, int16_t rssi, int8_t snr);
void OnRxTimeout(void);
void OnRxError(void);
void aplicarReles(bool umidade, bool temperatura);
void processarDownlink(const char* mensagem);
bool lerSHT40(float &temperatura, float &umidade);
void atualizarLCD();
void criarCaracteresGrandes();
void mostrarTemperatura(float temperatura);
void mostrarUmidade(float umidade);

/* ===============================
   LARGE LCD DIGITS
   =============================== */

byte blocoCheio[8] = { 0b11111, 0b11111, 0b11111, 0b11111, 0b11111, 0b11111, 0b11111, 0b11111 };
byte blocoCima[8] = { 0b11111, 0b11111, 0b11111, 0b11111, 0b00000, 0b00000, 0b00000, 0b00000 };
byte blocoBaixo[8] = { 0b00000, 0b00000, 0b00000, 0b00000, 0b11111, 0b11111, 0b11111, 0b11111 };

#define CHE 0
#define CIM 1
#define BAI 2
#define VAZ 32

const byte digitos[10][12] = {
    { CHE, CIM, CHE, CHE, VAZ, CHE, CHE, VAZ, CHE, CHE, BAI, CHE },
    { BAI, CHE, VAZ, VAZ, CHE, VAZ, VAZ, CHE, VAZ, BAI, CHE, BAI },
    { CIM, CIM, CHE, BAI, BAI, CHE, CHE, VAZ, VAZ, CHE, BAI, BAI },
    { CIM, CIM, CHE, BAI, BAI, CHE, VAZ, VAZ, CHE, BAI, BAI, CHE },
    { CHE, VAZ, CHE, CHE, BAI, CHE, VAZ, VAZ, CHE, VAZ, VAZ, CHE },
    { CHE, CIM, CIM, CHE, BAI, BAI, VAZ, VAZ, CHE, BAI, BAI, CHE },
    { CHE, CIM, CIM, CHE, BAI, BAI, CHE, VAZ, CHE, CHE, BAI, CHE },
    { CIM, CIM, CHE, VAZ, VAZ, CHE, VAZ, VAZ, CHE, VAZ, VAZ, CHE },
    { CHE, CIM, CHE, CHE, BAI, CHE, CHE, VAZ, CHE, CHE, BAI, CHE },
    { CHE, CIM, CHE, CHE, BAI, CHE, VAZ, VAZ, CHE, BAI, BAI, CHE }
};

void criarCaracteresGrandes()
{
    lcd.createChar(0, blocoCheio);
    lcd.createChar(1, blocoCima);
    lcd.createChar(2, blocoBaixo);
}

void desenharDigito(int digito, int coluna, int linha)
{
    if (digito < 0 || digito > 9) return;

    for (int l = 0; l < 4; l++)
    {
        lcd.setCursor(coluna, linha + l);
        for (int c = 0; c < 3; c++)
        {
            lcd.write((uint8_t)digitos[digito][l * 3 + c]);
        }
    }
}

void mostrarNumeroGrande(int numero)
{
    numero = constrain(numero, 0, 999);

    int centenas = numero / 100;
    int dezenas = (numero / 10) % 10;
    int unidades = numero % 10;
    int quantidade = numero >= 100 ? 3 : numero >= 10 ? 2 : 1;
    int largura = quantidade * 4 - 1;
    int coluna = (13 - largura) / 2;

    if (quantidade == 3)
    {
        desenharDigito(centenas, coluna, 0);
        coluna += 4;
    }
    if (quantidade >= 2)
    {
        desenharDigito(dezenas, coluna, 0);
        coluna += 4;
    }
    desenharDigito(unidades, coluna, 0);
}

// Colunas 14-19, linhas 1 e 2: estado dos reles (S1/S2 ligado ou "--").
void mostrarReles()
{
    lcd.setCursor(14, 1);
    lcd.print(rele_umidade_ligado ? "S1:ON " : "S1:-- ");
    lcd.setCursor(14, 2);
    lcd.print(rele_temperatura_ligado ? "S2:ON " : "S2:-- ");
}

void mostrarTemperatura(float temperatura)
{
    int valor = round((temperatura * 9.0 / 5.0) + 32.0);
    lcd.clear();
    lcd.setCursor(14, 0);
    lcd.print("TEMP");
    mostrarNumeroGrande(valor);
    mostrarReles();
    lcd.setCursor(14, 3);
    lcd.print((char)223);
    lcd.print("F");
}

void mostrarUmidade(float umidade)
{
    lcd.clear();
    lcd.setCursor(14, 0);
    lcd.print("UMID");
    mostrarNumeroGrande(round(umidade));
    mostrarReles();
    lcd.setCursor(14, 3);
    lcd.print("%");
}

void atualizarLCD()
{
    if (mostrar_temperatura) mostrarTemperatura(ultima_temperatura);
    else mostrarUmidade(ultima_umidade);
}

/* ===============================
   RELES
   =============================== */

void aplicarReles(bool umidade, bool temperatura)
{
    const bool mudou = !comando_recebido
        || umidade != rele_umidade_ligado
        || temperatura != rele_temperatura_ligado;

    rele_umidade_ligado = umidade;
    rele_temperatura_ligado = temperatura;
    comando_recebido = true;

    digitalWrite(RELE_UMIDADE_PIN, umidade ? RELE_LIGADO : RELE_DESLIGADO);
    digitalWrite(RELE_TEMPERATURA_PIN, temperatura ? RELE_LIGADO : RELE_DESLIGADO);

    if (mudou)
    {
        Serial.print("[RELES] GPIO2 ");
        Serial.print(umidade ? "LIGADO" : "desligado");
        Serial.print(" / GPIO3 ");
        Serial.println(temperatura ? "LIGADO" : "desligado");
        mostrarReles();
    }
}

// Formato: RELAY;ID=<controller_id>;H=<0|1>;T=<0|1>
// Comandos para outro CONTROLLER_ID sao ignorados.
void processarDownlink(const char* mensagem)
{
    char id[32];
    int umidade;
    int temperatura;

    if (sscanf(mensagem, "RELAY;ID=%31[^;];H=%d;T=%d", id, &umidade, &temperatura) == 3)
    {
        if (strcmp(id, CONTROLLER_ID) != 0) return;
    }
    else if (sscanf(mensagem, "RELAY;H=%d;T=%d", &umidade, &temperatura) != 2)
    {
        Serial.print("[LoRa] Downlink ignorado: ");
        Serial.println(mensagem);
        return;
    }

    aplicarReles(umidade != 0, temperatura != 0);
}

/* ===============================
   SENSOR
   =============================== */

bool lerSHT40(float &temperatura, float &umidade)
{
    sensors_event_t humidity;
    sensors_event_t temp;

    if (!sht40.getEvent(&humidity, &temp))
    {
        Serial.println("[SHT40] Erro de leitura");
        return false;
    }

    temperatura = temp.temperature;
    umidade = humidity.relative_humidity;
    return true;
}

/* ===============================
   SETUP
   =============================== */

void setup()
{
    Serial.begin(115200);
    delay(1000);

    Serial.println();
    Serial.println("=========================================");
    Serial.println("  MONITOR DE ESTUFA - SENDER (LoRa TX)   ");
    Serial.println("=========================================");
    Serial.print("  Controller ID: "); Serial.println(CONTROLLER_ID);
    Serial.print("  Modelo:        "); Serial.println(HARDWARE_MODEL);
    Serial.print("  Frequencia:    "); Serial.print(RF_FREQUENCY / 1000000.0); Serial.println(" MHz");
    Serial.println("=========================================");

    Mcu.begin(HELTEC_BOARD, SLOW_CLK_TPYE);

    // Comeca com tudo desligado ate o primeiro comando do gateway.
    pinMode(RELE_UMIDADE_PIN, OUTPUT);
    pinMode(RELE_TEMPERATURA_PIN, OUTPUT);
    digitalWrite(RELE_UMIDADE_PIN, RELE_DESLIGADO);
    digitalWrite(RELE_TEMPERATURA_PIN, RELE_DESLIGADO);

    Wire.begin(SDA_PIN, SCL_PIN);
    Wire.setClock(100000);

    lcd.init();
    lcd.backlight();
    lcd.clear();
    criarCaracteresGrandes();
    lcd.setCursor(0, 0);
    lcd.print("Iniciando ESP32...");
    lcd.setCursor(0, 1);
    lcd.print("ID: ");
    lcd.print(CONTROLLER_ID);

    Serial.println("[SHT40] Procurando sensor...");
    if (sht40.begin(&Wire))
    {
        sht40_ok = true;
        sht40.setPrecision(SHT4X_HIGH_PRECISION);
        sht40.setHeater(SHT4X_NO_HEATER);
        Serial.println("[SHT40] Sensor encontrado!");
    }
    else
    {
        Serial.println("[SHT40] ERRO: sensor nao encontrado");
        lcd.clear();
        lcd.setCursor(0, 0);
        lcd.print("SHT40 ERRO");
    }

    RadioEvents.TxDone = OnTxDone;
    RadioEvents.TxTimeout = OnTxTimeout;
    RadioEvents.RxDone = OnRxDone;
    RadioEvents.RxTimeout = OnRxTimeout;
    RadioEvents.RxError = OnRxError;
    Radio.Init(&RadioEvents);
    Radio.SetChannel(RF_FREQUENCY);
    Radio.SetTxConfig(
        MODEM_LORA, TX_OUTPUT_POWER, 0, LORA_BANDWIDTH,
        LORA_SPREADING_FACTOR, LORA_CODINGRATE, LORA_PREAMBLE_LENGTH,
        LORA_FIX_LENGTH, true, 0, 0, LORA_IQ_INVERSION, 3000
    );
    // Ultimo parametro false: recepcao com tempo limite (JANELA_RX_MS), nao continua.
    Radio.SetRxConfig(
        MODEM_LORA, LORA_BANDWIDTH, LORA_SPREADING_FACTOR,
        LORA_CODINGRATE, 0, LORA_PREAMBLE_LENGTH,
        LORA_SYMBOL_TIMEOUT, LORA_FIX_LENGTH,
        0, true, 0, 0, LORA_IQ_INVERSION, false
    );

    ultimo_envio = millis() - INTERVALO_ENVIO;
    ultima_troca_tela = millis();
}

/* ===============================
   LOOP
   =============================== */

void loop()
{
    Radio.IrqProcess();

    // Abre a janela de escuta assim que o envio termina (o gateway responde em ~100 ms).
    if (abrir_janela_rx)
    {
        abrir_janela_rx = false;
        Radio.Rx(JANELA_RX_MS);
    }

    // Protecao: se o radio nao avisar o fim do envio/escuta, volta a transmitir.
    if (!lora_idle && millis() - ultimo_envio > INTERVALO_ENVIO + JANELA_RX_MS + 3000)
    {
        Serial.println("[LoRa] Sem resposta do radio, reiniciando o ciclo");
        abrir_janela_rx = false;
        Radio.Sleep();
        lora_idle = true;
    }

    if (downlink_pendente)
    {
        char mensagem[TAMANHO_DOWNLINK];
        strcpy(mensagem, downlink);
        downlink_pendente = false;

        Serial.print("RX downlink: ");
        Serial.println(mensagem);
        processarDownlink(mensagem);
    }

    if (millis() - ultima_troca_tela >= INTERVALO_TELA)
    {
        ultima_troca_tela = millis();
        mostrar_temperatura = !mostrar_temperatura;
        atualizarLCD();
    }

    if (lora_idle && millis() - ultimo_envio >= INTERVALO_ENVIO)
    {
        ultimo_envio = millis();

        if (!sht40_ok) return;

        float temperatura;
        float umidade;
        if (!lerSHT40(temperatura, umidade)) return;

        ultima_temperatura = temperatura;
        ultima_umidade = umidade;
        atualizarLCD();

        // Formato do pacote (o receiver faz o parse):
        // ID=<id>;N=<contador>;T=<celsius>;H=<umidade>;R1=<0|1>;R2=<0|1>
        // R1/R2 sao o estado real dos reles, mostrado no app como confirmacao.
        char mensagem[96];
        snprintf(
            mensagem,
            sizeof(mensagem),
            "ID=%s;N=%ld;T=%.2f;H=%.2f;R1=%d;R2=%d",
            CONTROLLER_ID,
            numero_pacote,
            temperatura,
            umidade,
            rele_umidade_ligado ? 1 : 0,
            rele_temperatura_ligado ? 1 : 0
        );

        Serial.print("TX LoRa: ");
        Serial.println(mensagem);

        lora_idle = false;
        Radio.Send((uint8_t*)mensagem, strlen(mensagem));
        numero_pacote++;
    }
}

void OnTxDone(void)
{
    // Continua ocupado ate a janela de escuta do downlink terminar.
    abrir_janela_rx = true;
}

void OnTxTimeout(void)
{
    Serial.println("[LoRa] TX TIMEOUT");
    Radio.Sleep();
    lora_idle = true;
}

void OnRxDone(uint8_t *payload, uint16_t size, int16_t rssi, int8_t snr)
{
    Radio.Sleep();

    if (size >= TAMANHO_DOWNLINK) size = TAMANHO_DOWNLINK - 1;
    memcpy(downlink, payload, size);
    downlink[size] = '\0';
    downlink_pendente = true;

    lora_idle = true;
}

void OnRxTimeout(void)
{
    // Nenhum comando nesta rodada: os reles mantem o ultimo estado.
    Radio.Sleep();
    lora_idle = true;
}

void OnRxError(void)
{
    Serial.println("[LoRa] Erro ao receber o downlink (CRC)");
    Radio.Sleep();
    lora_idle = true;
}
