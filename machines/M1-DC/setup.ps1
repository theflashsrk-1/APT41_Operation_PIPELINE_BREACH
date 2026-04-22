# M1 — DC — Base Build
# Run on a clean Windows Server 2019 host as local Administrator.

Rename-Computer -NewName "DC" -Force

# Optional static addressing for fixed-lab deployments.
# Comment out if your orchestration layer already handles addressing.
New-NetIPAddress -InterfaceAlias "Ethernet0" -IPAddress "13.22.44.10" -PrefixLength 24 -DefaultGateway "13.22.44.2" -ErrorAction SilentlyContinue
Set-DnsClientServerAddress -InterfaceAlias "Ethernet0" -ServerAddresses "127.0.0.1"

Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
Install-WindowsFeature DNS -IncludeManagementTools
Install-WindowsFeature RSAT-DNS-Server

$safeModePass = ConvertTo-SecureString "LabSafeMode123!" -AsPlainText -Force

Install-ADDSForest `
    -DomainName "cyberange.local" `
    -DomainNetbiosName "CYBERANGE" `
    -ForestMode "WinThreshold" `
    -DomainMode "WinThreshold" `
    -InstallDns:$true `
    -SafeModeAdministratorPassword $safeModePass `
    -NoRebootOnCompletion:$false `
    -Force:$true
