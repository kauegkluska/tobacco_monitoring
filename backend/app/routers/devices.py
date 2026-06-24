from fastapi import APIRouter, HTTPException, Depends
from sqlalchemy.orm import Session

from dependencies.db import get_db
from models.device import Device
from schemas.devices import DeviceOut, DeviceCreate

router = APIRouter()

@router.post("/devices/link", response_model=DeviceOut)
def link_device(device: DeviceCreate, db: Session = Depends(get_db)):
    new_device = Device(**device.dict())
    db.add(new_device)
    db.commit()
    db.refresh(new_device)
    return new_device

@router.get("/devices/", response_model=list[DeviceOut])
def get_devices(db: Session = Depends(get_db)):
    devices = db.query(Device).all()
    return devices