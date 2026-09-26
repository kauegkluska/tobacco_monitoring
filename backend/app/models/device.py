from sqlalchemy import Column, DateTime, Float, ForeignKey, Integer, String, Text
from sqlalchemy.orm import relationship

from core.clock import utcnow
from core.database import Base


class Device(Base):
    __tablename__ = "devices"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=True)
    device_code = Column(String(100), nullable=True, index=True)
    mac_address = Column(String(50), nullable=True)
    lora_id = Column(String(50), nullable=True)
    hardware_model = Column(String(100), nullable=True, default="Heltec WiFi LoRa 32 V3")
    firmware_version = Column(String(50), nullable=True)
    # Telemetria só é preenchida quando o dispositivo envia; nulo significa "não informado".
    battery_level = Column(Integer, nullable=True)
    battery_status = Column(String(50), nullable=True)
    rssi = Column(Integer, nullable=True)
    snr = Column(Float, nullable=True)
    frequency = Column(String(50), default="915.0 MHz", nullable=True)
    # Limites em °C e % de umidade relativa.
    temp_min = Column(Float, default=35.0, nullable=True)
    temp_max = Column(Float, default=75.0, nullable=True)
    humidity_min = Column(Float, default=40.0, nullable=True)
    humidity_max = Column(Float, default=90.0, nullable=True)
    calibration_data = Column(Text, nullable=True)
    sensors_config = Column(Text, nullable=True)
    created_at = Column(DateTime, default=utcnow, nullable=False)
    last_seen_at = Column(DateTime, nullable=True)
    status = Column(String(20), default="offline", nullable=False)

    user = relationship("User", back_populates="devices")
    curing_units = relationship("CuringUnit", back_populates="device")
