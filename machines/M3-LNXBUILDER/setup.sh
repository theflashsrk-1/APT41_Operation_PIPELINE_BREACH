#!/bin/bash
set -euo pipefail

hostnamectl set-hostname LNXBUILDER

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y openssh-server net-tools python3 python3-pip ansible-core sshpass

getent group builders >/dev/null || groupadd builders
id -u deploy_user >/dev/null 2>&1 || useradd -m -s /bin/bash -G builders deploy_user
echo 'deploy_user:D3pl0y#2025!' | chpasswd

mkdir -p /opt/builds
chown root:builders /opt/builds
chmod 775 /opt/builds

cat > /opt/backup-builds.sh <<'EOF'
#!/bin/bash
cd /opt/builds && tar czf /var/backups/builds-$(date +%Y%m%d-%H%M).tar.gz *
EOF
chmod 755 /opt/backup-builds.sh

mkdir -p /var/backups
echo "*/2 * * * * root /opt/backup-builds.sh" > /etc/cron.d/build-backup
chmod 644 /etc/cron.d/build-backup

mkdir -p /opt/builds/release-2.14.3
echo "build output placeholder" > /opt/builds/release-2.14.3/app.jar
echo "build log placeholder" > /opt/builds/release-2.14.3/build.log
echo "README" > /opt/builds/README.md

mkdir -p /opt/ansible/{group_vars,inventory,playbooks}
echo 'V@ultP@ss2025!' > /opt/ansible/.vault_pass
chmod 600 /opt/ansible/.vault_pass

cat > /tmp/windows_creds.yml <<'VAULTDATA'
---
proxy_ssh_user: proxy-admin
proxy_ssh_password: "Pr0xyAdm!n2025"
proxy_host: LNXPROC.cyberange.local

win_admin_user: ansible_svc
win_admin_password: "Ans1bl3#Mgmt2025!"
win_domain: cyberange.local
win_mgmt_host: MGMT.cyberange.local
VAULTDATA

ansible-vault encrypt /tmp/windows_creds.yml --vault-password-file /opt/ansible/.vault_pass --output /opt/ansible/group_vars/windows_creds.yml
rm -f /tmp/windows_creds.yml

cat > /opt/ansible/inventory/hosts <<'EOFINV'
[linux]
LNXW.cyberange.local
LNXBUILDER.cyberange.local
LNXPROC.cyberange.local

[windows]
MGMT.cyberange.local
DC.cyberange.local
EOFINV

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
            echo "$(date) - Bootstrap OK. DC=$DC_IP" >> /opt/lab-bootstrap.log
            exit 0
        fi
    fi
    sleep 10
done
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

echo "[+] LNXBUILDER setup complete."
