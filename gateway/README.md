# ESP32 LoRa ponto a ponto

A comunicação usa duas placas Heltec WiFi LoRa 32 V3:

```
[sender]  SHT40 + LCD  --LoRa 915 MHz-->  [receiver]  --Wi-Fi/HTTP-->  API FastAPI
```

| Sketch | Função |
|---|---|
| [sender/sender.ino](sender/sender.ino) | Fica na estufa. Lê o SHT40, mostra no LCD e transmite via LoRa a cada 2 s. Logo depois escuta o gateway por 1,2 s e aplica nos relés (GPIO2/GPIO3) o comando do app. Não usa Wi-Fi. |
| [receiver/receiver.ino](receiver/receiver.ino) | Gateway. Recebe os pacotes LoRa, envia cada leitura para `POST /readings/readings/`, responde ao sender com o comando dos relés e toca o aviso sonoro no GPIO5. |

```
sender  --ID=..;T=..;H=..;R1=0;R2=1-->  receiver  --POST-->  API
sender  <--RELAY;ID=..;H=1;T=0-------  receiver  <--rele_umidade/rele_temperatura--
```

Formato do pacote LoRa (texto): `ID=ESP32-TOBACCO-01;N=42;T=25.31;H=61.20;R1=0;R2=1`

- `ID`: `CONTROLLER_ID` do sender (usado para vincular o dispositivo no app)
- `N`: contador de pacotes (o receiver usa para detectar perdas)
- `T`: temperatura em Celsius
- `H`: umidade relativa em %
- `R1`, `R2`: estado real dos relés 1 (GPIO2) e 2 (GPIO3). O app mostra "Sender confirmou" quando batem com o comando.

Resposta do receiver (downlink): `RELAY;ID=ESP32-TOBACCO-01;H=1;T=0`. `H` vai para o relé 1 e `T` para o relé 2. O sender ignora comandos com outro `ID`.

O receiver envia para a API o RSSI e o SNR do enlace LoRa medidos na recepção.

## Saídas e aviso sonoro

A resposta da API a cada leitura começa com o comando das duas saídas:

```json
{"rele_umidade": false, "rele_temperatura": true, "stored": true, ...}
```

O receiver guarda esses valores por sender, repassa-os no downlink seguinte e toca o buzzer do GPIO5 por 2 s sempre que um deles passa de `false` para `true`. O comando chega aos relés em até dois ciclos (cerca de 4 s).

No app e no painel (**Início > Saídas e aviso sonoro**), cada saída tem:

- **Nome** editável (ex.: "Ventoinhas", "Queimador"), usado também nas notificações.
- **Modo**: Automático (padrão), Ligada ou Desligada.
- **Regra do automático**: umidade ou temperatura fora da faixa, acima do máximo ou abaixo do mínimo. Liga ao violar o limite e desliga quando volta com folga (0,5 °C ou 1 ponto de umidade). Com a secagem parada, o automático fica desligado.

Os relés começam desligados ao ligar o sender e **mantêm o último comando** se o gateway parar de responder. O LCD mostra `S1:ON`/`S2:ON` ao lado do número.

## Configurar e gravar

1. Os parâmetros LoRa (`RF_FREQUENCY`, `LORA_BANDWIDTH`, `LORA_SPREADING_FACTOR`, `LORA_CODINGRATE`, `LORA_PREAMBLE_LENGTH`, `LORA_IQ_INVERSION`) devem ser iguais nos dois sketches.
2. No **sender**, ajuste `CONTROLLER_ID` se houver mais de uma estufa.
3. No **receiver**, não é preciso informar o IP do computador: deixe `API_FIXA` vazio. Ao conectar no Wi-Fi, o gateway procura o servidor na rede (mDNS, serviço `_estufa._tcp` anunciado pelo backend), escolhe o IP da mesma rede e confirma com `GET /health`. O endereço encontrado fica salvo, e ele procura de novo sozinho se o servidor parar de responder (por exemplo, quando o roteador troca o IP do computador).

   Se a sua rede bloquear mDNS (algumas redes corporativas ou com "isolamento de clientes"), informe o endereço de um destes jeitos:

   - Segure o botão **PRG** do gateway por 3 s: abre a rede `ESP32-LoRa-Gateway`. Conecte-se a ela pelo celular e preencha **Endereço da API**, por exemplo `192.168.0.14:8000`. Deixe o campo vazio para voltar ao automático.
   - Ou defina `API_FIXA` no sketch, por exemplo `"http://192.168.0.14:8000"`.

   `localhost` e `127.0.0.1` apontam para o próprio ESP32, não para o computador.

4. No **receiver**, `CURING_UNIT_ID` indica a estufa de destino. Com `0`, a API usa a estufa vinculada ao `controller_id` no painel ou no app. Um valor diferente só é aceito se aquela estufa estiver vinculada ao mesmo dispositivo; caso contrário, a API usa a estufa vinculada.
5. Se o backend tiver `GATEWAY_API_KEY` no `.env`, coloque o mesmo valor em `GATEWAY_API_KEY` no receiver.
6. No painel, em **Estufas**, vincule o `CONTROLLER_ID` do sender a uma estufa e clique em **Iniciar secagem**. Sem isso, a API recebe as leituras (resposta `202`) mas não as grava. O monitor serial do receiver mostra o motivo.
7. Abra cada pasta no Arduino IDE e grave cada sketch na sua placa.

Na primeira inicialização, o receiver abre a rede Wi-Fi `ESP32-LoRa-Gateway` para configurar a rede (WiFiManager).

## Iniciar a API para acesso na rede local

```powershell
cd backend/app
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

O receiver e o computador devem estar na mesma rede Wi-Fi. Ao iniciar, a API mostra no terminal `mDNS: API anunciada como _estufa._tcp.local.` com os IPs do computador. Na primeira execução o Firewall do Windows pergunta se o Python pode usar a rede: permita em **Redes privadas** (isso libera a porta `8000` e o mDNS, UDP `5353`).
