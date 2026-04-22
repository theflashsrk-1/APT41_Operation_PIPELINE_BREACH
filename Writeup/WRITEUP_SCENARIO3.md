# APT41 Operation PIPELINE BREACH — Scenario 3 Write-Up

Classification: UNCLASSIFIED // EXERCISE ONLY  
Purpose: Red-Team / Blue-Team Operator Write-Up  
Scenario: Pipeline Breach  
Network: `cyberange.local`  
Platform: 3 × Ubuntu 22.04, 2 × Windows Server 2019  

* * *

## Document Purpose

This document explains how Scenario 3 is intended to be executed inside the lab and how each stage should be validated. It is written to stay consistent with the rest of the repository and to support controlled replay when the red team needs a clear, structured reference during an exercise.

This write-up is aligned to the scripted Scenario 3 attack path:

1. `LNXW` — public-facing web application compromise
2. `LNXBUILDER` — local Linux privilege escalation
3. `LNXPROC` — rsync abuse leading to root access
4. `MGMT` — credentialed management pivot and Windows credential access
5. `DC` — final domain compromise and directory replication

Wherever a value may change between deployments, a placeholder is used.

* * *

## Scope

This write-up is for the following lab hosts:

| Hostname | Role | Operating System |
|---|---|---|
| `LNXW` | Public web server | Ubuntu 22.04 |
| `LNXBUILDER` | Build server | Ubuntu 22.04 |
| `LNXPROC` | Processing / config sync server | Ubuntu 22.04 |
| `MGMT` | Management server | Windows Server 2019 |
| `DC` | Domain controller | Windows Server 2019 |

* * *

## Dynamic Placeholders

Use the following placeholders during delivery or internal adaptation:

| Placeholder | Meaning |
|---|---|
| `<KALI_IP>` | Operator / attacker VM IP |
| `<DC_IP>` | Current IP address of `DC` |
| `<LNXW_IP>` | Current IP address of `LNXW` |
| `<LNXBUILDER_IP>` | Current IP address of `LNXBUILDER` |
| `<LNXPROC_IP>` | Current IP address of `LNXPROC` |
| `<MGMT_IP>` | Current IP address of `MGMT` |
| `<DOMAIN>` | `cyberange.local` |
| `<OPERATOR_PATH>` | Local operator working directory |
| `<LOOT_PATH>` | Local loot or output directory |
| `<NT_HASH>` | NTLM hash recovered during the exercise |
| `<TIMESTAMP>` | Time value relevant to the current run |

Hostnames remain static and should be written as-is.

* * *

## Operator Prerequisites

Before starting the scenario, confirm the following:

- `DC` is online first and DNS is functioning for `cyberange.local`
- all remaining hosts are reachable and have completed bootstrap
- the operator system can resolve `DC`, `MGMT`, `LNXW`, `LNXBUILDER`, and `LNXPROC`
- the exercise tooling approved for the lab build is available on the operator box
- a clean output directory exists for notes, screenshots, and captured artifacts
- the operator has access to the internal TTP set used by your team for execution

Recommended validation checks before running the scenario:

```bash
ping -c 1 DC.cyberange.local
ping -c 1 MGMT.cyberange.local
ping -c 1 LNXW.cyberange.local
ping -c 1 LNXBUILDER.cyberange.local
ping -c 1 LNXPROC.cyberange.local
```

```bash
nslookup cyberange.local <DC_IP>
nslookup DC.cyberange.local <DC_IP>
nslookup MGMT.cyberange.local <DC_IP>
```

If DNS does not resolve correctly, do not continue until name resolution is fixed.

* * *

## Scenario Goal

The objective of Scenario 3 is to simulate a realistic cross-platform enterprise intrusion beginning from an exposed Linux web application and ending in full Active Directory compromise. The environment is designed to create realistic logs for blue-team analysis while keeping the trigger path repeatable for red-team execution.

Final success state:

- the attacker reaches code execution or privileged access on each intended pivot host
- a valid Windows administrative credential is recovered from `MGMT`
- access is obtained to `DC`
- the final stage results in directory replication / domain credential access
- the blue team receives sufficient evidence across Linux and Windows telemetry to reconstruct the attack chain

* * *

## Attack Chain Summary

| Step | Source | Target | Goal |
|---|---|---|---|
| 1 | Operator | `LNXW` | Recover deployment credentials from the vulnerable application path |
| 2 | `deploy_user` | `LNXBUILDER` | Escalate to root and recover the next credential set |
| 3 | `proxy-admin` | `LNXPROC` | Gain root and recover Windows management access |
| 4 | `ansible_svc` | `MGMT` | Recover the `svc_itops` credential material |
| 5 | `svc_itops` | `DC` | Achieve final domain compromise |

* * *

## Step 1 — Initial Access on `LNXW`

### Objective

Obtain the `deploy_user` credential from the vulnerable web application path exposed on `LNXW`.

### Starting Position

The operator begins with only network access to the lab and no domain credentials.

### What the Red Team Is Expected to Achieve

- identify the exposed application on `LNXW`
- confirm the vulnerable path is reachable
- extract the deployment credential stored in the backing data set
- validate that the recovered credential works against `LNXBUILDER`

### Required Outcome

At the end of this step, the red team should possess:

- username: `deploy_user`
- a valid password for SSH access to `LNXBUILDER`

### Beginner Notes

- keep the action focused on the intended exposed application path only
- do not overcomplicate the first stage with unnecessary enumeration
- once the credential is recovered, immediately validate it and move on

### Validation Targets

Confirm that the following is true before leaving Step 1:

- `deploy_user` is known
- the credential is valid
- the operator can authenticate to `LNXBUILDER`

Example validation only:

```bash
ssh deploy_user@LNXBUILDER.cyberange.local
```

Expected result:

- the session opens successfully
- `whoami` returns `deploy_user`
- the operator can read normal user-accessible files on `LNXBUILDER`

### Expected Blue-Team Evidence

- web requests to `LNXW`
- unusual application search activity
- backend database query activity
- new SSH login from the operator host to `LNXBUILDER`

### Operator Notes

Record:

- the time Step 1 started
- the time the credential was recovered
- the time the first successful SSH login occurred

* * *

## Step 2 — Privilege Escalation on `LNXBUILDER`

### Objective

Escalate from `deploy_user` to root on `LNXBUILDER` and recover the next credential set from the local automation material.

### Starting Position

The operator already has valid SSH access as `deploy_user`.

### What the Red Team Is Expected to Achieve

- identify the intended privileged execution path on `LNXBUILDER`
- obtain root access
- access the local Ansible material
- recover the credential used for the next host

### Required Outcome

At the end of this step, the red team should possess:

- root-level access on `LNXBUILDER`
- the `proxy-admin` credential for `LNXPROC`

### Beginner Notes

- stay inside the intended writable build path
- once root access is confirmed, keep post-exploitation minimal
- collect only what is required for the next pivot

### Validation Targets

Confirm that the following is true before leaving Step 2:

- root access is active on `LNXBUILDER`
- the next credential has been recovered
- the next credential is associated with `LNXPROC`

Example validation only:

```bash
whoami
hostname
```

Expected result:

- `whoami` returns `root`
- `hostname` returns `LNXBUILDER`

If the host uses a separate root persistence method during the lab run, document exactly which method succeeded.

### Expected Blue-Team Evidence

- SSH login by `deploy_user`
- creation of files in the writable build path
- scheduled task / cron execution
- access to local vault or credential files
- privileged shell creation

### Operator Notes

Record:

- time root access was obtained
- path used to recover the next credential
- password or secret identifier recovered for `proxy-admin`

* * *

## Step 3 — Root Access on `LNXPROC`

### Objective

Use the recovered `proxy-admin` access to reach `LNXPROC`, gain root, and recover the Windows management credential set needed for the next pivot.

### Starting Position

The operator has the `proxy-admin` credential and a working path to `LNXPROC`.

### What the Red Team Is Expected to Achieve

- authenticate to `LNXPROC`
- identify the intended writable service or configuration path
- obtain root access
- recover the Windows management credential material

### Required Outcome

At the end of this step, the red team should possess:

- root-level access on `LNXPROC`
- the `ansible_svc` credential
- any supporting artifacts needed for documentation, such as the presence of domain-join material

### Beginner Notes

- keep the action aligned to the intended exposed rsync path only
- once root is obtained, recover the Windows credential and stop
- do not alter additional files unless needed for the scenario

### Validation Targets

Confirm that the following is true before leaving Step 3:

- root access is active on `LNXPROC`
- the `ansible_svc` credential has been identified
- the operator can see domain-related material on the host if expected by the setup

Example validation only:

```bash
whoami
hostname
ls -l /etc/krb5.keytab
```

Expected result:

- `whoami` returns `root`
- `hostname` returns `LNXPROC`
- domain-join material exists if the machine was joined correctly

### Expected Blue-Team Evidence

- SSH login by `proxy-admin`
- rsync daemon activity
- creation of a scheduled file or persistence file under `/etc`
- root SSH access
- access to local automation or vault data

### Operator Notes

Record:

- the exact time `LNXPROC` root access was obtained
- the file or configuration area used in the escalation
- the recovered `ansible_svc` credential

* * *

## Step 4 — Windows Pivot on `MGMT`

### Objective

Use the Windows management credential to access `MGMT` and recover the credential material associated with `svc_itops`.

### Starting Position

The operator has valid credentials for `ansible_svc`.

### What the Red Team Is Expected to Achieve

- authenticate to `MGMT`
- confirm the account has the expected administrative rights
- access the credential material present on the host
- recover the `svc_itops` NTLM material required for the final step

### Required Outcome

At the end of this step, the red team should possess:

- confirmed administrative access on `MGMT`
- the `svc_itops` NTLM hash or equivalent credential material used by the scenario

### Beginner Notes

- validate access first
- confirm the host is the intended management server
- collect only the credential material required for the final domain pivot

### Validation Targets

Confirm that the following is true before leaving Step 4:

- the login to `MGMT` is successful
- `ansible_svc` has the expected local administrative level
- `svc_itops` credential material has been recovered

Example validation only:

```powershell
whoami
hostname
whoami /groups
```

Expected result:

- the active user matches the expected execution context
- the host is `MGMT`
- group membership indicates administrative capability

### Expected Blue-Team Evidence

- network authentication from the operator system to `MGMT`
- Windows logon events
- process creation events related to administrative execution
- access to sensitive process memory or equivalent credential-access telemetry
- scheduled task visibility for persistent logged-on service contexts if present

### Operator Notes

Record:

- the time administrative access to `MGMT` was confirmed
- the exact form of `svc_itops` material recovered
- whether the fallback path was needed during collection

* * *

## Step 5 — Final Access on `DC`

### Objective

Use the recovered `svc_itops` material to reach `DC`, complete the final privilege path, and achieve full domain compromise.

### Starting Position

The operator has `svc_itops` credential material from `MGMT`.

### What the Red Team Is Expected to Achieve

- authenticate to `DC`
- interact with the intended writable operational path on the domain controller
- trigger the final privilege action
- validate that domain-level access has been achieved
- perform the final directory replication stage

### Required Outcome

At the end of this step, the red team should possess:

- confirmed domain-level access
- successful directory replication output
- final proof that the full scenario chain executed correctly

### Beginner Notes

- stay on the intended path only
- validate each condition before moving to the next sub-step
- once final compromise is confirmed, stop and preserve evidence

### Validation Targets

Confirm that the following is true before closing the scenario:

- the operator can authenticate to `DC`
- the final privileged state has been created successfully
- directory replication succeeds
- the expected domain-level output is captured and preserved

Example validation only:

```bash
# Record proof files, timestamps, and screenshots after the final stage.
# Do not continue with unrelated actions once success is confirmed.
```

### Expected Blue-Team Evidence

- authentication to `DC`
- SMB file write activity to the intended operational path
- domain user creation or group membership change
- replication-related directory access
- security log entries associated with privilege escalation and credential replication

### Operator Notes

Record:

- the time `DC` access was established
- the time domain-level access was confirmed
- the time replication succeeded
- the artifact names saved for the report pack

* * *

## Evidence Collection Checklist

The red team should preserve the following for after-action review:

- screenshots of each successful pivot
- recovered credentials or hashes handled according to exercise procedure
- timestamps for each completed step
- hostnames and resolved IPs used during the run
- copies of operator logs stored under `<LOOT_PATH>`
- final proof of domain compromise
- any errors encountered and how they were resolved

* * *

## Blue-Team Expected Investigation Path

A defender should be able to reconstruct the scenario roughly in the following order:

1. suspicious web activity against `LNXW`
2. SSH login to `LNXBUILDER`
3. privilege escalation behavior and vault access on `LNXBUILDER`
4. authenticated rsync abuse and root activity on `LNXPROC`
5. administrative Windows access on `MGMT`
6. credential-access behavior on `MGMT`
7. privileged access and final replication activity on `DC`

This ordering should remain consistent even if timestamps shift slightly between runs.

* * *

## Common Execution Issues

### DNS Resolution Fails

Symptoms:

- hostnames do not resolve
- Kerberos-aware tooling fails
- SSH or Windows management attempts fail when using hostnames

Checks:

```bash
nslookup DC.cyberange.local <DC_IP>
cat /etc/resolv.conf
```

### Bootstrap Did Not Complete

Symptoms:

- the host is online but not resolving the domain
- expected scheduled bootstrap task or service did not run
- the host still holds an incorrect DNS configuration

Checks:

- verify the host can reach `DC`
- review the local bootstrap log on the affected machine
- confirm the machine completed its startup sequence

### Credential Validation Fails

Symptoms:

- recovered credentials do not work on the expected next host
- authentication succeeds on one protocol but not another

Checks:

- confirm the credential was copied correctly
- confirm the target hostname is correct
- confirm the host has completed setup and is reachable
- confirm the exercise run is using the intended scenario version

### Final Stage Does Not Trigger

Symptoms:

- authentication to `DC` works but final domain access is not observed
- no new privileged state appears
- replication fails

Checks:

- confirm the correct credential material was used
- confirm the intended DC-side path exists
- confirm the relevant service or loader task is active
- wait for the configured polling interval if the final stage depends on it

* * *

## Reporting Format

For internal consistency, report each step using the same structure:

### Step Title
- objective
- source host
- target host
- access obtained
- evidence collected
- expected detection points
- result

Example reporting fields:

| Field | Example |
|---|---|
| Step | Step 2 — Privilege Escalation on `LNXBUILDER` |
| Start Time | `<TIMESTAMP>` |
| End Time | `<TIMESTAMP>` |
| Starting Access | `deploy_user` |
| Result | `root on LNXBUILDER` |
| Evidence | shell screenshot, relevant log copy, recovered credential |
| Detection Opportunities | SSH logon, cron execution, sensitive file access |

* * *

## Final Success Criteria

The write-up should be considered complete for a scenario run only when all of the following are true:

- each step has a recorded start and end time
- each pivot has a short proof note
- each recovered credential is documented
- final domain-level access is confirmed
- evidence has been preserved for both red-team review and blue-team analysis

* * *

## Internal Use Note

This document is intended to sit alongside the repository documentation and the internal TTP material. It should be used as the scenario write-up and execution reference, while any step-specific controlled operator procedures remain in your approved internal materials.

