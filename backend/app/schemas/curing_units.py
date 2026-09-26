from pydantic import BaseModel, Field

from schemas.common import UTCDateTime


class CuringUnitCreate(BaseModel):
    name: str = Field("Estufa", min_length=1, max_length=100)
    curing_stage: str = Field("Não iniciado", min_length=1, max_length=50)
    device_id: int | None = None
    estimated_duration_hours: float | None = Field(None, gt=0, le=1000)


class CuringUnitUpdate(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=100)
    curing_stage: str | None = Field(None, min_length=1, max_length=50)
    estimated_duration_hours: float | None = Field(None, gt=0, le=1000)


class CuringUnitOut(BaseModel):
    id: int
    name: str
    curing_stage: str
    device_id: int | None
    stage_started_at: UTCDateTime
    drying_started_at: UTCDateTime | None
    estimated_duration_hours: float | None
    estimated_completion_at: UTCDateTime | None = None
    is_drying: bool = False
    device_code: str | None = None
    device_status: str | None = None

    model_config = {"from_attributes": True}


class DryingEstimateOut(BaseModel):
    curing_unit_id: int
    stage: str
    remaining_hours: float | None
    estimated_completion_at: UTCDateTime | None
