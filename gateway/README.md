# ESP32 Wi-Fi API client

[esp32_lora_wifi_api.ino](esp32_lora_wifi_api.ino) is the complete single-file sketch. It contains your LoRa, LCD, SHT40, Wi-Fi, and API code.

## Configure and upload

1. Change `API_URL` near the top of `esp32_lora_wifi_api.ino` to the computer's LAN IPv4 address. For example:

   ```cpp
   const char* API_URL = "http://192.168.1.100:8000/readings/readings/";
   ```

   `localhost` and `127.0.0.1` are the ESP32 itself, not the computer.

2. Change `CURING_UNIT_ID` to an existing curing unit ID in the API database.

3. Open the `.ino` file in Arduino IDE and upload it to the ESP32.

## Start the API for LAN access

Run FastAPI so it listens beyond the computer itself:

```powershell
cd backend/app
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

The computer and ESP32 must be on the same Wi-Fi network. Windows Firewall may also need an inbound TCP rule for port `8000`.
