from fastapi import APIRouter, HTTPException, Depends
from sqlalchemy.orm import Session
from dependencies.db import get_db
from models.reading import Reading
from schemas.readings import ReadingOut, ReadingCreate


router = APIRouter()

@router.post("/readings/", response_model=ReadingOut)
def create_reading(reading: ReadingCreate, db: Session = Depends(get_db)):
    new_reading = Reading(**reading.dict())
    db.add(new_reading)
    db.commit()
    db.refresh(new_reading)
    return new_reading

@router.get("/readings/", response_model=list[ReadingOut])
def get_readings(db: Session = Depends(get_db)):
    readings = db.query(Reading).all()
    return readings