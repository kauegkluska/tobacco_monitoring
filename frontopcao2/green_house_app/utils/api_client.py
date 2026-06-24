import requests
import time

# Esta classe simula a interação com a API real
# O usuário poderá substituir a BASE_URL e os métodos pela integração real depois

class APIClient:
    BASE_URL = "http://localhost:8000"
    
    def __init__(self):
        self.token = None
        self.user_data = None
        
    def login(self, username, password):
        # Simulação de login
        time.sleep(1)
        if username == "admin" and password == "1234":
            self.token = "fake-jwt-token"
            self.user_data = {"id": 1, "username": "admin", "name": "Admin User"}
            return True, "Login realizado com sucesso"
        return False, "Usuário ou senha incorretos"

    def register(self, name, username, password):
        time.sleep(1)
        return True, "Registro realizado com sucesso"

    def get_curing_units(self):
        # Mock de estufas
        return [
            {"id": 1, "name": "Estufa Norte", "stage": "Secagem Inicial", "temp": 25.5, "humidity": 60},
            {"id": 2, "name": "Estufa Sul", "stage": "Maturação", "temp": 28.2, "humidity": 55},
        ]

    def get_readings(self, unit_id):
        # Mock de leituras para o gráfico
        return [
            {"timestamp": "10:00", "temp": 24, "humidity": 65},
            {"timestamp": "11:00", "temp": 25, "humidity": 63},
            {"timestamp": "12:00", "temp": 26, "humidity": 60},
            {"timestamp": "13:00", "temp": 25.5, "humidity": 60},
        ]

    def link_device(self, qr_code):
        time.sleep(1)
        if "device_" in qr_code:
            return True, "Dispositivo vinculado com sucesso"
        return False, "QR Code inválido"

api = APIClient()
