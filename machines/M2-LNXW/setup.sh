#!/bin/bash
set -euo pipefail

hostnamectl set-hostname LNXW

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y python3 python3-pip python3-venv mysql-server nginx openssh-server curl net-tools

systemctl enable mysql
systemctl start mysql

mysql -u root <<'SQLEOF'
CREATE DATABASE IF NOT EXISTS inventory_app;
USE inventory_app;

CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(50) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    email VARCHAR(100),
    role VARCHAR(20) DEFAULT 'viewer',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS inventory (
    id INT AUTO_INCREMENT PRIMARY KEY,
    item_name VARCHAR(100) NOT NULL,
    category VARCHAR(50),
    quantity INT DEFAULT 0,
    location VARCHAR(100),
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS deploy_credentials (
    id INT AUTO_INCREMENT PRIMARY KEY,
    hostname VARCHAR(100) NOT NULL,
    username VARCHAR(50) NOT NULL,
    password VARCHAR(100) NOT NULL,
    ssh_port INT DEFAULT 22,
    purpose VARCHAR(200),
    last_rotated TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO inventory (item_name, category, quantity, location) VALUES
('Dell Latitude 5540', 'Laptops', 45, 'Bristol HQ - IT Storage'),
('Dell OptiPlex 7010', 'Desktops', 30, 'Bristol HQ - Floor 2'),
('Cisco Catalyst 9200', 'Switches', 12, 'Server Room'),
('Aruba AP-535', 'WiFi APs', 15, 'All Floors'),
('APC Smart-UPS 3000', 'UPS', 4, 'Server Room'),
('Yealink T46U', 'IP Phones', 85, 'All Desks'),
('Microsoft 365 E3', 'Software', 87, 'Virtual');

INSERT INTO deploy_credentials (hostname, username, password, ssh_port, purpose) VALUES
('LNXBUILDER.cyberange.local', 'deploy_user', 'D3pl0y#2025!', 22, 'Automated build deployment'),
('LNXPROC.cyberange.local', 'proxy-admin', 'Pr0xyAdm!n2025', 22, 'Proxy configuration updates');

CREATE USER IF NOT EXISTS 'inventory_app'@'localhost' IDENTIFIED BY 'Inv3nt0ry@pp2025!';
GRANT SELECT, INSERT, UPDATE ON inventory_app.* TO 'inventory_app'@'localhost';
FLUSH PRIVILEGES;
SQLEOF

mkdir -p /opt/inventory-app
python3 -m venv /opt/inventory-app/venv
/opt/inventory-app/venv/bin/pip install flask mysql-connector-python

cat > /opt/inventory-app/app.py <<'PYEOF'
#!/usr/bin/env python3
from flask import Flask, request, render_template_string
import mysql.connector
import os

app = Flask(__name__)
app.secret_key = os.urandom(24)

DB_CONFIG = {
    "host": "localhost",
    "user": "inventory_app",
    "password": "Inv3nt0ry@pp2025!",
    "database": "inventory_app",
}

HOME = """
<!DOCTYPE html>
<html>
<head>
    <title>Psychorp Inventory Search</title>
    <style>
        body { font-family: Segoe UI, Arial, sans-serif; margin: 40px; background: #101520; color: #eef; }
        .wrap { max-width: 900px; margin: auto; }
        .card { background: #172033; padding: 24px; border-radius: 10px; margin-bottom: 20px; }
        input { width: 70%; padding: 12px; border-radius: 6px; border: 1px solid #334; background: #0f1524; color: #eef; }
        button { padding: 12px 18px; border: 0; border-radius: 6px; background: #c23f5a; color: white; cursor: pointer; }
        table { width: 100%; border-collapse: collapse; margin-top: 20px; background: #172033; }
        th, td { padding: 12px; border-bottom: 1px solid #223; text-align: left; }
        .meta { color: #98a2c3; font-size: 12px; }
    </style>
</head>
<body>
<div class="wrap">
    <div class="card">
        <h1>Psychorp Inventory Portal</h1>
        <p>Vendor-facing inventory lookups for approved stock requests.</p>
        <form method="GET" action="/search">
            <input type="text" name="q" placeholder="Search item, category, or location..." value="{{ query or '' }}">
            <button type="submit">Search</button>
        </form>
        <p class="meta">External inventory preview enabled for logistics partners.</p>
    </div>
    {% if items is not none %}
    <table>
        <tr><th>ID</th><th>Item</th><th>Category</th><th>Qty</th><th>Location</th></tr>
        {% for row in items %}
        <tr>
            <td>{{ row[0] }}</td><td>{{ row[1] }}</td><td>{{ row[2] }}</td><td>{{ row[3] }}</td><td>{{ row[4] }}</td>
        </tr>
        {% endfor %}
    </table>
    {% endif %}
</div>
</body>
</html>
"""

def db():
    return mysql.connector.connect(**DB_CONFIG)

@app.route("/")
def index():
    return render_template_string(HOME, items=None, query="")

@app.route("/search")
def search():
    query = request.args.get("q", "")
    conn = db()
    cur = conn.cursor()
    sql = f"SELECT id, item_name, category, quantity, location FROM inventory WHERE item_name LIKE '%{query}%' OR category LIKE '%{query}%' OR location LIKE '%{query}%'"
    try:
        cur.execute(sql)
        rows = cur.fetchall()
    except Exception:
        rows = []
    finally:
        cur.close()
        conn.close()
    return render_template_string(HOME, items=rows, query=query)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
PYEOF

cat > /etc/systemd/system/inventory-app.service <<'EOFSVC'
[Unit]
Description=Psychorp Inventory Portal
After=network.target mysql.service

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/inventory-app
ExecStart=/opt/inventory-app/venv/bin/python /opt/inventory-app/app.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOFSVC

chown -R www-data:www-data /opt/inventory-app
systemctl daemon-reload
systemctl enable inventory-app
systemctl start inventory-app

cat > /etc/nginx/sites-available/inventory <<'EOFNG'
server {
    listen 80 default_server;
    server_name _;
    access_log /var/log/nginx/inventory_access.log;
    error_log  /var/log/nginx/inventory_error.log;
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
EOFNG

ln -sf /etc/nginx/sites-available/inventory /etc/nginx/sites-enabled/inventory
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl restart nginx
systemctl enable nginx

cat > /opt/lab-bootstrap.sh <<'LABBOOT'
#!/bin/bash
set -e
for i in $(seq 1 30); do
    MY_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | grep -v '127.0.0.1' | head -1 || true)
    if [ -n "${MY_IP:-}" ]; then
        OCTETS=$(echo "$MY_IP" | cut -d. -f1-3)
        DC_IP="${OCTETS}.10"
        printf "nameserver %s\nsearch cyberange.local\n" "$DC_IP" > /etc/resolv.conf
        if getent hosts cyberange.local >/dev/null 2>&1; then
            echo "$(date) - Bootstrap OK. DC=$DC_IP MY_IP=$MY_IP" >> /opt/lab-bootstrap.log
            exit 0
        fi
    fi
    sleep 10
done
echo "$(date) - Bootstrap FAILED" >> /opt/lab-bootstrap.log
exit 1
LABBOOT
chmod +x /opt/lab-bootstrap.sh

cat > /etc/systemd/system/lab-bootstrap.service <<'EOFB'
[Unit]
Description=Lab DNS Bootstrap
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/lab-bootstrap.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOFB

systemctl daemon-reload
systemctl enable lab-bootstrap

echo "[+] LNXW setup complete."
