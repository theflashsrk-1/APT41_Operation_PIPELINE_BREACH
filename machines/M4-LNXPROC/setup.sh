#!/bin/bash
set -euo pipefail

hostnamectl set-hostname LNXPROC

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y openssh-server net-tools rsync realmd sssd sssd-tools adcli krb5-user packagekit samba-common-bin python3 ansible-core

id -u proxy-admin >/dev/null 2>&1 || useradd -m -s /bin/bash proxy-admin
echo 'proxy-admin:Pr0xyAdm!n2025' | chpasswd

# Optional domain join:
# export DOMAIN_JOIN_USER=Administrator
# export DOMAIN_JOIN_PASSWORD='YourPasswordHere'
if [ -n "${DOMAIN_JOIN_PASSWORD:-}" ]; then
    cat > /etc/krb5.conf <<'EOFKRB'
[libdefaults]
    default_realm = CYBERANGE.LOCAL
    dns_lookup_realm = false
    dns_lookup_kdc = true
    rdns = false

[realms]
    CYBERANGE.LOCAL = {
        kdc = DC.cyberange.local
        admin_server = DC.cyberange.local
    }

[domain_realm]
    .cyberange.local = CYBERANGE.LOCAL
    cyberange.local = CYBERANGE.LOCAL
EOFKRB
    echo "${DOMAIN_JOIN_PASSWORD}" | realm join cyberange.local --user="${DOMAIN_JOIN_USER:-Administrator}"
fi

cat > /etc/rsyncd.conf <<'EOFRSYNC'
uid = root
gid = root
use chroot = no
max connections = 10
log file = /var/log/rsyncd.log
pid file = /var/run/rsyncd.pid

[server-configs]
    path = /etc
    comment = Server configuration files
    read only = false
    list = yes
    auth users = proxy-admin
    secrets file = /etc/rsyncd.secrets
    hosts allow = *
EOFRSYNC

cat > /etc/rsyncd.secrets <<'EOFSEC'
proxy-admin:Pr0xyAdm!n2025
EOFSEC
chmod 600 /etc/rsyncd.secrets

cat > /etc/default/rsync <<'EOFDEFAULT'
RSYNC_ENABLE=true
EOFDEFAULT

systemctl enable rsync
systemctl restart rsync

mkdir -p /opt/ansible/{group_vars,inventory}
echo 'V@ultP@ss2025!' > /opt/ansible/.vault_pass
chmod 600 /opt/ansible/.vault_pass

cat > /tmp/windows_creds.yml <<'VAULTDATA'
---
win_admin_user: ansible_svc
win_admin_password: "Ans1bl3#Mgmt2025!"
win_domain: cyberange.local
win_mgmt_host: MGMT.cyberange.local
win_dc_host: DC.cyberange.local
VAULTDATA

ansible-vault encrypt /tmp/windows_creds.yml --vault-password-file /opt/ansible/.vault_pass --output /opt/ansible/group_vars/windows_creds.yml
rm -f /tmp/windows_creds.yml

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

echo "[+] LNXPROC setup complete."
