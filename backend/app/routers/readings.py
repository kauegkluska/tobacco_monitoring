from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from dependencies.db import get_db
from models.alert import Alert
from models.curing_unit import CuringUnit
from models.device import Device
from models.reading import Reading
from schemas.readings import ReadingCreate, ReadingOut

router = APIRouter()


@router.post("/readings/", response_model=ReadingOut)
def create_reading(reading: ReadingCreate, db: Session = Depends(get_db)):
    unit = None
    if reading.curing_unit_id is not None:
        unit = db.query(CuringUnit).filter(CuringUnit.id == reading.curing_unit_id).first()

    device = None
    target_code = (reading.controller_id or reading.device_code or "").strip()
    if reading.device_id is not None:
        device = db.query(Device).filter(Device.id == reading.device_id).first()
    elif target_code:
        device = db.query(Device).filter(Device.device_code == target_code).first()
    elif reading.mac_address is not None:
        device = db.query(Device).filter(Device.mac_address == reading.mac_address.strip().upper()).first()

    now = datetime.utcnow()

    if unit is None and device is not None:
        unit = db.query(CuringUnit).filter(CuringUnit.device_id == device.id).first()

    if unit is None:
        # Fallback to first curing unit if exists, or create a default one
        unit = db.query(CuringUnit).first()
        if not unit:
            if not device:
                device = Device(
                    device_code=reading.device_code or "ESP32-Principal",
                    mac_address=reading.mac_address or "24:6F:28:B1:09:4A",
                    status="online",
                    last_seen_at=now,
                )
                db.add(device)
                db.commit()
                db.refresh(device)
            unit = CuringUnit(name="Estufa 01", device_id=device.id)
            db.add(unit)
            db.commit()
            db.refresh(unit)

    if device is None and unit.device_id is not None:
        device = db.query(Device).filter(Device.id == unit.device_id).first()

    if device:
        device.last_seen_at = now
        device.status = "online"
        if reading.battery_level is not None:
            device.battery_level = reading.battery_level
        if reading.rssi is not None:
            device.rssi = reading.rssi
        if reading.snr is not None:
            device.snr = reading.snr

    new_reading = Reading(
        temperature=reading.temperature,
        humidity=reading.humidity,
        timestamp=now,
        curing_unit_id=unit.id,
    )
    db.add(new_reading)

    # Check thresholds for alert generation
    if device:
        if device.temp_max and reading.temperature > device.temp_max:
            db.add(Alert(
                curing_unit_id=unit.id,
                message=f"Temperatura alta ({reading.temperature:.1f}°C) acima do limite de {device.temp_max:.1f}°C",
                type="Temperatura Crítica",
                severity="critical",
                is_active=True,
                timestamp=now,
            ))
        elif device.temp_min and reading.temperature < device.temp_min:
            db.add(Alert(
                curing_unit_id=unit.id,
                message=f"Temperatura baixa ({reading.temperature:.1f}°C) abaixo do limite de {device.temp_min:.1f}°C",
                type="Temperatura Baixa",
                severity="warning",
                is_active=True,
                timestamp=now,
            ))

        if device.humidity_max and reading.humidity > device.humidity_max:
            db.add(Alert(
                curing_unit_id=unit.id,
                message=f"Umidade elevada ({reading.humidity:.1f}%) acima do limite de {device.humidity_max:.1f}%",
                type="Umidade Alta",
                severity="warning",
                is_active=True,
                timestamp=now,
            ))

    db.commit()
    db.refresh(new_reading)
    return new_reading


@router.get("/readings/", response_model=list[ReadingOut])
def get_readings(db: Session = Depends(get_db)):
    return db.query(Reading).order_by(Reading.timestamp.desc()).all()
