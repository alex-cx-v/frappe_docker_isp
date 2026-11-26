#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/pwd.yml"
JSON_FILE="$SCRIPT_DIR/data/isp_volkov.json"
BACKUP_DIR="$SCRIPT_DIR/.clean_backup"

# Перевіряємо наявність файлу з даними
if [ ! -f "$JSON_FILE" ]; then
  echo "Не знайдено файл із даними: $JSON_FILE"
  exit 1
fi

# Перший запуск створює базу з нуля та зберігає чистий знімок; наступні — миттєво відновлюють його
if [ ! -d "$BACKUP_DIR" ]; then
  echo "Перший запуск: очищаємо старі контейнери та запускаємо нові..."
  sudo docker compose -f "$COMPOSE_FILE" down -v --remove-orphans
  sudo docker compose -f "$COMPOSE_FILE" up -d

  echo "Чекаємо створення сайту ERPNext (1–2 хвилини)..."
  CREATE_SITE_ID=$(sudo docker compose -f "$COMPOSE_FILE" ps -q create-site)
  sudo docker wait "$CREATE_SITE_ID" >/dev/null

  BACKEND_ID=$(sudo docker compose -f "$COMPOSE_FILE" ps -q backend)
  echo "Зберігаємо копію чистої бази для швидких перезапусків..."
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

echo "Налаштовуємо компанію та переносимо всі дані з isp_volkov.json..."
sudo docker cp "$JSON_FILE" "$BACKEND_ID":/tmp/isp_volkov.json

sudo docker exec -i "$BACKEND_ID" bench --site frontend console << 'EOF'
import json
import frappe
from frappe.desk.page.setup_wizard.setup_wizard import setup_complete
from frappe.utils.password import update_password

# 1. Проходження початкового налаштування компанії
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

# 2. Налаштування облікового запису адміністратора (admin / admin)
update_password("Administrator", "admin")
frappe.db.set_single_value("System Settings", "allow_login_using_user_name", 1)
frappe.db.set_value("User", "Administrator", "username", "admin")
frappe.db.commit()

with open("/tmp/isp_volkov.json", encoding="utf-8") as f:
    raw = json.load(f)

tables = {
    item["name"]: [{k.lower(): v for k, v in row.items()} for row in item["data"]]
    for item in raw if item.get("type") == "table"
}
company = "ТОВ Полтава-Телеком"

# 3. Відділи -> Department
depts = {}
for r in tables.get("Departments", []):
    doc = frappe.get_doc({
        "doctype": "Department",
        "department_name": r["name"],
        "company": company
    }).insert(ignore_permissions=True)
    depts[str(r["id_department"])] = doc.name
frappe.db.commit()

# 4. Посади -> Designation та Співробітники -> Employee
# Прибираємо можливий тестовий запис із Setup Wizard, щоб перенести точний список з БД
for existing_emp in frappe.get_all("Employee", pluck="name"):
    frappe.delete_doc("Employee", existing_emp, force=True, ignore_permissions=True)
frappe.db.commit()

employees_map = {}
created_designations = set()
emp_rows = tables.get("Employees", [])

for idx, r in enumerate(emp_rows, start=1):
    pos = r.get("position")
    if pos and pos not in created_designations:
        if not frappe.db.exists("Designation", pos):
            frappe.get_doc({"doctype": "Designation", "designation_name": pos}).insert(ignore_permissions=True)
        created_designations.add(pos)

    parts = r["full_name"].strip().split()
    raw_gender = r.get("gender")
    if raw_gender in ("Чоловіча", "Male"):
        gender = "Male"
    elif raw_gender in ("Жіноча", "Female"):
        gender = "Female"
    else:
        gender = "Female" if r["full_name"].endswith("вна") else "Male"

    emp_id = f"HR-EMP-{idx:05d}"
    emp_doc = frappe.get_doc({
        "doctype": "Employee",
        "name": emp_id,
        "naming_series": "HR-EMP-",
        "employee_number": emp_id,
        "first_name": " ".join(parts[:2]) if len(parts) >= 2 else r["full_name"],
        "last_name": parts[-1] if len(parts) >= 3 else "",
        "gender": gender,
        "date_of_birth": str(r.get("birth_date") or "1995-05-15"),
        "date_of_joining": str(r.get("hire_date") or "2026-01-01"),
        "designation": pos,
        "department": depts.get(str(r.get("id_department"))),
        "company_email": r.get("email"),
        "cell_number": r.get("phone"),
        "status": "Active",
        "company": company
    })
    emp_doc.flags.name_set = True
    emp_doc.insert(ignore_permissions=True, ignore_mandatory=True)
    employees_map[str(r.get("id_employee", idx))] = r["full_name"]
    frappe.db.commit()

# Оновлюємо системний лічильник серії HR-EMP-, щоб ручне додавання працювало коректно
if emp_rows:
    frappe.db.sql(
        "INSERT INTO `tabSeries` (name, current) VALUES ('HR-EMP-', %s) ON DUPLICATE KEY UPDATE current = %s",
        (len(emp_rows), len(emp_rows))
    )
    frappe.db.commit()

# 5. Абоненти -> Customer
subs = {}
for r in tables.get("Subscribers", []):
    subs[str(r["id_subscriber"])] = r["full_name"]
    frappe.get_doc({
        "doctype": "Customer",
        "customer_name": r["full_name"],
        "customer_type": "Individual" if r["subscriber_type"] == "Фізична особа" else "Company",
        "mobile_no": r.get("phone"),
        "email_id": r.get("email"),
        "customer_details": f"Адреса: {r.get('address', '')} | Баланс: {r.get('balance', '0.00')} грн"
    }).insert(ignore_permissions=True)

# 6. Тарифні плани -> Item (Services)
tariffs = {}
for r in tables.get("TariffPlans", []):
    tariffs[str(r["id_tariff"])] = f"{r['name']} ({r['monthly_fee']} грн/міс)"
    frappe.get_doc({
        "doctype": "Item",
        "item_code": f"TARIFF-{r['id_tariff']}",
        "item_name": r["name"],
        "item_group": "Services",
        "stock_uom": "Nos",
        "is_stock_item": 0,
        "standard_rate": float(r["monthly_fee"]),
        "description": f"Тарифний план, швидкість доступу: {r['speed_mbps']} Мбіт/с"
    }).insert(ignore_permissions=True)

# 7. Додаткові послуги -> Item (Services)
for r in tables.get("AdditionalServices", []):
    frappe.get_doc({
        "doctype": "Item",
        "item_code": f"SERV-{r['id_service']}",
        "item_name": r["name"],
        "item_group": "Services",
        "stock_uom": "Nos",
        "is_stock_item": 0,
        "standard_rate": float(r["monthly_price"]),
        "description": f"Додаткова телекомунікаційна послуга: {r['name']}"
    }).insert(ignore_permissions=True)

# 8. Обладнання -> Item (Products)
for r in tables.get("Equipment", []):
    frappe.get_doc({
        "doctype": "Item",
        "item_code": r["serial_number"],
        "item_name": r["model"],
        "item_group": "Products",
        "stock_uom": "Nos",
        "is_stock_item": 1,
        "standard_rate": float(r["unit_price"]),
        "description": f"Серійний номер: {r['serial_number']} | Статус: {r['status']}"
    }).insert(ignore_permissions=True)

# 9. Договори з абонентами -> Contract
contracts = {}
for r in tables.get("Contracts", []):
    cust_name = subs.get(str(r["id_subscriber"]))
    contracts[str(r["id_contract"])] = {
        "customer": cust_name,
        "number": r["contract_number"]
    }
    frappe.get_doc({
        "doctype": "Contract",
        "party_type": "Customer",
        "party_name": cust_name,
        "start_date": str(r["sign_date"]),
        "status": "Active" if r.get("status") == "Чинний" else "Inactive",
        "contract_terms": f"Договір №{r['contract_number']} | Тариф: {tariffs.get(str(r['id_tariff']), '')}"
    }).insert(ignore_permissions=True)

# 10. Заявки служби технічної підтримки -> Issue
prio_map = {"Високий": "High", "Середній": "Medium", "Низький": "Low"}
stat_map = {"Новий": "Open", "В роботі": "On Hold", "Вирішено": "Resolved"}
for r in tables.get("SupportTickets", []):
    c_info = contracts.get(str(r["id_contract"]), {})
    emp_name = employees_map.get(str(r.get("id_employee")), "Не призначено")
    created_date = str(r.get("created_at", "")).split()[0] or "2026-11-20"
    frappe.get_doc({
        "doctype": "Issue",
        "subject": r["subject"],
        "customer": c_info.get("customer"),
        "opening_date": created_date,
        "priority": prio_map.get(r.get("priority"), "Medium"),
        "status": stat_map.get(r.get("status"), "Open"),
        "description": f"Договір: {c_info.get('number', '-')} | Відповідальний інженер: {emp_name}"
    }).insert(ignore_permissions=True)

frappe.db.commit()
frappe.clear_cache()

# Контрольна перевірка кількості перенесених записів
print("\n=== РЕЗУЛЬТАТ ПЕРЕНЕСЕННЯ ДАНИХ У ERPNEXT ===")
print(f"Відділи (Department):      {frappe.db.count('Department', {'company': company})}")
print(f"Співробітники (Employee):  {frappe.db.count('Employee', {'company': company})}")
print(f"Абоненти (Customer):       {frappe.db.count('Customer')}")
print(f"Номенклатура (Item):       {frappe.db.count('Item')}")
print(f"Договори (Contract):       {frappe.db.count('Contract')}")
print(f"Заявки підтримки (Issue):  {frappe.db.count('Issue')}")
print("===========================================\n")
EOF

echo "Перезапускаємо фонові обробники черг..."
sudo docker compose -f "$COMPOSE_FILE" restart queue-short queue-long

echo "Усе готово! Відкривайте http://localhost:8080 (логін: admin, пароль: admin)"
