from sqlalchemy.orm import Session

from core.security import verify_password
from models.user import User


def authenticate_user(db: Session, login: str, password: str) -> User | None:
    user = db.query(User).filter(User.login == login).first()
    if not user or not verify_password(password, user.password_hash):
        return None
    return user
