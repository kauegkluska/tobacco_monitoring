from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from dependencies.auth import get_current_user
from dependencies.db import get_db
from models.alert import Alert
from models.curing_unit import CuringUnit
from models.device import Device
from models.user import User
from schemas.alerts import AlertActionOut, AlertCreate, AlertOut

router = APIRouter()


def owned_alert(alert_id: int, db: Session, user: User) -> Alert:
    alert = (
        db.query(Alert)
        .join(CuringUnit, Alert.curing_unit_id == CuringUnit.id)
        .join(Device, CuringUnit.device_id == Device.id)
        .filter(Alert.id == alert_id, Device.user_id == user.id)
        .first()
    )
    if not alert:
        raise HTTPException(status_code=404, detail="Alert not found")
    return alert


@router.post("/alerts", response_model=AlertOut)
def create_alert(
    data: AlertCreate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    unit = (
        db.query(CuringUnit)
        .join(Device)
        .filter(CuringUnit.id == data.curing_unit_id, Device.user_id == user.id)
        .first()
    )
    if not unit:
        raise HTTPException(status_code=404, detail="Curing unit not found")
    alert = Alert(**data.model_dump())
    db.add(alert)
    db.commit()
    db.refresh(alert)
    return alert


@router.get("/alerts", response_model=list[AlertOut])
def get_alerts(db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    return (
        db.query(Alert)
        .join(CuringUnit)
        .join(Device)
        .filter(Device.user_id == user.id)
        .order_by(Alert.timestamp.desc())
        .all()
    )


@router.get("/alerts/{alert_id}", response_model=AlertOut)
def get_alert(alert_id: int, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    return owned_alert(alert_id, db, user)


@router.post("/alerts/{alert_id}/acknowledge", response_model=AlertActionOut)
def acknowledge_alert(alert_id: int, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    alert = owned_alert(alert_id, db, user)
    alert.acknowledged_at = datetime.utcnow()
    db.commit()
    db.refresh(alert)
    return {"message": "Alert acknowledged", "alert": alert}


@router.post("/alerts/{alert_id}/resolve", response_model=AlertActionOut)
def resolve_alert(alert_id: int, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    alert = owned_alert(alert_id, db, user)
    alert.is_active = False
    alert.resolved_at = datetime.utcnow()
    db.commit()
    db.refresh(alert)
    return {"message": "Alert resolved", "alert": alert}


@router.get("/curing_units/{curing_unit_id}/alerts", response_model=list[AlertOut])
def get_curing_unit_alerts(
    curing_unit_id: int,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    unit = (
        db.query(CuringUnit)
        .join(Device)
        .filter(CuringUnit.id == curing_unit_id, Device.user_id == user.id)
        .first()
    )
    if not unit:
        raise HTTPException(status_code=404, detail="Curing unit not found")
    return db.query(Alert).filter(Alert.curing_unit_id == curing_unit_id).order_by(Alert.timestamp.desc()).all()
