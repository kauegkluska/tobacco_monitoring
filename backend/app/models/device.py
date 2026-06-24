from sqlalchemy import Integer, Column, ForeignKey
from sqlalchemy.orm import relationship
from models.user import User
from core.database import Base


class Device(Base):
    __tablename__ = "devices"
    
    id = Column(Integer, primary_key=True, index=True)
    users_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    
    user = relationship("User", back_populates="devices")
    
    curing_units = relationship("CuringUnit", back_populates="device")