<#
  chenniXOS SetTheme.ps1 - 应用系统主题
  改写自 AtlasPlaybook Themes.psm1 (Atlas-OS, MIT)。
  原版依赖 AtlasModules\initPowerShell.ps1 的 dot-source 加载 Themes 模块；
  此处已将 Set-Theme / Set-ThemeMRU / Set-LockscreenImage 三个函数内联为独立脚本，
  通过 -Action 参数控制执行哪一步，供 themes.yml 分步调用。
#>

param (
    [ValidateSet('Apply', 'MRU', 'Lockscreen', 'All')]
    [string]$Action = 'All',

    [ValidateNotNullOrEmpty()]
    [string]$ThemePath = "$([Environment]::GetFolderPath('Windows'))\Resources\Themes\chenniXOS-dark.theme",

    [ValidateNotNullOrEmpty()]
    [string]$LockscreenPath = "$([Environment]::GetFolderPath('Windows'))\chenniXOS\Wallpapers\lockscreen_dark.png"
)

$ErrorActionPreference = 'Stop'
$windir = [Environment]::GetFolderPath('Windows')

# 终止设置/控制面板进程，避免占用主题资源
function Stop-ThemeProcesses {
    Get-Process 'SystemSettings', 'control' -EA 0 | Stop-Process -Force -EA 0
}

# 通过 COM ThemeManager2 应用 .theme 文件；失败时回退用 explorer 打开
function Set-Theme {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (!((Get-Item $Path -EA 0).Extension -eq '.theme')) {
        throw "'$Path' is not a valid path to a theme file."
    }

    function Set-ThemeUsingExplorer {
        Write-Warning "Failed to apply theme using COM, falling back to launching file..."

        Stop-ThemeProcesses
        Start-Process -FilePath explorer -ArgumentList $Path
        Start-Sleep 10
    }

    Add-Type @'
using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

public static class ThemeManagerAPI
{
    public static void ApplyTheme(string themeFilePath)
    {
        IThemeManager themeManager = new ThemeManagerClass();
        themeManager.ApplyTheme(themeFilePath);
    }

    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("D23CC733-5522-406D-8DFB-B3CF5EF52A71")]
    [ComImport]
    public interface ITheme
    {
    }

    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("0646EBBE-C1B7-4045-8FD0-FFD65D3FC792")]
    [ComImport]
    public interface IThemeManager
    {
        [DispId(1610678272)]
        ITheme CurrentTheme { get; }

        [MethodImpl(MethodImplOptions.InternalCall, MethodCodeType = MethodCodeType.Runtime)]
        void ApplyTheme([MarshalAs(UnmanagedType.BStr)] string themeFilePath);
    }

    [TypeLibType(TypeLibTypeFlags.FCanCreate)]
    [Guid("C04B329E-5823-4415-9C93-BA44688947B0")]
    [ClassInterface(ClassInterfaceType.None)]
    [ComImport]
    public class ThemeManagerClass : IThemeManager
    {
        [DispId(1610678272)]
        public virtual extern ITheme CurrentTheme { [MethodImpl(MethodImplOptions.InternalCall, MethodCodeType = MethodCodeType.Runtime)] get; }

        [MethodImpl(MethodImplOptions.InternalCall, MethodCodeType = MethodCodeType.Runtime)]
        public virtual extern void ApplyTheme([MarshalAs(UnmanagedType.BStr)] string themeFilePath);
    }
}
'@

    try {
        [ThemeManagerAPI]::ApplyTheme($Path)
    } catch {
        Set-ThemeUsingExplorer
    }

    Stop-ThemeProcesses
}

# 写入最近使用的主题列表（仅 Win11 Build >= 22000）
# chenniXOS 只保留 chenniXOS-dark 一个主题
function Set-ThemeMRU {
    if ([System.Environment]::OSVersion.Version.Build -ge 22000) {
        Stop-ThemeProcesses
        $mru = "$windir\resources\Themes\chenniXOS-dark.theme;"
        Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes" -Name "ThemeMRU" -Value $mru -Type String -Force
    }
}

# 通过 WinRT 设置锁屏壁纸，默认使用 chenniXOS 锁屏图
# 详见 https://superuser.com/a/1343640
function Set-LockscreenImage {
    param (
        [ValidateNotNullOrEmpty()]
        [string]$Path = "$([Environment]::GetFolderPath('Windows'))\chenniXOS\Wallpapers\lockscreen_dark.png"
    )

    if (!(Test-Path $Path)) {
        throw "Path ('$Path') for lockscreen not found."
    }
    $newImagePath = [System.IO.Path]::GetTempPath() + (New-Guid).Guid + [System.IO.Path]::GetExtension($Path)
    Copy-Item $Path $newImagePath

    # 加载 WinRT 命名空间
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime] | Out-Null

    # 异步辅助方法
    $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | ? {
            $_.Name -eq 'AsTask' -and
            $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        })[0]
    Function Await($WinRtTask, $ResultType) {
        $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
        $netTask = $asTask.Invoke($null, @($WinRtTask))
        $netTask.Wait(-1) | Out-Null
        $netTask.Result
    }
    Function AwaitAction($WinRtAction) {
        $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | ? { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and !$_.IsGenericMethod })[0]
        $netTask = $asTask.Invoke($null, @($WinRtAction))
        $netTask.Wait(-1) | Out-Null
    }

    # 构造图片对象并应用
    [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
    $image = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($newImagePath)) ([Windows.Storage.StorageFile])

    AwaitAction ([Windows.System.UserProfile.LockScreen]::SetImageFileAsync($image))

    # 清理临时文件
    Remove-Item $newImagePath
}

# 按 -Action 分派执行
switch ($Action) {
    'Apply' {
        Set-Theme -Path $ThemePath
        Set-ThemeMRU
    }
    'MRU' { Set-ThemeMRU }
    'Lockscreen' { Set-LockscreenImage -Path $LockscreenPath }
    'All' {
        Set-Theme -Path $ThemePath
        Set-ThemeMRU
        Set-LockscreenImage -Path $LockscreenPath
    }
}
