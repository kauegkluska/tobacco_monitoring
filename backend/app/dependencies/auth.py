from fastapi import Depends, Header, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from core.config import settings
from core.security import get_user_id_from_token, keys_match
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


def require_gateway_key(x_api_key: str | None = Header(default=None)) -> None:
	"""Protege os endpoints de ingestão com a chave do gateway (header X-API-Key).

	Fora do desenvolvimento a chave é obrigatória: sem GATEWAY_API_KEY configurada, nenhuma leitura é aceita, para que
	um servidor exposto na internet nunca receba dados de quem só descobriu o endereço.
	"""
	if not settings.GATEWAY_API_KEY:
		if settings.is_development:
			return
		raise HTTPException(
			status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
			detail="GATEWAY_API_KEY não configurada no servidor",
		)
	if not keys_match(x_api_key, settings.GATEWAY_API_KEY):
		raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid gateway key")
