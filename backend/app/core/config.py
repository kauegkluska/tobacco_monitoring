from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

BACKEND_DIR = Path(__file__).resolve().parents[2]


class Settings(BaseSettings):
    APP_NAME: str = "Monitor de Estufa de Tabaco"
    # "development" devolve o token de redefinição de senha na resposta (não há e-mail/SMS configurado).
    ENVIRONMENT: str = "development"

    DATA_DIR: Path = BACKEND_DIR / "data"

    # Sem SECRET_KEY, uma chave aleatória é gerada e salva em DATA_DIR/secret_key.
    SECRET_KEY: str | None = None
    ACCESS_TOKEN_MINUTES: int = 15
    REFRESH_TOKEN_DAYS: int = 30

    # Quando definida, o gateway ESP32 precisa enviar o header X-API-Key com este valor.
    GATEWAY_API_KEY: str | None = None

    # Lista separada por vírgulas, ou "*" para liberar qualquer origem.
    CORS_ORIGINS: str = "*"

    # Anúncio mDNS para o gateway achar o servidor sozinho (serviço "_estufa._tcp").
    MDNS_ENABLED: bool = True
    MDNS_NAME: str = "Monitor de Estufa"
    # Porta em que o uvicorn roda; vai no anúncio mDNS.
    API_PORT: int = 8000

    # Tempo sem leituras até o dispositivo aparecer como offline.
    DEVICE_OFFLINE_SECONDS: int = 90

    model_config = SettingsConfigDict(
        env_file=BACKEND_DIR / ".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    @property
    def is_development(self) -> bool:
        return self.ENVIRONMENT.strip().lower() in {"development", "dev", "local"}

    @property
    def cors_origins(self) -> list[str]:
        return [origin.strip() for origin in self.CORS_ORIGINS.split(",") if origin.strip()]


settings = Settings()
