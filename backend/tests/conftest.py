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
import main as main_module  # noqa: E402
from main import app  # noqa: E402

# O verificador de leituras em segundo plano usa o relógio real; os testes o chamam com o tempo que escolherem.
main_module.MISSING_READINGS_CHECK_SECONDS = 86400


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


def make_unit(client: TestClient, auth: dict) -> int:
    """Estufa sem dispositivo, para testes que gravam direto no banco."""
    return client.post("/curing_units/", json={"name": "Estufa de teste"}, headers=auth).json()["id"]


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


class Sim:
    """Cura simulada: alimenta o motor com leituras de horários escolhidos, sem esperar o tempo real."""

    def __init__(self, unit_id: int, stage: str = "Amarelação", start=None):
        from datetime import datetime

        from core.database import SessionLocal
        from models.curing_unit import CuringUnit
        from models.stage_change import StageChange

        self.unit_id = unit_id
        self.now = start or datetime(2026, 1, 10, 8, 0, 0)
        with SessionLocal() as db:
            unit = db.get(CuringUnit, unit_id)
            unit.curing_stage = stage
            unit.stage_started_at = unit.drying_started_at = unit.cycle_started_at = self.now
            unit.stage_changes.clear()
            unit.stage_changes.append(StageChange(stage=stage, started_at=self.now))
            db.commit()

    def skip(self, minutes: float) -> None:
        from datetime import timedelta

        self.now += timedelta(minutes=minutes)

    def run(
        self,
        minutes: float,
        temperature,
        humidity,
        step: float = 15,
        noise: bool = True,
        outputs: bool = False,
        on_reading=None,
    ) -> None:
        """Leituras a cada `step` segundos. `temperature` e `humidity` podem ser funções dos minutos decorridos.

        Com `outputs`, cada leitura também passa pelas saídas, como em reading_service; `on_reading(sim)` roda depois
        de cada uma, com o banco já gravado.
        """
        from datetime import timedelta

        from core.database import SessionLocal
        from models.curing_unit import CuringUnit
        from models.reading import Reading
        from services.alert_engine import evaluate_reading
        from services.output_service import update_outputs

        value = lambda source, elapsed: source(elapsed) if callable(source) else source  # noqa: E731
        with SessionLocal() as db:
            unit = db.get(CuringUnit, self.unit_id)
            for index in range(1, int(round(minutes * 60 / step)) + 1):
                self.now += timedelta(seconds=step)
                elapsed = index * step / 60
                # Um sensor real nunca repete exatamente o mesmo valor por minutos seguidos.
                wiggle = 0.02 if noise and index % 2 else 0.0
                reading = Reading(
                    temperature=value(temperature, elapsed) + wiggle,
                    humidity=value(humidity, elapsed) + wiggle,
                    timestamp=self.now,
                    curing_unit_id=self.unit_id,
                )
                db.add(reading)
                db.flush()
                evaluate_reading(db, unit, None, reading)
                if outputs:
                    update_outputs(db, unit, reading)
                if on_reading is not None:
                    db.commit()
                    on_reading(self)
            db.commit()

    def outputs(self) -> tuple[bool, bool]:
        """Comando atual: (flap, soprador)."""
        unit = self.unit()
        return bool(unit.humidity_output_on), bool(unit.temperature_output_on)

    def events(self, output: str | None = None) -> list:
        from core.database import SessionLocal
        from models.output_event import OutputEvent

        with SessionLocal() as db:
            query = db.query(OutputEvent).filter(OutputEvent.curing_unit_id == self.unit_id)
            if output is not None:
                query = query.filter(OutputEvent.output == output)
            rows = query.order_by(OutputEvent.id).all()
            db.expunge_all()
            return rows

    def set_unit(self, **fields) -> None:
        from core.database import SessionLocal
        from models.curing_unit import CuringUnit

        with SessionLocal() as db:
            unit = db.get(CuringUnit, self.unit_id)
            for field, value in fields.items():
                setattr(unit, field, value)
            db.commit()

    def change_stage(self, stage: str) -> None:
        from core.database import SessionLocal
        from models.curing_unit import CuringUnit
        from services.stage_service import change_stage

        with SessionLocal() as db:
            change_stage(db.get(CuringUnit, self.unit_id), stage, self.now)
            db.commit()

    def pause(self) -> None:
        from core.database import SessionLocal
        from models.curing_unit import CuringUnit
        from services.stage_service import close_segment

        with SessionLocal() as db:
            unit = db.get(CuringUnit, self.unit_id)
            close_segment(unit, self.now)
            unit.drying_started_at = None
            db.commit()

    def resume(self) -> None:
        from core.database import SessionLocal
        from models.curing_unit import CuringUnit
        from services.stage_service import open_segment

        with SessionLocal() as db:
            unit = db.get(CuringUnit, self.unit_id)
            unit.drying_started_at = self.now
            open_segment(unit, self.now)
            db.commit()

    def check_missing(self) -> None:
        from core.database import SessionLocal
        from services.alert_engine import check_missing_readings

        with SessionLocal() as db:
            check_missing_readings(db, self.now)

    def _alerts(self, *conditions):
        from core.database import SessionLocal
        from models.alert import Alert

        with SessionLocal() as db:
            rows = db.query(Alert).filter(Alert.curing_unit_id == self.unit_id, *conditions).order_by(Alert.id).all()
            db.expunge_all()
            return rows

    def active(self) -> dict:
        from models.alert import Alert

        return {alert.type: alert for alert in self._alerts(Alert.is_active.is_(True))}

    def all_alerts(self) -> list:
        return self._alerts()

    def unit(self):
        from core.database import SessionLocal
        from models.curing_unit import CuringUnit

        with SessionLocal() as db:
            unit = db.get(CuringUnit, self.unit_id)
            db.expunge(unit)
            return unit


def humidity_for(temperature: float, target_wet_bulb: float, pressure: float = 90.8) -> float:
    """Umidade relativa que dá o bulbo úmido pedido nessa temperatura."""
    from services.psychrometrics import wet_bulb

    low, high = 1.0, 100.0
    for _ in range(50):
        middle = (low + high) / 2
        if wet_bulb(temperature, middle, pressure) > target_wet_bulb:
            high = middle
        else:
            low = middle
    return (low + high) / 2


class Clock:
    """Relógio dos testes pela API: começa na hora real e só anda quando o teste manda."""

    def __init__(self):
        from core.clock import utcnow

        self.now = utcnow()

    def __call__(self):
        return self.now

    def advance(self, seconds: float) -> None:
        from datetime import timedelta

        self.now += timedelta(seconds=seconds)


@pytest.fixture()
def clock(monkeypatch) -> Clock:
    import importlib

    fake = Clock()
    for name in (
        "routers.alerts", "routers.curing_units", "routers.devices", "services.alert_engine", "services.cycle_service",
        "services.device_service", "services.output_service", "services.reading_service", "services.stage_service",
    ):
        monkeypatch.setattr(importlib.import_module(name), "utcnow", fake)
    return fake


def hold(client: TestClient, clock: Clock, temperature: float, humidity: float, seconds: float = 60, step: float = 10, **extra):
    """Uma leitura a cada `step` segundos pelo caminho do gateway; devolve a última resposta."""
    response = None
    for index in range(int(round(seconds / step))):
        clock.advance(step)
        # Um sensor real nunca repete exatamente o mesmo valor por minutos seguidos.
        wiggle = 0.02 if index % 2 else 0.0
        response = send_reading(client, temperature + wiggle, humidity + wiggle, **extra)
    return response


def shift_stage_start(unit_id: int, hours: float) -> None:
    """Faz a fase atual ter começado há mais tempo, com a secagem ligada o tempo todo."""
    from datetime import timedelta

    from core.database import SessionLocal
    from models.curing_unit import CuringUnit

    shift = timedelta(hours=hours)
    with SessionLocal() as db:
        unit = db.get(CuringUnit, unit_id)
        unit.stage_started_at -= shift
        if unit.drying_started_at is not None:
            unit.drying_started_at -= shift
        if unit.cycle_started_at is not None:
            unit.cycle_started_at -= shift
        for segment in unit.stage_changes:
            if segment.ended_at is None:
                segment.started_at -= shift
        db.commit()
