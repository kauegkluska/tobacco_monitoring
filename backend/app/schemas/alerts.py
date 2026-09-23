from datetime import datetime
from pydantic import BaseModel


class AlertOut(BaseModel):
    id: int
    timestamp: datetime
    message: str
    type: str
    is_active: bool
    severity: str
    acknowledged_at: datetime | None
    resolved_at: datetime | None
    curing_unit_id: int

    model_config = {"from_attributes": True}

class AlertCreate(BaseModel):
    type: str
    message: str
    curing_unit_id: int
    is_active: bool = True
    severity: str = "warning"

class AlertActionOut(BaseModel):
    message: str
    alert: AlertOut

