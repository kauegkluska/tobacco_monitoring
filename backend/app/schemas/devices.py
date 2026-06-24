
from pydantic import BaseModel

class DeviceOut(BaseModel):
    id: int
    user_id:int
    
class DeviceCreate(BaseModel):
    user_id: int