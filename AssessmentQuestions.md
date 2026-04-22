# APT41 — Operation PIPELINE BREACH — Participant Assessment

## Challenge Verification Questions

> Instructions:
>
> - Each step has 3 MCQs and 2 static-answer questions.
> - Questions are intended to verify the participant solved the challenge rather than guessed the path.
> - Static Question 4 in each section is the credential / artifact submission.
> - Answer key is for facilitator use only.

* * *

# STEP 1 — Initial Access (LNXW)

### MCQ 1.1
Which exposed application function is intentionally vulnerable and reachable without authentication?

- A) `/admin/export`
- B) `/search`
- C) `/api/login`
- D) `/healthz`
- E) `/reports`

### MCQ 1.2
Which backend table contains the credential that enables the next hop?

- A) `users`
- B) `inventory`
- C) `deploy_credentials`
- D) `audit_log`
- E) `sessions`

### MCQ 1.3
What SQL injection technique does the scripted trigger try first?

- A) Error-based
- B) Boolean-based
- C) Stacked queries
- D) Time-based blind
- E) Out-of-band DNS

### Static Question 1.4 — Credential Submission
Submit the password recovered for `deploy_user`.

**Answer:** `D3pl0y#2025!`

### Static Question 1.5
What hostname is stored alongside the recovered `deploy_user` credential?

**Answer:** `LNXBUILDER.cyberange.local`

* * *

# STEP 2 — Build Server Privilege Escalation (LNXBUILDER)

### MCQ 2.1
Which `tar` feature is abused to achieve code execution as root?

- A) `--use-compress-program`
- B) `--extract`
- C) `--checkpoint-action`
- D) `--listed-incremental`
- E) `--transform`

### MCQ 2.2
Why can the attacker influence a root-owned archive operation on LNXBUILDER?

- A) `deploy_user` has sudo rights
- B) `/opt/builds` is writable by `deploy_user`
- C) the backup script runs as `www-data`
- D) MySQL writes directly into `/var/backups`
- E) the root SSH key is world-readable

### MCQ 2.3
Which file is used to decrypt the local Ansible vault?

- A) `/root/.ansible.cfg`
- B) `/etc/krb5.keytab`
- C) `/opt/ansible/.vault_pass`
- D) `/home/deploy_user/.ssh/id_rsa`
- E) `/var/backups/builds.key`

### Static Question 2.4 — Credential Submission
Submit the password recovered for `proxy-admin`.

**Answer:** `Pr0xyAdm!n2025`

### Static Question 2.5
What is the full path of the encrypted vault file on LNXBUILDER?

**Answer:** `/opt/ansible/group_vars/windows_creds.yml`

* * *

# STEP 3 — Config Sync Abuse (LNXPROC)

### MCQ 3.1
Which network service is abused to write a cron file into `/etc`?

- A) NFS
- B) SMB
- C) FTP
- D) rsync daemon
- E) SNMP

### MCQ 3.2
Which rsync module name is used by the trigger?

- A) `root-share`
- B) `ops-sync`
- C) `server-configs`
- D) `etc-writable`
- E) `backup-drop`

### MCQ 3.3
What file does the trigger write to obtain root execution on the next minute boundary?

- A) `/etc/rc.local`
- B) `/etc/sudoers.d/attacker`
- C) `/etc/systemd/system/attacker.service`
- D) `/etc/cron.hourly/attacker`
- E) `/etc/cron.d/attacker`

### Static Question 3.4 — Credential Submission
Submit the password recovered for `ansible_svc`.

**Answer:** `Ans1bl3#Mgmt2025!`

### Static Question 3.5
What is the absolute path of the domain machine keytab left on LNXPROC?

**Answer:** `/etc/krb5.keytab`

* * *

# STEP 4 — Windows Credential Harvest (MGMT)

### MCQ 4.1
Which account is used to gain legitimate administrative access to MGMT?

- A) `svc_itops`
- B) `Administrator`
- C) `proxy-admin`
- D) `ansible_svc`
- E) `deploy_user`

### MCQ 4.2
Which configuration most directly makes LSASS dumping easier on MGMT?

- A) SMB signing disabled
- B) PowerShell logging disabled
- C) `RunAsPPL` disabled
- D) WinRM enabled
- E) RDP enabled

### MCQ 4.3
Which scheduled task helps keep `svc_itops` credential material resident on MGMT?

- A) `CorpMonitor`
- B) `ITOpsMonitor`
- C) `WindowsUpdate`
- D) `ProxyRefresh`
- E) `HealthLoader`

### Static Question 4.4 — Hash Submission
Submit the NT hash recovered for `svc_itops`.

**Answer:** `1e41c03da1d3143defa45aadf65e3afa`

### Static Question 4.5
What is the name of the service directory left writable for added realism on MGMT?

**Answer:** `C:\Program Files\CorpMonitor`

* * *

# STEP 5 — Domain Controller Compromise (DC)

### MCQ 5.1
Which share receives the malicious DLL on the domain controller?

- A) `NETLOGON`
- B) `SYSVOL`
- C) `ADMIN$`
- D) `DCHealthAgent`
- E) `Software`

### MCQ 5.2
What action does the health agent perform that makes the final stage possible?

- A) It executes any EXE in `C:\Temp`
- B) It imports any PowerShell script from SYSVOL
- C) It calls `LoadLibrary` on `health_check.dll`
- D) It runs `msiexec` on all uploaded packages
- E) It restarts DNS and applies a plugin DLL from the registry

### MCQ 5.3
Which action is used to verify full domain compromise at the end of the chain?

- A) Kerberoasting
- B) Password spraying
- C) Golden Ticket creation
- D) `secretsdump` DCSync
- E) RBCD

### Static Question 5.4 — Credential Submission
Submit the password of the domain account created by the malicious DLL.

**Answer:** `P@ssw0rd123!`

### Static Question 5.5
What is the name of the domain user created by the malicious DLL?

**Answer:** `hacker`

* * *

# Facilitator Answer Key

### Step 1
- MCQ 1.1 — **Option 2 (B)**
- MCQ 1.2 — **Option 3 (C)**
- MCQ 1.3 — **Option 4 (D)**
- Static 1.4 — `D3pl0y#2025!`
- Static 1.5 — `LNXBUILDER.cyberange.local`

### Step 2
- MCQ 2.1 — **Option 3 (C)**
- MCQ 2.2 — **Option 2 (B)**
- MCQ 2.3 — **Option 3 (C)**
- Static 2.4 — `Pr0xyAdm!n2025`
- Static 2.5 — `/opt/ansible/group_vars/windows_creds.yml`

### Step 3
- MCQ 3.1 — **Option 4 (D)**
- MCQ 3.2 — **Option 3 (C)**
- MCQ 3.3 — **Option 5 (E)**
- Static 3.4 — `Ans1bl3#Mgmt2025!`
- Static 3.5 — `/etc/krb5.keytab`

### Step 4
- MCQ 4.1 — **Option 4 (D)**
- MCQ 4.2 — **Option 3 (C)**
- MCQ 4.3 — **Option 2 (B)**
- Static 4.4 — `1e41c03da1d3143defa45aadf65e3afa`
- Static 4.5 — `C:\Program Files\CorpMonitor`

### Step 5
- MCQ 5.1 — **Option 4 (D)**
- MCQ 5.2 — **Option 3 (C)**
- MCQ 5.3 — **Option 4 (D)**
- Static 5.4 — `P@ssw0rd123!`
- Static 5.5 — `hacker`
