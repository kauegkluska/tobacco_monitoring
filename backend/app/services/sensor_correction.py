"""TEMPORÁRIO: correção da posição do SHT40 para o teste em campo (14/11/2026).

Com o cabo curto, o SHT40 ficou num ponto mais frio que o sensor da estufa. Lado a lado os dois concordam; separados,
o da estufa marcou 115 °F com o SHT40 em 100 °F e 143 °F com ele em 115 °F. A reta por esses dois pares estima a
temperatura no ponto do sensor da estufa. Abaixo do ponto em que a reta cruza a leitura real (~83 °F) não há correção.
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


def corrected_temperature(temperature: float) -> float:
    """Temperatura (°C) estimada no ponto do sensor da estufa."""
    (x1, y1), (x2, y2) = settings.SENSOR_CORRECTION_LOW_F, settings.SENSOR_CORRECTION_HIGH_F
    measured = _to_f(temperature)
    estimated = y1 + (y2 - y1) * (measured - x1) / (x2 - x1)
    return _to_c(max(measured, estimated))


def correct(temperature: float, humidity: float) -> tuple[float, float]:
    """(temperatura °C, umidade %) no ponto do sensor da estufa; devolve a leitura como veio se a correção estiver desligada."""
    if not settings.SENSOR_CORRECTION_ENABLED:
        return temperature, humidity
    new_temperature = corrected_temperature(temperature)
    return new_temperature, humidity_at(temperature, humidity, new_temperature)
