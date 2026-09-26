import json

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from core.clock import utcnow
from dependencies.auth import get_current_user, require_gateway_key
from dependencies.db import get_db
from dependencies.permissions import get_owned_device
from models.curing_unit import CuringUnit
from models.device import Device
from models.user import User
from schemas.devices import (
    DeviceCalibrationInput,
    DeviceCreate,
    DeviceOut,
    DeviceThresholdsInput,
    DeviceUpdate,
)
from schemas.readings import IngestResult, TelemetryInput
from services.device_service import (
    find_device,
    normalize_code,
    normalize_mac,
    parse_qr_string,
    serialize_device,
)
from services.reading_service import ingest_telemetry

router = APIRouter()


@router.post("/link", response_model=DeviceOut)
def link_device(
    data: DeviceCreate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    parsed = parse_qr_string(data.raw_qr) if data.raw_qr else {}

    device_code = normalize_code(data.controller_id) or normalize_code(data.device_code) or normalize_code(parsed.get("device_code"))
    mac_address = normalize_mac(data.mac_address) or normalize_mac(parsed.get("mac_address"))
    lora_id = normalize_code(data.lora_id) or normalize_code(parsed.get("lora_id"))
    hardware_model = normalize_code(data.hardware_model) or normalize_code(parsed.get("hardware_model"))

    unit = None
    if data.curing_unit_id is not None:
        unit = db.query(CuringUnit).filter(CuringUnit.id == data.curing_unit_id, CuringUnit.user_id == user.id).first()
        if not unit:
            raise HTTPException(status_code=404, detail="Estufa não encontrada")

    device = find_device(db, device_id=data.device_id, code=device_code, mac=mac_address)
    if data.device_id is not None and device is None:
        raise HTTPException(status_code=404, detail="Dispositivo não encontrado")

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
        if hardware_model:
            device.hardware_model = hardware_model
    else:
        if not (device_code or mac_address):
            raise HTTPException(status_code=422, detail="Informe o ID do controlador ou o endereço MAC")
        device = Device(
            user_id=user.id,
            device_code=device_code,
            mac_address=mac_address,
            lora_id=lora_id,
            hardware_model=hardware_model or "Heltec WiFi LoRa 32 V3",
            created_at=utcnow(),
            sensors_config=json.dumps([
                {"name": "SHT40 (Temp & Umid)", "type": "SHT40", "status": "Operacional"},
            ]),
        )
        db.add(device)
        db.flush()

    if unit is not None:
        unit.device_id = device.id

    db.commit()
    db.refresh(device)
    return serialize_device(device, db)


@router.post("/telemetry", response_model=IngestResult, dependencies=[Depends(require_gateway_key)])
def receive_telemetry(data: TelemetryInput, db: Session = Depends(get_db)):
    return ingest_telemetry(db, data)


@router.get("/", response_model=list[DeviceOut])
def get_devices(
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    devices = db.query(Device).filter(Device.user_id == user.id).order_by(Device.id).all()
    return [serialize_device(device, db) for device in devices]


@router.get("/{device_id}", response_model=DeviceOut)
def get_device(db: Session = Depends(get_db), device: Device = Depends(get_owned_device)):
    return serialize_device(device, db)


@router.patch("/{device_id}", response_model=DeviceOut)
def update_device(
    data: DeviceUpdate,
    db: Session = Depends(get_db),
    device: Device = Depends(get_owned_device),
):
    changes = data.model_dump(exclude_unset=True, exclude_none=True)
    merged = {name: getattr(device, name) for name in ("temp_min", "temp_max", "humidity_min", "humidity_max")}
    merged.update({key: value for key, value in changes.items() if key in merged})
    try:
        DeviceUpdate(**merged)
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error

    for field, value in changes.items():
        setattr(device, field, value)
    db.commit()
    db.refresh(device)
    return serialize_device(device, db)


@router.post("/{device_id}/calibrate", response_model=DeviceOut)
def calibrate_device_sensors(
    data: DeviceCalibrationInput,
    db: Session = Depends(get_db),
    device: Device = Depends(get_owned_device),
):
    device.calibration_data = json.dumps(data.model_dump())
    db.commit()
    db.refresh(device)
    return serialize_device(device, db)


@router.post("/{device_id}/thresholds", response_model=DeviceOut)
def update_device_thresholds(
    data: DeviceThresholdsInput,
    db: Session = Depends(get_db),
    device: Device = Depends(get_owned_device),
):
    device.temp_min = data.temp_min
    device.temp_max = data.temp_max
    device.humidity_min = data.humidity_min
    device.humidity_max = data.humidity_max
    db.commit()
    db.refresh(device)
    return serialize_device(device, db)


@router.post("/{device_id}/reconnect", response_model=DeviceOut)
def check_device_connection(db: Session = Depends(get_db), device: Device = Depends(get_owned_device)):
    # O status vem das leituras recebidas; aqui só é recalculado, nunca forçado para online.
    return serialize_device(device, db)


@router.delete("/{device_id}")
def unlink_device(
    db: Session = Depends(get_db),
    device: Device = Depends(get_owned_device),
):
    # A estufa e o histórico continuam com o usuário; apenas deixam de receber dados deste dispositivo.
    for unit in db.query(CuringUnit).filter(CuringUnit.device_id == device.id).all():
        unit.device_id = None
    device.user_id = None
    db.commit()
    return {"status": "success", "message": "Dispositivo desvinculado com sucesso"}
