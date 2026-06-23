from sqlalchemy import Column, Integer, String
from app.core.database import Base

class User(Base):
    __tablename__ = "users"
    
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(100), nullable=False)
    login = Column(String(100), unique=True, nullable=False)
    password_hash = Column(String(255), nullable=False)