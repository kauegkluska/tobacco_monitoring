#include "LoRaWan_APP.h"
#include "Arduino.h"

#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <Adafruit_SHT4x.h>
#include <WiFi.h>
#include <WiFiManager.h>
#include <HTTPClient.h>

/* ===============================
   CONFIGURATION
   =============================== */

#define RF_FREQUENCY           915000000
#define TX_OUTPUT_POWER        20
#define LORA_BANDWIDTH         0
#define LORA_SPREADING_FACTOR  7
#define LORA_CODINGRATE        1
#define LORA_PREAMBLE_LENGTH   8
#define LORA_FIX_LENGTH        false
#define LORA_IQ_INVERSION      false

#define SDA_PIN 4
#define SCL_PIN 5
#define INTERVALO_ENVIO 2000
#define INTERVALO_TELA 3000
#define CURING_UNIT_ID 1

// Identificador único deste controlador ESP32 (use este ID para vincular no app)
#define CONTROLLER_ID          "ESP32-TOBACCO-01"
#define HARDWARE_MODEL         "Heltec WiFi LoRa 32 V3"
#define LORA_NODE_ID           "0x74C0"

// Use the computer's LAN IP. Never use localhost here.
const char* API_URL = "http://192.168.1.2:8000/readings/readings/";

/* ===============================
   DEVICES AND STATE
   =============================== */

WiFiManager wifiManager;
LiquidCrystal_I2C lcd(0x27, 20, 4);
Adafruit_SHT4x sht40;

bool sht40_ok = false;
long numero_pacote = 0;
bool lora_idle = true;
static RadioEvents_t RadioEvents;
unsigned long ultimo_envio = 0;
unsigned long ultima_troca_tela = 0;
float ultima_temperatura = 0.0;
float ultima_umidade = 0.0;
bool mostrar_temperatura = true;

void OnTxDone(void);
void OnTxTimeout(void);
bool lerSHT40(float &temperatura, float &umidade);
bool enviarLeituraAPI(float temperatura, float umidade);
void atualizarLCD();
void criarCaracteresGrandes();
void mostrarTemperatura(float temperatura);
void mostrarUmidade(float umidade);

/* ===============================
   LARGE LCD DIGITS
   =============================== */

byte blocoCheio[8] = { B11111, B11111, B11111, B11111, B11111, B11111, B11111, B11111 };
byte blocoCima[8] = { B11111, B11111, B11111, B11111, B00000, B00000, B00000, B00000 };
byte blocoBaixo[8] = { B00000, B00000, B00000, B00000, B11111, B11111, B11111, B11111 };

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

void mostrarTemperatura(float temperatura)
{
    int valor = round((temperatura * 9.0 / 5.0) + 32.0);
    lcd.clear();
    lcd.setCursor(14, 0);
    lcd.print("TEMP");
    mostrarNumeroGrande(valor);
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
    lcd.setCursor(14, 3);
    lcd.print("%");
}

void atualizarLCD()
{
    if (mostrar_temperatura) mostrarTemperatura(ultima_temperatura);
    else mostrarUmidade(ultima_umidade);
}

/* ===============================
   WIFI AND API
   =============================== */

void conectarWiFi()
{
    Serial.println("[WiFi] Conectando...");
    lcd.clear();
    lcd.setCursor(0, 0);
    lcd.print("Conectando WiFi...");

    wifiManager.setConnectTimeout(15);
    wifiManager.setConfigPortalTimeout(180);

    if (wifiManager.autoConnect("ESP32-LoRa-Config"))
    {
        Serial.print("[WiFi] IP do ESP32: ");
        Serial.println(WiFi.localIP());
        lcd.clear();
        lcd.setCursor(0, 0);
        lcd.print("WiFi conectado!");
        lcd.setCursor(0, 1);
        lcd.print(WiFi.SSID());
        lcd.setCursor(0, 2);
        lcd.print("IP:");
        lcd.setCursor(0, 3);
        lcd.print(WiFi.localIP());
        delay(3000);
    }
    else
    {
        Serial.println("[WiFi] Nao foi possivel conectar.");
        lcd.clear();
        lcd.setCursor(0, 0);
        lcd.print("WiFi nao conectado");
        delay(2000);
    }
}

bool enviarLeituraAPI(float temperatura, float umidade)
{
    if (WiFi.status() != WL_CONNECTED)
    {
        Serial.println("[API] WiFi desconectado");
        return false;
    }

    HTTPClient http;
    http.begin(API_URL);
    http.addHeader("Content-Type", "application/json");
    http.setTimeout(3000);

    String payload = "{\"temperature\":";
    payload += String(temperatura, 2);
    payload += ",\"humidity\":";
    payload += String(umidade, 2);
    payload += ",\"curing_unit_id\":";
    payload += String(CURING_UNIT_ID);
    payload += ",\"controller_id\":\"";
    payload += String(CONTROLLER_ID);
    payload += "\",\"device_code\":\"";
    payload += String(CONTROLLER_ID);
    payload += "\",\"lora_id\":\"";
    payload += String(LORA_NODE_ID);
    payload += "\",\"mac_address\":\"";
    payload += WiFi.macAddress();
    payload += "\",\"battery_level\":98";
    payload += ",\"rssi\":";
    payload += String(WiFi.RSSI());
    payload += "}";

    int status = http.POST(payload);
    bool success = status >= 200 && status < 300;

    Serial.print("[API] HTTP status: ");
    Serial.print(status);
    Serial.print(" -> Controller: ");
    Serial.println(CONTROLLER_ID);
    if (!success)
    {
        Serial.print("[API] Erro: ");
        Serial.println(http.errorToString(status));
    }

    http.end();
    return success;
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
    Serial.println("  MONITOR DE ESTUFA DE TABACO - ESP32    ");
    Serial.println("=========================================");
    Serial.print("  Controller ID: "); Serial.println(CONTROLLER_ID);
    Serial.print("  Modelo:        "); Serial.println(HARDWARE_MODEL);
    Serial.print("  LoRa Node ID:  "); Serial.println(LORA_NODE_ID);
    Serial.print("  Frequencia:    "); Serial.print(RF_FREQUENCY / 1000000.0); Serial.println(" MHz");
    Serial.print("  Destino API:   "); Serial.println(API_URL);
    Serial.println("=========================================");

    Mcu.begin(HELTEC_BOARD, SLOW_CLK_TPYE);

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

    conectarWiFi();

    RadioEvents.TxDone = OnTxDone;
    RadioEvents.TxTimeout = OnTxTimeout;
    Radio.Init(&RadioEvents);
    Radio.SetChannel(RF_FREQUENCY);
    Radio.SetTxConfig(
        MODEM_LORA, TX_OUTPUT_POWER, 0, LORA_BANDWIDTH,
        LORA_SPREADING_FACTOR, LORA_CODINGRATE, LORA_PREAMBLE_LENGTH,
        LORA_FIX_LENGTH, true, 0, 0, LORA_IQ_INVERSION, 3000
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

    if (WiFi.status() != WL_CONNECTED)
    {
        conectarWiFi();
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

        char mensagem[96];
        snprintf(
            mensagem,
            sizeof(mensagem),
            "ID=%s;N=%ld;T=%.2f;H=%.2f",
            CONTROLLER_ID,
            numero_pacote,
            temperatura,
            umidade
        );

        Serial.print("TX LoRa: ");
        Serial.println(mensagem);

        // Sends the reading with controller_id directly to FastAPI over Wi-Fi
        enviarLeituraAPI(temperatura, umidade);

        lora_idle = false;
        Radio.Send((uint8_t*)mensagem, strlen(mensagem));
        numero_pacote++;
    }
}

void OnTxDone(void)
{
    Serial.println("[LoRa] TX concluido");
    lora_idle = true;
}

void OnTxTimeout(void)
{
    Serial.println("[LoRa] TX TIMEOUT");
    Radio.Sleep();
    lora_idle = true;
}
