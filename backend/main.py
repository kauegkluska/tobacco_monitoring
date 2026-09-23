import sys
from pathlib import Path

# Add the 'app' directory to sys.path so inner imports (e.g. from core..., from models...) resolve properly
app_path = Path(__file__).resolve().parent / "app"
if str(app_path) not in sys.path:
    sys.path.insert(0, str(app_path))

from app.main import app

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)

