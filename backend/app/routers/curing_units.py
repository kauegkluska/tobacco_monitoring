from datetime import datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from dependencies.auth import get_current_user
from dependencies.db import get_db
from dependencies.permissions import get_owned_curing_unit
from models.curing_unit import CuringUnit
from models.device import Device
from models.reading import Reading
from models.user import User
from schemas.curing_units import CuringUnitCreate, CuringUnitOut, CuringUnitUpdate
from schemas.readings import ReadingOut

router = APIRouter()


def serialize_unit(unit: CuringUnit) -> dict:
    result = CuringUnitOut.model_validate(unit).model_dump()
    if unit.drying_started_at is not None and unit.estimated_duration_hours is not None:
        result["estimated_completion_at"] = unit.drying_started_at + timedelta(hours=unit.estimated_duration_hours)
    return result


@router.post("/", response_model=CuringUnitOut)
def create_curing_unit(
    data: CuringUnitCreate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    device = db.query(Device).filter(Device.id == data.device_id).first()
    if not device:
        raise HTTPException(status_code=404, detail="Device not found")
    if device.user_id not in (None, user.id):
        raise HTTPException(status_code=403, detail="Device belongs to another user")

    device.user_id = user.id
    unit = CuringUnit(**data.model_dump())
    db.add(unit)
    db.commit()
    db.refresh(unit)
    return serialize_unit(unit)


@router.post("/{id}/start-drying", response_model=CuringUnitOut)
def start_drying(
    db: Session = Depends(get_db),
    unit: CuringUnit = Depends(get_owned_curing_unit),
):
    now = datetime.utcnow()
    unit.drying_started_at = now
    unit.stage_started_at = now
    if unit.curing_stage == "Não iniciado":
        unit.curing_stage = "Início da secagem"
    db.commit()
    db.refresh(unit)
    return serialize_unit(unit)


@router.post("/{id}/stop-drying", response_model=CuringUnitOut)
def stop_drying(
    db: Session = Depends(get_db),
    unit: CuringUnit = Depends(get_owned_curing_unit),
):
    unit.drying_started_at = None
    db.commit()
    db.refresh(unit)
    return serialize_unit(unit)


@router.get("/", response_model=list[CuringUnitOut])
def get_curing_units(
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    units = db.query(CuringUnit).join(Device).filter(Device.user_id == user.id).all()
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
    if "curing_stage" in changes and changes["curing_stage"] != unit.curing_stage:
        unit.stage_started_at = datetime.utcnow()
    for field, value in changes.items():
        setattr(unit, field, value)
    db.commit()
    db.refresh(unit)
    return serialize_unit(unit)


@router.get("/{id}/readings", response_model=list[ReadingOut])
def get_curing_unit_readings(
    db: Session = Depends(get_db),
    unit: CuringUnit = Depends(get_owned_curing_unit),
):
    return db.query(Reading).filter(Reading.curing_unit_id == unit.id).order_by(Reading.timestamp.desc()).all()


@router.get("/{id}/latest", response_model=ReadingOut)
def get_latest_reading(
    db: Session = Depends(get_db),
    unit: CuringUnit = Depends(get_owned_curing_unit),
):
    reading = db.query(Reading).filter(Reading.curing_unit_id == unit.id).order_by(Reading.timestamp.desc()).first()
    if not reading:
        raise HTTPException(status_code=404, detail="Reading not found")
    return reading


@router.get("/{id}/estimate")
def get_drying_estimate(unit: CuringUnit = Depends(get_owned_curing_unit)):
    completion = None
    if unit.drying_started_at is not None and unit.estimated_duration_hours is not None:
        completion = unit.drying_started_at + timedelta(hours=unit.estimated_duration_hours)
    remaining_hours = None if completion is None else max(0, (completion - datetime.utcnow()).total_seconds() / 3600)
    return {
        "curing_unit_id": unit.id,
        "stage": unit.curing_stage,
        "remaining_hours": remaining_hours,
        "estimated_completion_at": completion,
    }
