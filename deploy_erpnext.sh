#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/pwd.yml"
JSON_FILE="$SCRIPT_DIR/data/isp_volkov.json"
BACKUP_DIR="$SCRIPT_DIR/.clean_backup"

# Перевіряємо, чи є файл із даними перед початком
if [ ! -f "$JSON_FILE" ]; then
  echo "Не знайдено файл із даними: $JSON_FILE"
  exit 1
fi

# Якщо це перший запуск — піднімаємо все з нуля і зберігаємо копію чистої бази
if [ ! -d "$BACKUP_DIR" ]; then
  echo "Перший запуск: прибираємо старі контейнери та піднімаємо нові..."
  sudo docker compose -f "$COMPOSE_FILE" down -v --remove-orphans
  sudo docker compose -f "$COMPOSE_FILE" up -d

  echo "Чекаємо, поки створиться сайт ERPNext (зазвичай це займає декілька хвилини)..."
  CREATE_SITE_ID=$(sudo docker compose -f "$COMPOSE_FILE" ps -q create-site)
  sudo docker wait "$CREATE_SITE_ID" >/dev/null

  BACKEND_ID=$(sudo docker compose -f "$COMPOSE_FILE" ps -q backend)
  echo "Зберігаємо копію чистої бази, щоб наступні запуски проходили за лічені секунди..."
  sudo docker exec "$BACKEND_ID" bench --site frontend backup --backup-path /tmp/clean_backup
  mkdir -p "$BACKUP_DIR"
  sudo docker cp "$BACKEND_ID":/tmp/clean_backup/. "$BACKUP_DIR/"
else
  echo "Запускаємо контейнери та відновлюємо чисту базу зі збереженої копії..."
  sudo docker compose -f "$COMPOSE_FILE" up -d
  BACKEND_ID=$(sudo docker compose -f "$COMPOSE_FILE" ps -q backend)
  sudo docker cp "$BACKUP_DIR/." "$BACKEND_ID":/tmp/clean_backup/
  DB_SQL=$(ls "$BACKUP_DIR"/*-database.sql.gz | head -n 1 | xargs basename)
  sudo docker exec "$BACKEND_ID" bench --site frontend restore "/tmp/clean_backup/$DB_SQL" --mariadb-root-password admin --force
fi

echo "Налаштовуємо компанію, обліковий запис і завантажуємо дані провайдера..."
sudo docker cp "$JSON_FILE" "$BACKEND_ID":/tmp/isp_volkov.json

sudo docker exec -i "$BACKEND_ID" bench --site frontend console << 'EOF'
import json
import frappe
from frappe.desk.page.setup_wizard.setup_wizard import setup_complete
from frappe.utils.password import update_password

# Заповнюємо початкові налаштування системи та створюємо компанію
setup_complete({
    "language": "English",
    "country": "Ukraine",
    "timezone": "Europe/Kyiv",
    "currency": "UAH",
    "full_name": "Волков Олександр Віталійович",
    "email": "volkov@isp.ua",
    "password": "admin",
    "company_name": "ТОВ Полтава-Телеком",
    "company_abbr": "ПТ",
    "chart_of_accounts": "Standard",
    "fy_start_date": "2026-01-01",
    "fy_end_date": "2026-12-31"
})

# Встановлюємо зручний вхід за логіном admin і паролем admin
update_password("Administrator", "admin")
frappe.db.set_single_value("System Settings", "allow_login_using_user_name", 1)
frappe.db.set_value("User", "Administrator", "username", "admin")

# Вмикаємо режим швидкого імпорту без зайвих фонових сповіщень
frappe.flags.in_import = True

with open("/tmp/isp_volkov.json", encoding="utf-8") as f:
    raw = json.load(f)

# Зводимо назви полів до нижнього регістру, щоб не залежати від формату експорту
tables = {
    item["name"]: [{k.lower(): v for k, v in row.items()} for row in item["data"]]
    for item in raw if item.get("type") == "table"
}
company = "ТОВ Полтава-Телеком"

# Додаємо відділи
for r in tables.get("Departments", []):
    frappe.get_doc({
        "doctype": "Department",
        "department_name": r["name"],
        "company": company
    }).insert(ignore_permissions=True)

# Додаємо посади та картки співробітників
created_designations = set()
for r in tables.get("Employees", []):
    pos = r.get("position")
    if pos and pos not in created_designations:
        if not frappe.db.exists("Designation", pos):
            frappe.get_doc({"doctype": "Designation", "designation_name": pos}).insert(ignore_permissions=True)
        created_designations.add(pos)

    parts = r["full_name"].split()
    raw_gender = r.get("gender")
    gender = "Male" if raw_gender in ("Чоловіча", "Male") else ("Female" if raw_gender in ("Жіноча", "Female") or r["full_name"].endswith("вна") else "Male")

    frappe.get_doc({
        "doctype": "Employee",
        "first_name": " ".join(parts[:2]) if len(parts) >= 2 else r["full_name"],
        "last_name": parts[-1] if len(parts) >= 3 else "",
        "gender": gender,
        "date_of_birth": r.get("birth_date") or "1995-05-15",
        "date_of_joining": r.get("hire_date") or "2026-01-01",
        "designation": pos,
        "company_email": r["email"],
        "cell_number": r["phone"],
        "status": "Active",
        "company": company
    }).insert(ignore_permissions=True)

# Додаємо абонентів (клієнтів)
subs = {}
for r in tables.get("Subscribers", []):
    subs[r["id_subscriber"]] = r["full_name"]
    frappe.get_doc({
        "doctype": "Customer",
        "customer_name": r["full_name"],
        "customer_type": "Individual" if r["subscriber_type"] == "Фізична особа" else "Company",
        "mobile_no": r["phone"],
        "email_id": r["email"]
    }).insert(ignore_permissions=True)

# Додаємо тарифні плани як послуги
tariffs = {}
for r in tables.get("TariffPlans", []):
    tariffs[r["id_tariff"]] = r["name"]
    frappe.get_doc({
        "doctype": "Item",
        "item_code": f"TARIFF-{r['id_tariff']}",
        "item_name": r["name"],
        "item_group": "Services",
        "stock_uom": "Nos",
        "is_stock_item": 0,
        "standard_rate": float(r["monthly_fee"])
    }).insert(ignore_permissions=True)

# Додаємо додаткові послуги
for r in tables.get("AdditionalServices", []):
    frappe.get_doc({
        "doctype": "Item",
        "item_code": f"SERV-{r['id_service']}",
        "item_name": r["name"],
        "item_group": "Services",
        "stock_uom": "Nos",
        "is_stock_item": 0,
        "standard_rate": float(r["monthly_price"])
    }).insert(ignore_permissions=True)

# Додаємо обладнання на склад
for r in tables.get("Equipment", []):
    frappe.get_doc({
        "doctype": "Item",
        "item_code": r["serial_number"],
        "item_name": r["model"],
        "item_group": "Products",
        "stock_uom": "Nos",
        "is_stock_item": 1,
        "standard_rate": float(r["unit_price"])
    }).insert(ignore_permissions=True)

# Оформлюємо договори з абонентами
contracts = {}
for r in tables.get("Contracts", []):
    contracts[r["id_contract"]] = subs.get(r["id_subscriber"])
    frappe.get_doc({
        "doctype": "Contract",
        "party_type": "Customer",
        "party_name": subs.get(r["id_subscriber"]),
        "start_date": r["sign_date"],
        "status": "Active" if r.get("status") == "Чинний" else "Inactive",
        "contract_terms": f"Договір {r['contract_number']} | Тариф: {tariffs.get(r['id_tariff'])}"
    }).insert(ignore_permissions=True)

# Переносимо звернення до техпідтримки
prio_map = {"Високий": "High", "Середній": "Medium", "Низький": "Low"}
stat_map = {"Новий": "Open", "В роботі": "On Hold", "Вирішено": "Resolved"}
for r in tables.get("SupportTickets", []):
    frappe.get_doc({
        "doctype": "Issue",
        "subject": r["subject"],
        "customer": contracts.get(r["id_contract"]),
        "priority": prio_map.get(r.get("priority"), "Medium"),
        "status": stat_map.get(r.get("status"), "Open")
    }).insert(ignore_permissions=True)

frappe.db.commit()
frappe.clear_cache()
print("Усі дані успішно завантажено в систему!")
EOF

echo "Перезапускаємо фонові обробники черг..."
sudo docker compose -f "$COMPOSE_FILE" restart queue-short queue-long

echo "Усе готово! Можна відкривати http://localhost:8080 (логін: admin, пароль: admin)"
