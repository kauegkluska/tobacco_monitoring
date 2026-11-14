"""Bulbo úmido estimado a partir de temperatura e umidade relativa (equações ASHRAE, unidades SI)."""

import math

from core.config import settings

_WATER_AIR_RATIO = 0.621945


def _saturation_pressure(celsius: float) -> float:
    """Pressão de saturação do vapor d'água, em Pa."""
    kelvin = celsius + 273.15
    return math.exp(
        -5.8002206e3 / kelvin
        + 1.3914993
        - 4.8640239e-2 * kelvin
        + 4.1764768e-5 * kelvin**2
        - 1.4452093e-8 * kelvin**3
        + 6.5459673 * math.log(kelvin)
    )


def _humidity_ratio(vapor_pressure: float, pressure: float) -> float:
    if vapor_pressure >= pressure:
        return math.inf
    return _WATER_AIR_RATIO * vapor_pressure / (pressure - vapor_pressure)


def _ratio_at_wet_bulb(dry_bulb: float, wet_bulb: float, pressure: float) -> float:
    saturated = _humidity_ratio(_saturation_pressure(wet_bulb), pressure)
    return ((2501 - 2.326 * wet_bulb) * saturated - 1.006 * (dry_bulb - wet_bulb)) / (
        2501 + 1.86 * dry_bulb - 4.186 * wet_bulb
    )


def wet_bulb(dry_bulb: float, relative_humidity: float, pressure_kpa: float) -> float:
    """Temperatura de bulbo úmido em °C, por bisseção da equação psicrométrica."""
    pressure = pressure_kpa * 1000
    vapor = min(relative_humidity / 100 * _saturation_pressure(dry_bulb), 0.99 * pressure)
    target = _humidity_ratio(vapor, pressure)
    low, high = dry_bulb - 80, dry_bulb
    for _ in range(50):
        middle = (low + high) / 2
        if _ratio_at_wet_bulb(dry_bulb, middle, pressure) > target:
            high = middle
        else:
            low = middle
    return (low + high) / 2


def humidity_at(temperature: float, humidity: float, new_temperature: float) -> float:
    """Umidade relativa (%) do mesmo ar levado de temperature a new_temperature (°C), sem ganhar nem perder vapor."""
    vapor = humidity / 100 * _saturation_pressure(temperature)
    return min(100.0, 100 * vapor / _saturation_pressure(new_temperature))


def estimate_wet_bulb(temperature: float, humidity: float) -> float:
    """Bulbo úmido estimado (°C) de uma leitura do SHT40, na pressão atmosférica configurada para a estufa."""
    return wet_bulb(temperature, humidity, settings.ATMOSPHERIC_PRESSURE_KPA)
