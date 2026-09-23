from pydantic import BaseModel
    
class UserOut(BaseModel):
    id:int
    name:str
    login:str

    model_config = {"from_attributes": True}
    