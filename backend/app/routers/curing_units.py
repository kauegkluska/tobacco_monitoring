import math
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import StreamingResponse
from sqlalchemy import Integer, cast, func
from sqlalchemy.orm import Session

from core.clock import utcnow
from dependencies.auth import get_current_user
from dependencies.db import get_db
from dependencies.permissions import get_owned_curing_unit
from models.curing_unit import CuringUnit
from models.device import Device
from models.reading import Reading
from models.user import User
from routers.alerts import list_alerts
from schemas.alerts import AlertOut
from schemas.curing_units import CuringUnitCreate, CuringUnitOut, CuringUnitUpdate, DryingEstimateOut
from schemas.outputs import OutputsOut, OutputsUpdate
from schemas.readings import ReadingOut, SeriesOut
from services.device_service import device_status
from services.output_service import describe, recent_reading, update_outputs
from services.phases import FINISHED, NOT_STARTED, PHASES, current_phase, next_stage, phase_named
from services.stage_service import change_stage, close_segment, open_segment, phase_status

router = APIRouter()


def _completion(unit: CuringUnit) -> datetime | None:
    if unit.drying_started_at is None or unit.estimated_duration_hours is None:
        return None
    return unit.drying_started_at + timedelta(hours=unit.estimated_duration_hours)


def serialize_unit(unit: CuringUnit) -> dict:
    result = CuringUnitOut.model_validate(unit).model_dump()
    result["estimated_completion_at"] = _completion(unit)
    result["is_drying"] = unit.drying_started_at is not None
    result["phase"] = phase_status(unit)
    if unit.device is not None:
        result["device_code"] = unit.device.device_code
        result["device_status"] = device_status(unit.device)
    return result


def _claim_device(db: Session, device_id: int, user: User) -> Device:
    device = db.query(Device).filter(Device.id == device_id).first()
    if not device:
        raise HTTPException(status_code=404, detail="Dispositivo não encontrado")
    if device.user_id not in (None, user.id):
        raise HTTPException(status_code=403, detail="Dispositivo pertence a outro usuário")
    device.user_id = user.id
    return device


@router.post("/", response_model=CuringUnitOut, status_code=201)
def create_curing_unit(
    data: CuringUnitCreate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    if data.device_id is not None:
        _claim_device(db, data.device_id, user)

    unit = CuringUnit(**data.model_dump(), user_id=user.id, stage_started_at=utcnow())
    db.add(unit)
    db.commit()
    db.refresh(unit)
    return serialize_unit(unit)


@router.get("/", response_model=list[CuringUnitOut])
def get_curing_units(
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    units = db.query(CuringUnit).filter(CuringUnit.user_id == user.id).order_by(CuringUnit.id).all()
    return [serialize_unit(unit) for unit in units]


@router.get("/{id}", response_model=CuringUnitOut)
def get_curing_unit(unit: CuringUnit = Depends(get_owned_curing_unit)):
    return serialize_unit(unit)


@router.patch("/{id}", response_model=CuringUnitOut)
def update_curing_unit(
    data: CuringUnitUpdate,
    db: Session = Depends(get_db),
    unit: CuringUnit = Depends(get_owned_curing_unit),
):
    changes = data.model_dump(exclude_unset=True)
    stage = changes.pop("curing_stage", None)
    for field, value in changes.items():
        if field == "name" and value is None:
            continue
        setattr(unit, field, value)
    if stage is not None and stage != unit.curing_stage:
        now = utcnow()
        if stage in (NOT_STARTED, FINISHED) and unit.drying_started_at is not None:
            _stop(db, unit, now)
        change_stage(unit, stage, now)
        if unit.drying_started_at is not None:
            _refresh_outputs(db, unit)
    db.commit()
    db.refresh(unit)
    return serialize_unit(unit)


def _refresh_outputs(db: Session, unit: CuringUnit) -> None:
    """Reaplica o automático das saídas com a faixa da fase atual e a última leitura."""
    reading = recent_reading(db, unit)
    update_outputs(db, unit, reading.temperature if reading else None, reading.humidity if reading else None)


def _stop(db: Session, unit: CuringUnit, now) -> None:
    close_segment(unit, now)
    unit.drying_started_at = None
    # Saídas automáticas desligam junto com a secagem.
    update_outputs(db, unit)


@router.delete("/{id}")
def delete_curing_unit(
    db: Session = Depends(get_db),
    unit: CuringUnit = Depends(get_owned_curing_unit),
):
    if db.query(Reading.id).filter(Reading.curing_unit_id == unit.id).first() or unit.alerts:
        raise HTTPException(status_code=409, detail="A estufa possui histórico de leituras e não pode ser excluída")
    db.delete(unit)
    db.commit()
    return {"message": "Estufa excluída"}


@router.post("/{id}/start-drying", response_model=CuringUnitOut)
def start_drying(
    db: Session = Depends(get_db),
    unit: CuringUnit = Depends(get_owned_curing_unit),
):
    """Liga a secagem. Uma estufa nova (ou finalizada) começa na primeira fase, a Amarelação."""
    if unit.drying_started_at is not None:
        return serialize_unit(unit)
    now = utcnow()
    unit.drying_started_at = now
    if phase_named(unit.curing_stage) is None:
        unit.curing_stage = PHASES[0].name
        unit.stage_started_at = now
    # Retomada: continua na mesma fase, com um novo trecho no histórico.
    open_segment(unit, now)
    update_outputs(db, unit)
    db.commit()
    db.refresh(unit)
    return serialize_unit(unit)


@router.post("/{id}/stop-drying", response_model=CuringUnitOut)
def stop_drying(
    db: Session = Depends(get_db),
    unit: CuringUnit = Depends(get_owned_curing_unit),
):
    _stop(db, unit, utcnow())
    db.commit()
    db.refresh(unit)
    return serialize_unit(unit)


@router.post("/{id}/advance-stage", response_model=CuringUnitOut)
def advance_stage(
    db: Session = Depends(get_db),
    unit: CuringUnit = Depends(get_owned_curing_unit),
):
    """Passa para a próxima fase. Depois da Secagem do talo, a cura é finalizada e a secagem para."""
    phase = current_phase(unit)
    if phase is None:
        raise HTTPException(status_code=409, detail="Inicie a secagem antes de avançar de fase")
    now = utcnow()
    stage = next_stage(phase)
    if stage == FINISHED:
        _stop(db, unit, now)
        change_stage(unit, stage, now)
    else:
        change_stage(unit, stage, now)
        _refresh_outputs(db, unit)
    db.commit()
    db.refresh(unit)
    return serialize_unit(unit)


@router.get("/{id}/readings", response_model=list[ReadingOut])
def get_curing_unit_readings(
    since: datetime | None = Query(None, description="Somente leituras a partir desta data (ISO 8601)"),
    limit: int = Query(500, ge=1, le=5000),
    db: Session = Depends(get_db),
    unit: CuringUnit = Depends(get_owned_curing_unit),
):
    query = db.query(Reading).filter(Reading.curing_unit_id == unit.id)
    if since is not None:
        query = query.filter(Reading.timestamp >= _naive_utc(since))
    return query.order_by(Reading.timestamp.desc()).limit(limit).all()


def _naive_utc(value: datetime | None) -> datetime | None:
    if value is not None and value.tzinfo is not None:
        return value.astimezone(timezone.utc).replace(tzinfo=None)
    return value


@router.get("/{id}/series", response_model=SeriesOut)
def get_curing_unit_series(
    since: datetime | None = Query(None, description="Início do período (padrão: 24 h atrás)"),
    until: datetime | None = Query(None, description="Fim do período (padrão: agora)"),
    points: int = Query(240, ge=10, le=2000, description="Quantidade máxima de pontos no gráfico"),
    db: Session = Depends(get_db),
    unit: CuringUnit = Depends(get_owned_curing_unit),
):
    """Leituras agrupadas em intervalos iguais, para gráficos de períodos longos."""
    until = _naive_utc(until) or utcnow()
    since = _naive_utc(since) or until - timedelta(hours=24)
    if since >= until:
        raise HTTPException(status_code=422, detail="O início do período deve ser anterior ao fim")

    bucket_seconds = max(1, math.ceil((until - since).total_seconds() / points))
    in_range = (
        Reading.curing_unit_id == unit.id,
        Reading.timestamp >= since,
        Reading.timestamp <= until,
    )
    epoch = cast(func.strftime("%s", Reading.timestamp), Integer)
    # op("/") mantém a divisão inteira do SQLite (o operador "/" do SQLAlchemy vira divisão real).
    bucket = epoch.op("/")(bucket_seconds).label("bucket")
    rows = (
        db.query(
            bucket,
            func.avg(Reading.temperature),
            func.min(Reading.temperature),
            func.max(Reading.temperature),
            func.avg(Reading.humidity),
            func.min(Reading.humidity),
            func.max(Reading.humidity),
            func.count(Reading.id),
        )
        .filter(*in_range)
        .group_by(bucket)
        .order_by(bucket)
        .all()
    )
    series = [
        {
            # Centro do intervalo, para o ponto ficar alinhado ao período que representa.
            "timestamp": datetime.fromtimestamp(int(row[0]) * bucket_seconds + bucket_seconds / 2, tz=timezone.utc),
            "temperature": row[1],
            "temperature_min": row[2],
            "temperature_max": row[3],
            "humidity": row[4],
            "humidity_min": row[5],
            "humidity_max": row[6],
            "count": row[7],
        }
        for row in rows
    ]

    totals = db.query(
        func.count(Reading.id),
        func.min(Reading.temperature),
        func.avg(Reading.temperature),
        func.max(Reading.temperature),
        func.min(Reading.humidity),
        func.avg(Reading.humidity),
        func.max(Reading.humidity),
        func.min(Reading.timestamp),
        func.max(Reading.timestamp),
    ).filter(*in_range).one()
    stats = dict(zip(
        (
            "count", "temperature_min", "temperature_avg", "temperature_max",
            "humidity_min", "humidity_avg", "humidity_max", "first_at", "last_at",
        ),
        totals,
    ))

    return {
        "curing_unit_id": unit.id,
        "since": since,
        "until": until,
        "bucket_seconds": bucket_seconds,
        "points": series,
        "stats": stats,
        "phases": _phases_between(unit, since, until),
    }


def _phases_between(unit: CuringUnit, since: datetime, until: datetime) -> list[dict]:
    """Fases que aparecem no período, para colorir o fundo do gráfico."""
    now = utcnow()
    result = []
    for change in unit.stage_changes:
        end = change.ended_at or now
        if change.started_at >= until or end <= since:
            continue
        phase = phase_named(change.stage)
        result.append({
            "stage": change.stage,
            "key": phase.key if phase else None,
            "started_at": max(change.started_at, since),
            "ended_at": min(end, until),
            "temp_min": phase.temp_min if phase else None,
            "temp_max": phase.temp_max if phase else None,
            "humidity_min": phase.humidity_min if phase else None,
            "humidity_max": phase.humidity_max if phase else None,
        })
    return result


def _decimal(value: float) -> str:
    # Vírgula decimal e ";" como separador abrem direto no Excel em português.
    return f"{value:.2f}".replace(".", ",")


@router.get("/{id}/readings.csv")
def export_curing_unit_readings(
    since: datetime | None = Query(None),
    until: datetime | None = Query(None),
    db: Session = Depends(get_db),
    unit: CuringUnit = Depends(get_owned_curing_unit),
):
    query = db.query(Reading).filter(Reading.curing_unit_id == unit.id)
    if since is not None:
        query = query.filter(Reading.timestamp >= _naive_utc(since))
    if until is not None:
        query = query.filter(Reading.timestamp <= _naive_utc(until))
    query = query.order_by(Reading.timestamp)

    def rows():
        yield "﻿data_hora_utc;temperatura_c;temperatura_f;umidade_pct\r\n"
        for reading in query.yield_per(1000):
            yield (
                f"{reading.timestamp.isoformat(sep=' ', timespec='seconds')};"
                f"{_decimal(reading.temperature)};{_decimal(reading.temperature * 9 / 5 + 32)};"
                f"{_decimal(reading.humidity)}\r\n"
            )

    filename = f"leituras-estufa-{unit.id}.csv"
    return StreamingResponse(
        rows(),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@router.get("/{id}/latest", response_model=ReadingOut)
def get_latest_reading(
    db: Session = Depends(get_db),
    unit: CuringUnit = Depends(get_owned_curing_unit),
):
    reading = db.query(Reading).filter(Reading.curing_unit_id == unit.id).order_by(Reading.timestamp.desc()).first()
    if not reading:
        raise HTTPException(status_code=404, detail="Nenhuma leitura encontrada")
    return reading


@router.get("/{id}/alerts", response_model=list[AlertOut])
def get_curing_unit_alerts(
    active: bool | None = Query(None),
    limit: int = Query(200, ge=1, le=1000),
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
    unit: CuringUnit = Depends(get_owned_curing_unit),
):
    return list_alerts(db, user, active, limit, curing_unit_id=unit.id)


@router.get("/{id}/estimate", response_model=DryingEstimateOut)
def get_drying_estimate(unit: CuringUnit = Depends(get_owned_curing_unit)):
    completion = _completion(unit)
    remaining_hours = None if completion is None else max(0, (completion - utcnow()).total_seconds() / 3600)
    return {
        "curing_unit_id": unit.id,
        "stage": unit.curing_stage,
        "remaining_hours": remaining_hours,
        "estimated_completion_at": completion,
    }


@router.get("/{id}/outputs", response_model=OutputsOut)
def get_outputs(
    events: int = Query(10, ge=0, le=200),
    db: Session = Depends(get_db),
    unit: CuringUnit = Depends(get_owned_curing_unit),
):
    """Comando atual das saídas de umidade e temperatura e as últimas mudanças (avisos sonoros)."""
    return describe(db, unit, events)


@router.patch("/{id}/outputs", response_model=OutputsOut)
def update_output_modes(
    data: OutputsUpdate,
    db: Session = Depends(get_db),
    unit: CuringUnit = Depends(get_owned_curing_unit),
):
    """Troca nome, regra ou modo das saídas. O gateway recebe o novo comando na resposta da próxima leitura."""
    for output in ("humidity", "temperature"):
        for field in ("mode", "name", "trigger"):
            value = getattr(data, f"{output}_{field}")
            if value is not None:
                setattr(unit, f"{output}_output_{field}", value)
    _refresh_outputs(db, unit)
    db.commit()
    db.refresh(unit)
    return describe(db, unit)
