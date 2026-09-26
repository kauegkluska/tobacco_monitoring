from fastapi import HTTPException
from sqlalchemy.orm import Session

from core.clock import utcnow
from models.curing_unit import CuringUnit
from models.device import Device
from models.reading import Reading
from schemas.readings import TelemetryInput
from services.alert_engine import evaluate_reading
from services.device_service import find_device, normalize_code, normalize_mac
from services.output_service import commands, record_confirmation, update_outputs


def _resolve_unit(db: Session, device: Device, requested_unit_id: int | None) -> CuringUnit | None:
    # A estufa informada pelo gateway só é aceita se estiver vinculada a este dispositivo.
    if requested_unit_id is not None:
        unit = (
            db.query(CuringUnit)
            .filter(CuringUnit.id == requested_unit_id, CuringUnit.device_id == device.id)
            .first()
        )
        if unit:
            return unit
    return (
        db.query(CuringUnit)
        .filter(CuringUnit.device_id == device.id)
        .order_by(CuringUnit.id)
        .first()
    )


def ingest_telemetry(db: Session, data: TelemetryInput) -> dict:
    """Registra o sinal de vida do dispositivo e, se possível, grava a leitura na estufa vinculada."""
    code = normalize_code(data.controller_id) or normalize_code(data.device_code)
    mac = normalize_mac(data.mac_address)
    now = utcnow()

    device = find_device(db, device_id=data.device_id, code=code, mac=mac)
    if device is None:
        if data.device_id is not None or not (code or mac):
            raise HTTPException(
                status_code=422,
                detail="Identifique o dispositivo com controller_id, device_code ou mac_address",
            )
        # Dispositivo novo fica sem dono até ser vinculado pelo app (QR code ou cadastro manual).
        device = Device(device_code=code, mac_address=mac, created_at=now)
        db.add(device)
        db.flush()

    device.last_seen_at = now
    device.status = "online"
    if code and not device.device_code:
        device.device_code = code
    if mac and not device.mac_address:
        device.mac_address = mac
    if data.lora_id:
        device.lora_id = data.lora_id.strip()
    if data.firmware_version:
        device.firmware_version = data.firmware_version.strip()
    if data.battery_level is not None:
        device.battery_level = data.battery_level
    if data.rssi is not None:
        device.rssi = data.rssi
    if data.snr is not None:
        device.snr = data.snr

    unit = _resolve_unit(db, device, data.curing_unit_id)
    result = {
        "stored": False,
        "reason": None,
        "device_id": device.id,
        "curing_unit_id": unit.id if unit else None,
        "reading": None,
    }

    def finish(reason: str | None) -> dict:
        db.commit()
        # Comando das saídas para o gateway; ele toca o aviso sonoro quando uma delas liga.
        result.update(commands(unit), reason=reason)
        return result

    if unit is not None:
        record_confirmation(unit, data.output_humidity_state, data.output_temperature_state)

    if unit is None:
        return finish("no_measurement" if data.temperature is None or data.humidity is None else "no_curing_unit")

    if data.temperature is None or data.humidity is None:
        return finish("no_measurement")

    if unit.drying_started_at is None:
        update_outputs(db, unit)
        return finish("drying_not_started")

    reading = Reading(
        temperature=data.temperature,
        humidity=data.humidity,
        timestamp=now,
        curing_unit_id=unit.id,
    )
    db.add(reading)
    db.flush()
    evaluate_reading(db, unit, device, reading)
    update_outputs(db, unit, reading.temperature, reading.humidity)
    result["stored"] = True
    finish(None)
    db.refresh(reading)
    result["reading"] = reading
    return result
