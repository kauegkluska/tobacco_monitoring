from fastapi import APIRouter, HTTPException, Depends
from sqlalchemy.orm import Session
from models.user import User
from core.security import verify_password
from schemas.auth import Login, Register
from core.security import hash_password


from dependencies.db import get_db
from services.auth_service import authenticate_user


router = APIRouter()


@router.post("/login")
def login(data: Login, db: Session = Depends(get_db)):
    
    user = authenticate_user(db, data.login, data.password)
    
    if not user:
        raise HTTPException(status_code=401, detail="invalid credentials")
    
    
    return{
        "status": "ok",
        "message": "login successful",
        "user": {
            "id": user.id,
            "login": user.login
        }
    }
    
@router.post("/register")
def register(data: Register, db: Session = Depends(get_db)):
    password_hash = hash_password(data.password)
    new_user = User(name=data.name, login=data.login, password_hash=password_hash)
    db.add(new_user)
    db.commit()
    db.refresh(new_user)
    return {
        "status": "ok",
        "message": "registration successful",
        "user": {
            "id": new_user.id,
            "name": new_user.name,
            "login": new_user.login
        }
    }
    