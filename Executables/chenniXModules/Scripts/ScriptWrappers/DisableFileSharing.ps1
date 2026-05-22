#Requires -RunAsAdministrator

param (
    [switch]$Silent
)

$fileSharingConfigPath = "$([Environment]::GetFolderPath('Windows'))\chenniXDesktop\2.系统配置\配置\文件共享"

# Disable network items
Disable-NetAdapterBinding -Name "*" -ComponentID ms_msclient, ms_server, ms_lltdio, ms_rspndr | Out-Null

# Disable NetBios over TCP/IP
# NetbiosOptions: 0=Use DHCP setting, 1=Enable, 2=Disable
$interfaces = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces" -Recurse | Where-Object { $_.GetValue("NetbiosOptions") -ne $null }
foreach ($interface in $interfaces) {
    Set-ItemProperty -Path $interface.PSPath -Name "NetbiosOptions" -Value 2 | Out-Null
}

# Disable NetBIOS service
sc.exe config NetBT start=disabled | Out-Null

# Set network profile to 'Public Network'
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Public

# Disable network discovery firewall rules
Get-NetFirewallRule | Where-Object {
    # File and Printer Sharing, Network Discovery
    (($_.Group -eq "@FirewallAPI.dll,-28502" -or $_.Group -eq "@FirewallAPI.dll,-32752") -or
     ($_.DisplayGroup -eq "File and Printer Sharing" -or $_.DisplayGroup -eq "Network Discovery")) -and
    $_.Profile -like "*Private*"
} | Disable-NetFirewallRule

Start-Process -FilePath "$fileSharingConfigPath\网络导航窗格\Disable Network Navigation Pane (default).cmd" -ArgumentList "/silent" -WindowStyle Hidden
Start-Process -FilePath "$fileSharingConfigPath\授予访问菜单\Disable Give Access To Menu (default).cmd" -ArgumentList "/silent" -WindowStyle Hidden

if ($Silent) { exit }

Write-Host "`nCompleted! " -ForegroundColor Green -NoNewLine
Write-Host "You'll need to restart to apply the changes." -ForegroundColor Yellow
exit