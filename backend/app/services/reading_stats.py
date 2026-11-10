"""Resumo das leituras de um período (mínimo, média e máximo), usado nos gráficos e no histórico das estufadas.

O bulbo úmido vem do valor gravado em cada leitura (o da mediana de 30 s, calculado na chegada). Leituras anteriores
a esse cálculo não têm o valor: aí ele é estimado pelas médias de temperatura e umidade do período.
"""

from sqlalchemy import func
from sqlalchemy.orm import Session

from models.reading import Reading
from services.psychrometrics import estimate_wet_bulb

STAT_KEYS = (
    "count", "temperature_min", "temperature_avg", "temperature_max",
    "humidity_min", "humidity_avg", "humidity_max",
    "wet_bulb_min", "wet_bulb_avg", "wet_bulb_max", "first_at", "last_at",
)

WET_BULB_COLUMNS = (
    func.min(Reading.filtered_wet_bulb),
    func.avg(Reading.filtered_wet_bulb),
    func.max(Reading.filtered_wet_bulb),
)


def wet_bulb_or_estimate(
    low: float | None, mean: float | None, high: float | None, temperature: float | None, humidity: float | None,
) -> tuple[float | None, float | None, float | None]:
    """Mínimo, média e máximo do bulbo úmido; sem valor gravado, a estimativa pelas médias nas três posições."""
    if mean is not None:
        return low, mean, high
    if temperature is None or humidity is None:
        return None, None, None
    estimate = estimate_wet_bulb(temperature, humidity)
    return estimate, estimate, estimate


def reading_stats(db: Session, *filters) -> dict:
    row = db.query(
        func.count(Reading.id),
        func.min(Reading.temperature),
        func.avg(Reading.temperature),
        func.max(Reading.temperature),
        func.min(Reading.humidity),
        func.avg(Reading.humidity),
        func.max(Reading.humidity),
        *WET_BULB_COLUMNS,
        func.min(Reading.timestamp),
        func.max(Reading.timestamp),
    ).filter(*filters).one()
    count, t_min, t_avg, t_max, h_min, h_avg, h_max, w_min, w_avg, w_max, first_at, last_at = row
    w_min, w_avg, w_max = wet_bulb_or_estimate(w_min, w_avg, w_max, t_avg, h_avg)
    return dict(zip(STAT_KEYS, (count, t_min, t_avg, t_max, h_min, h_avg, h_max, w_min, w_avg, w_max, first_at, last_at)))
