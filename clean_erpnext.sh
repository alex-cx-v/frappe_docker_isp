#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/pwd.yml"
BACKUP_DIR="$SCRIPT_DIR/.clean_backup"

echo "Видаляємо контейнери, базу даних, томи та збережену копію..."
sudo docker compose -f "$COMPOSE_FILE" down -v --remove-orphans
rm -rf "$BACKUP_DIR"

echo "Готово! Усе повністю очищено."
