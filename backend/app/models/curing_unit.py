from sqlalchemy import Boolean, Column, DateTime, Float, ForeignKey, Integer, String
from sqlalchemy.orm import relationship

from core.clock import utcnow
from core.database import Base


class CuringUnit(Base):
    __tablename__ = "curing_units"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(100), nullable=False, default="Estufa")
    curing_stage = Column(String(50), nullable=False, default="Não iniciado")
    stage_started_at = Column(DateTime, default=utcnow, nullable=False)
    drying_started_at = Column(DateTime, nullable=True)
    estimated_duration_hours = Column(Float, nullable=True)

    user_id = Column(Integer, ForeignKey("users.id"), nullable=True)
    device_id = Column(Integer, ForeignKey("devices.id"), nullable=True)

    # Saídas (relés do sender) comandadas pela API na resposta de cada leitura do gateway.
    # "humidity" é o relé 1 (GPIO2, chave rele_umidade) e "temperature" o relé 2 (GPIO3, rele_temperatura).
    # Modo: "auto" (segue a regra em *_trigger), "on" (ligada) ou "off" (desligada).
    humidity_output_mode = Column(String(10), nullable=False, default="auto")
    temperature_output_mode = Column(String(10), nullable=False, default="auto")
    humidity_output_on = Column(Boolean, nullable=False, default=False)
    temperature_output_on = Column(Boolean, nullable=False, default=False)
    # Nome dado pelo usuário (ex.: "Ventoinhas") e regra do modo automático.
    humidity_output_name = Column(String(40), nullable=False, default="Saída de umidade")
    temperature_output_name = Column(String(40), nullable=False, default="Saída de temperatura")
    humidity_output_trigger = Column(String(20), nullable=False, default="humidity_out")
    temperature_output_trigger = Column(String(20), nullable=False, default="temperature_out")
    # Estado real informado pelo sender (nulo enquanto ele não informar).
    humidity_output_confirmed = Column(Boolean, nullable=True)
    temperature_output_confirmed = Column(Boolean, nullable=True)
    outputs_confirmed_at = Column(DateTime, nullable=True)

    user = relationship("User", back_populates="curing_units")
    device = relationship("Device", back_populates="curing_units")
    readings = relationship("Reading", back_populates="curing_unit")
    alerts = relationship("Alert", back_populates="curing_unit")
    output_events = relationship("OutputEvent", back_populates="curing_unit", cascade="all, delete-orphan")
