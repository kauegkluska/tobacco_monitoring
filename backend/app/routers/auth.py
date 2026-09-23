from datetime import datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from core.security import (
    ACCESS_TOKEN_SECONDS,
    create_access_token,
    create_refresh_token,
    get_user_id_from_refresh_token,
    hash_password,
    hash_reset_token,
    verify_password,
)
from dependencies.db import get_db
from models.user import User
from schemas.auth import (
    Login,
    LoginResponse,
    PasswordResetConfirm,
    PasswordResetRequest,
    RefreshRequest,
    Register,
)

router = APIRouter()


def token_response(user_id: int) -> dict:
    return {
        "access_token": create_access_token(user_id),
        "refresh_token": create_refresh_token(user_id),
        "token_type": "bearer",
        "expires_in": ACCESS_TOKEN_SECONDS,
    }


@router.post("/login", response_model=LoginResponse)
def login(data: Login, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.login == data.login).first()
    if not user or not verify_password(data.password, user.password_hash):
        raise HTTPException(status_code=401, detail="invalid credentials")
    return token_response(user.id)


@router.post("/register", response_model=LoginResponse)
def register(data: Register, db: Session = Depends(get_db)):
    if db.query(User).filter(User.login == data.login).first():
        raise HTTPException(status_code=409, detail="Login already registered")

    user = User(name=data.name, login=data.login, password_hash=hash_password(data.password))
    db.add(user)
    db.commit()
    db.refresh(user)
    return token_response(user.id)


@router.post("/refresh", response_model=LoginResponse)
def refresh(data: RefreshRequest, db: Session = Depends(get_db)):
    user_id = get_user_id_from_refresh_token(data.refresh_token)
    user = db.query(User).filter(User.id == user_id).first() if user_id else None
    if not user:
        raise HTTPException(status_code=401, detail="Invalid or expired refresh token")
    return token_response(user.id)


@router.post("/password-reset/request")
def request_password_reset(data: PasswordResetRequest, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.login == data.login).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    import secrets
    reset_token = secrets.token_urlsafe(24)
    user.reset_token_hash = hash_reset_token(reset_token)
    user.reset_token_expires_at = datetime.utcnow() + timedelta(minutes=15)
    db.commit()

    # Until email/SMS delivery is configured, development clients receive this token directly.
    return {"message": "Reset token generated", "reset_token": reset_token, "expires_in": 900}


@router.post("/password-reset/confirm")
def confirm_password_reset(data: PasswordResetConfirm, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.login == data.login).first()
    if not user or not user.reset_token_hash or not user.reset_token_expires_at:
        raise HTTPException(status_code=400, detail="Invalid password reset request")
    if user.reset_token_expires_at < datetime.utcnow() or user.reset_token_hash != hash_reset_token(data.reset_token):
        raise HTTPException(status_code=400, detail="Invalid or expired reset token")
    if len(data.new_password) < 6:
        raise HTTPException(status_code=422, detail="Password must have at least 6 characters")

    user.password_hash = hash_password(data.new_password)
    user.reset_token_hash = None
    user.reset_token_expires_at = None
    db.commit()
    return {"message": "Password updated"}
