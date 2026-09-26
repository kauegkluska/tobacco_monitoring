import secrets
from datetime import timedelta

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from core.clock import utcnow
from core.config import settings
from core.security import (
    ACCESS_TOKEN_SECONDS,
    create_access_token,
    create_refresh_token,
    get_user_id_from_refresh_token,
    hash_password,
    hash_reset_token,
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
from services.auth_service import authenticate_user

router = APIRouter()

RESET_TOKEN_MINUTES = 15


def token_response(user_id: int) -> dict:
    return {
        "access_token": create_access_token(user_id),
        "refresh_token": create_refresh_token(user_id),
        "token_type": "bearer",
        "expires_in": ACCESS_TOKEN_SECONDS,
    }


@router.post("/login", response_model=LoginResponse)
def login(data: Login, db: Session = Depends(get_db)):
    user = authenticate_user(db, data.login, data.password)
    if not user:
        raise HTTPException(status_code=401, detail="Login ou senha inválidos")
    return token_response(user.id)


@router.post("/register", response_model=LoginResponse, status_code=201)
def register(data: Register, db: Session = Depends(get_db)):
    if db.query(User).filter(User.login == data.login).first():
        raise HTTPException(status_code=409, detail="Este login já está cadastrado")

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
        raise HTTPException(status_code=401, detail="Sessão expirada, entre novamente")
    return token_response(user.id)


@router.post("/password-reset/request")
def request_password_reset(data: PasswordResetRequest, db: Session = Depends(get_db)):
    # A resposta é a mesma exista ou não o usuário, para não revelar quais logins estão cadastrados.
    response = {
        "message": "Se o login existir, um código de redefinição foi gerado",
        "expires_in": RESET_TOKEN_MINUTES * 60,
    }
    user = db.query(User).filter(User.login == data.login).first()
    if not user:
        return response

    reset_token = secrets.token_urlsafe(24)
    user.reset_token_hash = hash_reset_token(reset_token)
    user.reset_token_expires_at = utcnow() + timedelta(minutes=RESET_TOKEN_MINUTES)
    db.commit()

    # Sem envio por e-mail/SMS configurado, o código só é devolvido em ambiente de desenvolvimento.
    if settings.is_development:
        response["reset_token"] = reset_token
    return response


@router.post("/password-reset/confirm")
def confirm_password_reset(data: PasswordResetConfirm, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.login == data.login).first()
    valid = (
        user is not None
        and user.reset_token_hash is not None
        and user.reset_token_expires_at is not None
        and user.reset_token_expires_at >= utcnow()
        and secrets.compare_digest(user.reset_token_hash, hash_reset_token(data.reset_token))
    )
    if not valid:
        raise HTTPException(status_code=400, detail="Código inválido ou expirado")

    user.password_hash = hash_password(data.new_password)
    user.reset_token_hash = None
    user.reset_token_expires_at = None
    db.commit()
    return {"message": "Senha atualizada"}
