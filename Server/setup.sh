#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"

PYTHON=/opt/homebrew/bin/python3.12

echo "==> Creating Python 3.12 virtual environment..."
$PYTHON -m venv venv

echo "==> Activating venv..."
source venv/bin/activate

echo "==> Installing dependencies..."
pip install -r requirements.txt

if [ ! -f .env ]; then
    echo "==> Creating .env from env.example..."
    cp env.example .env
    echo "    Edit .env and add your GOOGLE_API_KEY before starting the server."
else
    echo "==> .env already exists, skipping."
fi

echo ""
echo "Setup complete! To run the server:"
echo "  cd Server"
echo "  source venv/bin/activate"
echo "  python main.py"
