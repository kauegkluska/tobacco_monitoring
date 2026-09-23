from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from core.security import get_user_id_from_token
from dependencies.db import get_db
from models.user import User

bearer = HTTPBearer(auto_error=False)

def get_current_user(
	credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
	db: Session = Depends(get_db),
) -> User:
	if not credentials or credentials.scheme.lower() != "bearer":
		raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Authentication required")

	user_id = get_user_id_from_token(credentials.credentials)
	user = db.query(User).filter(User.id == user_id).first() if user_id else None
	if not user:
		raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")
	return user
