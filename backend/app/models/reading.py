from sqlalchemy import Boolean, Column, DateTime, Float, ForeignKey, Index, Integer
from sqlalchemy.orm import relationship

from core.clock import utcnow
from core.database import Base


class Reading(Base):
    __tablename__ = "readings"
    __table_args__ = (Index("ix_readings_unit_timestamp", "curing_unit_id", "timestamp"),)

    id = Column(Integer, primary_key=True, index=True)
    temperature = Column(Float, nullable=False)
    humidity = Column(Float, nullable=False)
    # Entrada dos alertas: mediana dos últimos 30 s e bulbo úmido estimado. Nulos em leituras antigas ou descartadas.
    filtered_temperature = Column(Float, nullable=True)
    filtered_humidity = Column(Float, nullable=True)
    filtered_wet_bulb = Column(Float, nullable=True)
    # Salto em relação à amostra anterior: fica no histórico, mas não entra no filtro.
    is_outlier = Column(Boolean, nullable=False, default=False)
    timestamp = Column(DateTime, default=utcnow)
    curing_unit_id = Column(Integer, ForeignKey("curing_units.id"), nullable=False)
    curing_unit = relationship("CuringUnit", back_populates="readings")
