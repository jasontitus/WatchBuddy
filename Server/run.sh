#!/usr/bin/env bash
# Auto-restart server on crash
cd "$(dirname "$0")"
source venv/bin/activate

export PORT=${PORT:-8333}

while true; do
    echo "==> Starting server on port $PORT..."
    python main.py
    echo "==> Server exited ($?). Restarting in 3 seconds..."
    sleep 3
done
