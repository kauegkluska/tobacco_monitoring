# Monitor ambiental

Visualização em tempo real da temperatura em Fahrenheit e da umidade.

## Run

1. Start the FastAPI backend from `backend/app`:

   ```powershell
   uvicorn main:app --host 0.0.0.0 --port 8000 --reload
   ```

2. Serve this folder from the project root:

   ```powershell
   python -m http.server 5500 --directory frontend
   ```

3. Open <http://127.0.0.1:5500>.

A página consulta a API automaticamente a cada segundo e também pode ser atualizada manualmente.
