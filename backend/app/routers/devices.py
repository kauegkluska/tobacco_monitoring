import json
import re
from datetime import datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session

from dependencies.auth import get_current_user
from dependencies.db import get_db
from models.curing_unit import CuringUnit
from models.device import Device
from models.reading import Reading
from models.user import User
from schemas.devices import (
    DeviceCalibrationInput,
    DeviceCreate,
    DeviceOut,
    DeviceThresholdsInput,
    DeviceUpdate,
)

router = APIRouter()


class TelemetryInput(BaseModel):
    mac_address: str | None = None
    device_code: str | None = None
    lora_id: str | None = None
    temperature: float | None = None
    humidity: float | None = None
    battery_level: int | None = None
    rssi: int | None = None
    snr: float | None = None
    curing_unit_id: int | None = None


def _parse_qr_string(raw: str) -> dict:
    result = {}
    raw = raw.strip()
    if raw.startswith("{") and raw.endswith("}"):
        try:
            data = json.loads(raw)
            if "controller_id" in data:
                result["device_code"] = data["controller_id"]
            if "device_code" in data:
                result["device_code"] = data["device_code"]
            if "mac_address" in data:
                result["mac_address"] = data["mac_address"]
            if "lora_id" in data:
                result["lora_id"] = data["lora_id"]
            if "hardware_model" in data:
                result["hardware_model"] = data["hardware_model"]
            return result
        except Exception:
            pass

    mac_match = re.search(r"([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})", raw)
    if mac_match:
        result["mac_address"] = mac_match.group(0).upper()

    lora_match = re.search(r"0x[0-9A-Fa-f]{4,8}", raw)
    if lora_match:
        result["lora_id"] = lora_match.group(0).upper()

    id_match = re.search(r"(?:ID|controller_id|id)=([A-Za-z0-9\-_]+)", raw, re.IGNORECASE)
    if id_match:
        result["device_code"] = id_match.group(1)
    else:
        code_match = re.search(r"(ESP32-[A-Za-z0-9\-_]+)", raw, re.IGNORECASE)
        if code_match:
            result["device_code"] = code_match.group(1)
        elif " " not in raw and len(raw) < 40:
            result["device_code"] = raw

    return result


def _serialize_device(device: Device, db: Session) -> dict:
    unit = db.query(CuringUnit).filter(CuringUnit.device_id == device.id).first()
    
    # Check live online/offline status
    status = "offline"
    if device.last_seen_at:
        if datetime.utcnow() - device.last_seen_at < timedelta(seconds=60):
            status = "online"
    
    return {
        "id": device.id,
        "user_id": device.user_id,
        "device_code": device.device_code or f"ESP32-M{device.id}",
        "mac_address": device.mac_address or "Não configurado",
        "lora_id": device.lora_id or "LoRa AU915",
        "hardware_model": device.hardware_model or "Heltec WiFi LoRa 32 V3",
        "firmware_version": device.firmware_version or "v2.1.0",
        "battery_level": device.battery_level if device.battery_level is not None else 100,
        "battery_status": device.battery_status or ("Normal" if (device.battery_level or 100) > 25 else "Bateria Baixa"),
        "rssi": device.rssi if device.rssi is not None else -60,
        "snr": device.snr if device.snr is not None else 9.5,
        "frequency": device.frequency or "915.0 MHz",
        "temp_min": device.temp_min if device.temp_min is not None else 35.0,
        "temp_max": device.temp_max if device.temp_max is not None else 75.0,
        "humidity_min": device.humidity_min if device.humidity_min is not None else 40.0,
        "humidity_max": device.humidity_max if device.humidity_max is not None else 90.0,
        "calibration_data": device.calibration_data,
        "sensors_config": device.sensors_config or json.dumps([
            {"name": "SHT40 (Temp & Umid)", "type": "SHT40", "status": "Operacional" if status == "online" else "Aguardando"},
        ]),
        "created_at": device.created_at,
        "last_seen_at": device.last_seen_at,
        "status": status,
        "curing_unit_id": unit.id if unit else None,
        "curing_unit_name": unit.name if unit else None,
    }


@router.post("/link", response_model=DeviceOut)
def link_device(
    data: DeviceCreate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    parsed = {}
    if data.raw_qr:
        parsed = _parse_qr_string(data.raw_qr)

    device_code = (data.controller_id or data.device_code or parsed.get("device_code") or "").strip()
    mac_address = (data.mac_address or parsed.get("mac_address") or "").strip().upper() or None
    lora_id = (data.lora_id or parsed.get("lora_id") or "").strip() or None

    device = None
    if data.device_id is not None:
        device = db.query(Device).filter(Device.id == data.device_id).first()
    elif device_code:
        device = db.query(Device).filter(Device.device_code == device_code).first()
    elif mac_address:
        device = db.query(Device).filter(Device.mac_address == mac_address).first()

    now = datetime.utcnow()
    if device:
        if device.user_id not in (None, user.id):
            raise HTTPException(status_code=403, detail="Dispositivo pertence a outro usuário")
        device.user_id = user.id
        if device_code:
            device.device_code = device_code
        if mac_address:
            device.mac_address = mac_address
        if lora_id:
            device.lora_id = lora_id
        device.status = "online"
        device.last_seen_at = now
    else:
        device = Device(
            user_id=user.id,
            device_code=device_code or "ESP32-TOBACCO-01",
            mac_address=mac_address,
            lora_id=lora_id or "0x74C0",
            hardware_model=data.hardware_model or "Heltec WiFi LoRa 32 V3",
            firmware_version="v2.1.0",
            battery_level=100,
            battery_status="Normal",
            rssi=-60,
            snr=9.5,
            frequency="915.0 MHz",
            temp_min=35.0,
            temp_max=75.0,
            humidity_min=40.0,
            humidity_max=90.0,
            status="online",
            last_seen_at=now,
            sensors_config=json.dumps([
                {"name": "SHT40 (Temp & Umid)", "type": "SHT40", "status": "Operacional"},
            ]),
        )
        db.add(device)

    db.commit()
    db.refresh(device)

    # Link to curing unit if provided
    if data.curing_unit_id is not None:
        unit = db.query(CuringUnit).filter(CuringUnit.id == data.curing_unit_id).first()
        if unit:
            unit.device_id = device.id
            db.commit()

    return _serialize_device(device, db)


@router.post("/telemetry")
def receive_telemetry(data: TelemetryInput, db: Session = Depends(get_db)):
    mac = (data.mac_address or "").strip().upper()
    device = None
    if mac:
        device = db.query(Device).filter(Device.mac_address == mac).first()
    if not device and data.device_code:
        device = db.query(Device).filter(Device.device_code == data.device_code.strip()).first()

    now = datetime.utcnow()
    if not device:
        device = Device(
            device_code=data.device_code or "ESP32-LoRa",
            mac_address=mac or "24:6F:28:B1:09:4A",
            lora_id=data.lora_id or "0x74C0",
            status="online",
            last_seen_at=now,
        )
        db.add(device)
        db.commit()
        db.refresh(device)

    device.last_seen_at = now
    device.status = "online"
    if data.battery_level is not None:
        device.battery_level = data.battery_level
    if data.rssi is not None:
        device.rssi = data.rssi
    if data.snr is not None:
        device.snr = data.snr

    # If temperature and humidity are sent, store Reading
    if data.temperature is not None and data.humidity is not None:
        unit = None
        if data.curing_unit_id is not None:
            unit = db.query(CuringUnit).filter(CuringUnit.id == data.curing_unit_id).first()
        if not unit:
            unit = db.query(CuringUnit).filter(CuringUnit.device_id == device.id).first()
        if not unit:
            unit = db.query(CuringUnit).first()
            if not unit:
                unit = CuringUnit(name="Estufa 01", device_id=device.id)
                db.add(unit)
                db.commit()
                db.refresh(unit)

        reading = Reading(
            temperature=data.temperature,
            humidity=data.humidity,
            timestamp=now,
            curing_unit_id=unit.id,
        )
        db.add(reading)

    db.commit()
    return {"status": "success", "device_id": device.id}


@router.get("/", response_model=list[DeviceOut])
def get_devices(
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    devices = db.query(Device).filter(Device.user_id == user.id).all()
    return [_serialize_device(d, db) for d in devices]


@router.get("/{id}", response_model=DeviceOut)
def get_device(
    id: int,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    device = db.query(Device).filter(Device.id == id, Device.user_id == user.id).first()
    if not device:
        raise HTTPException(status_code=404, detail="Dispositivo não encontrado")
    return _serialize_device(device, db)


@router.patch("/{id}", response_model=DeviceOut)
def update_device(
    id: int,
    data: DeviceUpdate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    device = db.query(Device).filter(Device.id == id, Device.user_id == user.id).first()
    if not device:
        raise HTTPException(status_code=404, detail="Dispositivo não encontrado")

    changes = data.model_dump(exclude_unset=True)
    for field, val in changes.items():
        if val is not None:
            setattr(device, field, val)

    db.commit()
    db.refresh(device)
    return _serialize_device(device, db)


@router.post("/{id}/calibrate", response_model=DeviceOut)
def calibrate_device_sensors(
    id: int,
    data: DeviceCalibrationInput,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    device = db.query(Device).filter(Device.id == id, Device.user_id == user.id).first()
    if not device:
        raise HTTPException(status_code=404, detail="Dispositivo não encontrado")

    device.calibration_data = json.dumps(data.model_dump())
    db.commit()
    db.refresh(device)
    return _serialize_device(device, db)


@router.post("/{id}/thresholds", response_model=DeviceOut)
def update_device_thresholds(
    id: int,
    data: DeviceThresholdsInput,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    device = db.query(Device).filter(Device.id == id, Device.user_id == user.id).first()
    if not device:
        raise HTTPException(status_code=404, detail="Dispositivo não encontrado")

    device.temp_min = data.temp_min
    device.temp_max = data.temp_max
    device.humidity_min = data.humidity_min
    device.humidity_max = data.humidity_max
    db.commit()
    db.refresh(device)
    return _serialize_device(device, db)


@router.post("/{id}/reconnect", response_model=DeviceOut)
def reconnect_device(
    id: int,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    device = db.query(Device).filter(Device.id == id, Device.user_id == user.id).first()
    if not device:
        raise HTTPException(status_code=404, detail="Dispositivo não encontrado")

    device.status = "online"
    device.last_seen_at = datetime.utcnow()
    db.commit()
    db.refresh(device)
    return _serialize_device(device, db)


@router.delete("/{id}")
def unlink_device(
    id: int,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    device = db.query(Device).filter(Device.id == id, Device.user_id == user.id).first()
    if not device:
        raise HTTPException(status_code=404, detail="Dispositivo não encontrado")

    units = db.query(CuringUnit).filter(CuringUnit.device_id == device.id).all()
    for unit in units:
        unit.device_id = None

    db.delete(device)
    db.commit()
    return {"status": "success", "message": "Dispositivo desvinculado com sucesso"}
