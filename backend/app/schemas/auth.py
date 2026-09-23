from pydantic import BaseModel

class Login(BaseModel):
    login:str
    password:str

class Register(BaseModel):
    name:str
    login:str
    password:str

class LoginResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str
    expires_in: int

class RefreshRequest(BaseModel):
    refresh_token: str

class PasswordResetRequest(BaseModel):
    login: str

class PasswordResetConfirm(BaseModel):
    login: str
    reset_token: str
    new_password: str
