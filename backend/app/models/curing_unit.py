from datetime import datetime

from sqlalchemy import Column, DateTime, Float, ForeignKey, Integer, String
from sqlalchemy.orm import relationship
from core.database import Base


class CuringUnit(Base):
    __tablename__ = "curing_units"
    
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(100), nullable=False, default="Estufa")
    curing_stage = Column(String(50), nullable=False, default="Não iniciado")
    stage_started_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    drying_started_at = Column(DateTime, nullable=True)
    estimated_duration_hours = Column(Float, nullable=True)

    device_id = Column(Integer, ForeignKey("devices.id"), nullable=False)

    device = relationship("Device", back_populates="curing_units")
    readings = relationship("Reading", back_populates="curing_unit")
    alerts = relationship("Alert", back_populates="curing_unit")
    