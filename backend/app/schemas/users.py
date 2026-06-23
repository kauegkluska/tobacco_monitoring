from pydantic import BaseModel


    
class UserOut(BaseModel):
    id:str
    name:str
    login:str
    

    