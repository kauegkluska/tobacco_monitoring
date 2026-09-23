from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from dependencies.db import get_db
from models.user import User
from schemas.users import UserOut
from dependencies.auth import get_current_user


router = APIRouter()

@router.get("/me", response_model=UserOut)
def get_user(user: User = Depends(get_current_user)):
    return user
    
    