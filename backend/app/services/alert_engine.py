from datetime import datetime

from sqlalchemy.orm import Session

from models.alert import Alert
from models.curing_unit import CuringUnit
from models.reading import Reading

TEMPERATURE_LOW_C = 10.0
TEMPERATURE_HIGH_C = 45.0
HUMIDITY_LOW = 30.0
HUMIDITY_HIGH = 85.0


def evaluate_reading(db: Session, unit: CuringUnit, reading: Reading) -> None:
    conditions = {
        "temperature_low": (
            reading.temperature < TEMPERATURE_LOW_C,
            f"Temperatura baixa: {reading.temperature:.1f} °C.",
            "warning",
        ),
        "temperature_high": (
            reading.temperature > TEMPERATURE_HIGH_C,
            f"Temperatura alta: {reading.temperature:.1f} °C.",
            "critical",
        ),
        "humidity_low": (
            reading.humidity < HUMIDITY_LOW,
            f"Umidade baixa: {reading.humidity:.1f}%.",
            "warning",
        ),
        "humidity_high": (
            reading.humidity > HUMIDITY_HIGH,
            f"Umidade alta: {reading.humidity:.1f}%.",
            "warning",
        ),
    }

    now = datetime.utcnow()
    for alert_type, (violated, message, severity) in conditions.items():
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
                curing_unit_id=unit.id,
            ))
        elif not violated and active_alert:
            active_alert.is_active = False
            active_alert.resolved_at = now
