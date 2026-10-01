# API do Monitor de Estufa

FastAPI + SQLite. Os dados ficam em `backend/data/monitor.db`, criado automaticamente na primeira inicialização. Bancos de versões anteriores são migrados sozinhos.

## Executar no Windows

```powershell
cd backend
python -m venv venv
.\venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
cd app
python -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

- Painel web: <http://127.0.0.1:8000/> (ou `http://<ip-do-computador>:8000/` em outro aparelho da rede)
- Documentação interativa da API: <http://127.0.0.1:8000/docs>

O Firewall do Windows pode precisar de uma regra de entrada TCP para a porta `8000`.

## Configuração

Copie `.env.example` para `.env` e ajuste. Tudo é opcional:

| Variável | Para que serve |
|---|---|
| `ENVIRONMENT` | `development` devolve o código de redefinição de senha na resposta. Use `production` quando houver envio por e-mail/SMS. |
| `SECRET_KEY` | Assina os tokens de login. Sem ela, uma chave aleatória é criada em `data/secret_key`. |
| `GATEWAY_API_KEY` | Se definida, o gateway precisa enviar o header `X-API-Key` com o mesmo valor. |
| `CORS_ORIGINS` | Origens liberadas para o navegador (`*` ou lista separada por vírgulas). |
| `DEVICE_OFFLINE_SECONDS` | Segundos sem leitura até o dispositivo aparecer como offline e o alerta "Sensor sem resposta" (padrão 90). |
| `NO_READINGS_ALARM_SECONDS` | Segundos sem leitura, com a secagem ligada, até o alarme crítico "Estufa sem novas leituras" (padrão 300). |

## Descoberta na rede local

Ao iniciar, a API se anuncia por mDNS como `_estufa._tcp` (porta `API_PORT`, padrão `8000`), com todos os IPv4 do computador no TXT `ips`. O gateway usa esse anúncio para achar o servidor sem IP fixo no firmware. Desligue com `MDNS_ENABLED=false`. Se rodar o uvicorn em outra porta, defina `API_PORT` com o mesmo valor.

## Como as leituras são gravadas

O gateway envia `POST /readings/readings/` com `controller_id`, temperatura (°C) e umidade.

1. O dispositivo é identificado pelo `controller_id`. Se ainda não existir, ele é registrado sem dono e passa a aparecer para vínculo no app.
2. A leitura vai para a estufa vinculada a esse dispositivo. Nunca para a estufa de outro usuário.
3. A leitura só é gravada com a secagem em andamento (`start-drying`).

A resposta é `201` quando a leitura foi gravada. É `202` quando foi recebida mas não gravada, com o motivo em `reason`: `no_curing_unit` ou `drying_not_started`.

A resposta sempre começa com `rele_umidade` e `rele_temperatura`, o comando das saídas lido pelo receiver. O receiver pode enviar `output_humidity_state` e `output_temperature_state` com o estado real dos relés, que o app mostra como confirmação. Quando uma delas passa a `true`, o gateway toca o aviso sonoro. Cada mudança fica registrada em `/output-events/`.

## Fases da cura

Ao iniciar a secagem, a estufa entra na **Amarelação**. As faixas e os alarmes estão em `app/services/phases.py`:

| Fase | Faixa | Duração de referência | Alarmes |
|---|---|---|---|
| 1. Amarelação | 35–40 °C, 80–95% | 24–48 h | T > 40 °C por 10 min (atenção), T > 42 °C por 10 min (crítico), UR < 75% por 15 min (atenção), UR < 70% por 15 min (crítico) |
| 2. Murchamento | 40–48 °C, 65–85% | 12–24 h | T > 50 °C (atenção), T > 52 °C (crítico), UR < 60% (atenção), aquecimento > 1,5 °C/h |
| 3. Secagem da folha | 48–60 °C, 30–65% | 24–48 h | T > 60 °C (atenção), T > 63 °C (crítico), UR < 25% (atenção), aquecimento > 1,5 °C/h |
| 4. Secagem do talo | 60–74 °C, 15–40% | 24–48 h | T > 74 °C (atenção), T > 76 °C (crítico), T > 80 °C (emergência), UR < 10% (atenção) |

Em todas as fases também há:

- **Temperatura abaixo da faixa**: 2 °C abaixo do mínimo da fase por 30 min, depois do aquecimento inicial (6 h na Amarelação, 3 h nas outras).
- **Sem novas leituras**: atenção após `DEVICE_OFFLINE_SECONDS` e crítico após `NO_READINGS_ALARM_SECONDS`, verificado a cada 30 s em segundo plano. O gateway só envia quando recebe pacotes do sender, então a API não consegue separar falha do sensor e falha do gateway.

A troca de fase é confirmada pelo produtor (`POST /curing_units/{id}/advance-stage`), porque depende de olhar as folhas. O campo `phase` da estufa diz o que já foi atingido (tempo mínimo, temperatura e umidade) e o que conferir nas folhas. Depois da Secagem do talo, avançar finaliza a cura e para a secagem.

Cada alerta abre uma vez por tipo e fecha sozinho quando o valor volta com folga para dentro do limite mais leve da fase atual. Se a gravidade aumentar, o alerta antigo é encerrado e um novo é aberto, para o app notificar de novo. As saídas no automático usam a faixa da fase em andamento.

O SHT40 mede umidade relativa, não bulbo úmido: os limites de umidade são parâmetros indiretos de monitoramento.

Os períodos de cada fase ficam em `stage_changes` e aparecem em `GET /curing_units/{id}/series` (campo `phases`), que o painel e o app usam para colorir o gráfico.

## Endpoints principais

| Método e caminho | Descrição |
|---|---|
| `POST /auth/register`, `POST /auth/login`, `POST /auth/refresh` | Conta e sessão |
| `POST /auth/password-reset/request`, `.../confirm` | Redefinição de senha |
| `GET/PATCH /users/me`, `POST /users/me/password` | Perfil |
| `POST /readings/readings/` | Leitura enviada pelo gateway |
| `POST /devices/telemetry` | Sinal de vida do gateway (leitura opcional) |
| `GET /readings/` | Últimas leituras do usuário |
| `GET/POST /curing_units/`, `GET/PATCH/DELETE /curing_units/{id}` | Estufas |
| `POST /curing_units/{id}/start-drying`, `.../stop-drying` | Libera ou bloqueia a gravação de leituras |
| `POST /curing_units/{id}/advance-stage` | Passa para a próxima fase da cura (ou finaliza) |
| `GET /curing_units/{id}/latest`, `.../readings?since=&limit=` | Leituras da estufa |
| `GET /curing_units/{id}/series?since=&until=&points=` | Leituras agrupadas para gráficos, com as fases do período |
| `GET /curing_units/{id}/readings.csv` | Exportação para planilha |
| `GET /curing_units/{id}/estimate`, `.../alerts` | Previsão de término e alertas da estufa |
| `POST /devices/link`, `GET /devices/`, `DELETE /devices/{id}` | Vincular, listar e desvincular dispositivos |
| `POST /devices/{id}/thresholds`, `.../calibrate`, `.../reconnect` | Limites, calibração e verificação de conexão |
| `GET /alerts/?active=true`, `POST /alerts/{id}/acknowledge`, `.../resolve` | Central de alertas |
| `GET/PATCH /curing_units/{id}/outputs` | Saídas (relés 1 e 2): nome, modo (`auto`, `on`, `off`), regra do automático e confirmação do sender |
| `GET /output-events/?after_id=&buzzer=true` | Mudanças nas saídas; `buzzer: true` quando o gateway tocou o aviso |

Todas as datas saem em UTC com fuso (`...Z`). Temperaturas são sempre em °C; o painel e o app convertem para °F só na exibição.

Desvincular um dispositivo mantém a estufa e todo o histórico com o usuário.

## Testes

```powershell
cd backend
python -m pip install -r requirements-dev.txt
python -m pytest
```
