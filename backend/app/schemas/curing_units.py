from datetime import datetime

from pydantic import BaseModel

class CuringUnitCreate(BaseModel):
    name: str = "Estufa"
    curing_stage: str = "Não iniciado"
    device_id: int
    estimated_duration_hours: float | None = None

class CuringUnitUpdate(BaseModel):
    name: str | None = None
    curing_stage: str | None = None
    estimated_duration_hours: float | None = None

class CuringUnitOut(BaseModel):
    id: int
    name: str
    curing_stage: str
    device_id: int
    stage_started_at: datetime
    drying_started_at: datetime | None
    estimated_duration_hours: float | None
    estimated_completion_at: datetime | None = None

    model_config = {"from_attributes": True}
    