import random
from datetime import datetime, timedelta


MOCK_USER = {"id": 1, "name": "Carlos Silva", "email": "carlos@example.com"}

MOCK_ESTUFAS = [
    {
        "id": 1,
        "nome": "Estufa A - Galpao Norte",
        "estagio": "Secagem Inicial",
        "device_id": "DEV-001",
        "temp": 42.3,
        "umidade": 68.5,
        "status": "normal",
        "inicio": "20/06 08:00",
        "duracao_total_h": 120,
        "horas_decorridas": 72,
    },
    {
        "id": 2,
        "nome": "Estufa B - Galpao Sul",
        "estagio": "Fixacao da Cor",
        "device_id": "DEV-002",
        "temp": 58.1,
        "umidade": 35.2,
        "status": "alerta",
        "inicio": "18/06 14:00",
        "duracao_total_h": 120,
        "horas_decorridas": 105,
    },
    {
        "id": 3,
        "nome": "Estufa C - Area Leste",
        "estagio": "Finalizacao",
        "device_id": "DEV-003",
        "temp": 70.8,
        "umidade": 18.4,
        "status": "critico",
        "inicio": "17/06 06:00",
        "duracao_total_h": 120,
        "horas_decorridas": 118,
    },
]

MOCK_ALERTAS = [
    {
        "id": 1,
        "estufa_id": 2,
        "estufa_nome": "Estufa B - Galpao Sul",
        "tipo": "TEMPERATURA_ALTA",
        "mensagem": "Temperatura acima de 55 C detectada",
        "timestamp": "23/06 14:32",
        "ativo": True,
        "gravidade": "MEDIA",
        "valor_esperado": "<=55 C",
        "valor_encontrado": "58.1 C",
    },
    {
        "id": 2,
        "estufa_id": 3,
        "estufa_nome": "Estufa C - Area Leste",
        "tipo": "TEMPERATURA_CRITICA",
        "mensagem": "Temperatura critica - risco ao tabaco",
        "timestamp": "23/06 15:10",
        "ativo": True,
        "gravidade": "ALTA",
        "valor_esperado": "<=68 C",
        "valor_encontrado": "70.8 C",
    },
    {
        "id": 3,
        "estufa_id": 3,
        "estufa_nome": "Estufa C - Area Leste",
        "tipo": "UMIDADE_BAIXA",
        "mensagem": "Umidade abaixo do minimo para finalizacao",
        "timestamp": "23/06 15:05",
        "ativo": True,
        "gravidade": "MEDIA",
        "valor_esperado": ">=20 %",
        "valor_encontrado": "18.4 %",
    },
    {
        "id": 4,
        "estufa_id": 1,
        "estufa_nome": "Estufa A - Galpao Norte",
        "tipo": "FALTA_ENERGIA",
        "mensagem": "Queda de energia detectada (45 s)",
        "timestamp": "23/06 09:17",
        "ativo": False,
        "gravidade": "ALTA",
        "valor_esperado": "-",
        "valor_encontrado": "Sem alimentacao",
    },
]


def _gen_historico(n=16):
    agora = datetime.now()
    t, u = 38.0, 72.0
    out = []
    for i in range(n, 0, -1):
        t = max(30, min(80, t + random.uniform(-0.8, 1.2)))
        u = max(15, min(90, u + random.uniform(-1.5, 0.5)))
        out.append(
            {
                "ts": (agora - timedelta(minutes=i * 15)).strftime("%H:%M"),
                "temp": round(t, 1),
                "umid": round(u, 1),
            }
        )
    return out


HISTORICO = _gen_historico()

