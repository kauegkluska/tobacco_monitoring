from pydantic import BaseModel, Field, model_validator

from schemas.common import UTCDateTime


class DeviceOut(BaseModel):
    id: int
    user_id: int | None = None
    device_code: str | None = None
    mac_address: str | None = None
    lora_id: str | None = None
    hardware_model: str | None = None
    firmware_version: str | None = None
    battery_level: int | None = None
    battery_status: str | None = None
    rssi: int | None = None
    snr: float | None = None
    frequency: str | None = None
    temp_min: float | None = None
    temp_max: float | None = None
    humidity_min: float | None = None
    humidity_max: float | None = None
    calibration_data: str | None = None
    sensors_config: str | None = None
    created_at: UTCDateTime
    last_seen_at: UTCDateTime | None = None
    status: str = "offline"
    curing_unit_id: int | None = None
    curing_unit_name: str | None = None

    model_config = {"from_attributes": True}


class DeviceCreate(BaseModel):
    device_id: int | None = None
    controller_id: str | None = Field(None, max_length=100)
    device_code: str | None = Field(None, max_length=100)
    mac_address: str | None = Field(None, max_length=50)
    lora_id: str | None = Field(None, max_length=50)
    hardware_model: str | None = Field(None, max_length=100)
    curing_unit_id: int | None = None
    raw_qr: str | None = Field(None, max_length=500)


def _check_ranges(model):
    if model.temp_min is not None and model.temp_max is not None and model.temp_min >= model.temp_max:
        raise ValueError("A temperatura mínima deve ser menor que a máxima")
    if model.humidity_min is not None and model.humidity_max is not None and model.humidity_min >= model.humidity_max:
        raise ValueError("A umidade mínima deve ser menor que a máxima")
    return model


class DeviceUpdate(BaseModel):
    device_code: str | None = Field(None, min_length=1, max_length=100)
    temp_min: float | None = Field(None, ge=-40, le=125)
    temp_max: float | None = Field(None, ge=-40, le=125)
    humidity_min: float | None = Field(None, ge=0, le=100)
    humidity_max: float | None = Field(None, ge=0, le=100)

    @model_validator(mode="after")
    def check_ranges(self):
        return _check_ranges(self)


class DeviceCalibrationInput(BaseModel):
    dry_probe_offset: float = Field(0.0, ge=-20, le=20)
    wet_probe_offset: float = Field(0.0, ge=-20, le=20)
    humidity_offset: float = Field(0.0, ge=-20, le=20)
    flame_sensitivity: int = Field(80, ge=0, le=100)


class DeviceThresholdsInput(BaseModel):
    temp_min: float = Field(35.0, ge=-40, le=125)
    temp_max: float = Field(75.0, ge=-40, le=125)
    humidity_min: float = Field(40.0, ge=0, le=100)
    humidity_max: float = Field(90.0, ge=0, le=100)

    @model_validator(mode="after")
    def check_ranges(self):
        return _check_ranges(self)
