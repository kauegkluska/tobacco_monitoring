from sqlalchemy import Boolean, Column, DateTime, Float, ForeignKey, Index, Integer, String
from sqlalchemy.orm import relationship

from core.clock import utcnow
from core.database import Base


class Alert(Base):
    __tablename__ = "alerts"
    __table_args__ = (Index("ix_alerts_unit_active", "curing_unit_id", "is_active"),)

    id = Column(Integer, primary_key=True, index=True)
    timestamp = Column(DateTime, default=utcnow)
    message = Column(String(255), nullable=False)
    type = Column(String(50), nullable=False)
    is_active = Column(Boolean, default=True, nullable=False)
    severity = Column(String(20), default="warning", nullable=False)
    # Valor medido e limite violado, em °C para temperatura e % para umidade.
    value = Column(Float, nullable=True)
    threshold = Column(Float, nullable=True)
    acknowledged_at = Column(DateTime, nullable=True)
    resolved_at = Column(DateTime, nullable=True)
    curing_unit_id = Column(Integer, ForeignKey("curing_units.id"), nullable=False)
    curing_unit = relationship("CuringUnit", back_populates="alerts")
