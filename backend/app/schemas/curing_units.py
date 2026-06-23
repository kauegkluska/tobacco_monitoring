from pydantic import BaseModel

class CuringUnitOut(BaseModel):
    id:int
    curing_stage: str
    device_id: int
    