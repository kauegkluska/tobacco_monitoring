"""Troca de fase da cura e condições para sugerir a próxima."""

from datetime import datetime, timedelta

from sqlalchemy import func
from sqlalchemy.orm import Session, object_session

from core.clock import utcnow
from models.curing_unit import CuringUnit
from models.reading import Reading
from models.stage_change import StageChange
from services.phases import PHASES, current_phase, next_stage, phase_index


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


def active_hours(unit: CuringUnit, since: datetime | None, stage: str | None = None, now: datetime | None = None) -> float:
    """Horas com a secagem ligada desde `since` (só na fase `stage`, se informada). O tempo parado não conta."""
    if since is None:
        return 0.0
    now = now or utcnow()
    seconds = 0.0
    for segment in unit.stage_changes:
        if stage is not None and segment.stage != stage:
            continue
        start = max(segment.started_at, since)
        end = segment.ended_at or now
        if end > start:
            seconds += (end - start).total_seconds()
    return seconds / 3600


def stage_hours(unit: CuringUnit, now: datetime | None = None) -> float:
    """Horas de secagem na fase atual, somando os trechos antes e depois de cada parada."""
    return active_hours(unit, unit.stage_started_at, unit.curing_stage, now)


def cycle_hours(unit: CuringUnit, now: datetime | None = None) -> float:
    """Horas de secagem da estufada atual, sem o tempo parado."""
    return active_hours(unit, unit.cycle_started_at, now=now)


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
    hours = stage_hours(unit, now)
    recent = now - timedelta(minutes=phase.advance_temp_minutes)
    temperature = _average(db, unit, Reading.temperature, recent, now) if db else None
    target = phase.advance_temp_at_least
    held = " por 1 h" if phase.advance_temp_minutes >= 60 else ""

    checks = [
        {
            "label": f"Pelo menos {phase.min_hours:g} h nesta fase",
            "ok": hours >= phase.min_hours,
        },
        {
            "label": f"Temperatura em {_br(_fahrenheit(target), 0)} °F ou mais{held}",
            "ok": temperature is not None and temperature >= target,
            # O app usa metric/target para mostrar o alvo na unidade escolhida.
            "metric": "temperature",
            "target": target,
        },
    ]

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
