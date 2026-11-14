"""TEMPORÁRIO: correção da posição do SHT40 para o teste em campo (14/11/2026).

Com o cabo curto, o SHT40 ficou num ponto mais frio que o sensor da estufa. Lado a lado os dois concordam; separados,
o da estufa marcou 115, 133 e 140 °F com o SHT40 em 100, 116 e 119 °F. A reta ajustada a esses pares estima a
temperatura no ponto do sensor da estufa; ela nunca fica abaixo da leitura do SHT40.
A umidade é recalculada para a temperatura estimada, com o mesmo vapor d'água no ar, para o bulbo úmido continuar
coerente.

Aplicada na chegada da leitura (services/reading_service.py): o sistema inteiro passa a usar o valor corrigido.
Remover quando o cabo for aumentado.
"""

from core.config import settings
from services.psychrometrics import humidity_at


def _to_f(celsius: float) -> float:
    return celsius * 1.8 + 32


def _to_c(fahrenheit: float) -> float:
    return (fahrenheit - 32) / 1.8


def _line(points: list[tuple[float, float]]) -> tuple[float, float]:
    """Inclinação e intercepto da reta de mínimos quadrados pelos pares (SHT40, estufa)."""
    n = len(points)
    mean_x = sum(x for x, _ in points) / n
    mean_y = sum(y for _, y in points) / n
    sxx = sum((x - mean_x) ** 2 for x, _ in points)
    if sxx == 0:
        return 1.0, mean_y - mean_x
    slope = sum((x - mean_x) * (y - mean_y) for x, y in points) / sxx
    return slope, mean_y - slope * mean_x


def corrected_temperature(temperature: float) -> float:
    """Temperatura (°C) estimada no ponto do sensor da estufa."""
    slope, intercept = _line(settings.SENSOR_CORRECTION_POINTS_F)
    measured = _to_f(temperature)
    return _to_c(max(measured, slope * measured + intercept))


def correct(temperature: float, humidity: float) -> tuple[float, float]:
    """(temperatura °C, umidade %) no ponto do sensor da estufa; devolve a leitura como veio se a correção estiver desligada."""
    if not settings.SENSOR_CORRECTION_ENABLED:
        return temperature, humidity
    new_temperature = corrected_temperature(temperature)
    return new_temperature, humidity_at(temperature, humidity, new_temperature)
