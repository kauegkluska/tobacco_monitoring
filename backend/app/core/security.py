import base64
import hashlib
import hmac
import secrets
import time

from core.config import settings


def _load_token_secret() -> bytes:
    if settings.SECRET_KEY:
        return settings.SECRET_KEY.encode()

    secret_file = settings.DATA_DIR / "secret_key"
    if secret_file.exists():
        return secret_file.read_text(encoding="utf-8").strip().encode()

    settings.DATA_DIR.mkdir(parents=True, exist_ok=True)
    secret = secrets.token_urlsafe(48)
    secret_file.write_text(secret, encoding="utf-8")
    return secret.encode()


TOKEN_SECRET = _load_token_secret()

ACCESS_TOKEN_SECONDS = settings.ACCESS_TOKEN_MINUTES * 60
REFRESH_TOKEN_SECONDS = settings.REFRESH_TOKEN_DAYS * 24 * 60 * 60


def decode_base64(value: str) -> bytes:
    padding = "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(value + padding)


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 120_000)
    return "pbkdf2_sha256${}${}".format(
        base64.urlsafe_b64encode(salt).decode(),
        base64.urlsafe_b64encode(digest).decode(),
    )


def verify_password(plain_password: str, password_hash: str) -> bool:
    try:
        algorithm, encoded_salt, encoded_digest = password_hash.split("$", 2)
        if algorithm != "pbkdf2_sha256":
            return False
        salt = decode_base64(encoded_salt)
        expected = decode_base64(encoded_digest)
        actual = hashlib.pbkdf2_hmac("sha256", plain_password.encode(), salt, 120_000)
        return hmac.compare_digest(actual, expected)
    except (ValueError, TypeError):
        return False


def _create_token(user_id: int, expires_in: int, token_type: str) -> str:
    payload = f"{user_id}:{int(time.time()) + expires_in}:{token_type}".encode()
    encoded_payload = base64.urlsafe_b64encode(payload).decode().rstrip("=")
    signature = hmac.new(TOKEN_SECRET, encoded_payload.encode(), hashlib.sha256).digest()
    encoded_signature = base64.urlsafe_b64encode(signature).decode().rstrip("=")
    return f"{encoded_payload}.{encoded_signature}"


def create_access_token(user_id: int) -> str:
    return _create_token(user_id, ACCESS_TOKEN_SECONDS, "access")


def create_refresh_token(user_id: int) -> str:
    return _create_token(user_id, REFRESH_TOKEN_SECONDS, "refresh")


def _read_token(token: str, expected_type: str) -> int | None:
    try:
        encoded_payload, encoded_signature = token.split(".", 1)
        expected = hmac.new(TOKEN_SECRET, encoded_payload.encode(), hashlib.sha256).digest()
        actual = decode_base64(encoded_signature)
        if not hmac.compare_digest(actual, expected):
            return None
        user_id, expires_at, token_type = decode_base64(encoded_payload).decode().split(":", 2)
        if token_type != expected_type or int(expires_at) < int(time.time()):
            return None
        return int(user_id)
    except (ValueError, TypeError):
        return None


def get_user_id_from_token(token: str) -> int | None:
    return _read_token(token, "access")


def get_user_id_from_refresh_token(token: str) -> int | None:
    return _read_token(token, "refresh")


def hash_reset_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def keys_match(provided: str | None, expected: str) -> bool:
    return provided is not None and hmac.compare_digest(provided.encode(), expected.encode())
