from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from dependencies.auth import get_current_user
from dependencies.db import get_db
from models.alert import Alert
from models.curing_cycle import CuringCycle
from models.curing_unit import CuringUnit
from models.user import User
from routers.alerts import serialize_alert
from schemas.curing_cycles import CuringCycleDetail, CuringCycleOut
from services.cycle_service import cycle_alerts, serialize_cycle

router = APIRouter()


def _owned(db: Session, user: User):
    return db.query(CuringCycle).join(CuringUnit, CuringCycle.curing_unit_id == CuringUnit.id).filter(CuringUnit.user_id == user.id)


@router.get("/", response_model=list[CuringCycleOut])
def list_curing_cycles(
    curing_unit_id: int | None = Query(None),
    limit: int = Query(50, ge=1, le=200),
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Últimas secagens (estufadas) de todas as estufas do usuário, da mais nova para a mais antiga."""
    query = _owned(db, user)
    if curing_unit_id is not None:
        query = query.filter(CuringCycle.curing_unit_id == curing_unit_id)
    cycles = query.order_by(CuringCycle.started_at.desc(), CuringCycle.id.desc()).limit(limit).all()
    return [serialize_cycle(db, cycle) for cycle in cycles]


@router.get("/{cycle_id}", response_model=CuringCycleDetail)
def get_curing_cycle(
    cycle_id: int,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    cycle = _owned(db, user).filter(CuringCycle.id == cycle_id).first()
    if not cycle:
        raise HTTPException(status_code=404, detail="Secagem não encontrada")
    result = serialize_cycle(db, cycle)
    alerts = cycle_alerts(db, cycle).order_by(Alert.timestamp.desc()).limit(200).all()
    result["alert_items"] = [serialize_alert(alert) for alert in alerts]
    return result
