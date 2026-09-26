from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles

from core.config import settings
from core.database import initialize_database
from core.discovery import DiscoveryAnnouncer
from models.alert import Alert  # noqa: F401  (registra os modelos antes do create_all)
from models.curing_unit import CuringUnit  # noqa: F401
from models.device import Device  # noqa: F401
from models.output_event import OutputEvent  # noqa: F401
from models.reading import Reading  # noqa: F401
from models.user import User  # noqa: F401
from routers.alerts import router as alerts_router
from routers.auth import router as auth_router
from routers.curing_units import router as curing_units_router
from routers.devices import router as devices_router
from routers.output_events import router as output_events_router
from routers.readings import router as readings_router
from routers.users import router as users_router

FRONTEND_DIR = Path(__file__).resolve().parents[2] / "frontend"
# App Flutter compilado para web (flutter build web --base-href /mobile/).
MOBILE_WEB_DIR = Path(__file__).resolve().parents[2] / "frontend_mobile" / "build" / "web"


@asynccontextmanager
async def lifespan(_app: FastAPI):
    initialize_database()
    announcer = DiscoveryAnnouncer()
    await announcer.start()
    try:
        yield
    finally:
        await announcer.stop()


app = FastAPI(title=settings.APP_NAME, lifespan=lifespan)

app.add_middleware(
	CORSMiddleware,
	allow_origins=settings.cors_origins,
	allow_credentials=False,
	allow_methods=["*"],
	allow_headers=["*"],
)

app.include_router(readings_router, prefix="/readings", tags=["readings"])
app.include_router(curing_units_router, prefix="/curing_units", tags=["curing_units"])
app.include_router(devices_router, prefix="/devices", tags=["devices"])
app.include_router(alerts_router, prefix="/alerts", tags=["alerts"])
app.include_router(output_events_router, prefix="/output-events", tags=["outputs"])
app.include_router(auth_router, prefix="/auth", tags=["auth"])
app.include_router(users_router, prefix="/users", tags=["users"])


@app.get("/health", tags=["health"])
def health():
	return {"status": "ok"}


if MOBILE_WEB_DIR.is_dir():
	# Mesmo app do celular, aberto pelo navegador: http://<ip-do-computador>:8000/mobile/
	app.mount("/mobile", StaticFiles(directory=MOBILE_WEB_DIR, html=True), name="mobile")

if FRONTEND_DIR.is_dir():
	# Painel web servido pela própria API: http://<ip-do-computador>:8000/
	app.mount("/app", StaticFiles(directory=FRONTEND_DIR, html=True), name="frontend")

	@app.get("/", include_in_schema=False)
	def root():
		return RedirectResponse("/app/")
else:
	@app.get("/", include_in_schema=False)
	def root():
		return {"status": "ok", "docs": "/docs"}
