from fastapi import HTTPException
from sqlalchemy.orm import Session

from core.clock import utcnow
from models.curing_unit import CuringUnit
from models.alert import Alert
from models.device import Device
from models.output_event import OutputEvent
from models.reading import Reading
from schemas.readings import TelemetryInput
from services.alert_engine import evaluate_reading
from services.device_service import find_device, normalize_code, normalize_mac
from services.output_service import commands, record_confirmation, update_outputs
from services.sensor_correction import correct


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


def _buzzer(db: Session, device: Device, unit: CuringUnit | None, now) -> bool:
    """Se o gateway deve tocar o aviso: saída ligada pelo app ou alerta de atenção ou mais grave desde o último aviso."""
    since, device.buzzer_checked_at = device.buzzer_checked_at, now
    if unit is None or since is None:
        return False
    manual = (
        db.query(OutputEvent.id)
        .filter(
            OutputEvent.curing_unit_id == unit.id,
            OutputEvent.timestamp > since,
            OutputEvent.turned_on.is_(True),
            OutputEvent.cause == "manual",
        )
        .first()
    )
    alert = (
        db.query(Alert.id)
        .filter(Alert.curing_unit_id == unit.id, Alert.timestamp > since, Alert.severity != "info")
        .first()
    )
    return manual is not None or alert is not None


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
    # Pacote repetido: o mesmo contador do anterior. Um contador menor é o sender reiniciado e vale normalmente.
    duplicate = data.packet_number is not None and data.packet_number == device.last_packet_number
    if data.packet_number is not None:
        device.last_packet_number = data.packet_number

    unit = _resolve_unit(db, device, data.curing_unit_id)
    result = {
        "stored": False,
        "reason": None,
        "device_id": device.id,
        "curing_unit_id": unit.id if unit else None,
        "reading": None,
    }

    def finish(reason: str | None) -> dict:
        # Depois do motor de alertas e das saídas, para o aviso já considerar o que esta leitura abriu.
        aviso = _buzzer(db, device, unit, now)
        db.commit()
        result.update(commands(unit), aviso=aviso, reason=reason)
        return result

    if duplicate:
        return finish("duplicate")

    if unit is not None:
        record_confirmation(unit, data.output_humidity_state, data.output_temperature_state)

    if unit is None:
        return finish("no_measurement" if data.temperature is None or data.humidity is None else "no_curing_unit")

    if data.temperature is None or data.humidity is None:
        return finish("no_measurement")

    if unit.drying_started_at is None:
        update_outputs(db, unit)
        return finish("drying_not_started")

    # TEMPORÁRIO: posição do SHT40 no teste em campo (services/sensor_correction.py).
    temperature, humidity = correct(data.temperature, data.humidity)
    reading = Reading(
        temperature=temperature,
        humidity=humidity,
        timestamp=now,
        curing_unit_id=unit.id,
        device_id=device.id,
    )
    db.add(reading)
    db.flush()
    evaluate_reading(db, unit, device, reading)
    # Depois do motor de alertas, que grava a mediana de 30 s e marca os saltos.
    update_outputs(db, unit, reading)
    result["stored"] = True
    finish(None)
    db.refresh(reading)
    result["reading"] = reading
    return result
