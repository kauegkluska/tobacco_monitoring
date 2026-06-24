from sqlalchemy.orm import Session
from models.user import User
from core.security import verify_password


def authenticate_user(db: Session, login: str, password: str):
    user = db.query(User).filter(User.login == login).first()
    
    if not user:
        return None
    
    if not verify_password(password, user.hashed_password):
        return None
    
    return user

