"""Troca de fase da cura e condições para sugerir a próxima."""

from datetime import datetime, timedelta

from sqlalchemy import func
from sqlalchemy.orm import Session, object_session

from core.clock import utcnow
from models.curing_unit import CuringUnit
from models.reading import Reading
from models.stage_change import StageChange
from services.phases import PHASES, current_phase, next_stage, phase_index

# Janela da média usada para conferir temperatura e umidade antes de avançar.
RECENT_MINUTES = 10
# Umidade "em queda": média das últimas 2 h abaixo da média das 2 h anteriores, por esta margem.
HUMIDITY_TREND_HOURS = 2
HUMIDITY_TREND_DROP = 2.0


def _open_segment(unit: CuringUnit) -> StageChange | None:
    return next((change for change in unit.stage_changes if change.ended_at is None), None)


def close_segment(unit: CuringUnit, now: datetime) -> None:
    segment = _open_segment(unit)
    if segment is not None:
        segment.ended_at = now


def open_segment(unit: CuringUnit, now: datetime) -> None:
    """Começa um período no histórico com a fase atual (ao ligar a secagem ou trocar de fase)."""
    close_segment(unit, now)
    unit.stage_changes.append(StageChange(stage=unit.curing_stage, started_at=now))


def change_stage(unit: CuringUnit, stage: str, now: datetime | None = None) -> None:
    now = now or utcnow()
    if stage == unit.curing_stage:
        return
    unit.curing_stage = stage
    unit.stage_started_at = now
    if unit.drying_started_at is not None:
        open_segment(unit, now)


def _fahrenheit(celsius: float) -> float:
    return celsius * 9 / 5 + 32


def _br(value: float, digits: int = 1) -> str:
    return f"{value:.{digits}f}".replace(".", ",")


def _average(db: Session, unit: CuringUnit, column, since: datetime, until: datetime) -> float | None:
    return (
        db.query(func.avg(column))
        .filter(Reading.curing_unit_id == unit.id, Reading.timestamp >= since, Reading.timestamp <= until)
        .scalar()
    )


def phase_status(unit: CuringUnit, now: datetime | None = None) -> dict | None:
    """Fase atual, faixas de referência e o que falta para avançar."""
    phase = current_phase(unit)
    if phase is None:
        return None
    now = now or utcnow()
    db = object_session(unit)
    hours = max(0.0, (now - unit.stage_started_at).total_seconds() / 3600)
    recent = now - timedelta(minutes=RECENT_MINUTES)
    temperature = _average(db, unit, Reading.temperature, recent, now) if db else None
    humidity = _average(db, unit, Reading.humidity, recent, now) if db else None

    checks = [{
        "label": f"Pelo menos {phase.min_hours:g} h nesta fase",
        "ok": hours >= phase.min_hours,
    }]
    if phase.advance_temp_at_least is not None:
        target = phase.advance_temp_at_least
        checks.append({
            "label": f"Temperatura em {_br(_fahrenheit(target), 0)} °F ({_br(target, 0)} °C) ou mais",
            "ok": temperature is not None and temperature >= target,
        })
    if phase.advance_humidity_at_most is not None:
        target = phase.advance_humidity_at_most
        checks.append({
            "label": f"Umidade em {_br(target, 0)}% ou menos",
            "ok": humidity is not None and humidity <= target,
        })
    if phase.advance_humidity_falling:
        window = timedelta(hours=HUMIDITY_TREND_HOURS)
        latest = _average(db, unit, Reading.humidity, now - window, now) if db else None
        earlier = _average(db, unit, Reading.humidity, now - 2 * window, now - window) if db else None
        checks.append({
            "label": "Umidade caindo nas últimas horas",
            "ok": latest is not None and earlier is not None and latest <= earlier - HUMIDITY_TREND_DROP,
        })

    return {
        "key": phase.key,
        "name": phase.name,
        "number": phase_index(phase) + 1,
        "total": len(PHASES),
        "temp_min": phase.temp_min,
        "temp_max": phase.temp_max,
        "humidity_min": phase.humidity_min,
        "humidity_max": phase.humidity_max,
        "min_hours": phase.min_hours,
        "max_hours": phase.max_hours,
        "hours": hours,
        "overdue": hours > phase.max_hours,
        "next_stage": next_stage(phase),
        "ready": all(check["ok"] for check in checks),
        "checks": checks,
        "visual_check": phase.visual_check,
    }
