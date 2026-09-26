from fastapi import APIRouter, Depends, Query, Response
from sqlalchemy.orm import Session

from dependencies.auth import get_current_user, require_gateway_key
from dependencies.db import get_db
from models.curing_unit import CuringUnit
from models.reading import Reading
from models.user import User
from schemas.readings import IngestResult, ReadingCreate, ReadingOut
from services.reading_service import ingest_telemetry

router = APIRouter()


# "/readings/readings/" é o caminho usado pelo firmware do gateway; "/readings/" é o equivalente curto.
@router.post("/", response_model=IngestResult, dependencies=[Depends(require_gateway_key)])
@router.post("/readings/", response_model=IngestResult, dependencies=[Depends(require_gateway_key)])
def create_reading(reading: ReadingCreate, response: Response, db: Session = Depends(get_db)):
    result = ingest_telemetry(db, reading)
    response.status_code = 201 if result["stored"] else 202
    return result


@router.get("/", response_model=list[ReadingOut])
@router.get("/readings/", response_model=list[ReadingOut], include_in_schema=False)
def get_readings(
    limit: int = Query(200, ge=1, le=5000),
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    return (
        db.query(Reading)
        .join(CuringUnit, Reading.curing_unit_id == CuringUnit.id)
        .filter(CuringUnit.user_id == user.id)
        .order_by(Reading.timestamp.desc())
        .limit(limit)
        .all()
    )
