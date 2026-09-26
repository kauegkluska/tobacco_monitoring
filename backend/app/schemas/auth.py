from pydantic import BaseModel, Field, field_validator


class Login(BaseModel):
    login: str
    password: str

    @field_validator("login", mode="before")
    @classmethod
    def strip_login(cls, value):
        return value.strip() if isinstance(value, str) else value


class Register(BaseModel):
    name: str = Field(min_length=2, max_length=100)
    login: str = Field(min_length=3, max_length=100)
    password: str = Field(min_length=6, max_length=128)

    @field_validator("name", "login", mode="before")
    @classmethod
    def strip_text(cls, value):
        return value.strip() if isinstance(value, str) else value


class LoginResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str
    expires_in: int


class RefreshRequest(BaseModel):
    refresh_token: str


class PasswordResetRequest(BaseModel):
    login: str

    @field_validator("login", mode="before")
    @classmethod
    def strip_login(cls, value):
        return value.strip() if isinstance(value, str) else value


class PasswordResetConfirm(BaseModel):
    login: str
    reset_token: str
    new_password: str = Field(min_length=6, max_length=128)

    @field_validator("login", "reset_token", mode="before")
    @classmethod
    def strip_text(cls, value):
        return value.strip() if isinstance(value, str) else value
