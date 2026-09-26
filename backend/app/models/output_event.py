from sqlalchemy import Boolean, Column, DateTime, Float, ForeignKey, Index, Integer, String
from sqlalchemy.orm import relationship

from core.clock import utcnow
from core.database import Base


class OutputEvent(Base):
    """Mudança no comando de uma saída. Ao ligar, o gateway toca o aviso sonoro por 2 s."""

    __tablename__ = "output_events"
    __table_args__ = (Index("ix_output_events_unit_id", "curing_unit_id", "id"),)

    id = Column(Integer, primary_key=True, index=True)
    timestamp = Column(DateTime, default=utcnow, nullable=False)
    # "humidity" ou "temperature".
    output = Column(String(20), nullable=False)
    turned_on = Column(Boolean, nullable=False)
    # "auto" (regra da faixa segura) ou "manual" (alterado no app).
    cause = Column(String(10), nullable=False)
    # Leitura que provocou a mudança automática, quando houver: "temperature" (°C) ou "humidity" (%).
    metric = Column(String(20), nullable=True)
    value = Column(Float, nullable=True)
    curing_unit_id = Column(Integer, ForeignKey("curing_units.id"), nullable=False)
    curing_unit = relationship("CuringUnit", back_populates="output_events")
