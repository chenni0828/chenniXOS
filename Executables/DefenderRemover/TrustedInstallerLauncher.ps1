# Synchronous TrustedInstaller routing for the persistent SYSTEM cleanup task.
# API references: Microsoft Learn CreateProcessAsUserW, DuplicateTokenEx,
# AdjustTokenPrivileges, WaitForSingleObject and TerminateProcess documentation.
# Dot-source only. No process is started until Invoke-TrustedInstallerCleanupStage is called.

function Invoke-TrustedInstallerCleanupStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Wait', 'RemoveApp', 'Registry', 'UserRegistry', 'Files', 'Finalize')]
        [string]$Stage,
        [Parameter(Mandatory = $true)][ValidateRange(1, 1800000)][int]$TimeoutMilliseconds,
        [switch]$AfterRestart
    )

    $ErrorActionPreference = 'Stop'
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        if ($identity.User.Value -ne 'S-1-5-18') { throw 'TrustedInstaller 补清启动器只允许 SYSTEM 调用。' }
    } finally { $identity.Dispose() }
    if (-not [Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -eq 'Core') {
        throw 'TrustedInstaller 补清启动器需要 64 位 Windows PowerShell。'
    }
    if ($AfterRestart -and $Stage -ne 'Finalize') { throw 'AfterRestart 仅适用于 Finalize 阶段。' }
    if (-not [IO.Path]::IsPathRooted($ScriptPath)) { throw '补清脚本必须使用绝对路径。' }
    $scriptFullPath = [IO.Path]::GetFullPath($ScriptPath)
    if ($scriptFullPath.Contains('"') -or -not (Test-Path -LiteralPath $scriptFullPath -PathType Leaf)) {
        throw 'TrustedInstaller 补清脚本路径无效或资源缺失。'
    }
    $powershellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) { throw '64 位 Windows PowerShell 启动资源缺失。' }

    if (-not ('ChenniXOS.DefenderRemoval.TiStageLauncher' -as [type])) {
        $nativeSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace ChenniXOS.DefenderRemoval
{
    public static class TiStageLauncher
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct LUID { public uint LowPart; public int HighPart; }
        [StructLayout(LayoutKind.Sequential)]
        private struct TOKEN_PRIVILEGES
        {
            public uint PrivilegeCount;
            public LUID Luid;
            public uint Attributes;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public uint cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public uint dwX;
            public uint dwY;
            public uint dwXSize;
            public uint dwYSize;
            public uint dwXCountChars;
            public uint dwYCountChars;
            public uint dwFillAttribute;
            public uint dwFlags;
            public ushort wShowWindow;
            public ushort cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public uint dwProcessId;
            public uint dwThreadId;
        }

        [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool LookupPrivilegeValue(string system, string name, out LUID luid);
        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll,
            ref TOKEN_PRIVILEGES requested, uint bufferLength, out TOKEN_PRIVILEGES previous, out uint returnLength);
        [DllImport("advapi32.dll", EntryPoint = "AdjustTokenPrivileges", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool RestoreTokenPrivileges(IntPtr token, bool disableAll,
            ref TOKEN_PRIVILEGES previous, uint bufferLength, IntPtr unusedPrevious, IntPtr unusedLength);
        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DuplicateTokenEx(IntPtr existing, uint access, IntPtr attributes,
            int impersonationLevel, int tokenType, out IntPtr duplicate);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessAsUserW(IntPtr token, string application,
            StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes,
            bool inherit, uint flags, IntPtr environment, string currentDirectory,
            ref STARTUPINFO startup, out PROCESS_INFORMATION process);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        private static Win32Exception NativeError(string operation)
        {
            return new Win32Exception(Marshal.GetLastWin32Error(), operation);
        }

        private static void EnablePrivilege(IntPtr token, string name, List<TOKEN_PRIVILEGES> previousStates)
        {
            LUID luid;
            if (!LookupPrivilegeValue(null, name, out luid)) { throw NativeError("LookupPrivilegeValue: " + name); }
            TOKEN_PRIVILEGES requested = new TOKEN_PRIVILEGES();
            requested.PrivilegeCount = 1;
            requested.Luid = luid;
            requested.Attributes = 2; // SE_PRIVILEGE_ENABLED
            TOKEN_PRIVILEGES previous;
            uint returned;
            bool adjusted = AdjustTokenPrivileges(token, false, ref requested,
                (uint)Marshal.SizeOf(typeof(TOKEN_PRIVILEGES)), out previous, out returned);
            int error = Marshal.GetLastWin32Error();
            if (adjusted && previous.PrivilegeCount != 0) { previousStates.Add(previous); }
            // TRUE alone is insufficient: ERROR_NOT_ALL_ASSIGNED is a failure.
            if (!adjusted || error != 0) { throw new Win32Exception(error, "AdjustTokenPrivileges: " + name); }
        }

        private static void TerminateAndWait(IntPtr process)
        {
            if (WaitForSingleObject(process, 0) == 0) { return; }
            if (!TerminateProcess(process, 1))
            {
                int error = Marshal.GetLastWin32Error();
                if (WaitForSingleObject(process, 0) != 0) { throw new Win32Exception(error, "TerminateProcess"); }
            }
            uint waited = WaitForSingleObject(process, 10000);
            if (waited == 0xffffffff) { throw NativeError("WaitForSingleObject after termination"); }
            if (waited != 0) { throw new TimeoutException("TrustedInstaller child termination did not complete within 10 seconds."); }
        }

        public static int Run(uint installerProcessId, string application, string commandLine,
            string workingDirectory, int timeoutMilliseconds)
        {
            IntPtr callerToken = IntPtr.Zero;
            IntPtr installerProcess = IntPtr.Zero;
            IntPtr installerToken = IntPtr.Zero;
            IntPtr primaryToken = IntPtr.Zero;
            PROCESS_INFORMATION child = new PROCESS_INFORMATION();
            List<TOKEN_PRIVILEGES> previousStates = new List<TOKEN_PRIVILEGES>();
            bool childCompleted = false;
            try
            {
                if (!OpenProcessToken(GetCurrentProcess(), 0x0028, out callerToken)) { throw NativeError("OpenProcessToken caller"); }
                EnablePrivilege(callerToken, "SeDebugPrivilege", previousStates);
                EnablePrivilege(callerToken, "SeAssignPrimaryTokenPrivilege", previousStates);
                EnablePrivilege(callerToken, "SeIncreaseQuotaPrivilege", previousStates);
                installerProcess = OpenProcess(0x1000, false, installerProcessId);
                if (installerProcess == IntPtr.Zero) { throw NativeError("OpenProcess TrustedInstaller"); }
                if (!OpenProcessToken(installerProcess, 0x000a, out installerToken)) { throw NativeError("OpenProcessToken TrustedInstaller"); }
                // SecurityImpersonation = 2, TokenPrimary = 1.
                if (!DuplicateTokenEx(installerToken, 0x000b, IntPtr.Zero, 2, 1, out primaryToken)) { throw NativeError("DuplicateTokenEx TrustedInstaller"); }
                STARTUPINFO startup = new STARTUPINFO();
                startup.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
                startup.dwFlags = 1; // STARTF_USESHOWWINDOW
                startup.wShowWindow = 0; // SW_HIDE; the service stays in its noninteractive session.
                StringBuilder mutableCommand = new StringBuilder(commandLine);
                // CREATE_NO_WINDOW; a null environment intentionally retains the SYSTEM deployment paths.
                if (!CreateProcessAsUserW(primaryToken, application, mutableCommand, IntPtr.Zero,
                    IntPtr.Zero, false, 0x08000000, IntPtr.Zero, workingDirectory, ref startup, out child))
                {
                    throw NativeError("CreateProcessAsUserW TrustedInstaller");
                }
                uint waited = WaitForSingleObject(child.hProcess, (uint)timeoutMilliseconds);
                if (waited == 0x00000102)
                {
                    TerminateAndWait(child.hProcess);
                    childCompleted = true;
                    throw new TimeoutException("TrustedInstaller cleanup stage exceeded its timeout.");
                }
                if (waited != 0)
                {
                    int error = Marshal.GetLastWin32Error();
                    TerminateAndWait(child.hProcess);
                    childCompleted = true;
                    throw new Win32Exception(error, "WaitForSingleObject TrustedInstaller child");
                }
                childCompleted = true;
                uint exitCode;
                if (!GetExitCodeProcess(child.hProcess, out exitCode)) { throw NativeError("GetExitCodeProcess TrustedInstaller child"); }
                return unchecked((int)exitCode);
            }
            finally
            {
                // Release every owned handle even after a launch, wait or privilege failure.
                if (child.hProcess != IntPtr.Zero && !childCompleted)
                {
                    TerminateProcess(child.hProcess, 1);
                    WaitForSingleObject(child.hProcess, 10000);
                }
                if (child.hThread != IntPtr.Zero) { CloseHandle(child.hThread); }
                if (child.hProcess != IntPtr.Zero) { CloseHandle(child.hProcess); }
                if (primaryToken != IntPtr.Zero) { CloseHandle(primaryToken); }
                if (installerToken != IntPtr.Zero) { CloseHandle(installerToken); }
                if (installerProcess != IntPtr.Zero) { CloseHandle(installerProcess); }
                Exception restoreError = null;
                for (int index = previousStates.Count - 1; index >= 0; index--)
                {
                    TOKEN_PRIVILEGES previous = previousStates[index];
                    bool restored = RestoreTokenPrivileges(callerToken, false, ref previous, 0, IntPtr.Zero, IntPtr.Zero);
                    int error = Marshal.GetLastWin32Error();
                    if ((!restored || error != 0) && restoreError == null)
                    {
                        restoreError = new Win32Exception(error, "RestoreTokenPrivileges caller");
                    }
                }
                if (callerToken != IntPtr.Zero) { CloseHandle(callerToken); }
                if (restoreError != null) { throw restoreError; }
            }
        }
    }
}
'@
        Add-Type -TypeDefinition $nativeSource -Language CSharp -ErrorAction Stop
    }

    $installerService = Get-Service -Name TrustedInstaller -ErrorAction Stop
    try {
        if ($installerService.Status -ne [ServiceProcess.ServiceControllerStatus]::Running) {
            Start-Service -Name TrustedInstaller -ErrorAction Stop
            $installerService.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, (New-TimeSpan -Seconds 30))
        }
    } finally { $installerService.Dispose() }
    $deadline = (Get-Date).AddSeconds(10)
    $installerProcessId = 0
    do {
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='TrustedInstaller'" -ErrorAction Stop
        if (-not $service) { throw '无法查询 TrustedInstaller 的实际服务进程。' }
        if ($service.State -eq 'Running' -and $service.ProcessId -gt 0) { $installerProcessId = [uint32]$service.ProcessId; break }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    if ($installerProcessId -eq 0) { throw 'TrustedInstaller 未在限时内提供实际服务进程。' }

    $commandLine = '"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -Stage {2}' -f $powershellPath, $scriptFullPath, $Stage
    if ($AfterRestart) { $commandLine += ' -AfterRestart' }
    return [ChenniXOS.DefenderRemoval.TiStageLauncher]::Run($installerProcessId, $powershellPath,
        $commandLine, [IO.Path]::GetDirectoryName($scriptFullPath), $TimeoutMilliseconds)
}
