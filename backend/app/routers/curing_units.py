from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from dependencies.db import get_db
from models.curing_unit import CuringUnit
from schemas.curing_units import CuringUnitOut


router = APIRouter()

@router.get("/curing_units", response_model=list[CuringUnitOut])
def get_curing_units(db: Session = Depends(get_db)):
   units = db.query(CuringUnit).all()
   return units

@router.get("/curing_units/{id}", response_model=CuringUnitOut)
def get_curing_unit(id: int, db: Session = Depends(get_db)):
    unit = db.query(CuringUnit).filter(CuringUnit.id == id).first()
    if not unit:
        raise HTTPException(status_code=404, detail="Curing unit not found")
    return unit