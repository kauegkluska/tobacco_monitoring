from sqlalchemy.orm import Session

from core.clock import utcnow
from models.alert import Alert
from models.curing_unit import CuringUnit
from models.device import Device
from models.reading import Reading

DEFAULT_LIMITS = {"temp_min": 35.0, "temp_max": 75.0, "humidity_min": 40.0, "humidity_max": 90.0}

# Margem para encerrar um alerta: evita que ele abra e feche a cada leitura perto do limite.
TEMPERATURE_HYSTERESIS_C = 0.5
HUMIDITY_HYSTERESIS = 1.0


def _fahrenheit(celsius: float) -> float:
    return celsius * 9 / 5 + 32


def _br(value: float) -> str:
    """Uma casa decimal com vírgula, como no restante da interface."""
    return f"{value:.1f}".replace(".", ",")


def _limit(device: Device | None, name: str) -> float:
    value = getattr(device, name, None) if device is not None else None
    return DEFAULT_LIMITS[name] if value is None else value


def evaluate_reading(db: Session, unit: CuringUnit, device: Device | None, reading: Reading) -> None:
    """Abre um alerta por tipo de violação e o encerra quando o valor volta para a faixa."""
    temp_min = _limit(device, "temp_min")
    temp_max = _limit(device, "temp_max")
    humidity_min = _limit(device, "humidity_min")
    humidity_max = _limit(device, "humidity_max")
    t = reading.temperature
    h = reading.humidity

    conditions = (
        # tipo, violado, normalizado, severidade, valor, limite, mensagem
        (
            "Temperatura alta",
            t > temp_max,
            t <= temp_max - TEMPERATURE_HYSTERESIS_C,
            "critical",
            t,
            temp_max,
            f"Temperatura de {_br(_fahrenheit(t))} °F ({_br(t)} °C) acima do máximo de "
            f"{_br(_fahrenheit(temp_max))} °F ({_br(temp_max)} °C).",
        ),
        (
            "Temperatura baixa",
            t < temp_min,
            t >= temp_min + TEMPERATURE_HYSTERESIS_C,
            "warning",
            t,
            temp_min,
            f"Temperatura de {_br(_fahrenheit(t))} °F ({_br(t)} °C) abaixo do mínimo de "
            f"{_br(_fahrenheit(temp_min))} °F ({_br(temp_min)} °C).",
        ),
        (
            "Umidade alta",
            h > humidity_max,
            h <= humidity_max - HUMIDITY_HYSTERESIS,
            "warning",
            h,
            humidity_max,
            f"Umidade de {_br(h)}% acima do máximo de {_br(humidity_max)}%.",
        ),
        (
            "Umidade baixa",
            h < humidity_min,
            h >= humidity_min + HUMIDITY_HYSTERESIS,
            "warning",
            h,
            humidity_min,
            f"Umidade de {_br(h)}% abaixo do mínimo de {_br(humidity_min)}%.",
        ),
    )

    now = utcnow()
    for alert_type, violated, normalized, severity, value, threshold, message in conditions:
        active_alert = (
            db.query(Alert)
            .filter(
                Alert.curing_unit_id == unit.id,
                Alert.type == alert_type,
                Alert.is_active.is_(True),
            )
            .first()
        )

        if violated and not active_alert:
            db.add(Alert(
                type=alert_type,
                message=message,
                severity=severity,
                value=value,
                threshold=threshold,
                curing_unit_id=unit.id,
                timestamp=now,
            ))
        elif normalized and active_alert:
            active_alert.is_active = False
            active_alert.resolved_at = now
