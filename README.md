VPN 退出后的网络修复工具 1.0
适用：Windows 10 / 11，使用系统自带 Windows PowerShell 5.1，无需安装 Python。

【使用指南】
1. 解压压缩包，将“一键网络修复.cmd”放置在桌面。
2. 出现 VPN 退出后不能打开网页的问题时，请首先在 VPN 软件中关闭系统代理、TUN 模式，之后退出软件。
3. 双击“一键网络修复.cmd”。如 Windows 请求管理员权限，请选择“是”。
4. 等待显示处理和解析测试结束后，打开浏览器刷新网页即可。
5. 若完成上述操作后仍然显示域名解析错误，请在程序窗口输入 D，按提示恢复当前物理网卡的自动 DNS。
   如果学校或单位要求手动 DNS，请勿选择 D选项。
6. 关闭窗口请直接按回车键。每次运行都会创建独立备份。

【工具自动执行操作说明】
- 备份当前登录用户的 Windows 代理配置。
- 关闭手动代理、自动配置脚本（PAC）和代理自动检测（WPAD），切换到直连。
- 请求管理员权限，先备份 WinHTTP 配置，再重置 WinHTTP 代理并清理 DNS 缓存。
- 检查 www.bing.com、www.baidu.com、www.microsoft.com 能否解析；显示解析成功则表示得到IP地址。

【进一步修复与撤销命令说明】
- D：选择当前有默认路由的已连接物理网卡，确认后恢复其 IPv4 / IPv6 DNS 自动获取。
   DNS 修改前会保留原设置；单次修改出错时尝试自动恢复，并显示恢复是否成功。
- R：恢复本次运行前的 Windows 用户代理设置（不含 WinHTTP）。
- U：恢复本次运行前的网卡 DNS，分别恢复自动与手动模式。
- B：打开本次备份文件夹。
- 本工具无法实现以下操作：
1.修改 IP 地址、网关或路由；
2.禁用 IPv6；
3.重置防火墙；
4.删除 VPN 驱动；

【备份】
按 Win+R，输入 %LOCALAPPDATA%\NetworkRepair 即可打开。
每次运行一个时间戳文件夹，包括：
- proxy-before.json：原用户代理设置。
- winhttp-before.txt：原 WinHTTP 配置命令备份（如已授权管理员任务）。
- dns-before.json：原 DNS 设置（仅执行过 D 时存在）。
- repair.log 和 result-*.json：处理结果。
R/U 操作针对当前打开窗口中的本次操作。退出后仍保留备份，可用于人工恢复。
原 WinHTTP 可由管理员命令提示符执行 netsh exec "备份文件的完整路径\winhttp-before.txt" 恢复。
备份可能包含代理地址或网络信息，请勿公开发送整个备份文件夹。

【限制与注意】
- 本工具仅针对 VPN 残留代理 / DNS 导致的网络问题，无法强行关闭浏览器或 VPN，重新启动电脑，或是安装常驻服务。
- 如果 VPN 仍在运行并重新设置代理，程序的修改可能被覆盖。
- 公司/学校要求使用专用代理时，不适合直接运行自动清理。请勿绕过组织策略。
- 取消管理员授权后，已完成的当前用户代理修改仍会保留，不会执行系统级操作。
- PowerShell 执行策略参数只作用于当前程序进程。
- 此文件是未签名的可读脚本，用记事本打开即可查看全部代码。

【技术依据】
Windows 代理 API：
https://learn.microsoft.com/en-us/windows/win32/wininet/setting-and-retrieving-internet-options
WinHTTP 代理：
https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-winhttp
DNS 自动获取：
https://learn.microsoft.com/en-us/powershell/module/dnsclient/set-dnsclientserveraddress
DNS 缓存：
https://learn.microsoft.com/en-us/powershell/module/dnsclient/clear-dnsclientcache
