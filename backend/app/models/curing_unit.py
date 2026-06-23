from sqlalchemy import Integer, Column, String, Float, DateTime, ForeignKey
from sqlalchemy import relationship
from datetime import datetime
from app.core.database import Base


class CuringUnit(Base):
    id = Column(Integer, primary_key=True, index=True)
    curing_stage = Column(String(50))
    device_id = Column(Integer, ForeignKey("device.id"), nullable=False)
    device = relationship("Device", back_populates="readings")
    