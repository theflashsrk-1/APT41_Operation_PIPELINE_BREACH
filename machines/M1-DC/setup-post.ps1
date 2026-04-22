# M1 — DC — Post-Promotion Configuration
# Run after the forest is up and the server has rebooted.

Import-Module ActiveDirectory
Import-Module DnsServer

# ===========================
# OUs
# ===========================
New-ADOrganizationalUnit -Name "CorpServers" -Path "DC=cyberange,DC=local" -ErrorAction SilentlyContinue
New-ADOrganizationalUnit -Name "CorpUsers" -Path "DC=cyberange,DC=local" -ErrorAction SilentlyContinue
New-ADOrganizationalUnit -Name "ServiceAccounts" -Path "DC=cyberange,DC=local" -ErrorAction SilentlyContinue
New-ADOrganizationalUnit -Name "LinuxServers" -Path "OU=CorpServers,DC=cyberange,DC=local" -ErrorAction SilentlyContinue

# ===========================
# SERVICE ACCOUNTS
# ===========================
$svcAccounts = @(
    @{ Sam="svc_itops";  Name="svc_itops";  UPN="svc_itops@cyberange.local";  Pass="ITops#Adm1n2025!";   Desc="IT Operations Admin Account" },
    @{ Sam="deploy_user";Name="deploy_user";UPN="deploy_user@cyberange.local";Pass="D3pl0y#2025!";       Desc="Deployment Service Account" },
    @{ Sam="ansible_svc";Name="ansible_svc";UPN="ansible_svc@cyberange.local";Pass="Ans1bl3#Mgmt2025!"; Desc="Ansible Automation Account" }
)

foreach ($acct in $svcAccounts) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$($acct.Sam)'" -ErrorAction SilentlyContinue)) {
        New-ADUser `
            -Name $acct.Name `
            -SamAccountName $acct.Sam `
            -UserPrincipalName $acct.UPN `
            -Path "OU=ServiceAccounts,DC=cyberange,DC=local" `
            -AccountPassword (ConvertTo-SecureString $acct.Pass -AsPlainText -Force) `
            -Enabled $true `
            -PasswordNeverExpires $true `
            -CannotChangePassword $true `
            -Description $acct.Desc
    }
}

Add-ADGroupMember -Identity "Domain Admins" -Members "svc_itops" -ErrorAction SilentlyContinue

# ===========================
# REGULAR USERS
# ===========================
$users = @(
    @{Name="jparker";  First="James";   Last="Parker";   Pass="JP@rker2025!"},
    @{Name="slee";     First="Sarah";   Last="Lee";      Pass="SL33#2025!"},
    @{Name="mchen";    First="Michael"; Last="Chen";     Pass="MCh3n!2025"},
    @{Name="awright";  First="Amy";     Last="Wright";   Pass="Wr1ght@2025"},
    @{Name="rsingh";   First="Raj";     Last="Singh";    Pass="RS!ngh2025"},
    @{Name="lmartinez";First="Laura";   Last="Martinez"; Pass="LM@rt2025!"},
    @{Name="dwilliams";First="Daniel";  Last="Williams"; Pass="DW1ll!2025"},
    @{Name="kpatel";   First="Kavita";  Last="Patel";    Pass="KP@tel2025"},
    @{Name="tnguyen";  First="Thomas";  Last="Nguyen";   Pass="TN9uy3n!25"},
    @{Name="egarcia";  First="Elena";   Last="Garcia";   Pass="EG@rc1a25!"}
)

foreach ($u in $users) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.Name)'" -ErrorAction SilentlyContinue)) {
        New-ADUser `
            -Name "$($u.First) $($u.Last)" `
            -SamAccountName $u.Name `
            -UserPrincipalName "$($u.Name)@cyberange.local" `
            -GivenName $u.First `
            -Surname $u.Last `
            -Path "OU=CorpUsers,DC=cyberange,DC=local" `
            -AccountPassword (ConvertTo-SecureString $u.Pass -AsPlainText -Force) `
            -Enabled $true `
            -PasswordNeverExpires $true
    }
}

# ===========================
# PASSWORD POLICY
# ===========================
Set-ADDefaultDomainPasswordPolicy -Identity "cyberange.local" `
    -MinPasswordLength 8 `
    -LockoutThreshold 0 `
    -ComplexityEnabled $true `
    -MaxPasswordAge "365.00:00:00" `
    -MinPasswordAge "0.00:00:00"

# ===========================
# AUDIT / HARDENING CHANGES FOR EXERCISE
# ===========================
auditpol /set /subcategory:"Kerberos Authentication Service" /success:enable /failure:enable
auditpol /set /subcategory:"Kerberos Service Ticket Operations" /success:enable /failure:enable
auditpol /set /subcategory:"Logon" /success:enable /failure:enable
auditpol /set /subcategory:"Process Creation" /success:enable /failure:enable
auditpol /set /subcategory:"Directory Service Changes" /success:enable /failure:enable
auditpol /set /subcategory:"Computer Account Management" /success:enable /failure:enable
auditpol /set /subcategory:"User Account Management" /success:enable /failure:enable
auditpol /set /subcategory:"Sensitive Privilege Use" /success:enable /failure:enable
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" /v ProcessCreationIncludeCmdLine_Enabled /t REG_DWORD /d 1 /f

Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
Set-MpPreference -DisableIOAVProtection $true -ErrorAction SilentlyContinue
Set-MpPreference -DisableBehaviorMonitoring $true -ErrorAction SilentlyContinue
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Force -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Name "DisableAntiSpyware" -Value 1 -Type DWORD -Force -ErrorAction SilentlyContinue
Stop-Service WinDefend -Force -ErrorAction SilentlyContinue
Set-Service WinDefend -StartupType Disabled -ErrorAction SilentlyContinue
Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled False

# ===========================
# DCHEALTHAGENT — FINAL STAGE DLL LOAD PATH
# ===========================
$agentDir = "C:\DCHealthAgent"
New-Item -Path $agentDir -ItemType Directory -Force | Out-Null

if (-not (Get-SmbShare -Name "DCHealthAgent" -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name "DCHealthAgent" -Path $agentDir -FullAccess "CYBERANGE\Domain Admins" | Out-Null
}

@'
using System;
using System.Runtime.InteropServices;

public class Loader {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr LoadLibrary(string lpFileName);
}
'@ | Add-Type

$loaderScript = @'
$dllPath = "C:\DCHealthAgent\health_check.dll"
if (Test-Path $dllPath) {
    try {
        [Loader]::LoadLibrary($dllPath) | Out-Null
        "$(Get-Date) - Loaded $dllPath" | Out-File "C:\DCHealthAgent\loader.log" -Append
    } catch {
        "$(Get-Date) - Load failed: $($_.Exception.Message)" | Out-File "C:\DCHealthAgent\loader.log" -Append
    }
}
'@

Set-Content -Path "C:\DCHealthAgent\Load-HealthDll.ps1" -Value $loaderScript -Encoding UTF8

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\DCHealthAgent\Load-HealthDll.ps1"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
$trigger.Repetition.Interval = "PT1M"
$trigger.Repetition.Duration = "P1D"
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
Register-ScheduledTask -TaskName "DCHealthAgent" -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

# ===========================
# BOOTSTRAP / SELF-REGISTRATION
# ===========================
New-Item -Path "C:\LabBootstrap" -ItemType Directory -Force | Out-Null
@'
Start-Sleep -Seconds 15
$adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
$ipConfig = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
if ($ipConfig) {
    $myIP = $ipConfig.IPAddress
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses "127.0.0.1"
    ipconfig /registerdns | Out-Null
    nltest /dsregdns | Out-Null
    "$(Get-Date) - DC bootstrap OK. IP=$myIP" | Out-File "C:\LabBootstrap\bootstrap.log" -Append
}
'@ | Out-File "C:\LabBootstrap\DC-SelfUpdate.ps1" -Encoding UTF8

$bootAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\LabBootstrap\DC-SelfUpdate.ps1"
$bootTrigger = New-ScheduledTaskTrigger -AtStartup
$bootPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
Register-ScheduledTask -TaskName "LabBootstrap-DC" -Action $bootAction -Trigger $bootTrigger -Principal $bootPrincipal -Force | Out-Null

Write-Host "[+] DC post-configuration complete." -ForegroundColor Green
