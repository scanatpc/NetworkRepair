@echo off
setlocal DisableDelayedExpansion
title Network Repair
set "NETREPAIR_PATH=%~f0"
set "NETREPAIR_MODE=%~1"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:NETREPAIR_PATH,[Text.Encoding]::UTF8); $m=[regex]::Match($t,'(?m)^#==PS_PAYLOAD==\r?$'); if(!$m.Success){throw 'Missing program payload'}; & ([scriptblock]::Create($t.Substring($m.Index+$m.Length)))"
if errorlevel 1 (
  echo.
  echo Repair tool stopped with an error. Please copy the message above.
  pause
)
exit /b
#==PS_PAYLOAD==
# Embedded by build_tool.py into a single, double-clickable CMD file.
# Windows PowerShell 5.1 / Windows 10 and 11. No downloaded dependencies.
$ErrorActionPreference = 'Stop'

function Initialize-NativeProxy {
    if ('NetworkRepair.NativeProxy' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace NetworkRepair {
    public class ProxyState {
        public int Flags {get;set;}
        public string Server {get;set;}
        public string Bypass {get;set;}
        public string Pac {get;set;}
    }
    public static class NativeProxy {
        [StructLayout(LayoutKind.Explicit)] public struct Value {
            [FieldOffset(0)] public int Number;
            [FieldOffset(0)] public IntPtr Text;
            [FieldOffset(0)] public System.Runtime.InteropServices.ComTypes.FILETIME Time;
        }
        [StructLayout(LayoutKind.Sequential)] public struct Option { public int Id; public Value Data; }
        [StructLayout(LayoutKind.Sequential)] public struct OptionList {
            public int Size; public IntPtr Connection; public int Count; public int Error; public IntPtr Options;
        }
        [DllImport("wininet.dll", EntryPoint="InternetQueryOptionW", SetLastError=true)]
        [return:MarshalAs(UnmanagedType.Bool)]
        static extern bool Query(IntPtr h, int option, ref OptionList list, ref int length);
        [DllImport("wininet.dll", EntryPoint="InternetSetOptionW", SetLastError=true)]
        [return:MarshalAs(UnmanagedType.Bool)]
        static extern bool Set(IntPtr h, int option, ref OptionList list, int length);
        [DllImport("wininet.dll", EntryPoint="InternetSetOptionW", SetLastError=true)]
        [return:MarshalAs(UnmanagedType.Bool)]
        static extern bool Notify(IntPtr h, int option, IntPtr value, int length);
        [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr p);
        static OptionList NewList() {
            OptionList l = new OptionList(); l.Size = Marshal.SizeOf(typeof(OptionList)); l.Count = 4;
            l.Options = Marshal.AllocHGlobal(4 * Marshal.SizeOf(typeof(Option))); return l;
        }
        static IntPtr At(OptionList l, int i) { return IntPtr.Add(l.Options, i * Marshal.SizeOf(typeof(Option))); }
        public static ProxyState Read() {
            OptionList l = NewList();
            try {
                for(int i=0;i<4;i++) { Option o=new Option(); o.Id = i==0 ? 10 : i+1; Marshal.StructureToPtr(o,At(l,i),false); }
                int n=l.Size;
                if(!Query(IntPtr.Zero,75,ref l,ref n)) throw new Win32Exception(Marshal.GetLastWin32Error());
                ProxyState s=new ProxyState();
                s.Flags=((Option)Marshal.PtrToStructure(At(l,0),typeof(Option))).Data.Number;
                s.Server=Marshal.PtrToStringUni(((Option)Marshal.PtrToStructure(At(l,1),typeof(Option))).Data.Text);
                s.Bypass=Marshal.PtrToStringUni(((Option)Marshal.PtrToStructure(At(l,2),typeof(Option))).Data.Text);
                s.Pac=Marshal.PtrToStringUni(((Option)Marshal.PtrToStructure(At(l,3),typeof(Option))).Data.Text);
                return s;
            } finally {
                for(int i=1;i<4;i++) { IntPtr p=((Option)Marshal.PtrToStructure(At(l,i),typeof(Option))).Data.Text; if(p!=IntPtr.Zero) GlobalFree(p); }
                Marshal.FreeHGlobal(l.Options);
            }
        }
        public static void Apply(ProxyState s) {
            OptionList l=NewList(); IntPtr[] strings=new IntPtr[3];
            try {
                string[] values={s.Server,s.Bypass,s.Pac};
                for(int i=0;i<4;i++) {
                    Option o=new Option(); o.Id=i+1;
                    if(i==0) o.Data.Number=s.Flags;
                    else { strings[i-1]=Marshal.StringToHGlobalUni(values[i-1] ?? ""); o.Data.Text=strings[i-1]; }
                    Marshal.StructureToPtr(o,At(l,i),false);
                }
                if(!Set(IntPtr.Zero,75,ref l,l.Size)) throw new Win32Exception(Marshal.GetLastWin32Error());
                if(!Notify(IntPtr.Zero,39,IntPtr.Zero,0)) throw new Win32Exception(Marshal.GetLastWin32Error());
                if(!Notify(IntPtr.Zero,37,IntPtr.Zero,0)) throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally { foreach(IntPtr p in strings) if(p!=IntPtr.Zero) Marshal.FreeHGlobal(p); Marshal.FreeHGlobal(l.Options); }
        }
    }
}
'@
}

function Write-Status([string]$Message, [string]$Color = 'Gray') {
    Write-Host $Message -ForegroundColor $Color
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $Message) -Encoding UTF8 }
}

function Get-WorkerSource {
    # Runs elevated. It never touches HKCU, so using a different administrator
    # account does not accidentally repair that administrator's browser settings.
    return @'
param([ValidateSet('Basic','Dns','RestoreDns')][string]$Mode, [string]$RunPath)
$ErrorActionPreference = 'Stop'
$result = [ordered]@{ Success = $false; Messages = @(); Error = ''; Mode = $Mode }
function Add-Message([string]$s) { $result.Messages += $s }
function Invoke-Netsh([string[]]$Arguments) {
    $out = @(& "$env:SystemRoot\System32\netsh.exe" @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ('netsh 执行失败：' + ($out -join ' ')) }
    return ($out -join [Environment]::NewLine)
}
function Restore-DnsRecord($record, $adapter) {
    foreach ($family in @($record.Families)) {
        $current = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily $family.Family -ErrorAction Stop
        if ($family.Automatic) {
            $current | Set-DnsClientServerAddress -ResetServerAddresses -ErrorAction Stop
        } else {
            $current | Set-DnsClientServerAddress -ServerAddresses @($family.Servers) -ErrorAction Stop
        }
    }
}
try {
    if ($Mode -eq 'Basic') {
        # A dump is saved before changing WinHTTP. Failure to back it up prevents its reset.
        try {
            $dump = Invoke-Netsh @('winhttp','dump')
            # netsh exec rejects UTF-16 and a UTF-8 BOM. Preserve the console
            # code page and reject unrepresentable data instead of losing it.
            $encoding = [Console]::OutputEncoding.Clone()
            $encoding.EncoderFallback = New-Object Text.EncoderExceptionFallback
            [IO.File]::WriteAllText((Join-Path $RunPath 'winhttp-before.txt'), ($dump + [Environment]::NewLine), $encoding)
            Add-Message (Invoke-Netsh @('winhttp','reset','proxy'))
        } catch { Add-Message ('WinHTTP 未完成：' + $_.Exception.Message) }
        Clear-DnsClientCache -ErrorAction Stop
        Add-Message '已清理 Windows DNS 缓存。'
        $result.Success = $true
    } elseif ($Mode -eq 'Dns') {
        $request = Get-Content -LiteralPath (Join-Path $RunPath 'dns-request.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $adapter = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { [string]$_.InterfaceGuid -eq [string]$request.Guid -and $_.Status -eq 'Up' })
        if ($adapter.Count -ne 1) { throw '所选物理网卡已变化或断开，请重新运行工具。' }
        $adapter = $adapter[0]
        $routes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -ErrorAction Stop | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0','::/0') })
        if ($routes.Count -eq 0) { throw '所选网卡已无默认路由，未修改 DNS。' }
        $families = @()
        foreach ($family in @('IPv4','IPv6')) {
            $service = if ($family -eq 'IPv4') { 'Tcpip' } else { 'Tcpip6' }
            $guid = '{' + ([guid]$adapter.InterfaceGuid).ToString() + '}'
            $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$service\Parameters\Interfaces\$guid"
            # Missing/unreadable keys are not guessed to mean automatic.
            $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            $manual = [string]$props.NameServer
            $addresses = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily $family -ErrorAction Stop
            $families += [pscustomobject]@{ Family = $family; Automatic = [string]::IsNullOrWhiteSpace($manual); Servers = @($addresses.ServerAddresses); OriginalNameServer = $manual }
        }
        $record = [pscustomobject]@{ Guid = [string]$adapter.InterfaceGuid; Name = $adapter.Name; Families = $families }
        $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $RunPath 'dns-before.json') -Encoding UTF8
        try {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction Stop
        } catch {
            $originalError = $_.Exception.Message
            try { Restore-DnsRecord $record $adapter; Add-Message 'DNS 修改失败，已恢复原 DNS 设置。' }
            catch { Add-Message ('DNS 恢复也失败：' + $_.Exception.Message) }
            throw $originalError
        }
        Clear-DnsClientCache -ErrorAction Stop
        Add-Message ('已将网卡“' + $adapter.Name + '”的 IPv4 / IPv6 DNS 恢复为网络自动提供。')
        $result.Success = $true
    } else {
        $record = Get-Content -LiteralPath (Join-Path $RunPath 'dns-before.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $adapter = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { [string]$_.InterfaceGuid -eq [string]$record.Guid })
        if ($adapter.Count -ne 1) { throw '原网卡已不存在，无法恢复。' }
        Restore-DnsRecord $record $adapter[0]
        Clear-DnsClientCache -ErrorAction Stop
        Add-Message '已恢复本次运行之前的 DNS 设置。'
        $result.Success = $true
    }
} catch { $result.Error = $_.Exception.Message }
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $RunPath ('result-' + $Mode + '.json')) -Encoding UTF8
if ($result.Success) { exit 0 } else { exit 1 }
'@
}

function Invoke-AdminWorker([string]$Mode) {
    $worker = Join-Path $script:RunPath 'worker.ps1'
    $resultPath = Join-Path $script:RunPath ('result-' + $Mode + '.json')
    if (Test-Path -LiteralPath $resultPath) { Remove-Item -LiteralPath $resultPath -Force }
    Get-WorkerSource | Set-Content -LiteralPath $worker -Encoding UTF8
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Write-Status '如 Windows 弹出权限提示，请选择“是”；取消后会保留已完成的用户代理修复。' 'Yellow'
    try {
        $args = '-NoProfile -ExecutionPolicy Bypass -File "' + $worker + '" -Mode ' + $Mode + ' -RunPath "' + $script:RunPath + '"'
        $p = Start-Process -FilePath $ps -ArgumentList $args -Verb RunAs -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
        if (!(Test-Path -LiteralPath $resultPath)) { throw ('管理任务没有返回结果，退出码：' + $p.ExitCode) }
        $r = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($message in $r.Messages) { Write-Status $message }
        if (!$r.Success) { Write-Status ('未完成：' + $r.Error) 'Yellow' }
        return [bool]$r.Success
    } catch {
        Write-Status ('管理任务未运行或未完成：' + $_.Exception.Message) 'Yellow'
        return $false
    }
}

function Disable-UserProxy {
    $state = [NetworkRepair.NativeProxy]::Read()
    $record = [pscustomobject]@{ Version = 1; UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; Proxy = $state }
    $backup = Join-Path $script:RunPath 'proxy-before.json'
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backup -Encoding UTF8
    # Verify the backup can be read before any mutation.
    $null = Get-Content -LiteralPath $backup -Raw -Encoding UTF8 | ConvertFrom-Json
    $direct = New-Object NetworkRepair.ProxyState
    $direct.Flags = 1
    [NetworkRepair.NativeProxy]::Apply($direct)
    $after = [NetworkRepair.NativeProxy]::Read()
    if (($after.Flags -band 14) -ne 0) { throw '代理开关仍开启，可能被 VPN 或组织策略重新设置。' }
    Write-Status '已关闭当前用户的手动代理、自动脚本和自动检测代理。' 'Green'
}

function Restore-UserProxy {
    $record = Get-Content -LiteralPath (Join-Path $script:RunPath 'proxy-before.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($record.UserSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw '备份属于其他用户，未执行恢复。' }
    $state = New-Object NetworkRepair.ProxyState
    $state.Flags = [int]$record.Proxy.Flags
    $state.Server = $record.Proxy.Server
    $state.Bypass = $record.Proxy.Bypass
    $state.Pac = $record.Proxy.Pac
    [NetworkRepair.NativeProxy]::Apply($state)
    Write-Status '已恢复本次运行之前的 Windows 用户代理设置（不含 WinHTTP）。' 'Green'
}

function Test-DnsResolution {
    $successes = 0
    foreach ($hostname in @('www.bing.com','www.baidu.com','www.microsoft.com')) {
        try {
            $task = [Net.Dns]::GetHostAddressesAsync($hostname)
            if (!$task.Wait(4000)) { throw '等待超过 4 秒' }
            if (@($task.Result).Count -eq 0) { throw '无解析地址' }
            Write-Status ('[解析成功] ' + $hostname) 'Green'
            $successes++
        } catch { Write-Status ('[解析失败] ' + $hostname) 'Yellow' }
    }
    return $successes
}

function Get-EligibleAdapters {
    foreach ($adapter in @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
        $routes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -ErrorAction Stop | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0','::/0') })
        if ($routes.Count -gt 0) { $adapter }
    }
}

function Invoke-DnsRepair {
    $adapters = @(Get-EligibleAdapters)
    if ($adapters.Count -eq 0) { Write-Status '没有发现已连接且有默认路由的物理网卡。请检查 Wi-Fi / 网线，以及 VPN 的 TUN 模式。' 'Yellow'; return }
    for ($i=0; $i -lt $adapters.Count; $i++) { Write-Status (('{0}. {1}' -f ($i+1),$adapters[$i].Name)) }
    $selected = 0
    if ($adapters.Count -gt 1) {
        $raw = Read-Host '输入要修复的网卡序号，直接回车取消'
        $number = 0
        if (![int]::TryParse($raw,[ref]$number) -or $number -lt 1 -or $number -gt $adapters.Count) { return }
        $selected = $number - 1
    }
    $adapter = $adapters[$selected]
    Write-Status ('将“' + $adapter.Name + '”的 IPv4 / IPv6 DNS 改为自动获取，并备份旧值。') 'Yellow'
    Write-Status '如果学校或单位要求专用 DNS，请不要执行此项；IP 地址和网关不会改变。' 'Yellow'
    if ((Read-Host '确认执行请输入 Y，其他输入取消') -ne 'Y') { return }
    [pscustomobject]@{ Guid = [string]$adapter.InterfaceGuid } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:RunPath 'dns-request.json') -Encoding UTF8
    $null = Invoke-AdminWorker 'Dns'
    $null = Test-DnsResolution
}

function Invoke-RepairMain {
    $script:LogFile = $null
    $root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'NetworkRepair'
    $script:RunPath = Join-Path $root ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6))
    New-Item -ItemType Directory -Path $script:RunPath -Force | Out-Null
    $script:LogFile = Join-Path $script:RunPath 'repair.log'
    Write-Status '=== VPN 退出后的网络修复 · 1.0 ===' 'Cyan'
    Write-Status '请先正常退出 VPN，并关闭其系统代理 / TUN 模式。'
    Write-Status '开始备份、清理代理并刷新 DNS；请勿同时运行多个副本。'
    Initialize-NativeProxy
    try { Disable-UserProxy } catch { Write-Status ('用户代理修复未完成：' + $_.Exception.Message) 'Yellow' }
    $null = Invoke-AdminWorker 'Basic'
    Write-Status '正在检查域名解析……' 'Cyan'
    $count = Test-DnsResolution
    if ($count -eq 3) { Write-Status '三个测试域名均可解析。请刷新网页；仍异常时，保存工作后退出并重开浏览器。' 'Green' }
    elseif ($count -gt 0) { Write-Status '部分域名可解析。请测试原网页，个别域名失败不一定是系统 DNS 故障。' 'Yellow' }
    else { Write-Status '三个域名均未解析成功。可以选 D 尝试恢复当前网卡的自动 DNS。' 'Yellow' }
    Write-Status '解析测试不能保证网站访问正常；本工具不处理 VPN 断网保护或浏览器独立的安全 DNS 配置。'
    Write-Status ('本次备份和日志：' + $script:RunPath)
    $dnsAttempted = $false
    do {
        Write-Host ''
        Write-Host '[回车] 退出    [D] DNS 进一步修复    [R] 撤销本次用户代理修改    [U] 撤销本次 DNS 修改    [B] 查看备份'
        $choice = (Read-Host '选择').Trim().ToUpperInvariant()
        try {
            switch ($choice) {
                'D' {
                    if ($dnsAttempted) { Write-Status '本次已尝试过 DNS 修复。为保留原始备份，请先查看结果或按 U 撤销。' 'Yellow' }
                    else { Invoke-DnsRepair; $dnsAttempted = Test-Path -LiteralPath (Join-Path $script:RunPath 'dns-before.json') }
                }
                'R' { Restore-UserProxy }
                'U' {
                    if (Test-Path -LiteralPath (Join-Path $script:RunPath 'dns-before.json')) { $null = Invoke-AdminWorker 'RestoreDns' }
                    else { Write-Status '本次没有修改 DNS，无需撤销。' }
                }
                'B' { Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList ('"' + $script:RunPath + '"') }
            }
        } catch { Write-Status ('此操作未完成：' + $_.Exception.Message) 'Yellow' }
    } while ($choice -ne '')
}

if ($env:NETREPAIR_MODE -ne '--load-only') {
    try { Invoke-RepairMain }
    catch {
        Write-Host ('工具运行失败：' + $_.Exception.Message) -ForegroundColor Red
        Write-Host '未完成的步骤不会被报告为成功。请复制错误信息以便排查。'
        $null = Read-Host '按回车退出'
        exit 1
    }
}
