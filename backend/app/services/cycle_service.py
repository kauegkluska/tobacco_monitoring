"""Estufadas (cargas de tabaco): abertura, encerramento e resumo de cada secagem."""

from datetime import datetime

from sqlalchemy import func
from sqlalchemy.orm import Session

from core.clock import utcnow
from models.alert import Alert
from models.curing_cycle import CuringCycle
from models.curing_unit import CuringUnit
from models.reading import Reading
from services.phases import PHASES, phase_named

IN_PROGRESS = "in_progress"
FINISHED = "finished"
STOPPED = "stopped"


def open_cycle(unit: CuringUnit) -> CuringCycle | None:
    return next((cycle for cycle in reversed(unit.cycles) if cycle.ended_at is None), None)


def _last_drying_at(unit: CuringUnit, now: datetime) -> datetime:
    """Último instante com a secagem ligada: agora, se ligada, ou o fim do último trecho."""
    ends = [segment.ended_at or now for segment in unit.stage_changes]
    return max(ends) if ends else now


def close_cycle(unit: CuringUnit, status: str, now: datetime | None = None) -> None:
    """Encerra a estufada aberta. Chame antes de trocar a fase, para guardar a última fase em que ela esteve."""
    cycle = open_cycle(unit)
    if cycle is None:
        return
    now = now or utcnow()
    cycle.ended_at = max(cycle.started_at, _last_drying_at(unit, now))
    cycle.status = status
    cycle.final_stage = unit.curing_stage if phase_named(unit.curing_stage) else _last_phase(unit, cycle)


def start_cycle(unit: CuringUnit, now: datetime) -> None:
    """Nova estufada. A anterior, se ainda aberta (parada no meio), fica registrada como interrompida."""
    close_cycle(unit, STOPPED, now)
    unit.cycles.append(CuringCycle(started_at=now, status=IN_PROGRESS))


def resume_cycle(unit: CuringUnit, now: datetime) -> None:
    """Continua a estufada atual. Se ela já tinha sido encerrada (fase corrigida depois de finalizar), reabre."""
    if open_cycle(unit) is not None:
        return
    started = unit.cycle_started_at or now
    last = unit.cycles[-1] if unit.cycles else None
    if last is not None and last.started_at == started:
        last.ended_at = None
        last.status = IN_PROGRESS
        last.final_stage = None
    else:
        unit.cycles.append(CuringCycle(started_at=started, status=IN_PROGRESS))


def _window(cycle: CuringCycle, now: datetime) -> tuple[datetime, datetime]:
    return cycle.started_at, cycle.ended_at or now


def _last_phase(unit: CuringUnit, cycle: CuringCycle) -> str | None:
    start, end = _window(cycle, utcnow())
    stages = [segment.stage for segment in unit.stage_changes if start <= segment.started_at <= end]
    return stages[-1] if stages else None


def phase_hours(unit: CuringUnit, cycle: CuringCycle, now: datetime) -> list[dict]:
    """Horas com a secagem ligada em cada fase da estufada, na ordem da cura."""
    start, end = _window(cycle, now)
    totals: dict[str, float] = {}
    for segment in unit.stage_changes:
        begin = max(segment.started_at, start)
        finish = min(segment.ended_at or now, end)
        if finish > begin:
            totals[segment.stage] = totals.get(segment.stage, 0.0) + (finish - begin).total_seconds() / 3600
    ordered = [phase.name for phase in PHASES if phase.name in totals]
    ordered += [stage for stage in totals if stage not in ordered]
    return [
        {"stage": stage, "key": phase.key if (phase := phase_named(stage)) else None, "hours": totals[stage]}
        for stage in ordered
    ]


def _stats(db: Session, unit: CuringUnit, start: datetime, end: datetime) -> dict:
    row = db.query(
        func.count(Reading.id),
        func.min(Reading.temperature),
        func.avg(Reading.temperature),
        func.max(Reading.temperature),
        func.min(Reading.humidity),
        func.avg(Reading.humidity),
        func.max(Reading.humidity),
        func.min(Reading.timestamp),
        func.max(Reading.timestamp),
    ).filter(Reading.curing_unit_id == unit.id, Reading.timestamp >= start, Reading.timestamp <= end).one()
    return dict(zip(
        (
            "count", "temperature_min", "temperature_avg", "temperature_max",
            "humidity_min", "humidity_avg", "humidity_max", "first_at", "last_at",
        ),
        row,
    ))


def cycle_alerts(db: Session, cycle: CuringCycle, now: datetime | None = None):
    """Alertas abertos durante a estufada."""
    start, end = _window(cycle, now or utcnow())
    return db.query(Alert).filter(
        Alert.curing_unit_id == cycle.curing_unit_id, Alert.timestamp >= start, Alert.timestamp <= end,
    )


def serialize_cycle(db: Session, cycle: CuringCycle) -> dict:
    unit = cycle.curing_unit
    now = utcnow()
    start, end = _window(cycle, now)
    phases = phase_hours(unit, cycle, now)
    in_progress = cycle.ended_at is None
    alerts = cycle_alerts(db, cycle, now)
    return {
        "id": cycle.id,
        "curing_unit_id": unit.id,
        "curing_unit_name": unit.name,
        "started_at": cycle.started_at,
        "ended_at": cycle.ended_at,
        "status": cycle.status,
        "final_stage": unit.curing_stage if in_progress else cycle.final_stage,
        "is_drying": in_progress and unit.drying_started_at is not None,
        "drying_hours": sum(item["hours"] for item in phases),
        "phases": phases,
        "stats": _stats(db, unit, start, end),
        "alerts": alerts.count(),
        "critical_alerts": alerts.filter(Alert.severity.in_(("critical", "emergency"))).count(),
    }
