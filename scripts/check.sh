#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"
./scripts/test.sh
swift build -c release --product bleach
python3 scripts/verify-cli.py
