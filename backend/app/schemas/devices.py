from datetime import datetime
from typing import Any
from pydantic import BaseModel


class DeviceOut(BaseModel):
    id: int
    user_id: int | None = None
    device_code: str | None = None
    mac_address: str | None = None
    lora_id: str | None = None
    hardware_model: str | None = None
    firmware_version: str | None = None
    battery_level: int | None = 100
    battery_status: str | None = "Normal"
    rssi: int | None = -64
    snr: float | None = 9.5
    frequency: str | None = "915.0 MHz"
    temp_min: float | None = 35.0
    temp_max: float | None = 75.0
    humidity_min: float | None = 40.0
    humidity_max: float | None = 90.0
    calibration_data: str | None = None
    sensors_config: str | None = None
    created_at: datetime
    last_seen_at: datetime | None = None
    status: str = "offline"
    curing_unit_id: int | None = None
    curing_unit_name: str | None = None

    model_config = {"from_attributes": True}


class DeviceCreate(BaseModel):
    device_id: int | None = None
    controller_id: str | None = None
    device_code: str | None = None
    mac_address: str | None = None
    lora_id: str | None = None
    hardware_model: str | None = None
    curing_unit_id: int | None = None
    raw_qr: str | None = None


class DeviceUpdate(BaseModel):
    device_code: str | None = None
    temp_min: float | None = None
    temp_max: float | None = None
    humidity_min: float | None = None
    humidity_max: float | None = None


class DeviceCalibrationInput(BaseModel):
    dry_probe_offset: float = 0.0
    wet_probe_offset: float = 0.0
    humidity_offset: float = 0.0
    flame_sensitivity: int = 80


class DeviceThresholdsInput(BaseModel):
    temp_min: float = 35.0
    temp_max: float = 75.0
    humidity_min: float = 40.0
    humidity_max: float = 90.0