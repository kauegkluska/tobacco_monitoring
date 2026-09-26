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
| `DEVICE_OFFLINE_SECONDS` | Segundos sem leitura até o dispositivo aparecer como offline (padrão 90). |

## Descoberta na rede local

Ao iniciar, a API se anuncia por mDNS como `_estufa._tcp` (porta `API_PORT`, padrão `8000`), com todos os IPv4 do computador no TXT `ips`. O gateway usa esse anúncio para achar o servidor sem IP fixo no firmware. Desligue com `MDNS_ENABLED=false`. Se rodar o uvicorn em outra porta, defina `API_PORT` com o mesmo valor.

## Como as leituras são gravadas

O gateway envia `POST /readings/readings/` com `controller_id`, temperatura (°C) e umidade.

1. O dispositivo é identificado pelo `controller_id`. Se ainda não existir, ele é registrado sem dono e passa a aparecer para vínculo no app.
2. A leitura vai para a estufa vinculada a esse dispositivo. Nunca para a estufa de outro usuário.
3. A leitura só é gravada com a secagem em andamento (`start-drying`).

A resposta é `201` quando a leitura foi gravada. É `202` quando foi recebida mas não gravada, com o motivo em `reason`: `no_curing_unit` ou `drying_not_started`.

A resposta sempre começa com `rele_umidade` e `rele_temperatura`, o comando das saídas lido pelo receiver. O receiver pode enviar `output_humidity_state` e `output_temperature_state` com o estado real dos relés, que o app mostra como confirmação. Quando uma delas passa a `true`, o gateway toca o aviso sonoro. Cada mudança fica registrada em `/output-events/`.

Cada leitura avalia os limites do dispositivo. Um alerta abre por tipo (temperatura alta/baixa, umidade alta/baixa) e fecha sozinho quando o valor volta para a faixa. Há uma pequena margem para o alerta não abrir e fechar a cada leitura.

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
| `GET /curing_units/{id}/latest`, `.../readings?since=&limit=` | Leituras da estufa |
| `GET /curing_units/{id}/series?since=&until=&points=` | Leituras agrupadas para gráficos |
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
