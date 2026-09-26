from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from dependencies.auth import get_current_user
from dependencies.db import get_db
from models.curing_unit import CuringUnit
from models.output_event import OutputEvent
from models.user import User
from schemas.outputs import OutputEventOut
from services.output_service import serialize_event

router = APIRouter()


@router.get("/", response_model=list[OutputEventOut])
def list_output_events(
    after_id: int | None = Query(None, description="Somente eventos mais novos que este id"),
    curing_unit_id: int | None = Query(None),
    buzzer: bool | None = Query(None, description="true: só os que tocaram o aviso sonoro"),
    limit: int = Query(50, ge=1, le=500),
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Mudanças nas saídas de todas as estufas do usuário, da mais nova para a mais antiga."""
    query = (
        db.query(OutputEvent)
        .join(CuringUnit, OutputEvent.curing_unit_id == CuringUnit.id)
        .filter(CuringUnit.user_id == user.id)
    )
    if after_id is not None:
        query = query.filter(OutputEvent.id > after_id)
    if curing_unit_id is not None:
        query = query.filter(OutputEvent.curing_unit_id == curing_unit_id)
    if buzzer is not None:
        query = query.filter(OutputEvent.turned_on.is_(buzzer))
    return [serialize_event(event) for event in query.order_by(OutputEvent.id.desc()).limit(limit).all()]
