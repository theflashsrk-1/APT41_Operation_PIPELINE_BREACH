# Operation PIPELINE BREACH — Blue Team Writeup
## Range 3 (APT41) · Domain: cyberange.local

Range 3 is the mixed-platform chain: three Ubuntu hosts carry the first three stages (web SQL injection, a tar wildcard root escalation, and a writable rsync), then the attacker crosses onto Windows to dump LSASS on the management server and finishes with a DnsAdmins DLL load on the DC followed by DCSync. Detection therefore splits across two telemetry worlds — Linux (web logs, auditd, sshd) for stages 1 to 3, and Windows event logs for stages 4 and 5. Treat the Linux side as first-class; it is where this chain begins and where it is cheapest to stop.

Severity scale: Informational, Low, Medium, High, Critical.

SIEM examples are Splunk SPL. Linux stages query web, auditd, and sshd sourcetypes; Windows stages query the Windows add-on. Field and sourcetype names depend on your ingest and may need adjusting.

## Detection prerequisites

- Linux hosts: web server access logs (gunicorn/nginx/apache) shipped to the SIEM; auditd running with execve rules so command execution is recorded; sshd logging to `/var/log/auth.log`; cron logging.
- Windows hosts (MGMT, DC): Detailed Tracking (4688 with command line), Sysmon for LSASS access, DS Access (4662), and DNS Server audit logging enabled on the DC.
- Registry auditing or Sysmon EID 13 on the DC for the DNS `ServerLevelPluginDll` key.

## Stage 1 — Blind SQL injection (LNXW, Flask /search)

Attacker action: blind SQL injection in the Flask `/search` route, automated with sqlmap, ending with the `deploy_credentials` table dumped (and `deploy_user`'s SSH password recovered).

Telemetry and what you see:
- Web access logs fill with requests to `/search` carrying injection payloads — time-based tests like `SLEEP(5)`, boolean tests, and UNION attempts — all from one source. Time-based blind injection shows as a run of requests whose response times cluster around the injected delay.
- sqlmap leaves a heavy, machine-paced request volume and, unless changed, a recognisable User-Agent. The sheer request count against a single parameter is the giveaway.
- If a WAF or ModSecurity sits in front, it raises rule hits for SQLi signatures.

Severity: High once extraction succeeds; the database holds credentials reused for SSH.

Detection: alert on repeated SQL keywords in query parameters, on clustered delayed responses indicating time-based blind injection, and on request-rate anomalies against one endpoint.

```spl
index=web host=LNXW uri_path="/search"
| regex uri_query="(?i)(sleep|benchmark|union\s+select|information_schema|0x[0-9a-f]+)"
| stats count BY src_ip uri_query
| where count > 20
```

Response: parameterise the query, rotate `deploy_user`, and review the `deploy_credentials` table for other reused secrets.

## Stage 2 — Tar wildcard injection via root cron (LNXBUILDER)

Attacker action: SSH in as `deploy_user`, drop files named like `--checkpoint=1` and `--checkpoint-action=exec=...` into a directory a root cron job archives with `tar *`. tar interprets the filenames as options and runs the attacker's command as root.

Telemetry and what you see:
- `/var/log/auth.log` shows `Accepted password for deploy_user from <attacker IP>`.
- auditd records the cron-triggered `tar` execve, then an execve of a shell or script running as `uid=0` moments later — the parent/child timing tied to the cron schedule is the signature. Cron firing is visible in syslog.
- The malicious filenames themselves (`--checkpoint-action=exec=...`) are unusual on disk and worth hunting for.

Severity: High — this is local privilege escalation to root.

Detection: alert on auditd execve of `tar` with `--checkpoint`/`--checkpoint-action` arguments, on files whose names begin with `--`, and on root-context processes spawned by cron jobs that read attacker-writable directories.

```spl
index=linux host=LNXBUILDER sourcetype=linux_audit type=EXECVE
| search a0="tar" AND (a1="--checkpoint*" OR a2="--checkpoint-action*" OR a3="--checkpoint-action*")
```
```spl
index=linux host=LNXBUILDER sourcetype=linux_secure "Accepted password for deploy_user"
```

Response: rewrite the backup job to avoid unquoted wildcards (use `--` or explicit paths), and lock down write access to the archived directory.

## Stage 3 — Writable rsync to root (LNXPROC)

Attacker action: SSH in as `proxy-admin` (recovered on LNXBUILDER), abuses a root-run rsync over an attacker-writable path to write into a privileged location and gain root.

Telemetry and what you see:
- `/var/log/auth.log` shows the `proxy-admin` SSH login.
- auditd shows `rsync` executing in a root context and writing to sensitive paths (cron directories, SUID locations, or authorized_keys). Unexpected writes to those paths by an rsync process are the indicator.

Severity: High.

Detection: alert on root-owned rsync writing into privilege-relevant directories, and on new SUID files or cron entries appearing after an rsync run.

```spl
index=linux host=LNXPROC sourcetype=linux_audit type=EXECVE a0="rsync" uid=0
| table _time exe a0 a1 a2
```

Response: remove the writable path from the rsync job, run it under least privilege, and restrict the module/source ACLs.

## Stage 4 — LSASS dump on the management server (MGMT)

Attacker action: from root on LNXPROC, recovers `ansible_svc` (local admin on MGMT), pivots over SMB/WMI to MGMT, and dumps LSASS to extract the `svc_itops` NT hash. `svc_itops` is both a Domain Admin and a member of DnsAdmins.

Telemetry and what you see:
- Windows Security 4624 Logon Type 3 on MGMT for `ansible_svc` originating from the Linux pivot host (an unusual source for that account).
- Sysmon EID 10 on MGMT against `lsass.exe` with a credential-theft access mask.
- The extracted `svc_itops` being a Domain Admin makes this the pivot from "Linux estate compromised" to "domain at risk".

Severity: Critical — a Domain Admin hash leaves memory here.

Detection: alert on LSASS access by non-system processes on MGMT, and on `ansible_svc` authenticating from an unexpected (non-Windows-automation) source.

```spl
index=sysmon host=MGMT EventCode=10 TargetImage="*\\lsass.exe"
```
```spl
index=wineventlog host=MGMT EventCode=4624 Logon_Type=3 Account_Name=ansible_svc
| search NOT Source_Network_Address IN ("<known-automation-hosts>")
```

Response: enable RunAsPPL and Credential Guard on MGMT, scope `ansible_svc` to least privilege, and keep `svc_itops` out of interactive/cached use on member servers.

## Stage 5 — DnsAdmins ServerLevelPluginDll and DCSync (DC)

Attacker action: as `svc_itops` (DnsAdmins), sets the DNS `ServerLevelPluginDll` registry value to a malicious DLL and restarts the DNS service, loading the DLL as SYSTEM on the DC, then performs DCSync.

Telemetry and what you see:
- DNS Server event log on the DC: Event ID 770 when the plugin DLL is loaded successfully (with the DLL path), 150 on load failure, and 771 as related. The `Microsoft-Windows-DNS-Server/Audit` log records Event ID 541 when `ServerLevelPluginDll` is changed.
- A registry write to `HKLM\SYSTEM\CurrentControlSet\services\DNS\Parameters\ServerLevelPluginDll` (Sysmon EID 13 or registry auditing). Note a subtlety confirmed by detection research: when the DNS service is restarted through its RPC operation rather than the service control manager, it does not emit the usual 7036 service event — so do not rely on service-restart logging alone.
- DCSync that follows: Security 4662 on the domain object from a non-DC principal carrying `DS-Replication-Get-Changes` (`1131f6aa-9c07-11d1-f79f-00c04fc2dcd2`).

Severity: Critical.

Detection: alert on any change to the `ServerLevelPluginDll` value, on DNS Event IDs 150/770/771, on DLLs loaded by `dns.exe` from non-standard paths, and on replication requests from non-DC principals.

```spl
index=wineventlog host=DC sourcetype="WinEventLog:DNS Server" EventCode IN (150,770,771)
```
```spl
index=sysmon host=DC EventCode=13 TargetObject="*\\Services\\DNS\\Parameters\\ServerLevelPluginDll"
```
```spl
index=wineventlog host=DC EventCode=4662 Properties="*1131f6aa-9c07-11d1-f79f-00c04fc2dcd2*"
| search NOT Account_Name="DC$"
```

Response: treat as full domain compromise. Remove the registry value, restore the DNS service, audit DnsAdmins membership, rotate privileged credentials, and reset `krbtgt` twice.

## Root-cause remediation

1. Blind SQL injection in the Flask app: parameterise queries and remove plaintext credentials from the database.
2. Tar wildcard in a root cron job: quote arguments and use explicit file lists; lock the archived directory's permissions.
3. Writable rsync running as root: remove writable paths and drop the job's privileges.
4. `ansible_svc` as unconstrained local admin and `svc_itops` reachable on MGMT: least-privilege the automation account, protect LSASS, and keep Domain Admins off member servers.
5. DnsAdmins privilege on a Domain Admin account: minimise DnsAdmins membership and monitor the plugin-DLL registry value continuously.

## Detection coverage summary

| Stage | ATT&CK | Primary log source | Event ID / record | Severity |
|---|---|---|---|---|
| 1 Blind SQLi | T1190 | LNXW web access log / WAF | injection payloads, delayed responses | High |
| 2 Tar wildcard | T1548.001 | LNXBUILDER auditd / sshd / cron | execve tar `--checkpoint`, Accepted password | High |
| 3 Writable rsync | T1222 | LNXPROC auditd / sshd | rsync root writes, Accepted password | High |
| 4 LSASS on MGMT | T1003.001 | MGMT Security / Sysmon | 4624 (Type 3), Sysmon 10 | Critical |
| 5 DnsAdmins DLL + DCSync | T1574 / T1003.006 | DC DNS Server log + Security | 770/150/771, Audit 541, Sysmon 13, 4662 (repl GUID) | Critical |