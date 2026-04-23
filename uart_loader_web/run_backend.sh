#!/usr/bin/env bash
set -euo pipefail

# Run the FastAPI backend (Git Bash / Linux / macOS)
# Usage:
#   ./run_backend.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Pick a Python 3 command that works on Windows + Git Bash too.
PYTHON=(python3)
if ! command -v python3 >/dev/null 2>&1; then
  if command -v python >/dev/null 2>&1; then
    PYTHON=(python)
  elif command -v py >/dev/null 2>&1; then
    PYTHON=(py -3)
  else
    echo "[ERROR] Python 3 not found in PATH." >&2
    echo "Install Python 3 and ensure it's available as 'python' or 'python3'." >&2
    exit 1
  fi
fi

# Create venv if needed
if [[ ! -d ".venv" ]]; then
  "${PYTHON[@]}" -m venv .venv
fi

# Activate venv
# shellcheck disable=SC1091
source .venv/Scripts/activate 2>/dev/null || source .venv/bin/activate

python -m pip install -r requirements.txt

exec python -m uvicorn app:app --reload --host 127.0.0.1 --port 8000

