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
    token_type:str
