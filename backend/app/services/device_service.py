import json
import re
from datetime import datetime, timedelta

from sqlalchemy.orm import Session

from core.clock import utcnow
from core.config import settings
from models.curing_unit import CuringUnit
from models.device import Device

LOW_BATTERY_LEVEL = 25


def normalize_mac(value: str | None) -> str | None:
    value = (value or "").strip().upper().replace("-", ":")
    return value or None


def normalize_code(value: str | None) -> str | None:
    value = (value or "").strip()
    return value or None


def find_device(
    db: Session,
    device_id: int | None = None,
    code: str | None = None,
    mac: str | None = None,
) -> Device | None:
    if device_id is not None:
        return db.query(Device).filter(Device.id == device_id).first()
    if code:
        device = db.query(Device).filter(Device.device_code == code).first()
        if device:
            return device
    if mac:
        return db.query(Device).filter(Device.mac_address == mac).first()
    return None


def device_status(device: Device, now: datetime | None = None) -> str:
    if device.last_seen_at is None:
        return "offline"
    now = now or utcnow()
    limit = timedelta(seconds=settings.DEVICE_OFFLINE_SECONDS)
    return "online" if now - device.last_seen_at < limit else "offline"


def battery_status(level: int | None) -> str | None:
    if level is None:
        return None
    return "Normal" if level > LOW_BATTERY_LEVEL else "Bateria Baixa"


def serialize_device(device: Device, db: Session) -> dict:
    unit = (
        db.query(CuringUnit)
        .filter(CuringUnit.device_id == device.id, CuringUnit.user_id == device.user_id)
        .order_by(CuringUnit.id)
        .first()
    )
    status = device_status(device)

    return {
        "id": device.id,
        "user_id": device.user_id,
        "device_code": device.device_code or f"ESP32-M{device.id}",
        "mac_address": device.mac_address,
        "lora_id": device.lora_id,
        "hardware_model": device.hardware_model,
        "firmware_version": device.firmware_version,
        "battery_level": device.battery_level,
        "battery_status": battery_status(device.battery_level),
        "rssi": device.rssi,
        "snr": device.snr,
        "frequency": device.frequency,
        "temp_min": device.temp_min,
        "temp_max": device.temp_max,
        "humidity_min": device.humidity_min,
        "humidity_max": device.humidity_max,
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


def parse_qr_string(raw: str) -> dict:
    result = {}
    raw = raw.strip()
    if raw.startswith("{") and raw.endswith("}"):
        try:
            data = json.loads(raw)
        except ValueError:
            data = None
        if isinstance(data, dict):
            for source, target in (
                ("controller_id", "device_code"),
                ("device_code", "device_code"),
                ("mac_address", "mac_address"),
                ("lora_id", "lora_id"),
                ("hardware_model", "hardware_model"),
            ):
                if data.get(source):
                    result[target] = str(data[source])
            return result

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
