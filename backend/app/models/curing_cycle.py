from sqlalchemy import Column, DateTime, ForeignKey, Index, Integer, String
from sqlalchemy.orm import relationship

from core.database import Base


class CuringCycle(Base):
    """Uma estufada (carga de tabaco), do início da secagem até a cura finalizada ou abandonada.

    Leituras, alertas e fases continuam nas próprias tabelas; a estufada guarda o período e como terminou.
    """

    __tablename__ = "curing_cycles"
    __table_args__ = (Index("ix_curing_cycles_unit_started", "curing_unit_id", "started_at"),)

    id = Column(Integer, primary_key=True, index=True)
    started_at = Column(DateTime, nullable=False)
    # Nulo enquanto a estufada está em andamento (inclusive com a secagem parada no meio).
    ended_at = Column(DateTime, nullable=True)
    # "in_progress", "finished" (cura concluída) ou "stopped" (encerrada antes de concluir).
    status = Column(String(20), nullable=False, default="in_progress")
    # Última fase em que a estufada esteve.
    final_stage = Column(String(50), nullable=True)
    curing_unit_id = Column(Integer, ForeignKey("curing_units.id"), nullable=False)
    curing_unit = relationship("CuringUnit", back_populates="cycles")
