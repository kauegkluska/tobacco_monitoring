from datetime import datetime
from pydantic import BaseModel


class ReadingCreate(BaseModel):
    temperature: float
    humidity: float
    curing_unit_id: int | None = None
    device_id: int | None = None
    controller_id: str | None = None
    mac_address: str | None = None
    device_code: str | None = None
    battery_level: int | None = None
    rssi: int | None = None
    snr: float | None = None


class ReadingOut(BaseModel):
    id: int
    temperature: float
    humidity: float
    timestamp: datetime
    curing_unit_id: int

    model_config = {"from_attributes": True}