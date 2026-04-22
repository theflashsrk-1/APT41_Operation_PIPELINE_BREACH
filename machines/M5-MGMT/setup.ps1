# M5 — MGMT — Setup Script
# Run after the DC exists. Use a local administrator session.

Rename-Computer -NewName "MGMT" -Force
Restart-Computer -Force

# Run the rest after reboot.
Set-DnsClientServerAddress -InterfaceAlias "Ethernet0" -ServerAddresses "13.22.44.10"
$cred = Get-Credential  # CYBERANGE\Administrator
Add-Computer -DomainName "cyberange.local" -Credential $cred -OUPath "OU=CorpServers,DC=cyberange,DC=local" -Force
Restart-Computer -Force

# Re-run after domain join.
$svcPath = "C:\Program Files\CorpMonitor"
New-Item -Path $svcPath -ItemType Directory -Force | Out-Null

@'
while ($true) {
    try {
        $dllPath = "C:\Program Files\CorpMonitor\logger.dll"
        if (Test-Path $dllPath) {
            [System.Reflection.Assembly]::LoadFile($dllPath) | Out-Null
        }
        Add-Content "C:\Program Files\CorpMonitor\monitor.log" "$(Get-Date) - CorpMonitor heartbeat"
    } catch {}
    Start-Sleep -Seconds 60
}
'@ | Out-File "$svcPath\CorpMonitor.ps1" -Encoding UTF8

@"
@echo off
powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Program Files\CorpMonitor\CorpMonitor.ps1"
"@ | Out-File "$svcPath\CorpMonitor.bat" -Encoding ASCII

sc.exe create CorpMonitor binPath= "cmd.exe /c `"C:\Program Files\CorpMonitor\CorpMonitor.bat`"" start= auto
sc.exe start CorpMonitor 2>$null

$acl = Get-Acl $svcPath
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "CYBERANGE\Domain Users",
    "Modify",
    "ContainerInherit,ObjectInherit",
    "None",
    "Allow"
)
$acl.AddAccessRule($rule)
Set-Acl $svcPath $acl

'placeholder' | Out-File "$svcPath\logger.dll.readme" -Encoding ASCII
"$(Get-Date) - CorpMonitor installed and started" | Out-File "$svcPath\monitor.log" -Encoding UTF8

Enable-PSRemoting -Force -SkipNetworkProfileCheck
New-NetFirewallRule -DisplayName "Allow WinRM" -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow -ErrorAction SilentlyContinue
Add-LocalGroupMember -Group "Administrators" -Member "CYBERANGE\ansible_svc" -ErrorAction SilentlyContinue

Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "RunAsPPL" -Value 0 -Type DWORD -Force
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest" /v UseLogonCredential /t REG_DWORD /d 1 /f
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "LocalAccountTokenFilterPolicy" -Value 1 -Type DWORD -Force

Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Force -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Name "DisableAntiSpyware" -Value 1 -Type DWORD -Force -ErrorAction SilentlyContinue
Stop-Service WinDefend -Force -ErrorAction SilentlyContinue
Set-Service WinDefend -StartupType Disabled -ErrorAction SilentlyContinue
Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled False

auditpol /set /subcategory:"Process Creation" /success:enable /failure:enable
auditpol /set /subcategory:"Logon" /success:enable /failure:enable
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" /v ProcessCreationIncludeCmdLine_Enabled /t REG_DWORD /d 1 /f

# Maintain a persistent svc_itops logon context for LSASS collection.
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -Command `"while(`$true){Start-Sleep -Seconds 3600}`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DontStopOnIdleEnd -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName "ITOpsMonitor" -Action $action -Trigger $trigger -Settings $settings -User "CYBERANGE\svc_itops" -Password "ITops#Adm1n2025!" -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName "ITOpsMonitor"

New-Item -Path "C:\LabBootstrap" -ItemType Directory -Force | Out-Null
@'
$maxRetries = 30
for ($i = 0; $i -lt $maxRetries; $i++) {
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Name -notlike '*Loopback*' } | Select-Object -First 1
    $ipConfig = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
    if ($ipConfig) {
        $myIP = $ipConfig.IPAddress
        $octets = $myIP.Split('.')
        $dcIP = "$($octets[0]).$($octets[1]).$($octets[2]).10"
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $dcIP
        try {
            Resolve-DnsName -Name "cyberange.local" -ErrorAction Stop | Out-Null
            ipconfig /registerdns | Out-Null
            "$(Get-Date) - Bootstrap OK. DC=$dcIP MyIP=$myIP" | Out-File "C:\LabBootstrap\bootstrap.log" -Append
            exit 0
        } catch {}
    }
    Start-Sleep -Seconds 10
}
'@ | Out-File "C:\LabBootstrap\Find-DC.ps1" -Encoding UTF8

$bootAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\LabBootstrap\Find-DC.ps1"
$bootTrigger = New-ScheduledTaskTrigger -AtStartup
$bootPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
Register-ScheduledTask -TaskName "LabBootstrap" -Action $bootAction -Trigger $bootTrigger -Principal $bootPrincipal -Force | Out-Null

Write-Host "[+] MGMT setup complete." -ForegroundColor Green
