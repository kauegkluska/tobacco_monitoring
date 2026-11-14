"""TEMPORÁRIO: correção da posição do SHT40 para o teste em campo (14/11/2026).

Com o cabo curto, o SHT40 ficou longe do sensor da estufa, que fica perto do fogo. Lado a lado os dois concordam;
separados, o da estufa reage muito antes e muito mais à lenha; o SHT40 sobe cerca de 3 vezes menos e atrasado. Por
isso a estimativa usa uma média exponencial do SHT40 (o patamar, com peso maior nos últimos minutos) e amplia o quanto
ele está acima ou abaixo dela (a subida ou descida recente). Com a média curta, a subida atrasada do SHT40 depois que a
lenha já queimou pesa pouco. Parâmetros em core/config.py.

A umidade é recalculada para a temperatura estimada, com o mesmo vapor d'água no ar, para o bulbo úmido continuar
coerente. Aplicada na chegada da leitura (services/reading_service.py): o sistema inteiro passa a usar o valor
corrigido, e o valor do SHT40 fica guardado em sensor_temperature/sensor_humidity. Remover quando o cabo for aumentado.
"""

import math
from datetime import datetime, timedelta

from sqlalchemy.orm import Session

from core.config import settings
from models.reading import Reading
from services.psychrometrics import humidity_at


def _to_f(celsius: float) -> float:
    return celsius * 1.8 + 32


def _to_c(fahrenheit: float) -> float:
    return (fahrenheit - 32) / 1.8


def estimate(temperature: float, window_mean: float) -> float:
    """Temperatura (°C) estimada no ponto do sensor da estufa; nunca abaixo da leitura do SHT40."""
    measured, mean = _to_f(temperature), _to_f(window_mean)
    estimated = settings.SENSOR_CORRECTION_OFFSET_F + mean + settings.SENSOR_CORRECTION_GAIN * (measured - mean)
    return _to_c(max(measured, estimated))


def _exponential_mean(db: Session, unit_id: int, temperature: float, now: datetime) -> float:
    """Média do SHT40 com peso exp(-idade/tau), contando a leitura que acabou de chegar."""
    tau = settings.SENSOR_CORRECTION_TAU_MINUTES * 60
    rows = (
        db.query(Reading.timestamp, Reading.sensor_temperature)
        .filter(
            Reading.curing_unit_id == unit_id,
            Reading.is_outlier.is_(False),
            Reading.sensor_temperature.isnot(None),
            Reading.timestamp >= now - timedelta(seconds=4 * tau),
            Reading.timestamp <= now,
        )
        .all()
    )
    total, weights = temperature, 1.0
    for at, value in rows:
        weight = math.exp(-(now - at).total_seconds() / tau)
        total += weight * value
        weights += weight
    return total / weights


def correct(db: Session, unit_id: int, temperature: float, humidity: float, now: datetime) -> tuple[float, float]:
    """(temperatura °C, umidade %) no ponto do sensor da estufa; a leitura como veio se a correção estiver desligada."""
    if not settings.SENSOR_CORRECTION_ENABLED:
        return temperature, humidity
    new_temperature = estimate(temperature, _exponential_mean(db, unit_id, temperature, now))
    return new_temperature, humidity_at(temperature, humidity, new_temperature)
