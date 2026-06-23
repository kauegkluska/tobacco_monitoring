from datetime import datetime
from pydantic import BaseModel

class ReadingCreate(BaseModel):
    temperature: float
    humidity: float
    curing_unit_id: int 
    
class ReadingOut(BaseModel):
    id: int
    temperature: float
    humidity: float
    timestamp: datetime
    curing_unit_id: int
    