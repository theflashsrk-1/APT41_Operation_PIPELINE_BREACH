# Operation PIPELINE BREACH — Full Storyline

## Intelligence Brief

Operation: PIPELINE BREACH  
Classification: UNCLASSIFIED // EXERCISE ONLY  
Issuing Authority: Corporate Incident Response Division (CIRD)  
Target Organization: Psychorp Industrial Systems  
Threat Actor Emulation: APT41-aligned intrusion pattern  
Date: [EXERCISE DATE]

* * *

## Situation

Psychorp Industrial Systems operates a small internal software delivery environment supporting warehouse, asset, and edge-device management. The estate is typical of a mid-sized enterprise with limited segregation between engineering, operational Linux administration, and Windows domain operations.

The company’s external-facing inventory platform was developed quickly to support remote teams and third-party logistics staff. Behind that application sits a build server used to package internal releases, a Linux proxy host used for configuration synchronization, a Windows management node used by administrators and automation tooling, and a single Active Directory domain controller providing DNS and identity services.

Threat reporting indicates a highly capable actor is targeting organizations with exactly this profile: mixed Linux/Windows estates, exposed application surfaces, and operational credentials stored in local automation systems. Rather than relying on malware-heavy tradecraft early, the actor is assessed to favor legitimate services, harvested credentials, and built-in administrative paths.

* * *

## Assessment

The simulated adversary follows a practical intrusion route:

1. **Exploit the public application surface** to obtain a legitimate foothold.
2. **Abuse trusted operational automation** on Linux to escalate privileges and recover additional credentials.
3. **Cross the Linux / Windows boundary** using service-account material rather than overt exploit code.
4. **Harvest administrator secrets already resident in memory** on a management server.
5. **Convert domain-level access into full directory replication rights** using a writable DLL load path on the domain controller.

The exercise is built to reward defenders who correlate weak signals across multiple platforms rather than chasing a single “loud” event.

* * *

## Environment Narrative

### M2 — LNXW: Psychorp Inventory Portal

LNXW hosts the public inventory search application used by procurement staff and partner vendors to verify stock levels. The application was rushed into production and still performs SQL queries using string concatenation in the search workflow. Because the endpoint is public and appears low risk, it draws little operational scrutiny.

### M3 — LNXBUILDER: Internal Build Automation

LNXBUILDER packages deployment artifacts for internal releases. Engineers upload files to `/opt/builds`, and a root-owned cron job archives the directory on a short schedule. An Ansible vault is kept locally for convenience, including credentials for downstream operational systems.

### M4 — LNXPROC: Proxy and Config Sync Host

LNXPROC distributes configuration updates. Administrators created an rsync daemon module pointing directly at `/etc` so that configuration changes could be pushed quickly. Authentication exists, but the authorized user is over-privileged and can write cron content as root-owned files. The server is also joined to the domain, leaving a machine keytab behind as another potential artifact.

### M5 — MGMT: Windows Operations Hub

MGMT is the place where automation and human administration intersect. `ansible_svc` is trusted for Windows maintenance and is therefore a local administrator. `svc_itops` also maintains a persistent session through a scheduled task. Defensive controls are intentionally weak enough that an operator with administrative access can recover credential material from LSASS without needing an additional local privilege escalation.

A writable `CorpMonitor` service directory is left in place to reflect the sort of service-hardening gap commonly found on internally managed Windows servers. It gives defenders extra forensic surface even though the supplied trigger path does not rely on it.

### M1 — DC: Identity and DNS Core

The domain controller hosts AD DS and DNS for `cyberange.local`. For operational convenience, an internal health agent periodically checks a DLL path under `C:\DCHealthAgent` and loads it if present. The share is intended for trusted IT operations staff, but in practice any compromise of that trust boundary is catastrophic because the DLL is loaded by a SYSTEM-context process.

* * *

## Adversary Objectives

### Primary Objective
Obtain domain administrator access and replicate directory secrets.

### Secondary Objectives
- Demonstrate end-to-end movement from public web entry point to AD compromise.
- Exercise blue-team correlation across web, Linux, Windows, and domain logs.
- Force defenders to identify operational trust failures rather than single-host malware indicators.

* * *

## Expected Operator Timeline

### Phase 1 — Initial Access
The operator reaches the inventory search function over HTTP and fingerprints the stack. Time-based SQL injection confirms backend query manipulation. A database dump reveals deployment credentials used elsewhere in the environment.

### Phase 2 — Linux Privilege Escalation
Using the recovered SSH password, the operator logs onto the build server, observes the root cron archive process, and plants `tar` checkpoint arguments as filenames. The resulting root execution yields vault access and the next credential.

### Phase 3 — Operational Service Abuse
The operator authenticates to the rsync daemon on LNXPROC, writes a cron file into `/etc/cron.d`, and establishes root persistence via SSH key injection. A second vault yields the Windows management account.

### Phase 4 — Windows Credential Harvest
The operator pivots to MGMT with legitimate admin credentials, confirms local administrator rights, and extracts `svc_itops` material from LSASS. This stage is intentionally low-noise compared with typical malware deployment and is meant to resemble hands-on-keyboard activity.

### Phase 5 — Domain Dominance
The operator authenticates to the DC with the recovered `svc_itops` hash, uploads a malicious DLL into the health-agent path, waits for it to be loaded, validates creation of a new domain admin account, and performs DCSync.

* * *

## Blue-Team Focus Areas

### Web Tier
- Unusual request timing and parameter patterns on `/search`
- Repeated error / latency anomalies against the same endpoint
- DB access to sensitive credential tables not normally exposed through search

### Linux Tier
- SSH from unusual source to build and proxy hosts
- Suspicious filenames beginning with `--checkpoint`
- Creation of new cron files through rsync-backed workflows
- Vault decryption and keytab access outside normal maintenance windows

### Windows Tier
- WinRM / SMB logons by automation accounts from unexpected source systems
- LSASS access telemetry, especially after service-account logons
- Persistence tasks running under privileged domain users
- New SMB writes to `DCHealthAgent`

### Active Directory
- New domain user creation
- Membership changes to `Domain Admins`
- Directory replication requests from a newly created account

* * *

## Exercise Outcome

A successful participant should be able to reconstruct the entire chain from exposed web application to domain compromise, identify the weak trust assumptions that made each hop possible, and explain which platform logs would have given defenders the earliest reliable signal.
