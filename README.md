# APT41 Operation PIPELINE BREACH — Cross-Platform Build Pipeline Cyber Range

Classification: UNCLASSIFIED // EXERCISE ONLY  
Domain Theme: Corporate Enterprise — Internal Software Delivery and Operations Infrastructure  
Network: cyberange.local  
Platform: 3 × Ubuntu 22.04, 2 × Windows Server 2019 — QEMU / OpenStack Compatible  

* * *

## Machine Summary

| Hostname | Role | Primary Exposure | MITRE ATT&CK |
|---|---|---|---|
| M1 — DC | Domain Controller (AD DS + DNS) | Writable operational plugin path exposed through `DCHealthAgent` share and periodic DLL load path | T1574.001, T1003.006 |
| M2 — LNXW | Public-facing inventory portal (Nginx + Flask + MySQL) | Blind SQL injection on unauthenticated search endpoint exposes deployment credentials | T1190, T1552.001 |
| M3 — LNXBUILDER | Build server | Root cron job archives attacker-controlled filenames from writable build path (`tar` wildcard / checkpoint abuse) | T1059.004, T1068 |
| M4 — LNXPROC | Proxy / configuration sync host | Authenticated rsync module maps directly to `/etc`, enabling cron write and root persistence | T1021.004, T1053.003 |
| M5 — MGMT | Windows management server | Remote admin access with weak LSASS protections exposes cached `svc_itops` credentials; CorpMonitor DLL load weakness retained as secondary realism | T1003.001, T1550.002 |

* * *

## Credential Chain

```text
M2 SQLi                → deploy_user : D3pl0y#2025!
M3 Tar Wildcard        → proxy-admin : Pr0xyAdm!n2025
M4 Rsync + Vault       → ansible_svc : Ans1bl3#Mgmt2025!
M5 LSASS Dump          → svc_itops NT hash : 1e41c03da1d3143defa45aadf65e3afa
M1 DCHealthAgent DLL   → hacker : P@ssw0rd123!  → Domain Admin → DCSync
```

* * *

## Attack Flow (Scripted Trigger Path)

### Step 1 — Internet-Facing Blind SQL Injection (LNXW)

The external entry point is the Psychorp inventory search function. The `/search` route is deliberately left reachable without authentication and concatenates user-controlled input directly into a MySQL query. The trigger script uses `sqlmap` in time-based mode against the search parameter and dumps the `deploy_credentials` table to recover the SSH password for `deploy_user`.

**Primary artifacts:** Nginx access logs, Flask application logs, MySQL general / slow query logs, abnormal search latency.

```bash
sqlmap -u 'http://LNXW.cyberange.local/search?q=test'   --batch --level=3 --risk=2 --technique=T --dbms=MySQL   -D inventory_app -T deploy_credentials --dump
```

### Step 2 — Tar Wildcard Checkpoint Abuse (LNXBUILDER)

`deploy_user` can write into `/opt/builds`. A root cron job archives everything in that directory with `tar czf /var/backups/builds-<date>.tar.gz *`. Because the job expands attacker-controlled filenames, the operator plants `--checkpoint=1` and `--checkpoint-action=exec=sh shell.sh`, causing `tar` to execute the attacker’s script as root. The root context is then used to decrypt the local Ansible vault and recover the `proxy-admin` SSH password.

**Primary artifacts:** `/var/log/auth.log`, cron logs, file creation timestamps under `/opt/builds`, access to `/opt/ansible/.vault_pass`.

### Step 3 — Authenticated Rsync Write to `/etc` (LNXPROC)

`proxy-admin` can authenticate to the rsync daemon’s `server-configs` module. That module maps to `/etc` and is writable, so the trigger writes a new file under `/etc/cron.d/attacker` which appends the attacker SSH key into `/root/.ssh/authorized_keys`. Once root access is confirmed, the operator decrypts a second vault on LNXPROC to recover the WinRM / SMB credentials for `ansible_svc`. The machine is also domain-joined, leaving `/etc/krb5.keytab` available as a bonus artifact.

**Primary artifacts:** `/var/log/rsyncd.log`, `/etc/cron.d/attacker`, root SSH logons, access to `/opt/ansible/group_vars/windows_creds.yml`.

### Step 4 — Remote Management Pivot and LSASS Credential Theft (MGMT)

`ansible_svc` is a legitimate automation account with local administrator rights on MGMT. LSASS protections are deliberately weak: `RunAsPPL` is disabled, WDigest is enabled, and a scheduled task maintains an active logon context for `svc_itops`. The scripted trigger uses the management credentials directly to run `lsassy` / `secretsdump` style collection and recover the `svc_itops` NT hash. A writable `CorpMonitor` service directory remains on the box as an additional realistic weakness, but the deterministic trigger path does not rely on it.

**Primary artifacts:** 4624 logons, 4688 process creation, LSASS access telemetry, scheduled task state for `ITOpsMonitor`.

### Step 5 — DCHealthAgent DLL Hijack to Domain Admin (DC)

The final step uses the recovered `svc_itops` NT hash to authenticate to the DC and upload `health_check.dll` into the `DCHealthAgent` share. A loader task on the DC periodically calls `LoadLibrary` on that DLL path. On load, the DLL adds the `hacker` domain user and places it into `Domain Admins`. The trigger then validates the new account and performs DCSync with `impacket-secretsdump`.

**Primary artifacts:** SMB file write to `\DC\DCHealthAgent`, domain user creation, group membership change to `Domain Admins`, DCSync activity against the DC.

```bash
echo -e 'use DCHealthAgent\nput health_check.dll\nexit' |   impacket-smbclient 'cyberange.local/svc_itops@DC.cyberange.local' -hashes ':<NT_HASH>'
impacket-secretsdump 'cyberange.local/hacker:P@ssw0rd123!@DC.cyberange.local'
```

* * *

## Design Notes

- This range is intentionally mixed-platform. The operator moves from an internet-facing Linux application, into Linux operations infrastructure, then into Windows administrative controls and finally Active Directory.
- The environment is designed to feel operationally plausible rather than “CTF-clean”: there are real-looking applications, automation vaults, config sync services, scheduled tasks, and service-account usage patterns.
- The scripted trigger path is deterministic for replayability. Some secondary weaknesses remain present for realism and blue-team depth, but the documentation below reflects the route actually exercised by the supplied `Exploit.sh`.

* * *

## Recommended Build Order

```text
1. M1 — DC
2. M5 — MGMT
3. M2 — LNXW
4. M3 — LNXBUILDER
5. M4 — LNXPROC
6. Copy machines/Exploit.sh to the operator box if required
```

## Boot Order

```text
1. DC first
2. Wait ~90 seconds for AD DS / DNS
3. Boot remaining four systems
4. Allow bootstrap tasks / services to complete
5. Validate name resolution and reachability before running the trigger
```
