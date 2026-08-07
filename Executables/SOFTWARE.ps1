<#
  chenniXOS SOFTWARE.ps1 - 实用软件本地安装脚本
  改写自 AtlasPlaybook SOFTWARE.ps1 (Atlas-OS, MIT)。
  保留原安装逻辑；将 curl 下载改为读取 .\Software\ 下的本地安装包。
  已排除：Atlas Toolbox、可选浏览器 (Brave/Firefox/LibreWolf/Chrome)、7-Zip 回退。
#>

$ErrorActionPreference = 'Continue'

# 本地安装包目录（本脚本旁的 .\Software\）
$softwareDir = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'Software' } else { 'Software' }

# 静默安装参数集（与 Atlas 一致）
$msiArgs    = "/qn /quiet /norestart ALLUSERS=1 REBOOT=ReallySuppress"
$legacyArgs = '/q /norestart'
$modernArgs = "/install /quiet /norestart"

# 用于 MSI / exe 解压的临时工作目录
$tempDir = Join-Path -Path $env:TEMP -ChildPath ("chenniXOS-Software-" + ([guid]::NewGuid().ToString()))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    # -------------------------------------------------------------------------
    # Visual C++ 运行时（12 个：2005-2022，x64 + x86）
    # https://learn.microsoft.com/en-US/cpp/windows/latest-supported-vc-redist
    # -------------------------------------------------------------------------
    $vcredists = [ordered] @{
        # 2005 - SP1（基于 MSI：先解压再 msiexec）
        "vcredist-2005-x64.exe" = @("2005-x64", "/c /q /t:")
        "vcredist-2005-x86.exe" = @("2005-x86", "/c /q /t:")
        # 2008 - SP1（先解压再 msiexec）
        "vcredist-2008-x64.exe" = @("2008-x64", "/q /extract:")
        "vcredist-2008-x86.exe" = @("2008-x86", "/q /extract:")
        # 2010 - SP1
        "vcredist-2010-x64.exe" = @("2010-x64", $legacyArgs)
        "vcredist-2010-x86.exe" = @("2010-x86", $legacyArgs)
        # 2012
        "vcredist-2012-x64.exe" = @("2012-x64", $modernArgs)
        "vcredist-2012-x86.exe" = @("2012-x86", $modernArgs)
        # 2013
        "vcredist-2013-x64.exe" = @("2013-x64", $modernArgs)
        "vcredist-2013-x86.exe" = @("2013-x86", $modernArgs)
        # 2015-2022（2015+）
        "vcredist-2015-x64.exe" = @("2015-x64", $modernArgs)
        "vcredist-2015-x86.exe" = @("2015-x86", $modernArgs)
    }

    foreach ($a in $vcredists.GetEnumerator()) {
        $vcName = $a.Value[0]
        $vcArgs = $a.Value[1]
        $vcExePath = Join-Path $softwareDir $a.Name

        Write-Output "Installing Visual C++ Runtime $vcName..."
        if (!(Test-Path -LiteralPath $vcExePath)) {
            Write-Error "Visual C++ Runtime $vcName installer not found at '$vcExePath', skipping."
            continue
        }

        if ($vcArgs -match ":") {
            $msiDir = Join-Path $tempDir "vcredist-$vcName"
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

    # -------------------------------------------------------------------------
    # NanaZip（用本地 .msixbundle + License .xml 预配 AppX）
    # -------------------------------------------------------------------------
    $nanaZipInstalled = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "*NanaZip*" }
    if ($nanaZipInstalled) {
        Write-Output "NanaZip is already installed, skipping installation."
    }
    else {
        $nanazipBundle  = Get-ChildItem -LiteralPath $softwareDir -Filter "*.msixbundle" -EA 0 | Select-Object -First 1
        $nanazipLicense = Get-ChildItem -LiteralPath $softwareDir -Filter "*.xml"          -EA 0 | Select-Object -First 1
        if ($nanazipBundle -and $nanazipLicense) {
            Write-Output "Installing NanaZip..."
            try {
                Add-AppxProvisionedPackage -Online -PackagePath $nanazipBundle.FullName -LicensePath $nanazipLicense.FullName | Out-Null
                Write-Output "Installed NanaZip!"
            }
            catch {
                Write-Error "Failed to install NanaZip! $_"
            }
        }
        else {
            Write-Error "NanaZip installer (.msixbundle) or License (.xml) not found in '$softwareDir', skipping."
        }
    }

    # -------------------------------------------------------------------------
    # 旧版 DirectX 运行时（2010 年 6 月）
    # -------------------------------------------------------------------------
    $directxExe = Join-Path $softwareDir "directx_Jun2010_redist.exe"
    if (Test-Path -LiteralPath $directxExe) {
        Write-Output "Extracting legacy DirectX runtimes..."
        $dxDir = Join-Path $tempDir "directx"
        Start-Process -FilePath $directxExe -WindowStyle Hidden -ArgumentList "/q /c /t:`"$dxDir`"" -Wait
        Write-Output "Installing legacy DirectX runtimes..."
        Start-Process -FilePath "$dxDir\dxsetup.exe" -WindowStyle Hidden -ArgumentList '/silent' -Wait
    }
    else {
        Write-Error "DirectX installer not found at '$directxExe', skipping."
    }
}
finally {
    # 删除临时目录
    Remove-Item -Path $tempDir -Force -Recurse -EA 0
}
