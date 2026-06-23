
from sqlalchemy import Integer, Column, String, Float, DateTime, ForeignKey
from sqlalchemy import relationship
from datetime import datetime
from app.core.database import Base


class Reading(Base):
    id = Column(Integer, primary_key=True, index=True)
    temperature = Column(Float, nullable=False)
    humidity = Column(Float, nullable=False)
    timestamp = Column(DateTime, default=datetime.utcnow)
    curing_unit_id = Column(Integer, ForeignKey("curing__unit.id"), nullable=False)
    curing_unit = relationship("CuringUnit", back_populates="readings")
    