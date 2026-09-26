from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from core.security import hash_password, verify_password
from dependencies.auth import get_current_user
from dependencies.db import get_db
from models.user import User
from schemas.users import UserOut

router = APIRouter()


class UserUpdate(BaseModel):
    name: str = Field(min_length=2, max_length=100)


class PasswordChange(BaseModel):
    current_password: str
    new_password: str = Field(min_length=6, max_length=128)


@router.get("/me", response_model=UserOut)
def get_user(user: User = Depends(get_current_user)):
    return user


@router.patch("/me", response_model=UserOut)
def update_user(data: UserUpdate, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    user.name = data.name.strip()
    db.commit()
    db.refresh(user)
    return user


@router.post("/me/password")
def change_password(data: PasswordChange, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    if not verify_password(data.current_password, user.password_hash):
        raise HTTPException(status_code=400, detail="Senha atual incorreta")
    user.password_hash = hash_password(data.new_password)
    db.commit()
    return {"message": "Senha atualizada"}
