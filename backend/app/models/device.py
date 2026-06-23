from sqlalchemy import Integer, Column, ForeignKey
from sqlalchemy import relationship
from datetime import datetime
from app.core.database import Base


class Device(Base):
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("user.id"), nullable=False)
    user = relationship("User", back_populates="device")
    