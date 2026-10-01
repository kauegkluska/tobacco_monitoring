import os
import sys
import tempfile
from pathlib import Path

import pytest

# Banco e chave isolados para os testes; precisa acontecer antes de importar o app.
_DATA_DIR = tempfile.mkdtemp(prefix="monitor-tests-")
os.environ["DATA_DIR"] = _DATA_DIR
os.environ["ENVIRONMENT"] = "development"
os.environ.pop("GATEWAY_API_KEY", None)
os.environ["MDNS_ENABLED"] = "false"  # os testes não anunciam nada na rede

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))

from fastapi.testclient import TestClient  # noqa: E402

from core.database import Base, engine  # noqa: E402
from main import app  # noqa: E402


@pytest.fixture()
def client():
    Base.metadata.drop_all(bind=engine)
    with TestClient(app) as test_client:
        yield test_client


def register(client: TestClient, login: str = "produtor", password: str = "segredo123") -> dict:
    response = client.post("/auth/register", json={"name": "Produtor Teste", "login": login, "password": password})
    assert response.status_code == 201, response.text
    return {"Authorization": f"Bearer {response.json()['access_token']}"}


@pytest.fixture()
def auth(client):
    return register(client)


@pytest.fixture()
def drying_unit(client, auth):
    """Dispositivo vinculado a uma estufa com secagem iniciada."""
    device = client.post("/devices/link", json={"controller_id": "ESP32-TOBACCO-01"}, headers=auth).json()
    unit = client.post("/curing_units/", json={"name": "Estufa 01", "device_id": device["id"]}, headers=auth).json()
    client.post(f"/curing_units/{unit['id']}/start-drying", headers=auth)
    return {"device": device, "unit": unit}


def send_reading(client: TestClient, temperature: float = 40.0, humidity: float = 60.0, **extra):
    payload = {"temperature": temperature, "humidity": humidity, "controller_id": "ESP32-TOBACCO-01", **extra}
    return client.post("/readings/readings/", json=payload)


def set_stage(client: TestClient, auth: dict, unit_id: int, stage: str) -> dict:
    response = client.patch(f"/curing_units/{unit_id}", json={"curing_stage": stage}, headers=auth)
    assert response.status_code == 200, response.text
    return response.json()


def add_past_readings(unit_id: int, minutes_ago: range, temperature: float, humidity: float = 85.0) -> None:
    """Grava leituras antigas direto no banco, uma por minuto, para testar regras com duração."""
    from datetime import timedelta

    from core.clock import utcnow
    from core.database import SessionLocal
    from models.reading import Reading

    now = utcnow()
    with SessionLocal() as db:
        for minutes in minutes_ago:
            db.add(Reading(
                temperature=temperature,
                humidity=humidity,
                timestamp=now - timedelta(minutes=minutes),
                curing_unit_id=unit_id,
            ))
        db.commit()


def shift_stage_start(unit_id: int, hours: float) -> None:
    """Faz a fase atual ter começado há mais tempo."""
    from datetime import timedelta

    from core.database import SessionLocal
    from models.curing_unit import CuringUnit

    with SessionLocal() as db:
        unit = db.get(CuringUnit, unit_id)
        unit.stage_started_at -= timedelta(hours=hours)
        db.commit()
