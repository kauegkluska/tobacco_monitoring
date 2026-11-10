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
    # Início do trecho atual com a secagem ligada (nulo com a secagem parada).
    drying_started_at = Column(DateTime, nullable=True)
    # Início da estufada (carga de tabaco) atual; continua o mesmo quando a secagem é parada e retomada.
    cycle_started_at = Column(DateTime, nullable=True)
    estimated_duration_hours = Column(Float, nullable=True)

    user_id = Column(Integer, ForeignKey("users.id"), nullable=True)
    device_id = Column(Integer, ForeignKey("devices.id"), nullable=True)

    # Saídas (relés do sender) comandadas pela API na resposta de cada leitura do gateway.
    # "humidity" é o relé 1 (GPIO2, chave rele_umidade, o flap) e "temperature" o relé 2 (GPIO3, rele_temperatura,
    # o soprador da fornalha).
    # Modo: "auto" (segue a regra em *_trigger), "on" (ligada) ou "off" (desligada).
    humidity_output_mode = Column(String(10), nullable=False, default="auto")
    temperature_output_mode = Column(String(10), nullable=False, default="auto")
    humidity_output_on = Column(Boolean, nullable=False, default=False)
    temperature_output_on = Column(Boolean, nullable=False, default=False)
    # Nome dado pelo usuário e regra do modo automático.
    humidity_output_name = Column(String(40), nullable=False, default="Flap")
    temperature_output_name = Column(String(40), nullable=False, default="Soprador")
    humidity_output_trigger = Column(String(20), nullable=False, default="humidity_phase")
    temperature_output_trigger = Column(String(20), nullable=False, default="temperature_target")
    # Temperatura alvo em °C, definida pelo produtor: na regra "temperature_target" a saída liga abaixo dela.
    target_temperature = Column(Float, nullable=True)
    # Estado real informado pelo sender (nulo enquanto ele não informar).
    humidity_output_confirmed = Column(Boolean, nullable=True)
    temperature_output_confirmed = Column(Boolean, nullable=True)
    outputs_confirmed_at = Column(DateTime, nullable=True)
    # Última troca de estado de cada relé, para os tempos mínimos ligado e desligado.
    humidity_output_changed_at = Column(DateTime, nullable=True)
    # Quando o produtor trocou o modo do flap pela última vez (alerta de flap aberto à mão na Amarelação).
    humidity_output_mode_at = Column(DateTime, nullable=True)
    temperature_output_changed_at = Column(DateTime, nullable=True)
    # Soprador: alvo efetivo (°C) que sobe em rampa até a temperatura alvo, e quando foi atualizado.
    target_effective = Column(Float, nullable=True)
    target_effective_at = Column(DateTime, nullable=True)
    # A troca de fase reduziu o alvo ao máximo da nova fase.
    target_limited = Column(Boolean, nullable=False, default=False)
    # Flap aberto pelo automático por umidade e bulbo seco (°C) no instante da abertura (intertravamentos 4.1 a 4.3).
    flap_humidity_open = Column(Boolean, nullable=False, default=False)
    flap_open_temperature = Column(Float, nullable=True)
    # Fechado porque a estufa esfriava com ele aberto: só reabre com a temperatura recuperada (4.3).
    flap_drop_locked = Column(Boolean, nullable=False, default=False)
    # Início da falha de sensor (congelado ou pulando) do alerta "Sensor suspeito" ativo; nulo sem falha (4.4).
    sensor_fault_since = Column(DateTime, nullable=True)
    # A temperatura sobe mais rápido que o limite da fase: o soprador fica desligado (gravado pelo motor de alertas).
    fan_rate_cut = Column(Boolean, nullable=False, default=False)

    # Estado dos alertas. A âncora é o início do trecho atual (fase ou retomada) já tratado pelo motor.
    alert_anchor_at = Column(DateTime, nullable=True)
    alert_grace_until = Column(DateTime, nullable=True)
    # Referência (°C) do alerta de queda; nula enquanto a queda é a correção pedida por outro alerta.
    drop_reference = Column(Float, nullable=True)
    wet_bulb_gate_open = Column(Boolean, nullable=False, default=True)

    user = relationship("User", back_populates="curing_units")
    device = relationship("Device", back_populates="curing_units")
    readings = relationship("Reading", back_populates="curing_unit")
    alerts = relationship("Alert", back_populates="curing_unit")
    output_events = relationship("OutputEvent", back_populates="curing_unit", cascade="all, delete-orphan")
    stage_changes = relationship(
        "StageChange", back_populates="curing_unit", cascade="all, delete-orphan", order_by="StageChange.started_at",
    )
    cycles = relationship(
        "CuringCycle", back_populates="curing_unit", cascade="all, delete-orphan", order_by="CuringCycle.started_at",
    )
