from sqlalchemy import Column, DateTime, Integer, String
from sqlalchemy.orm import relationship

from core.database import Base


class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(100), nullable=False)
    login = Column(String(100), unique=True, nullable=False)
    password_hash = Column(String(255), nullable=False)
    reset_token_hash = Column(String(128), nullable=True)
    reset_token_expires_at = Column(DateTime, nullable=True)

    devices = relationship("Device", back_populates="user")
    curing_units = relationship("CuringUnit", back_populates="user")
