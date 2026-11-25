#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/pwd.yml"

echo "Зупиняємо контейнери ERPNext (усі дані залишаються збереженими)..."
sudo docker compose -f "$COMPOSE_FILE" stop

echo "Контейнери зупинено. Щоб продовжити роботу пізніше, запустіть ./start_erpnext.sh"
