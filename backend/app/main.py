from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from core.database import initialize_database
from models.alert import Alert
from models.curing_unit import CuringUnit
from models.device import Device
from models.reading import Reading
from models.user import User
from routers.curing_units import router as curing_units_router
from routers.devices import router as devices_router
from routers.readings import router as readings_router
from routers.auth import router as auth_router
from routers.users import router as users_router


app = FastAPI()

app.add_middleware(
	CORSMiddleware,
	allow_origins=["*"],
	allow_credentials=False,
	allow_methods=["*"],
	allow_headers=["*"],
)

app.include_router(readings_router, prefix="/readings", tags=["readings"])
app.include_router(curing_units_router, prefix="/curing_units", tags=["curing_units"])
app.include_router(devices_router, prefix="/devices", tags=["devices"])
app.include_router(auth_router, prefix="/auth", tags=["auth"])
app.include_router(users_router, prefix="/users", tags=["users"])

initialize_database()