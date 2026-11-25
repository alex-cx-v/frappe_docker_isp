#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Запускаємо контейнери ERPNext..."
sudo docker compose -f "$SCRIPT_DIR/pwd.yml" up -d
echo "Готово! Відкривайте http://localhost:8080"
