param (
    [switch]$Local
)

.\chenniXModules\initPowerShell.ps1

$timeouts = @("--connect-timeout", "10", "--retry", "5", "--retry-delay", "0", "--retry-all-errors")
$msiArgs = "/qn /quiet /norestart ALLUSERS=1 REBOOT=ReallySuppress"
$arm = ((Get-CimInstance -Class Win32_ComputerSystem).SystemType -match 'ARM64') -or ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64')

# 完美的解决方案：完全避免中文字符路径！通过查找文件来找目录！（放在 Push-Location 之前！）
$localDir = $null
# 从 Executables 目录开始查找
$execDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $execDir) { $execDir = Get-Location }
$file = Get-ChildItem -Path $execDir -Recurse -Filter "7z2601-x64.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($file) { $localDir = $file.DirectoryName }
Write-Output "Local software directory found at: $localDir"

function Remove-TempDirectory { Pop-Location; Remove-Item -Path $tempDir -Force -Recurse -EA 0 }
$tempDir = Join-Path -Path $env:TEMP -ChildPath ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
Push-Location $tempDir

function Install7Zip {
    $website = 'https://7-zip.org/'
    $7zipArch = ('x64', 'arm64')[$arm]
    $download = $website + ((Invoke-WebRequest $website -UseBasicParsing).Links.href | Where-Object { $_ -like "a/7z*-$7zipArch.exe" })
    Write-Output "Downloading 7-Zip..."
    & curl.exe -LSs $download -o "$tempDir\7zip.exe" $timeouts
    Write-Output "Installing 7-Zip..."
    Start-Process -FilePath "$tempDir\7zip.exe" -WindowStyle Hidden -ArgumentList '/S' -Wait
}

function InstallNanaZip {
    Write-Output "Downloading NanaZip..."
    $path = New-Item "$tempDir\nanazip" -ItemType Directory
    $assets | ForEach-Object {
        $filename = $_ -split '/' | Select-Object -Last 1
        Write-Output "Downloading '$filename'..."
        & curl.exe -LSs $_ -o "$path\$filename" $timeouts
    }

    Write-Output "Installing NanaZip..."
    try {
        $appxArgs = @{
            "PackagePath" = (Get-ChildItem $path -Filter "*.msixbundle" | Select-Object -First 1).FullName
            "LicensePath" = (Get-ChildItem $path -Filter "*.xml" | Select-Object -First 1).FullName
        }
        Add-AppxProvisionedPackage -Online @appxArgs | Out-Null
        Write-Output "Installed NanaZip!"
    }
    catch {
        Write-Error "Failed to install NanaZip! Getting 7-Zip instead. $_"
        Install7Zip
    }
}

function InstallVcRedistsOnline {
    $legacyArgs = '/q /norestart'
    $modernArgs = "/install /quiet /norestart"

    $vcredists = [ordered] @{
        "https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x64.exe"       = @("2005-x64", "/c /q /t:")
        "https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x86.exe"       = @("2005-x86", "/c /q /t:")
        "https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x64.exe"       = @("2008-x64", "/q /extract:")
        "https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x86.exe"       = @("2008-x86", "/q /extract:")
        "https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe"       = @("2010-x64", $legacyArgs)
        "https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe"       = @("2010-x86", $legacyArgs)
        "https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe" = @("2012-x64", $modernArgs)
        "https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe" = @("2012-x86", $modernArgs)
        "https://aka.ms/highdpimfc2013x64enu"                                                                       = @("2013-x64", $modernArgs)
        "https://aka.ms/highdpimfc2013x86enu"                                                                       = @("2013-x86", $modernArgs)
        "https://aka.ms/vs/17/release/vc_redist.x64.exe"                                                            = @("2015+-x64", $modernArgs)
        "https://aka.ms/vs/17/release/vc_redist.x86.exe"                                                            = @("2015+-x86", $modernArgs)
    }
    foreach ($a in $vcredists.GetEnumerator()) {
        $vcName = $a.Value[0]
        $vcArgs = $a.Value[1]
        $vcUrl = $a.Name
        $vcExePath = "$tempDir\vcredist-$vcName.exe"
        Write-Output "Downloading and installing Visual C++ Runtime $vcName..."
        & curl.exe -LSs "$vcUrl" -o "$vcExePath" $timeouts
        if ($vcArgs -match ":") {
            $msiDir = "$tempDir\vcredist-$vcName"
            Start-Process -FilePath $vcExePath -ArgumentList "$vcArgs`"$msiDir`"" -Wait -WindowStyle Hidden
            $msiPaths = (Get-ChildItem -Path $msiDir -Filter *.msi -EA 0).FullName
            if (!$msiPaths) {
                Write-Output "Failed to extract MSI for $vcName, not installing."
            }
            else {
                $msiPaths | ForEach-Object {
                    Start-Process -FilePath "msiexec.exe" -ArgumentList "/log `"$msiDir\logfile.log`" /i `"$_`" $msiArgs" -WindowStyle Hidden
                }
            }
        }
        else {
            Start-Process -FilePath $vcExePath -ArgumentList $vcArgs -Wait -WindowStyle Hidden
        }
    }
}

function InstallDirectXOnline {
    & curl.exe -LSs "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe" -o "$tempDir\directx.exe" $timeouts
    Write-Output "Extracting legacy DirectX runtimes..."
    Start-Process -FilePath "$tempDir\directx.exe" -WindowStyle Hidden -ArgumentList "/q /c /t:`"$tempDir\directx`"" -Wait
    Write-Output "Installing legacy DirectX runtimes..."
    Start-Process -FilePath "$tempDir\directx\dxsetup.exe" -WindowStyle Hidden -ArgumentList '/silent' -Wait
}

function InstallNanaZipLocal {
    param([string]$MsixPath, [string]$XmlPath)
    Write-Output "Installing NanaZip from local..."
    $alreadyInstalled = Get-AppxPackage *NanaZip*
    if ($alreadyInstalled) {
        Write-Output "NanaZip is already installed, skipping."
        return
    }
    try {
        Add-AppxProvisionedPackage -Online -PackagePath $MsixPath -LicensePath $XmlPath | Out-Null
        $verify = Get-AppxPackage *NanaZip*
        if ($verify) {
            Write-Output "Installed NanaZip via Add-AppxProvisionedPackage!"
            return
        }
        Write-Warning "Add-AppxProvisionedPackage completed but NanaZip not found, trying Add-AppxPackage..."
    }
    catch {
        Write-Warning "Add-AppxProvisionedPackage failed: $_"
        Write-Output "Trying Add-AppxPackage instead..."
    }
    try {
        Add-AppxPackage -Path $MsixPath
        Write-Output "Installed NanaZip via Add-AppxPackage!"
    }
    catch {
        Write-Error "Failed to install NanaZip from local! Falling back to 7-Zip. $_"
        Install7ZipLocalOrOnline
    }
}

function Install7ZipLocalOrOnline {
    $7zipLocal = Get-ChildItem -Path $localDir -Filter "7z*.exe" -EA 0 | Select-Object -First 1
    $7zipRegistry = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\7-Zip"
    if (Test-Path $7zipRegistry) { Write-Output "7-Zip is already installed, skipping."; return }
    if ($7zipLocal) {
        Write-Output "Installing 7-Zip from local ($($7zipLocal.Name))..."
        Start-Process -FilePath $7zipLocal.FullName -WindowStyle Hidden -ArgumentList '/S' -Wait
        if (Test-Path $7zipRegistry) { Write-Output "7-Zip installed successfully!" }
        else { Write-Warning "7-Zip installer ran but registry entry not found!" }
    }
    else {
        Write-Warning "7-Zip installer not found locally, downloading 7-Zip..."
        Install7Zip
    }
}

if ($Local) {
    Write-Output "=== Local installation mode ==="
    if (-not $localDir) {
        Write-Error "Could not find local software directory (7z2601-x64.exe not found)"
        Remove-TempDirectory
        exit 1
    }
    Write-Output "Local install directory: $localDir"

    if (-not (Test-Path $localDir)) {
        Write-Error "Local install directory not found: $localDir"
        Remove-TempDirectory
        exit 1
    }

    $nanaZipInstalled = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "*NanaZip*" }
    if ($nanaZipInstalled) {
        Write-Output "NanaZip is already installed, skipping."
    }
    else {
        $7zipRegistry = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\7-Zip"
        if (Test-Path $7zipRegistry) {
            Write-Output "7-Zip is already installed, skipping."
        }
        else {
            $nanazipMsix = Get-ChildItem -Path $localDir -Filter "*.msixbundle" -EA 0 | Select-Object -First 1
            $nanazipXml = Get-ChildItem -Path $localDir -Filter "*.xml" -EA 0 | Select-Object -First 1
            if ($nanazipMsix -and $nanazipXml) {
                InstallNanaZipLocal -MsixPath $nanazipMsix.FullName -XmlPath $nanazipXml.FullName
            }
            else {
                Install7ZipLocalOrOnline
            }
        }
    }

    $vcModernLocal = Get-ChildItem -Path $localDir -Filter "vc_redist*.exe" -EA 0
    if ($vcModernLocal) {
        foreach ($vc in $vcModernLocal) {
            Write-Output "Installing VC++ Redist from local ($($vc.Name))..."
            Start-Process -FilePath $vc.FullName -WindowStyle Hidden -ArgumentList '/install /quiet /norestart' -Wait
        }
    }
    else {
        Write-Warning "VC++ Redist installers not found locally, falling back to online..."
        InstallVcRedistsOnline
    }

    if (Test-Path $localDir) {
        $dxLocal = Get-ChildItem -Path $localDir -Filter "directx*.exe" -EA 0 | Select-Object -First 1
        if ($dxLocal) {
            Write-Output "Installing DirectX from local ($($dxLocal.Name))..."
            $dxTemp = "$tempDir\directx"
            Start-Process -FilePath $dxLocal.FullName -WindowStyle Hidden -ArgumentList "/q /c /t:`"$dxTemp`"" -Wait
            if (Test-Path "$dxTemp\dxsetup.exe") {
                Start-Process -FilePath "$dxTemp\dxsetup.exe" -WindowStyle Hidden -ArgumentList '/silent' -Wait
            }
        }
        else {
            Write-Warning "DirectX installer not found locally, falling back to online..."
            InstallDirectXOnline
        }
    }
    else {
        Write-Warning "Local install directory not found, falling back to online for DirectX..."
        InstallDirectXOnline
    }

    Remove-TempDirectory
    exit
}

$githubApi = Invoke-RestMethod "https://api.github.com/repos/M2Team/NanaZip/releases/latest" -EA 0
$assets = $githubApi.Assets.browser_download_url | Select-String ".xml", ".msixbundle" | Select-Object -Unique -First 2
Write-Output "=== Online installation mode ==="
InstallVcRedistsOnline
$nanaZipInstalled = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "*NanaZip*" }
if ($nanaZipInstalled) {
    Write-Output "NanaZip is already installed, skipping installation."
}
elseif ($assets.Count -eq 2) {
    $7zipRegistry = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\7-Zip"
    if (Test-Path $7zipRegistry) {
        $Message = @'
Would you like to uninstall 7-Zip and replace it with NanaZip?
'@
        if ((Read-MessageBox -Title 'Installing NanaZip - chenniXOS' -Body $Message -Icon Question) -eq 'Yes') {
            $7zipUninstall = (Get-ItemProperty -Path $7zipRegistry -Name "QuietUninstallString" -EA 0).QuietUninstallString
            Start-Process -FilePath "cmd" -WindowStyle Hidden -ArgumentList "/c $7zipUninstall" -Wait
            InstallNanaZip
        }
        else { Write-Output "Keeping existing 7-Zip installation." }
    }
    else { InstallNanaZip }
}
else { Write-Error "Can't access GitHub API, downloading 7-Zip instead of NanaZip."; Install7Zip }
InstallDirectXOnline
Remove-TempDirectory