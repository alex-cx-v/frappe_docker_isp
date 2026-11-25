#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/pwd.yml"

echo "Запускаємо контейнери ERPNext..."
sudo docker compose -f "$COMPOSE_FILE" start

echo "Готово! Система працює за адресою http://localhost:8080 (логін: admin, пароль: admin)"
