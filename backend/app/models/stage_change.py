from sqlalchemy import Column, DateTime, ForeignKey, Index, Integer, String
from sqlalchemy.orm import relationship

from core.database import Base


class StageChange(Base):
    """Período em que a estufa ficou numa fase da cura, com a secagem ligada (faixas do histórico)."""

    __tablename__ = "stage_changes"
    __table_args__ = (Index("ix_stage_changes_unit_started", "curing_unit_id", "started_at"),)

    id = Column(Integer, primary_key=True, index=True)
    stage = Column(String(50), nullable=False)
    started_at = Column(DateTime, nullable=False)
    # Nulo enquanto a fase está em andamento.
    ended_at = Column(DateTime, nullable=True)
    curing_unit_id = Column(Integer, ForeignKey("curing_units.id"), nullable=False)
    curing_unit = relationship("CuringUnit", back_populates="stage_changes")
