#!/usr/bin/env bash
# Cópia do banco da API, consistente mesmo com a API gravando (API de backup do SQLite), compactada e com rodízio.
# Instalado como serviço com timer (estufa-backup.timer); pode ser rodado à mão: deploy/backup/estufa-backup.sh
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/estufa/tobacco_monitoring}"
DEST="${DEST:-$HOME/backup-estufa/auto}"
KEEP_DAYS="${KEEP_DAYS:-14}"

mkdir -p "$DEST"
FILE="$DEST/monitor-$(date +%F-%H%M).db"

"$APP_DIR/backend/venv/bin/python" -I - "$APP_DIR/backend/data/monitor.db" "$FILE" <<'PY'
import sqlite3
import sys

source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
target = sqlite3.connect(sys.argv[2])
with target:
    source.backup(target)
check = target.execute("PRAGMA integrity_check").fetchone()[0]
target.close()
source.close()
if check != "ok":
    sys.exit(f"Cópia com problema: {check}")
PY

gzip -f "$FILE"
find "$DEST" -name 'monitor-*.db.gz' -mtime +"$KEEP_DAYS" -delete
echo "Backup salvo em $FILE.gz ($(du -h "$FILE.gz" | cut -f1))"
