from sqlalchemy import Integer, Column, String, ForeignKey
from sqlalchemy.orm import relationship
from models.device import Device
from models.reading import Reading
from core.database import Base


class CuringUnit(Base):
    __tablename__ = "curing_units"
    
    id = Column(Integer, primary_key=True, index=True)
    curing_stage = Column(String(50))
    
    device_id = Column(Integer, ForeignKey("devices.id"), nullable=False)
    
    device = relationship("Device", back_populates="curing_units")
    
    readings = relationship("Reading", back_populates="curing_unit")
    
    alerts = relationship("Alert", back_populates="curing_unit")
    