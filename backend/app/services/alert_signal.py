"""Sinal de entrada dos alertas: descarte de saltos, filtro, janelas por tempo e persistência.

Cada leitura guarda o próprio valor filtrado. Assim as janelas são consultas no banco e sobrevivem a reinícios.
"""

from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from statistics import median

from sqlalchemy import func
from sqlalchemy.orm import Session

from core.config import settings
from models.reading import Reading
from services.psychrometrics import wet_bulb

FILTER_WINDOW = timedelta(seconds=30)

# Salto entre amostras próximas: descartado do filtro (DE).
JUMP_MAX_GAP = timedelta(seconds=10)
JUMP_TEMPERATURE_C = 2.0
JUMP_HUMIDITY = 10.0
# Depois de tantas amostras coerentes entre si, o salto é aceito como mudança real de nível.
JUMP_CONFIRM_SAMPLES = 5

# Persistência: fração das amostras da janela e cobertura mínima do tempo da janela (DE; C41).
PERSISTENCE_FRACTION = 0.8
MIN_COVERAGE = 0.5
# Lacuna maior que esta não conta como tempo coberto.
COVERAGE_MAX_GAP_SECONDS = 60.0


@dataclass(frozen=True)
class Sample:
    at: datetime
    temperature: float
    humidity: float
    wet_bulb: float

    @property
    def depression(self) -> float:
        return self.temperature - self.wet_bulb


def _estimate_wet_bulb(temperature: float, humidity: float) -> float:
    return wet_bulb(temperature, humidity, settings.ATMOSPHERIC_PRESSURE_KPA)


def _is_jump(a: Reading, b: Reading) -> bool:
    return abs(a.temperature - b.temperature) > JUMP_TEMPERATURE_C or abs(a.humidity - b.humidity) > JUMP_HUMIDITY


def _set_filtered(reading: Reading, temperature: float, humidity: float) -> None:
    reading.filtered_temperature = temperature
    reading.filtered_humidity = humidity
    reading.filtered_wet_bulb = _estimate_wet_bulb(temperature, humidity)


def prepare_reading(db: Session, reading: Reading) -> None:
    """Marca a leitura como salto ou grava os valores filtrados. A leitura já precisa estar no banco."""
    unit_filter = (Reading.curing_unit_id == reading.curing_unit_id, Reading.id != reading.id)
    last = (
        db.query(Reading)
        .filter(*unit_filter, Reading.is_outlier.is_(False), Reading.timestamp <= reading.timestamp)
        .order_by(Reading.timestamp.desc(), Reading.id.desc())
        .first()
    )
    if last is not None and reading.timestamp - last.timestamp <= JUMP_MAX_GAP and _is_jump(last, reading):
        pending = (
            db.query(Reading)
            .filter(*unit_filter, Reading.is_outlier.is_(True), Reading.timestamp > last.timestamp)
            .all()
        )
        if len(pending) + 1 < JUMP_CONFIRM_SAMPLES or any(_is_jump(item, reading) for item in pending):
            reading.is_outlier = True
            db.flush()
            return
        for item in pending:
            item.is_outlier = False
            _set_filtered(item, item.temperature, item.humidity)
        db.flush()

    rows = (
        db.query(Reading.temperature, Reading.humidity)
        .filter(
            Reading.curing_unit_id == reading.curing_unit_id,
            Reading.is_outlier.is_(False),
            Reading.timestamp > reading.timestamp - FILTER_WINDOW,
            Reading.timestamp <= reading.timestamp,
        )
        .all()
    )
    _set_filtered(reading, median(row[0] for row in rows), median(row[1] for row in rows))
    db.flush()


def load_samples(db: Session, unit_id: int, start: datetime, end: datetime) -> list[Sample]:
    """Amostras válidas do intervalo, em ordem. Leituras anteriores ao filtro usam o valor bruto."""
    rows = (
        db.query(
            Reading.timestamp,
            func.coalesce(Reading.filtered_temperature, Reading.temperature),
            func.coalesce(Reading.filtered_humidity, Reading.humidity),
            Reading.filtered_wet_bulb,
        )
        .filter(
            Reading.curing_unit_id == unit_id,
            Reading.is_outlier.is_(False),
            Reading.timestamp >= start,
            Reading.timestamp <= end,
        )
        .order_by(Reading.timestamp, Reading.id)
        .all()
    )
    return [
        Sample(at, temperature, humidity, _estimate_wet_bulb(temperature, humidity) if estimated is None else estimated)
        for at, temperature, humidity, estimated in rows
    ]


def coverage(samples: list[Sample], start: datetime, end: datetime) -> float:
    """Fração do tempo da janela coberta por amostras."""
    total = (end - start).total_seconds()
    covered = sum(
        min((after.at - before.at).total_seconds(), COVERAGE_MAX_GAP_SECONDS)
        for before, after in zip(samples, samples[1:], strict=False)
    )
    return covered / total if total > 0 else 0.0


def window_ratio(
    samples: list[Sample], now: datetime, minutes: float, predicate: Callable[[Sample], bool],
) -> float | None:
    """Fração das amostras da janela que atendem à condição; None sem cobertura suficiente."""
    start = now - timedelta(minutes=minutes)
    inside = [sample for sample in samples if start <= sample.at <= now]
    if coverage(inside, start, now) < MIN_COVERAGE:
        return None
    return sum(1 for sample in inside if predicate(sample)) / len(inside)


def persisted(samples: list[Sample], now: datetime, minutes: float, predicate: Callable[[Sample], bool]) -> bool:
    ratio = window_ratio(samples, now, minutes, predicate)
    return ratio is not None and ratio >= PERSISTENCE_FRACTION


def minute_means(db: Session, unit_id: int, start: datetime, end: datetime) -> list[tuple[datetime, float]]:
    """Média da temperatura filtrada em cada minuto, para estimar inclinações sem carregar a janela toda."""
    minute = func.strftime("%Y-%m-%d %H:%M:30", Reading.timestamp)
    rows = (
        db.query(minute, func.avg(func.coalesce(Reading.filtered_temperature, Reading.temperature)))
        .filter(
            Reading.curing_unit_id == unit_id,
            Reading.is_outlier.is_(False),
            Reading.timestamp >= start,
            Reading.timestamp <= end,
        )
        .group_by(minute)
        .order_by(minute)
        .all()
    )
    return [(datetime.strptime(text, "%Y-%m-%d %H:%M:%S"), value) for text, value in rows]


def slope_per_hour(points: list[tuple[datetime, float]], start: datetime, end: datetime) -> float | None:
    """Inclinação em °C/h por regressão linear; None com menos de metade dos minutos da janela."""
    inside = [(at, value) for at, value in points if start < at <= end]
    if len(inside) < (end - start).total_seconds() / 120 or len(inside) < 2:
        return None
    hours = [(at - start).total_seconds() / 3600 for at, _ in inside]
    values = [value for _, value in inside]
    mean_hour, mean_value = sum(hours) / len(hours), sum(values) / len(values)
    spread = sum((hour - mean_hour) ** 2 for hour in hours)
    if spread == 0:
        return None
    return sum((hour - mean_hour) * (value - mean_value) for hour, value in zip(hours, values, strict=True)) / spread
