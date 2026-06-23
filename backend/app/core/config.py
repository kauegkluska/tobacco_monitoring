import os
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    # Configurações do App
    APP_NAME: str = "Minha API FastAPI"
    ENVIRONMENT: str = "development"
    DEBUG: bool = True
    
    # Configurações de Banco de Dados
    DATABASE_URL: str = "postgresql://user:password@localhost:5432/dbname"
    
    # Configurações de Segurança
    SECRET_KEY: str = "sua-chave-secreta-muito-segura"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 30

    # Define o arquivo .env a ser lido
    model_config = SettingsConfigDict(env_file="./.env", env_file_encoding="utf-8")

settings = Settings()