"""Alarmes da cura: regras da fase atual, aquecimento rápido e estufa sem leituras.

Cada tipo de alarme tem no máximo um alerta ativo por estufa. Quando a gravidade aumenta
(ex.: atenção -> crítico), o alerta antigo é encerrado e um novo é aberto, para notificar de novo.
"""

from datetime import datetime, timedelta

from sqlalchemy import case, func
from sqlalchemy.orm import Session

from core.clock import utcnow
from core.config import settings
from models.alert import Alert
from models.curing_unit import CuringUnit
from models.device import Device
from models.reading import Reading
from services.phases import (
    BELOW_RANGE_MARGIN_C,
    BELOW_RANGE_SUSTAIN_MINUTES,
    BELOW_RANGE_TYPE,
    HEATING_TYPE,
    NO_READINGS_TYPE,
    SEVERITY_RANK,
    Phase,
    Rule,
    Tier,
    current_phase,
)

# Margem para encerrar um alerta: evita que ele abra e feche a cada leitura perto do limite.
TEMPERATURE_HYSTERESIS_C = 0.5
HUMIDITY_HYSTERESIS = 1.0

# Aquecimento: média dos últimos 5 min comparada com a de 30 min antes.
HEATING_SAMPLE_MINUTES = 5
HEATING_SPAN_MINUTES = 30
# Encerra o alerta de aquecimento abaixo de 1,1 °C/h (recomendação clássica de ~2 °F/h).
HEATING_CLEAR_RATE = 1.1

# Folga para considerar que as leituras cobrem a janela de um alarme com duração mínima.
COVERAGE_SLACK = timedelta(minutes=1)


def _fahrenheit(celsius: float) -> float:
    return celsius * 9 / 5 + 32


def _br(value: float) -> str:
    """Uma casa decimal com vírgula, como no restante da interface."""
    return f"{value:.1f}".replace(".", ",")


def _column(metric: str):
    return Reading.temperature if metric == "temperature" else Reading.humidity


def _hysteresis(metric: str) -> float:
    return TEMPERATURE_HYSTERESIS_C if metric == "temperature" else HUMIDITY_HYSTERESIS


def _violates(value: float, direction: str, threshold: float) -> bool:
    return value > threshold if direction == "high" else value < threshold


def _sustained(db: Session, unit: CuringUnit, rule: Rule, tier: Tier, now: datetime) -> bool:
    """Todas as leituras dos últimos N minutos violam o limite, e elas cobrem a janela inteira."""
    if tier.sustain_minutes <= 0:
        return True
    start = now - timedelta(minutes=tier.sustain_minutes)
    column = _column(rule.metric)
    inside = column <= tier.threshold if rule.direction == "high" else column >= tier.threshold
    total, inside_count, first = (
        db.query(func.count(Reading.id), func.sum(case((inside, 1), else_=0)), func.min(Reading.timestamp))
        .filter(Reading.curing_unit_id == unit.id, Reading.timestamp >= start, Reading.timestamp <= now)
        .one()
    )
    return bool(total) and not inside_count and first <= start + COVERAGE_SLACK


def _describe(rule: Rule, value: float, threshold: float) -> str:
    side = "acima de" if rule.direction == "high" else "abaixo de"
    if rule.metric == "temperature":
        return (
            f"Temperatura de {_br(_fahrenheit(value))} °F ({_br(value)} °C) {side} "
            f"{_br(_fahrenheit(threshold))} °F ({_br(threshold)} °C)"
        )
    return f"Umidade de {_br(value)}% {side} {_br(threshold)}%"


def _active(db: Session, unit: CuringUnit, alert_type: str) -> Alert | None:
    return (
        db.query(Alert)
        .filter(Alert.curing_unit_id == unit.id, Alert.type == alert_type, Alert.is_active.is_(True))
        .first()
    )


def _close(alert: Alert | None, now: datetime) -> None:
    if alert is not None:
        alert.is_active = False
        alert.resolved_at = now


def _raise(
    db: Session,
    unit: CuringUnit,
    alert_type: str,
    severity: str,
    message: str,
    now: datetime,
    value: float | None = None,
    threshold: float | None = None,
) -> None:
    """Abre o alerta, ou o substitui por um mais grave. Mesma gravidade: mantém o atual."""
    active = _active(db, unit, alert_type)
    if active is not None:
        if SEVERITY_RANK.get(severity, 0) <= SEVERITY_RANK.get(active.severity, 0):
            return
        _close(active, now)
    db.add(Alert(
        type=alert_type,
        message=message[:255],
        severity=severity,
        value=value,
        threshold=threshold,
        curing_unit_id=unit.id,
        timestamp=now,
    ))


def _evaluate_rule(db: Session, unit: CuringUnit, phase: Phase, rule: Rule, value: float, now: datetime) -> None:
    worst = None
    if _violates(value, rule.direction, rule.tiers[0].threshold):
        for tier in rule.tiers:
            if _violates(value, rule.direction, tier.threshold) and _sustained(db, unit, rule, tier, now):
                worst = tier

    if worst is not None:
        duration = f" por {worst.sustain_minutes} min" if worst.sustain_minutes else ""
        message = f"{_describe(rule, value, worst.threshold)} na fase de {phase.name}{duration}."
        _raise(db, unit, rule.type, worst.severity, message, now, value, worst.threshold)
        return

    # Encerra só com folga dentro do limite mais leve da fase atual.
    mildest = rule.tiers[0].threshold
    margin = _hysteresis(rule.metric)
    normalized = value <= mildest - margin if rule.direction == "high" else value >= mildest + margin
    if normalized:
        _close(_active(db, unit, rule.type), now)


def _average_temperature(db: Session, unit: CuringUnit, since: datetime, until: datetime) -> float | None:
    return (
        db.query(func.avg(Reading.temperature))
        .filter(Reading.curing_unit_id == unit.id, Reading.timestamp >= since, Reading.timestamp <= until)
        .scalar()
    )


def heating_rate(db: Session, unit: CuringUnit, now: datetime) -> float | None:
    """Aquecimento em °C/h nos últimos 30 min; None sem leituras suficientes."""
    sample = timedelta(minutes=HEATING_SAMPLE_MINUTES)
    span = timedelta(minutes=HEATING_SPAN_MINUTES)
    recent = _average_temperature(db, unit, now - sample, now)
    earlier = _average_temperature(db, unit, now - span - sample, now - span)
    if recent is None or earlier is None:
        return None
    return (recent - earlier) / (span.total_seconds() / 3600)


def _evaluate_heating(db: Session, unit: CuringUnit, phase: Phase, now: datetime) -> None:
    if phase.heating_limit is None:
        _close(_active(db, unit, HEATING_TYPE), now)
        return
    rate = heating_rate(db, unit, now)
    if rate is None:
        return
    if rate > phase.heating_limit:
        message = (
            f"Aquecimento de {_br(rate)} °C por hora na fase de {phase.name}. "
            f"Suba no máximo {_br(phase.heating_limit)} °C por hora para a umidade acompanhar."
        )
        _raise(db, unit, HEATING_TYPE, "warning", message, now)
    elif rate <= HEATING_CLEAR_RATE:
        _close(_active(db, unit, HEATING_TYPE), now)


def _evaluate_below_range(db: Session, unit: CuringUnit, phase: Phase, value: float, now: datetime) -> None:
    rule = Rule(
        BELOW_RANGE_TYPE,
        "temperature",
        "low",
        (Tier(phase.temp_min - BELOW_RANGE_MARGIN_C, "warning", BELOW_RANGE_SUSTAIN_MINUTES),),
    )
    warming_up = now - unit.stage_started_at < timedelta(hours=phase.warmup_hours)
    if warming_up:
        # A estufa ainda está chegando na faixa da fase.
        _close(_active(db, unit, BELOW_RANGE_TYPE), now)
        return
    _evaluate_rule(db, unit, phase, rule, value, now)


def evaluate_reading(db: Session, unit: CuringUnit, device: Device | None, reading: Reading) -> None:
    """Avalia uma leitura gravada com as regras da fase em andamento."""
    phase = current_phase(unit)
    if phase is None:
        return
    now = reading.timestamp
    _close(_active(db, unit, NO_READINGS_TYPE), now)

    values = {"temperature": reading.temperature, "humidity": reading.humidity}
    for rule in phase.rules:
        _evaluate_rule(db, unit, phase, rule, values[rule.metric], now)
    _evaluate_below_range(db, unit, phase, reading.temperature, now)
    _evaluate_heating(db, unit, phase, now)


def check_missing_readings(db: Session, now: datetime | None = None) -> None:
    """Alarme para estufas em secagem que pararam de receber leituras (sensor, gateway ou Wi-Fi)."""
    now = now or utcnow()
    warning_after = settings.DEVICE_OFFLINE_SECONDS
    critical_after = max(warning_after, settings.NO_READINGS_ALARM_SECONDS)

    for unit in db.query(CuringUnit).all():
        if unit.drying_started_at is None:
            _close(_active(db, unit, NO_READINGS_TYPE), now)
            continue
        last = (
            db.query(func.max(Reading.timestamp))
            .filter(Reading.curing_unit_id == unit.id, Reading.timestamp >= unit.drying_started_at)
            .scalar()
        )
        silent = (now - (last or unit.drying_started_at)).total_seconds()
        minutes = max(1, round(silent / 60))
        if silent >= critical_after:
            message = (
                f"Estufa sem novas leituras há {minutes} min. O sensor ou o gateway perdeu a comunicação: "
                "confira o sender, o receiver e o Wi-Fi."
            )
            _raise(db, unit, NO_READINGS_TYPE, "critical", message, now)
        elif silent >= warning_after:
            message = f"Sensor sem resposta há {minutes} min. Confira se o sender e o gateway estão ligados."
            _raise(db, unit, NO_READINGS_TYPE, "warning", message, now)
        else:
            _close(_active(db, unit, NO_READINGS_TYPE), now)
    db.commit()
