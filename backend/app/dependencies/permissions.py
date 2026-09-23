from fastapi import Depends, HTTPException
from sqlalchemy.orm import Session

from dependencies.auth import get_current_user
from dependencies.db import get_db
from models.curing_unit import CuringUnit
from models.device import Device
from models.user import User


def get_owned_device(
    device_id: int,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
) -> Device:
    device = db.query(Device).filter(Device.id == device_id, Device.user_id == user.id).first()
    if not device:
        raise HTTPException(status_code=404, detail="Device not found")
    return device


def get_owned_curing_unit(
    id: int,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
) -> CuringUnit:
    unit = (
        db.query(CuringUnit)
        .join(Device, CuringUnit.device_id == Device.id)
        .filter(CuringUnit.id == id, Device.user_id == user.id)
        .first()
    )
    if not unit:
        raise HTTPException(status_code=404, detail="Curing unit not found")
    return unit
