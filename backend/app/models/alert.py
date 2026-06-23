from sqlalchemy import Integer, Column, String, Boolean, Float, DateTime, ForeignKey
from sqlalchemy import relationship
from datetime import datetime
from app.core.database import Base


class CuringUnit(Base):
    id = Column(Integer, primary_key=True, index=True)
    timestamp = Column(DateTime, default=datetime.utcnow)
    message = Column(String(50))
    type = Column(String(50))
    is_active = Column(Boolean, default=True)
    curing_unit_id = Column(Integer, ForeignKey("curing__unit.id"), nullable=False)
    curing_unit = relationship("CuringUnit", back_populates="readings")
    

    