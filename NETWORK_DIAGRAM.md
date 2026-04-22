# Network Diagram — Operation PIPELINE BREACH

```text
                         [Attacker — Kali Linux]
                                   │
                            lab-net / DHCP
                                   │
        ┌──────────────────────────┼──────────────────────────┐
        │                          │                          │
        │                  cyberange.local                    │
        │           Mixed Linux / Windows / AD Estate         │
        │                          │                          │
        │   ┌──────────────────────────────────────────────┐  │
        │   │ M1 — DC                                     │  │
        │   │ Windows Server 2019                         │  │
        │   │ AD DS + DNS + DCHealthAgent loader          │  │
        │   │ Ports: 53, 88, 135, 389, 445, 5985          │  │
        │   │ Share: \\DC\DCHealthAgent                │  │
        │   └──────────────────────────────────────────────┘  │
        │                          ▲                          │
        │                          │ NT hash / SMB            │
        │                          │                          │
        │   ┌──────────────────────────────────────────────┐  │
        │   │ M5 — MGMT                                   │  │
        │   │ Windows Server 2019                         │  │
        │   │ WinRM / SMB admin node                      │  │
        │   │ Weak LSASS posture, cached svc_itops        │  │
        │   │ CorpMonitor writable service path           │  │
        │   └──────────────────────────────────────────────┘  │
        │                          ▲                          │
        │                          │ ansible_svc             │
        │                          │                          │
        │   ┌──────────────────────────────────────────────┐  │
        │   │ M4 — LNXPROC                                │  │
        │   │ Ubuntu 22.04                                │  │
        │   │ rsync daemon → /etc                         │  │
        │   │ SSH + SSSD + local vault                    │  │
        │   │ Ports: 22, 873                              │  │
        │   └──────────────────────────────────────────────┘  │
        │                          ▲                          │
        │                          │ proxy-admin             │
        │                          │                          │
        │   ┌──────────────────────────────────────────────┐  │
        │   │ M3 — LNXBUILDER                             │  │
        │   │ Ubuntu 22.04                                │  │
        │   │ Writable /opt/builds                        │  │
        │   │ Root cron tar archive                       │  │
        │   │ Local Ansible vault                         │  │
        │   │ Port: 22                                    │  │
        │   └──────────────────────────────────────────────┘  │
        │                          ▲                          │
        │                          │ deploy_user             │
        │                          │                          │
        │   ┌──────────────────────────────────────────────┐  │
        │   │ M2 — LNXW                                   │  │
        │   │ Ubuntu 22.04                                │  │
        │   │ Nginx → Flask → MySQL                       │  │
        │   │ Unauthenticated /search SQLi                │  │
        │   │ Ports: 80, 22                               │  │
        │   └──────────────────────────────────────────────┘  │
        └──────────────────────────────────────────────────────┘
```

* * *

## Port and Service Matrix

| Host | Services | Purpose |
|---|---|---|
| DC | 53/TCP+UDP, 88/TCP+UDP, 389/TCP+UDP, 445/TCP, 5985/TCP | DNS, Kerberos, LDAP, SMB, WinRM |
| MGMT | 445/TCP, 5985/TCP, 3389/TCP | Administrative access and remote management |
| LNXW | 80/TCP, 22/TCP | Public web app and SSH |
| LNXBUILDER | 22/TCP | Build server administration |
| LNXPROC | 22/TCP, 873/TCP | SSH and rsync daemon |

## Logical Trust Relationships

| Source | Target | Trust Assumption | Abuse Path |
|---|---|---|---|
| Internet | LNXW | Search endpoint is “read-only” and safe to expose | Blind SQL injection |
| LNXW operator creds | LNXBUILDER | Deployment user can only manage builds | SSH access + cron-influenced tar |
| LNXBUILDER vault | LNXPROC | Stored operational SSH credential is trustworthy | Authenticated rsync write to `/etc` |
| LNXPROC vault | MGMT | Automation account has broad Windows maintenance rights | WinRM / SMB admin access |
| MGMT cached session | DC | `svc_itops` is trusted for DC operations | Hash-based auth + DLL load path on DC |

## Attack Path Summary

```text
HTTP /search
   ↓
MySQL deploy_credentials
   ↓
SSH deploy_user@LNXBUILDER
   ↓
tar --checkpoint-action → root
   ↓
Ansible vault → proxy-admin
   ↓
rsync server-configs:/etc → /etc/cron.d/attacker
   ↓
root@LNXPROC
   ↓
Ansible vault → ansible_svc
   ↓
WinRM / SMB to MGMT
   ↓
LSASS dump → svc_itops NT hash
   ↓
SMB write to \\DC\DCHealthAgent\health_check.dll
   ↓
SYSTEM loads DLL → create hacker DA
   ↓
DCSync
```

## Log Collection Priorities

### Linux
- `/var/log/nginx/access.log`
- Flask service logs / journalctl
- MySQL general / slow query logs
- `/var/log/auth.log`
- `/var/log/syslog`
- `/var/log/rsyncd.log`

### Windows
- Security.evtx
- System.evtx
- Microsoft-Windows-TaskScheduler/Operational
- PowerShell Operational logs
- Sysmon (if enabled)
