## API com SQLite

Os dados são persistidos em `backend/data/monitor.db`. O banco é criado automaticamente na primeira inicialização.

### Executar no Windows

```powershell
cd "C:\Users\Kaue Kluska\Documents\Aplicativo\backend"
python -m venv venv
.\venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
cd app
python -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

Endpoints usados pelo ESP32 e pelo frontend:

- `POST /readings/readings/` adiciona uma leitura.
- `GET /readings/readings/` retorna as leituras salvas.
- `GET /curing_units/` lista as estufas.
- `GET /curing_units/{id}/latest` retorna a última leitura da estufa.
- `GET /curing_units/{id}/readings` retorna o histórico da estufa.
- `POST /curing_units/{id}/start-drying` inicia a secagem e libera leituras.
- `POST /curing_units/{id}/stop-drying` interrompe a secagem e bloqueia novas leituras.
- `PATCH /curing_units/{id}` atualiza nome, estágio e duração estimada.
- `GET /curing_units/{id}/estimate` calcula o tempo restante do estágio.
- `POST /devices/link` vincula ou cadastra um dispositivo para o usuário autenticado.
- `GET /devices/` lista apenas os dispositivos do usuário autenticado.
- `POST /auth/register` cadastra um usuário e retorna um token.
- `POST /auth/login` autentica um usuário e retorna um token.
- `GET /users/me` retorna o usuário autenticado.

O ESP32 continua enviando temperatura em Celsius. O app mobile e o frontend convertem o valor para Fahrenheit apenas na apresentação.

Cada leitura atualiza `last_seen_at` e marca o dispositivo como `online`. Um dispositivo sem leitura por mais de 60 segundos aparece como `offline` ao ser consultado.

O frontend pode ser aberto em `http://127.0.0.1:5500` usando:

```powershell
python -m http.server 5500 --directory ..\..\frontend
```
