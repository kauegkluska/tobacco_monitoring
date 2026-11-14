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

    # O gateway ESP32 envia o header X-API-Key com este valor. Obrigatória fora de "development": sem ela, o servidor
    # recusa todas as leituras (503).
    GATEWAY_API_KEY: str | None = None

    # Lista separada por vírgulas, ou "*" para liberar qualquer origem.
    CORS_ORIGINS: str = "*"

    # Anúncio mDNS para o gateway achar o servidor sozinho (serviço "_estufa._tcp").
    MDNS_ENABLED: bool = True
    MDNS_NAME: str = "Monitor de Estufa"
    # Porta em que o uvicorn roda; vai no anúncio mDNS.
    API_PORT: int = 8000

    # Tempo sem leituras até o dispositivo aparecer como offline ("Sem sinal" na interface).
    DEVICE_OFFLINE_SECONDS: int = 90

    # Pressão usada para estimar o bulbo úmido (padrão: Lages, 916 m). O efeito no resultado é pequeno.
    ATMOSPHERIC_PRESSURE_KPA: float = 90.8
    # TEMPORÁRIO (teste em campo, 14/11/2026): o SHT40 ficou longe do sensor da estufa por causa do cabo curto.
    # Ligado, cada leitura que chega é convertida para a temperatura estimada no ponto do sensor da estufa, a partir de
    # pares medidos (SHT40, estufa) em °F, pela reta que melhor passa por todos, e todo o sistema usa o valor corrigido.
    SENSOR_CORRECTION_ENABLED: bool = False
    SENSOR_CORRECTION_POINTS_F: list[tuple[float, float]] = [(100.0, 115.0), (116.0, 133.0), (119.0, 140.0)]
    # Aquecimento rápido: janela da regressão. Fica como "info" até medir a oscilação real da fornalha.
    HEATING_RATE_WINDOW_MINUTES: int = 60
    HEATING_RATE_SEVERITY: str = "info"

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
