from datetime import datetime
from pydantic import BaseModel


class AlertOut(BaseModel):
    id: int
    timestamp: datetime
    message: str
    type: str
    is_active: bool
    curing_unit_id: int
    
class AlertCreate(BaseModel):
    type: str
    message: str
    curing_unit_id: int
    
