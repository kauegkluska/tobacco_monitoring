from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from core.clock import utcnow
from dependencies.auth import get_current_user
from dependencies.db import get_db
from dependencies.permissions import get_owned_alert
from models.alert import Alert
from models.curing_unit import CuringUnit
from models.user import User
from schemas.alerts import AlertActionOut, AlertCreate, AlertOut

router = APIRouter()


def serialize_alert(alert: Alert) -> dict:
    result = AlertOut.model_validate(alert).model_dump()
    result["curing_unit_name"] = alert.curing_unit.name if alert.curing_unit else None
    return result


def list_alerts(db: Session, user: User, active: bool | None, limit: int, curing_unit_id: int | None = None) -> list[dict]:
    query = (
        db.query(Alert)
        .join(CuringUnit, Alert.curing_unit_id == CuringUnit.id)
        .filter(CuringUnit.user_id == user.id)
    )
    if curing_unit_id is not None:
        query = query.filter(Alert.curing_unit_id == curing_unit_id)
    if active is not None:
        query = query.filter(Alert.is_active.is_(active))
    alerts = query.order_by(Alert.timestamp.desc()).limit(limit).all()
    return [serialize_alert(alert) for alert in alerts]


@router.post("/", response_model=AlertOut, status_code=201)
def create_alert(
    data: AlertCreate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    unit = db.query(CuringUnit).filter(CuringUnit.id == data.curing_unit_id, CuringUnit.user_id == user.id).first()
    if not unit:
        raise HTTPException(status_code=404, detail="Estufa não encontrada")
    alert = Alert(**data.model_dump(), timestamp=utcnow())
    db.add(alert)
    db.commit()
    db.refresh(alert)
    return serialize_alert(alert)


@router.get("/", response_model=list[AlertOut])
def get_alerts(
    active: bool | None = Query(None, description="true: só ativos; false: só resolvidos; vazio: todos"),
    limit: int = Query(200, ge=1, le=1000),
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    return list_alerts(db, user, active, limit)


@router.get("/{alert_id}", response_model=AlertOut)
def get_alert(alert: Alert = Depends(get_owned_alert)):
    return serialize_alert(alert)


@router.post("/{alert_id}/acknowledge", response_model=AlertActionOut)
def acknowledge_alert(db: Session = Depends(get_db), alert: Alert = Depends(get_owned_alert)):
    if alert.acknowledged_at is None:
        alert.acknowledged_at = utcnow()
        db.commit()
        db.refresh(alert)
    return {"message": "Alerta reconhecido", "alert": serialize_alert(alert)}


@router.post("/{alert_id}/resolve", response_model=AlertActionOut)
def resolve_alert(db: Session = Depends(get_db), alert: Alert = Depends(get_owned_alert)):
    if alert.is_active:
        alert.is_active = False
        alert.resolved_at = utcnow()
        db.commit()
        db.refresh(alert)
    return {"message": "Alerta resolvido", "alert": serialize_alert(alert)}
