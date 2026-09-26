#include "LoRaWan_APP.h"
#include "Arduino.h"

#include <WiFi.h>
#include <WiFiManager.h>
#include <HTTPClient.h>
#include <ESPmDNS.h>
#include <Preferences.h>
#include <esp_timer.h>
#include <esp_err.h>
#include <atomic>

/* ===============================
   RECEIVER - GATEWAY
   Recebe os pacotes LoRa do sender, envia as leituras para a API via Wi-Fi
   e responde ao sender com o comando de rele (via LoRa downlink), que o
   sender aplica nos reles. O estado real dos reles (R1/R2) volta para a API.
   GPIO5: aviso de 2 s quando um comando de rele muda de false para true.
   =============================== */

/* ===============================
   CONFIGURATION
   Os parametros LoRa devem ser IDENTICOS no sender.
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

#define TAMANHO_BUFFER         128
#define INTERVALO_RECONEXAO    10000
#define MAX_SENDERS            8

// Espera antes do downlink: tempo para o sender sair do TX e abrir a janela de escuta.
#define ATRASO_DOWNLINK_MS     100

// AVISO SONORO LOCAL DO GATEWAY: GPIO5, nao o terminal 5V.
// Buzzer ativo ou entrada de acionamento do modulo ja testado.
#define AVISO_PIN                5
#define AVISO_NIVEL_ATIVO         HIGH  // Use LOW para modulo ativo em nivel baixo.
#define AVISO_DURACAO_MS          2000UL
#define AVISO_POR_UMIDADE         true
#define AVISO_POR_TEMPERATURA     true

constexpr uint8_t AVISO_NIVEL_INATIVO =
    (AVISO_NIVEL_ATIVO == HIGH) ? LOW : HIGH;

static_assert(AVISO_DURACAO_MS > 0, "A duracao do aviso deve ser positiva.");

// Estufa de destino na API. Use 0 para deixar a API escolher pela estufa vinculada ao controller_id.
#define CURING_UNIT_ID 1

// ENDERECO DA API
// Vazio (recomendado): o gateway acha o servidor sozinho na rede Wi-Fi (mDNS, servico
// "_estufa._tcp" anunciado pelo backend) e procura de novo se o IP do computador mudar.
// Preencha so se a descoberta nao funcionar na sua rede, ex.: "http://192.168.0.14:8000".
// Tambem da para definir no portal de configuracao (segure o botao PRG por 3 s).
const char* API_FIXA = "";
const char* API_CAMINHO = "/readings/readings/";

#define BOTAO_CONFIG_PIN          0      // botao PRG da Heltec V3
#define BOTAO_CONFIG_MS           3000   // segurar para abrir o portal de configuracao
#define FALHAS_PARA_REDESCOBRIR   3      // erros de conexao seguidos antes de procurar de novo
#define INTERVALO_REDESCOBERTA    30000
#define TEMPO_TESTE_API_MS        1500

// Igual a GATEWAY_API_KEY do backend/.env. Deixe vazio se a API nao exigir chave.
const char* GATEWAY_API_KEY = "";

/* ===============================
   STATE
   =============================== */

WiFiManager wifiManager;
WiFiManagerParameter parametro_api("api", "Endereco da API (vazio = automatico)", "", 64);
Preferences preferencias;

String api_base = "";        // ex.: http://192.168.0.14:8000 (sem o caminho)
bool api_fixa = false;       // definido em API_FIXA ou no portal: nao usa a descoberta
bool mdns_iniciado = false;
int falhas_seguidas = 0;
unsigned long ultima_descoberta = 0;
unsigned long botao_pressionado_desde = 0;
static RadioEvents_t RadioEvents;
bool lora_idle = true;
unsigned long ultima_reconexao = 0;

char pacote[TAMANHO_BUFFER];
volatile bool pacote_pendente = false;
int16_t pacote_rssi = 0;
int8_t pacote_snr = 0;

// Ultimo comando de rele conhecido de cada sender, obtido da resposta da API.
// E reenviado ao sender assim que uma leitura chega, sem esperar a chamada HTTP terminar.
struct EstadoSender
{
    char id[32];
    long ultimo_numero;
    bool rele_umidade;
    bool rele_temperatura;
};

EstadoSender senders[MAX_SENDERS];
int quantidade_senders = 0;

// Um unico timer, de disparo unico: apenas desliga o aviso apos 2 s.
// Nao existe timer periodico nem acionamento de teste ao iniciar.
esp_timer_handle_t timer_aviso_desligar = nullptr;
bool aviso_pronto = false;

// Compartilhado entre loop() e a tarefa esp_timer.
// Permanece true ate o callback terminar de desligar o GPIO.
std::atomic<bool> aviso_ativo{false};

void OnRxDone(uint8_t *payload, uint16_t size, int16_t rssi, int8_t snr);
void OnRxTimeout(void);
void OnRxError(void);
void OnTxDone(void);
void OnTxTimeout(void);
bool enviarLeituraAPI(EstadoSender* sender, float temperatura, float umidade, int16_t rssi, int8_t snr, int r1, int r2);
void enviarDownlink(const EstadoSender* sender);
bool extrairBooleanJSON(const String &json, const char *chave, bool valorPadrao);

/* ===============================
   AVISO SONORO POR ACIONAMENTO DAS SAIDAS
   Dispara na transicao false -> true de um dos comandos da API.
   Nao altera os comandos dos reles nem cria regras de temperatura/umidade.
   =============================== */

void desligarAviso(void* arg)
{
    (void)arg;
    // Callback curto, executado pela tarefa esp_timer, nao por loop().
    digitalWrite(AVISO_PIN, AVISO_NIVEL_INATIVO);
    aviso_ativo.store(false);
}

bool iniciarAvisoSonoro()
{
    pinMode(AVISO_PIN, OUTPUT);
    digitalWrite(AVISO_PIN, AVISO_NIVEL_INATIVO);
    aviso_ativo.store(false);
    aviso_pronto = false;

    esp_timer_create_args_t args = {};
    args.callback = desligarAviso;
    args.dispatch_method = ESP_TIMER_TASK;
    args.name = "aviso_off";

    esp_err_t erro = esp_timer_create(&args, &timer_aviso_desligar);
    if (erro != ESP_OK)
    {
        timer_aviso_desligar = nullptr;
        Serial.printf("[AVISO] Erro ao criar timer: %s\n", esp_err_to_name(erro));
        return false;
    }

    aviso_pronto = true;
    Serial.println("[AVISO] GPIO5: pulso de 2 s ao ligar uma saida. Sem teste periodico.");
    return true;
}

bool acionarAvisoSonoro()
{
    if (!aviso_pronto || timer_aviso_desligar == nullptr)
    {
        Serial.println("[AVISO] Indisponivel: falha na inicializacao do timer.");
        return false;
    }

    // Dois comandos simultaneos geram um unico aviso.
    // Se outra saida ligar durante o pulso, nao o prolonga nem o enfileira.
    // O atomic tambem impede rearmar enquanto o callback anterior desliga.
    bool esperado = false;
    if (!aviso_ativo.compare_exchange_strong(esperado, true))
    {
        return false;
    }

    digitalWrite(AVISO_PIN, AVISO_NIVEL_ATIVO);

    esp_err_t erro = esp_timer_start_once(
        timer_aviso_desligar,
        static_cast<uint64_t>(AVISO_DURACAO_MS) * 1000ULL
    );

    // Nunca deixa a saida ligada se nao conseguir agendar o desligamento.
    if (erro != ESP_OK)
    {
        digitalWrite(AVISO_PIN, AVISO_NIVEL_INATIVO);
        aviso_ativo.store(false);
        Serial.printf("[AVISO] Falha ao agendar desligamento: %s\n", esp_err_to_name(erro));
        return false;
    }

    Serial.println("[AVISO] Acionamento detectado: aviso por 2 s.");
    return true;
}

EstadoSender* buscarSender(const char* id)
{
    for (int i = 0; i < quantidade_senders; i++)
    {
        if (strcmp(senders[i].id, id) == 0) return &senders[i];
    }
    if (quantidade_senders >= MAX_SENDERS) return nullptr;

    EstadoSender* novo = &senders[quantidade_senders++];
    strncpy(novo->id, id, sizeof(novo->id) - 1);
    novo->id[sizeof(novo->id) - 1] = '\0';
    novo->ultimo_numero = -1;
    novo->rele_umidade = false;
    novo->rele_temperatura = false;
    return novo;
}

void atualizarComandosRele(EstadoSender* sender, bool novaUmidade, bool novaTemperatura)
{
    // Detecta cada saida separadamente: a segunda tambem pode gerar aviso
    // mesmo que a primeira ja esteja ligada.
    const bool ligouUmidade =
        AVISO_POR_UMIDADE && novaUmidade && !sender->rele_umidade;
    const bool ligouTemperatura =
        AVISO_POR_TEMPERATURA && novaTemperatura && !sender->rele_temperatura;

    sender->rele_umidade = novaUmidade;
    sender->rele_temperatura = novaTemperatura;

    if (ligouUmidade || ligouTemperatura)
    {
        acionarAvisoSonoro();
    }
    // true -> true e true -> false nao geram outro aviso.
    // O pulso ja iniciado termina apos 2 s, mesmo que a saida desligue antes.
    // Este e um aviso do COMANDO da API, nao uma confirmacao fisica do rele.
}

/* ===============================
   WIFI AND API
   =============================== */

void conectarWiFi()
{
    Serial.println("[WiFi] Conectando...");

    wifiManager.setConnectTimeout(15);
    wifiManager.setConfigPortalTimeout(180);
    wifiManager.addParameter(&parametro_api);
    wifiManager.setSaveParamsCallback(salvarParametros);

    if (wifiManager.autoConnect("ESP32-LoRa-Gateway"))
    {
        Serial.print("[WiFi] Conectado a ");
        Serial.print(WiFi.SSID());
        Serial.print(" - IP: ");
        Serial.println(WiFi.localIP());
    }
    else
    {
        Serial.println("[WiFi] Nao foi possivel conectar.");
    }
}

/* ===============================
   DESCOBERTA DA API (mDNS)
   =============================== */

// Aceita "192.168.0.14", "192.168.0.14:8000" ou a URL completa com o caminho.
String normalizarBase(String endereco)
{
    endereco.trim();
    if (endereco.isEmpty()) return endereco;
    if (!endereco.startsWith("http://") && !endereco.startsWith("https://")) endereco = "http://" + endereco;
    if (endereco.endsWith(API_CAMINHO)) endereco.remove(endereco.length() - strlen(API_CAMINHO));
    while (endereco.endsWith("/")) endereco.remove(endereco.length() - 1);
    // Sem porta, assume a padrao do backend.
    if (endereco.indexOf(':', endereco.indexOf("//") + 2) < 0) endereco += ":8000";
    return endereco;
}

bool testarAPI(const String &base)
{
    HTTPClient http;
    http.setTimeout(TEMPO_TESTE_API_MS);
    http.setConnectTimeout(TEMPO_TESTE_API_MS);
    if (!http.begin(base + "/health")) return false;
    const int status = http.GET();
    http.end();
    return status == 200;
}

bool mesmaRede(const IPAddress &ip)
{
    const IPAddress local = WiFi.localIP();
    const IPAddress mascara = WiFi.subnetMask();
    for (int i = 0; i < 4; i++)
    {
        if ((ip[i] & mascara[i]) != (local[i] & mascara[i])) return false;
    }
    return true;
}

bool usarBase(const IPAddress &ip, uint16_t porta)
{
    const String base = "http://" + ip.toString() + ":" + String(porta);
    if (!testarAPI(base)) return false;

    api_base = base;
    falhas_seguidas = 0;
    preferencias.putString("api_ultima", base);
    Serial.print("[mDNS] Servidor encontrado: ");
    Serial.println(base);
    return true;
}

IPAddress enderecoMDNS(int indice)
{
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
    return MDNS.address(indice);
#else
    return MDNS.IP(indice);
#endif
}

// O backend anuncia todos os IPs do computador no TXT "ips" (ele pode ter varias placas de
// rede). Primeiro testa os da mesma rede do gateway; cada candidato e confirmado com /health.
bool descobrirAPI()
{
    if (WiFi.status() != WL_CONNECTED) return false;
    if (!mdns_iniciado) mdns_iniciado = MDNS.begin("estufa-gateway");
    ultima_descoberta = millis();

    Serial.println("[mDNS] Procurando o servidor na rede (_estufa._tcp)...");
    const int encontrados = MDNS.queryService("estufa", "tcp");

    for (int i = 0; i < encontrados; i++)
    {
        const uint16_t porta = MDNS.port(i);
        const String ips = MDNS.hasTxt(i, "ips") ? MDNS.txt(i, "ips") : String("");

        for (int passada = 0; passada < 2; passada++)
        {
            int inicio = 0;
            while (inicio < (int)ips.length())
            {
                int fim = ips.indexOf(',', inicio);
                if (fim < 0) fim = ips.length();
                String texto = ips.substring(inicio, fim);
                texto.trim();
                inicio = fim + 1;

                IPAddress ip;
                if (!ip.fromString(texto)) continue;
                if ((passada == 0) != mesmaRede(ip)) continue;
                if (usarBase(ip, porta)) return true;
            }
        }

        if (usarBase(enderecoMDNS(i), porta)) return true;
    }

    Serial.println("[mDNS] Servidor nao encontrado. Confira se o backend esta rodando na mesma rede.");
    return false;
}

void iniciarAPI()
{
    String fixa = strlen(API_FIXA) > 0 ? String(API_FIXA) : preferencias.getString("api_fixa", "");
    fixa = normalizarBase(fixa);
    parametro_api.setValue(fixa.c_str(), 64);

    if (!fixa.isEmpty())
    {
        api_fixa = true;
        api_base = fixa;
        Serial.print("[API] Endereco fixo: ");
        Serial.println(api_base);
        return;
    }

    // Comeca pelo ultimo servidor encontrado; se nao responder, procura de novo.
    api_base = preferencias.getString("api_ultima", "");
    if (WiFi.status() != WL_CONNECTED) return;
    if (!api_base.isEmpty() && testarAPI(api_base))
    {
        Serial.print("[API] Usando o ultimo servidor encontrado: ");
        Serial.println(api_base);
        return;
    }
    api_base = "";
    descobrirAPI();
}

// Chamado no loop: procura o servidor quando ainda nao achou ou quando ele parou de responder.
void manterAPI()
{
    if (api_fixa || WiFi.status() != WL_CONNECTED) return;
    if (!api_base.isEmpty() && falhas_seguidas < FALHAS_PARA_REDESCOBRIR) return;
    if (ultima_descoberta != 0 && millis() - ultima_descoberta < INTERVALO_REDESCOBERTA) return;
    descobrirAPI();
}

void salvarParametros()
{
    const String fixa = normalizarBase(String(parametro_api.getValue()));
    preferencias.putString("api_fixa", fixa);
    api_fixa = !fixa.isEmpty();
    if (api_fixa) api_base = fixa;
    else ultima_descoberta = 0;
    Serial.print("[API] Endereco salvo no portal: ");
    Serial.println(api_fixa ? fixa : String("automatico (mDNS)"));
}

// Segurar o PRG por 3 s abre o portal "ESP32-LoRa-Gateway" para trocar o Wi-Fi ou o endereco da API.
void verificarBotaoConfig()
{
    if (digitalRead(BOTAO_CONFIG_PIN) != LOW)
    {
        botao_pressionado_desde = 0;
        return;
    }
    if (botao_pressionado_desde == 0)
    {
        botao_pressionado_desde = millis();
        return;
    }
    if (millis() - botao_pressionado_desde < BOTAO_CONFIG_MS) return;

    botao_pressionado_desde = 0;
    Serial.println("[WiFi] Abrindo o portal de configuracao (rede ESP32-LoRa-Gateway)...");
    Radio.Sleep();
    wifiManager.startConfigPortal("ESP32-LoRa-Gateway");
    lora_idle = true;
    if (!api_fixa) descobrirAPI();
}

// Tenta reconectar sem abrir o portal de configuracao, para nao travar a recepcao LoRa.
void manterWiFi()
{
    if (WiFi.status() == WL_CONNECTED) return;
    if (millis() - ultima_reconexao < INTERVALO_RECONEXAO) return;

    ultima_reconexao = millis();
    Serial.println("[WiFi] Desconectado, tentando reconectar...");
    WiFi.reconnect();
}

// Parser simples (sem biblioteca) para extrair um valor booleano de uma resposta JSON.
// Funciona para "chave":true ou "chave": false (com ou sem espaco depois dos dois pontos).
// Se a chave nao for encontrada, retorna valorPadrao (mantem o ultimo estado conhecido).
bool extrairBooleanJSON(const String &json, const char *chave, bool valorPadrao)
{
    int pos = json.indexOf(chave);
    if (pos < 0) return valorPadrao;

    pos = json.indexOf(':', pos);
    if (pos < 0) return valorPadrao;
    pos++;

    while (pos < (int)json.length() && json[pos] == ' ') pos++;

    if (json.startsWith("true", pos)) return true;
    if (json.startsWith("false", pos)) return false;

    return valorPadrao;
}

// A API devolve os comandos no inicio da resposta do POST:
// {"rele_umidade": true, "rele_temperatura": false, ...}
// Eles sao configurados no app (Inicio > Saidas e aviso sonoro).
bool enviarLeituraAPI(EstadoSender* sender, float temperatura, float umidade, int16_t rssi, int8_t snr, int r1, int r2)
{
    const char* controller_id = sender->id;
    if (WiFi.status() != WL_CONNECTED)
    {
        Serial.println("[API] WiFi desconectado, leitura descartada");
        return false;
    }
    if (api_base.isEmpty())
    {
        Serial.println("[API] Servidor ainda nao encontrado, leitura descartada");
        return false;
    }

    HTTPClient http;
    if (!http.begin(api_base + API_CAMINHO))
    {
        Serial.println("[API] Nao foi possivel iniciar a requisicao");
        return false;
    }
    http.addHeader("Content-Type", "application/json");
    if (strlen(GATEWAY_API_KEY) > 0)
    {
        http.addHeader("X-API-Key", GATEWAY_API_KEY);
    }
    http.setTimeout(3000);

    String payload = "{\"temperature\":";
    payload += String(temperatura, 2);
    payload += ",\"humidity\":";
    payload += String(umidade, 2);
    if (CURING_UNIT_ID > 0)
    {
        payload += ",\"curing_unit_id\":";
        payload += String(CURING_UNIT_ID);
    }
    payload += ",\"controller_id\":\"";
    payload += controller_id;
    payload += "\",\"device_code\":\"";
    payload += controller_id;
    payload += "\",\"rssi\":";
    payload += String(rssi);
    payload += ",\"snr\":";
    payload += String(snr);
    // Estado real dos reles informado pelo sender (confirmacao no app).
    if (r1 >= 0)
    {
        payload += ",\"output_humidity_state\":";
        payload += r1 ? "true" : "false";
    }
    if (r2 >= 0)
    {
        payload += ",\"output_temperature_state\":";
        payload += r2 ? "true" : "false";
    }
    payload += "}";

    int status = http.POST(payload);
    bool success = status >= 200 && status < 300;
    // Erros de conexao seguidos indicam que o IP do servidor mudou: o loop procura de novo.
    falhas_seguidas = status < 0 ? falhas_seguidas + 1 : 0;

    Serial.print("[API] HTTP status: ");
    Serial.print(status);
    Serial.print(" -> Controller: ");
    Serial.println(controller_id);

    if (success)
    {
        String resposta = http.getString();

        const bool novaUmidade =
            extrairBooleanJSON(resposta, "rele_umidade", sender->rele_umidade);
        const bool novaTemperatura =
            extrairBooleanJSON(resposta, "rele_temperatura", sender->rele_temperatura);

        // Preserva os comandos da API e dispara o aviso apenas ao ligar.
        atualizarComandosRele(sender, novaUmidade, novaTemperatura);

        Serial.print("[API] Comando de rele atualizado -> Rele1=");
        Serial.print(sender->rele_umidade ? "LIGADO" : "desligado");
        Serial.print(" Rele2=");
        Serial.println(sender->rele_temperatura ? "LIGADO" : "desligado");
    }
    else
    {
        if (status < 0)
        {
            Serial.print("[API] Erro de conexao: ");
            Serial.println(http.errorToString(status));
        }
        else
        {
            Serial.println("[API] O servidor retornou um status de erro.");
        }
    }

    http.end();
    return success;
}

/* ===============================
   DOWNLINK PARA O SENDER
   =============================== */

// Envia o ultimo comando de rele conhecido (cache) logo apos a leitura, sem esperar
// a chamada HTTP terminar - isso mantem a resposta dentro da janela de escuta
// do sender, que e curta. O cache so e atualizado depois, pela API.
// Formato: RELAY;ID=<controller_id>;H=<0|1>;T=<0|1>
void enviarDownlink(const EstadoSender* sender)
{
    char downlink[64];
    snprintf(
        downlink,
        sizeof(downlink),
        "RELAY;ID=%s;H=%d;T=%d",
        sender->id,
        sender->rele_umidade ? 1 : 0,
        sender->rele_temperatura ? 1 : 0
    );

    delay(ATRASO_DOWNLINK_MS);

    Serial.print("TX downlink: ");
    Serial.println(downlink);

    lora_idle = false;
    Radio.Send((uint8_t*)downlink, strlen(downlink));
}

/* ===============================
   PACKET HANDLING
   =============================== */

// Formato esperado: ID=<id>;N=<contador>;T=<celsius>;H=<umidade>[;R1=<0|1>;R2=<0|1>]
void processarPacote(const char* mensagem, int16_t rssi, int8_t snr)
{
    char controller_id[32];
    long numero;
    float temperatura;
    float umidade;

    if (sscanf(mensagem, "ID=%31[^;];N=%ld;T=%f;H=%f", controller_id, &numero, &temperatura, &umidade) != 4)
    {
        Serial.print("[LoRa] Pacote invalido: ");
        Serial.println(mensagem);
        return;
    }

    if (temperatura < -40.0 || temperatura > 125.0 || umidade < 0.0 || umidade > 100.0)
    {
        Serial.println("[LoRa] Valores fora da faixa do SHT40, descartado");
        return;
    }

    // Estado real dos reles (-1 quando o sender nao informa).
    int r1 = -1;
    int r2 = -1;
    const char* reles = strstr(mensagem, ";R1=");
    if (reles != nullptr && sscanf(reles, ";R1=%d;R2=%d", &r1, &r2) != 2)
    {
        r1 = -1;
        r2 = -1;
    }

    EstadoSender* sender = buscarSender(controller_id);
    if (sender == nullptr)
    {
        Serial.println("[LoRa] Limite de senders atingido (MAX_SENDERS), pacote ignorado");
        return;
    }

    if (sender->ultimo_numero >= 0 && numero > sender->ultimo_numero + 1)
    {
        Serial.print("[LoRa] Pacotes perdidos de ");
        Serial.print(controller_id);
        Serial.print(": ");
        Serial.println(numero - sender->ultimo_numero - 1);
    }
    sender->ultimo_numero = numero;

    // 1) Responde logo com o ultimo comando de rele conhecido (nao espera a API)
    enviarDownlink(sender);

    // 2) So depois manda a leitura pra API e atualiza o cache pra proxima rodada
    enviarLeituraAPI(sender, temperatura, umidade, rssi, snr, r1, r2);
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
    Serial.println("  MONITOR DE ESTUFA - RECEIVER (GATEWAY) ");
    Serial.println("=========================================");
    Serial.print("  Frequencia:    "); Serial.print(RF_FREQUENCY / 1000000.0); Serial.println(" MHz");
    Serial.print("  Destino API:   "); Serial.println(strlen(API_FIXA) > 0 ? API_FIXA : "automatico (mDNS)");
    Serial.println("=========================================");

    Mcu.begin(HELTEC_BOARD, SLOW_CLK_TPYE);

    // Inicializa desligado; nao toca ao ligar a placa nem a cada 10 segundos.
    if (!iniciarAvisoSonoro())
    {
        Serial.println("[AVISO] Desabilitado por falha de inicializacao.");
    }

    pinMode(BOTAO_CONFIG_PIN, INPUT_PULLUP);

    // Aberto antes do Wi-Fi: o portal pode salvar o endereco da API durante o autoConnect.
    preferencias.begin("gateway", false);
    parametro_api.setValue(preferencias.getString("api_fixa", API_FIXA).c_str(), 64);

    conectarWiFi();
    iniciarAPI();

    RadioEvents.RxDone = OnRxDone;
    RadioEvents.RxTimeout = OnRxTimeout;
    RadioEvents.RxError = OnRxError;
    RadioEvents.TxDone = OnTxDone;
    RadioEvents.TxTimeout = OnTxTimeout;
    Radio.Init(&RadioEvents);
    Radio.SetChannel(RF_FREQUENCY);
    Radio.SetRxConfig(
        MODEM_LORA, LORA_BANDWIDTH, LORA_SPREADING_FACTOR,
        LORA_CODINGRATE, 0, LORA_PREAMBLE_LENGTH,
        LORA_SYMBOL_TIMEOUT, LORA_FIX_LENGTH,
        0, true, 0, 0, LORA_IQ_INVERSION, true
    );
    Radio.SetTxConfig(
        MODEM_LORA, TX_OUTPUT_POWER, 0, LORA_BANDWIDTH,
        LORA_SPREADING_FACTOR, LORA_CODINGRATE, LORA_PREAMBLE_LENGTH,
        LORA_FIX_LENGTH, true, 0, 0, LORA_IQ_INVERSION, 3000
    );
}

/* ===============================
   LOOP
   =============================== */

void loop()
{
    Radio.IrqProcess();

    if (pacote_pendente)
    {
        char mensagem[TAMANHO_BUFFER];
        strcpy(mensagem, pacote);
        int16_t rssi = pacote_rssi;
        int8_t snr = pacote_snr;
        pacote_pendente = false;

        Serial.print("RX LoRa: ");
        Serial.print(mensagem);
        Serial.print(" | RSSI: ");
        Serial.print(rssi);
        Serial.print(" dBm | SNR: ");
        Serial.println(snr);

        processarPacote(mensagem, rssi, snr);
    }
    else if (lora_idle)
    {
        lora_idle = false;
        Radio.Rx(0);
    }

    manterWiFi();
    manterAPI();
    verificarBotaoConfig();
}

void OnRxDone(uint8_t *payload, uint16_t size, int16_t rssi, int8_t snr)
{
    Radio.Sleep();

    if (size >= TAMANHO_BUFFER) size = TAMANHO_BUFFER - 1;
    memcpy(pacote, payload, size);
    pacote[size] = '\0';
    pacote_rssi = rssi;
    pacote_snr = snr;
    pacote_pendente = true;

    lora_idle = true;
}

void OnRxTimeout(void)
{
    Radio.Sleep();
    lora_idle = true;
}

void OnRxError(void)
{
    Serial.println("[LoRa] Erro de recepcao (CRC)");
    Radio.Sleep();
    lora_idle = true;
}

void OnTxDone(void)
{
    Serial.println("[LoRa] Downlink enviado");
    lora_idle = true;
}

void OnTxTimeout(void)
{
    Serial.println("[LoRa] Downlink TX TIMEOUT");
    Radio.Sleep();
    lora_idle = true;
}
