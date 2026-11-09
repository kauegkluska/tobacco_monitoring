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
| `DEVICE_OFFLINE_SECONDS` | Segundos sem leitura até o dispositivo aparecer como offline, o "Sem sinal" da interface (padrão 90). |
| `ATMOSPHERIC_PRESSURE_KPA` | Pressão usada para estimar o bulbo úmido (padrão 90,8, Lages a 916 m). |
| `HEATING_RATE_WINDOW_MINUTES` | Janela da regressão do aquecimento rápido (padrão 60). |
| `HEATING_RATE_SEVERITY` | Gravidade do aquecimento rápido (padrão `info`, até medir a oscilação real da fornalha). |

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
| 1. Amarelação | 35–40 °C, 80–95% | 48–60 h | T > 40 °C (atenção) ou > 42 °C (crítico) por 10 min; diferença entre bulbo seco e úmido > 4,4 °C por 15 min (atenção) |
| 2. Murchamento | 40–48 °C, 65–85% | 18–24 h | T > 47,8 °C (atenção) ou > 52 °C (crítico) por 2 min; bulbo úmido > 40,6 °C (atenção) ou ≥ 43 °C (crítico) por 2 min; UR < 60% por 15 min (informativo) |
| 3. Secagem da folha | 48–60 °C, 30–65% | 24–60 h | T > 57,2 °C (atenção) ou > 63 °C (crítico) por 2 min; bulbo úmido como no Murchamento, só com T até 57,2 °C |
| 4. Secagem do talo | 60–74 °C, 15–40% | 18–48 h | T > 74 °C (atenção), > 77 °C (crítico) ou > 80 °C (emergência) por 2 min |

A duração mínima só condiciona a sugestão de avanço; a máxima gera um informativo. Em todas as fases também há:

- **Temperatura abaixo da faixa**: 2 °C abaixo do mínimo da fase por 30 min, depois da carência. Na Amarelação ela vale 12 h mais a subida desde a temperatura inicial; nas outras fases e na retomada, a subida até o mínimo mais 1 h.
- **Temperatura em queda**: 2,8 °C abaixo do máximo alcançado na fase, por 5 min. Não abre com "Temperatura alta" ou "Umidade alta" ativos, nem até 2 h depois de encerrados.
- **Aquecimento rápido**: regressão da temperatura acima de 1,1 / 0,8 / 1,1 / 1,7 °C/h, conforme a fase.
- **Sensor suspeito**: valores congelados por 10 min ou 3 saltos em 5 min suspendem as regras que dependem da medição; UR ≥ 99% por 30 min só avisa.
- **Permanência longa**: informativo quando a fase passa da duração máxima.
- **Sem novas leituras**: crítico aos 5 min na Amarelação; atenção aos 5 min e crítico aos 30 min nas demais fases, verificado a cada 30 s em segundo plano. O gateway só envia quando recebe pacotes do sender, então a API não consegue separar falha do sensor e falha do gateway.

A troca de fase é confirmada pelo produtor (`POST /curing_units/{id}/advance-stage`), porque depende de olhar as folhas. O campo `phase` da estufa diz o que já foi atingido (tempo mínimo, temperatura e umidade) e o que conferir nas folhas. Depois da Secagem do talo, avançar finaliza a cura e para a secagem.

As regras usam a mediana dos últimos 30 s e exigem 80 % das amostras da janela, com ao menos 50 % do tempo coberto. Cada alerta abre uma vez por tipo e fecha sozinho quando o valor volta com folga para dentro do limite mais leve da fase atual e se mantém por 2 min. Se a gravidade cair, o mesmo alerta é rebaixado, sem notificar. Se a gravidade aumentar, o alerta antigo é encerrado e um novo é aberto, para o app notificar de novo. As saídas no automático usam a faixa da fase em andamento.

O SHT40 mede temperatura e umidade relativa. O bulbo úmido, que é o que a literatura de cura controla, é estimado a partir delas em `services/psychrometrics.py`.

Os períodos de cada fase ficam em `stage_changes` e aparecem em `GET /curing_units/{id}/series` (campo `phases`), que o painel e o app usam para colorir o gráfico.

## Últimas secagens

Cada estufada (carga de tabaco) fica registrada em `curing_cycles`: abre ao iniciar a secagem na Amarelação e fecha ao finalizar a cura (`finished`) ou ao começar outra estufada com a anterior parada no meio (`stopped`). Parar e retomar a mesma estufada não abre outra. Se a fase for corrigida depois de finalizar, ao ligar a secagem a mesma estufada reabre.

Leituras, alertas e fases continuam nas próprias tabelas; `GET /curing-cycles/` resume o período de cada estufada (horas por fase, mínima/média/máxima e alertas). Bancos de versões anteriores ganham o registro da estufada atual (ou da última) ao iniciar a API.

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
| `GET /curing-cycles/?curing_unit_id=&limit=` | Últimas secagens (estufadas), da mais nova para a mais antiga, com o resumo de cada uma |
| `GET /curing-cycles/{id}` | Uma secagem, com os alertas do período |

Todas as datas saem em UTC com fuso (`...Z`). Temperaturas são sempre em °C; o painel e o app convertem para °F só na exibição.

Desvincular um dispositivo mantém a estufa e todo o histórico com o usuário.

## Testes

```powershell
cd backend
python -m pip install -r requirements-dev.txt
python -m pytest
```
