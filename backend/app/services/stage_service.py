"""Troca de fase da cura e condições para sugerir a próxima."""

from datetime import datetime, timedelta

from sqlalchemy import func
from sqlalchemy.orm import Session, object_session

from core.clock import utcnow
from models.curing_unit import CuringUnit
from models.reading import Reading
from models.stage_change import StageChange
from services.phases import (
    DRY_AIR_DEPRESSION_C,
    PHASES,
    VERY_WET_DEPRESSION_C,
    WET_BULB_LOW_MARGIN_C,
    YELLOWING_DEPRESSION_IDEAL_C,
    Phase,
    current_phase,
    flap_setting,
    next_stage,
    phase_index,
    wet_bulb_limit,
)


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


def _wet_bulb_guide(db: Session | None, unit: CuringUnit, phase: Phase, hours: float) -> dict:
    """Referências do bulbo úmido para a tela: as mesmas que guiam o flap e os alertas.

    Amarelação: diferença entre seco e úmido (a faixa acompanha a temperatura). Murchamento e Secagem da folha: do alvo
    do flap menos 2 °C até o teto do alerta "Umidade alta". Secagem do talo: nenhuma, o úmido cai sozinho com a folha seca.
    """
    guide = dict.fromkeys((
        "wet_bulb_target", "wet_bulb_min", "depression_min", "depression_ideal_min", "depression_ideal_max",
        "depression_max",
    ))
    guide["wet_bulb_max"] = wet_bulb_limit(phase)
    if phase.key == "amarelacao":
        guide.update(
            depression_min=VERY_WET_DEPRESSION_C,
            depression_ideal_min=YELLOWING_DEPRESSION_IDEAL_C[0],
            depression_ideal_max=YELLOWING_DEPRESSION_IDEAL_C[1],
            depression_max=DRY_AIR_DEPRESSION_C,
        )
        return guide
    if guide["wet_bulb_max"] is None or db is None:
        return guide
    # O alvo do Murchamento acompanha o bulbo seco, como no controle do flap.
    temperature = (
        db.query(func.coalesce(Reading.filtered_temperature, Reading.temperature))
        .filter(Reading.curing_unit_id == unit.id, Reading.is_outlier.is_(False))
        .order_by(Reading.timestamp.desc(), Reading.id.desc())
        .limit(1)
        .scalar()
    )
    setting = flap_setting(phase, temperature, hours) if temperature is not None else None
    if setting is not None and setting.setpoint is not None:
        guide.update(wet_bulb_target=setting.setpoint, wet_bulb_min=setting.setpoint - WET_BULB_LOW_MARGIN_C)
    return guide


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

    # Faixa, nunca valor único: a duração real depende das folhas.
    later = PHASES[phase_index(phase) + 1:]
    remaining_min = max(0.0, phase.min_hours - hours) + sum(item.min_hours for item in later)
    remaining_max = max(0.0, phase.max_hours - hours) + sum(item.max_hours for item in later)

    return {
        "key": phase.key,
        "name": phase.name,
        "number": phase_index(phase) + 1,
        "total": len(PHASES),
        "temp_min": phase.temp_min,
        "temp_max": phase.temp_max,
        "humidity_min": phase.humidity_min,
        "humidity_max": phase.humidity_max,
        **_wet_bulb_guide(db, unit, phase, hours),
        "min_hours": phase.min_hours,
        "max_hours": phase.max_hours,
        "hours": hours,
        "overdue": hours > phase.max_hours,
        "remaining_hours_min": remaining_min,
        "remaining_hours_max": remaining_max,
        "next_stage": next_stage(phase),
        "ready": all(check["ok"] for check in checks),
        "checks": checks,
        "visual_check": phase.visual_check,
    }
