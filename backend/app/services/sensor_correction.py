"""TEMPORÁRIO: correção da posição do SHT40 para o teste em campo (14/11/2026).

Com o cabo curto, o SHT40 ficou longe do sensor da estufa, que fica perto do fogo. Lado a lado os dois concordam;
separados, o da estufa reage muito mais à lenha: logo que o fogo sobe, ele sobe cerca de 3,8 vezes mais que o SHT40,
e a diferença vai diminuindo com o tempo. Por isso a estimativa usa a média do SHT40 nas últimas 2 h (o patamar) e
amplia o quanto ele está acima ou abaixo dela (a subida ou descida recente). Parâmetros em core/config.py.

A umidade é recalculada para a temperatura estimada, com o mesmo vapor d'água no ar, para o bulbo úmido continuar
coerente. Aplicada na chegada da leitura (services/reading_service.py): o sistema inteiro passa a usar o valor
corrigido, e o valor do SHT40 fica guardado em sensor_temperature/sensor_humidity. Remover quando o cabo for aumentado.
"""

from datetime import datetime, timedelta

from sqlalchemy import func
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


def _window_mean(db: Session, unit_id: int, temperature: float, now: datetime) -> float:
    """Média do SHT40 na janela, contando a leitura que acabou de chegar."""
    start = now - timedelta(minutes=settings.SENSOR_CORRECTION_WINDOW_MINUTES)
    total, count = (
        db.query(func.sum(Reading.sensor_temperature), func.count(Reading.sensor_temperature))
        .filter(
            Reading.curing_unit_id == unit_id,
            Reading.is_outlier.is_(False),
            Reading.sensor_temperature.isnot(None),
            Reading.timestamp >= start,
            Reading.timestamp <= now,
        )
        .one()
    )
    return ((total or 0.0) + temperature) / ((count or 0) + 1)


def correct(db: Session, unit_id: int, temperature: float, humidity: float, now: datetime) -> tuple[float, float]:
    """(temperatura °C, umidade %) no ponto do sensor da estufa; a leitura como veio se a correção estiver desligada."""
    if not settings.SENSOR_CORRECTION_ENABLED:
        return temperature, humidity
    new_temperature = estimate(temperature, _window_mean(db, unit_id, temperature, now))
    return new_temperature, humidity_at(temperature, humidity, new_temperature)
