from pydantic import BaseModel, Field

from schemas.common import UTCDateTime


class AlertOut(BaseModel):
    id: int
    timestamp: UTCDateTime
    message: str
    type: str
    is_active: bool
    severity: str
    value: float | None = None
    threshold: float | None = None
    acknowledged_at: UTCDateTime | None
    resolved_at: UTCDateTime | None
    curing_unit_id: int
    curing_unit_name: str | None = None

    model_config = {"from_attributes": True}


class AlertCreate(BaseModel):
    type: str = Field(min_length=1, max_length=50)
    message: str = Field(min_length=1, max_length=255)
    curing_unit_id: int
    is_active: bool = True
    severity: str = Field("warning", pattern="^(info|warning|critical|emergency)$")


class AlertActionOut(BaseModel):
    message: str
    alert: AlertOut
