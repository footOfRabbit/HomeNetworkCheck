# Docker Desktop 跳转失败排查总结

## 结论

这次问题不是单一故障，而是两层因素叠加：

1. `C:\Users\AAA\AppData\Local\Docker` 目录权限异常，导致 Docker Desktop 的 URL Handler 一开始会因为无法写日志或切换工作目录而报 `Access is denied`。
2. 后续手动测试时使用的 `docker-desktop://dashboard` 和 `docker-desktop://` 并不是这版 Docker Desktop URL Handler 支持的 deeplink 形式，所以即使权限修复后，手动输入这两个地址也会报 `unhandled path`。

也就是说：

- 早期“点按钮没反应”的主要问题是本地目录权限异常。
- 后来“Win + R 输入 `docker-desktop://dashboard` 还是打不开”的问题，不代表权限还坏着，而是这个 URL 本身不被当前版本支持。

## 现象

最初看到的是 Docker 网页提示：

> You're almost done!  
> We're redirecting you to the desktop app.  
> If you don't see a dialog, click the button below.

点击 `Proceed to Docker Desktop` 后没有正常拉起桌面端，因此开始排查：

- Docker Desktop 是否已安装
- 自定义协议 `docker-desktop://` 是否已注册
- Docker Desktop 进程是否正常
- 浏览器是否拦截外部应用跳转
- Docker Desktop URL Handler 启动后是否报错

## 排查过程

### 1. 确认 Docker Desktop 是否已安装

执行命令：

```powershell
Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' |
Where-Object { $_.DisplayName -like 'Docker Desktop*' } |
Select-Object DisplayName, DisplayVersion, InstallLocation
```

作用：

- 从系统和当前用户的卸载注册表中查 Docker Desktop 的安装信息。
- 用来确认是否真的安装了 Docker Desktop，以及安装到了哪里。

结果：

- 已安装 `Docker Desktop 4.93.0`
- 安装目录是 `C:\Users\AAA\AppData\Local\Programs\DockerDesktop`

结论：

- 不是“没装软件”导致的跳转失败。

### 2. 确认自定义协议 `docker-desktop://` 是否注册

执行命令：

```powershell
Get-Item 'Registry::HKEY_CLASSES_ROOT\docker-desktop'
Get-Item 'Registry::HKEY_CURRENT_USER\Software\Classes\docker-desktop'

Get-ItemProperty 'Registry::HKEY_CLASSES_ROOT\docker-desktop\shell\open\command',
'Registry::HKEY_CURRENT_USER\Software\Classes\docker-desktop\shell\open\command'
```

作用：

- 查看 `docker-desktop` 这个 URI Scheme 是否在系统里注册。
- 查看它最终指向哪个可执行文件。

结果：

- 协议已注册。
- 协议处理程序指向：

```text
"C:\Users\AAA\AppData\Local\Programs\DockerDesktop\resources\Docker Desktop.exe" "%1"
```

结论：

- 不是“协议没注册”。

### 3. 确认 Docker Desktop 进程是否在运行

执行命令：

```powershell
Get-Process 'Docker Desktop','com.docker.backend' |
Select-Object ProcessName, Id, Path
```

作用：

- 查看 Docker 前端和后端进程是否已经启动。

结果：

- `Docker Desktop`
- `com.docker.backend`

都能看到。

结论：

- Docker Desktop 本体并没有完全坏掉。

### 4. 直接从系统层测试 `docker-desktop://` 协议

执行命令：

```powershell
Start-Process 'docker-desktop://dashboard'
```

作用：

- 绕过浏览器，直接让 Windows 触发自定义协议。
- 用来判断问题在“浏览器层”还是“系统协议层”。

早期结果：

- 没有明显弹出成功。

后续深入测试发现：

- 协议处理程序其实被拉起来了，但执行过程中失败。

### 5. 确认默认浏览器和 Chrome 对协议的处理状态

执行命令：

```powershell
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice'
```

作用：

- 查看当前默认浏览器是谁。

结果：

- 默认浏览器是 `Chrome`

之后又解析了 Chrome 配置文件 `Preferences`，查找：

```text
protocol_handler
custom_handlers
excluded_schemes
docker-desktop
```

作用：

- 检查 Chrome 有没有拦掉 `auth.docker.com -> docker-desktop` 这类外部协议跳转。

结果：

- Chrome 配置里已经允许 `https://auth.docker.com` 触发 `docker-desktop`

结论：

- 不是 Chrome 没授权。

### 6. 直接执行 Docker Desktop 的 URL Handler，抓真实错误

执行命令：

```powershell
& 'C:\Users\AAA\AppData\Local\Programs\DockerDesktop\resources\Docker Desktop.exe' 'docker-desktop://dashboard'
```

作用：

- 不通过浏览器，不通过协议注册，直接把 URL 参数喂给 Docker 的 URL Handler。
- 这样能看到最真实的失败原因。

第一次抓到的关键报错：

```text
Failed to fire hook: opening log file: unable to create a log file for Docker Desktop.exe in directory C:\Users\AAA\AppData\Local\Docker\log\host: Access is denied.
[Docker Desktop.exe.paths][F] chdir <HOME>\AppData\Local\Docker: Access is denied.
```

结论：

- Docker URL Handler 启动后会先访问 `C:\Users\AAA\AppData\Local\Docker`
- 它当时没有足够权限，因此在真正处理 deeplink 之前就失败了

这一步基本锁定了第一层根因。

### 7. 检查 `C:\Users\AAA\AppData\Local\Docker` 目录 ACL

执行命令：

```powershell
icacls 'C:\Users\AAA\AppData\Local\Docker'
icacls 'C:\Users\AAA\AppData\Local\Docker\log\host'
```

以及：

```powershell
Get-Acl 'C:\Users\AAA\AppData\Local\Docker' | Format-List Owner,AccessToString
Get-Acl 'C:\Users\AAA\AppData\Local\Docker\log\host' | Format-List Owner,AccessToString
```

作用：

- 查看目录所有者和权限规则。

结果：

- Owner 是 `BUILTIN\Administrators`
- 当前普通用户没有明确的正常写权限

结论：

- 这解释了前面的 `Access is denied`

### 8. 通过写入探针验证日志目录是否真的不可写

执行命令：

```powershell
$probe='C:\Users\AAA\AppData\Local\Docker\log\host\trae_write_test.tmp'
Set-Content -Path $probe -Value 'ok' -Encoding UTF8
```

作用：

- 用最直接的方式验证当前用户能不能往 Docker 的日志目录写文件。

早期结果：

- `Access is denied`

结论：

- 目录权限异常被再次验证。

## 修复过程

### 1. 停掉 Docker 相关进程

执行命令：

```powershell
Get-Process 'Docker Desktop','com.docker.backend' -ErrorAction SilentlyContinue | Stop-Process -Force
```

作用：

- 释放 `AppData\Local\Docker` 下的锁文件、日志文件和内部数据库。
- 避免改权限时失败，或者改完不能立刻生效。

### 2. 把 Docker 用户目录 owner 改成当前用户

执行命令：

```powershell
takeown /F "C:\Users\AAA\AppData\Local\Docker" /R /D Y
```

作用：

- 递归把 `C:\Users\AAA\AppData\Local\Docker` 及所有子文件、子目录的所有者改成当前用户。

结果：

- 你执行后已成功，大量条目都变成了 `DESKTOP-G8T92TO\AtomicHeart`

结论：

- 这是修复里最关键的一步。

### 3. 重新开启权限继承

执行命令：

```powershell
icacls "C:\Users\AAA\AppData\Local\Docker" /inheritance:e
```

作用：

- 重新允许该目录从父目录继承 ACL。
- 如果某个目录过去被人为打断继承，就可能只剩下一套很奇怪的 ACL，导致当前用户无法正常访问。

结果：

- 成功处理。

结论：

- 这一步通常能把“权限链断掉”的问题恢复。

### 4. 试图显式授予当前用户完全控制

执行命令：

```powershell
icacls "C:\Users\AAA\AppData\Local\Docker" /grant:r "$env:USERNAME:(OI)(CI)F" /T
```

作用：

- 原本想递归给当前用户授予完全控制权限。

参数含义：

- `OI`：文件继承
- `CI`：目录继承
- `F`：完全控制
- `/T`：递归
- `/grant:r`：替换同用户已有授权，而不是叠加

结果：

- 失败，报错：

```text
无效参数“(OI)(CI)F”
```

原因：

- PowerShell 对 `"$env:USERNAME:(OI)(CI)F"` 这种写法解析不稳定
- 变量后直接跟 `:` 时，容易被拆坏

正确写法建议：

```powershell
icacls "C:\Users\AAA\AppData\Local\Docker" /grant:r "${env:USERNAME}:(OI)(CI)F" /T
```

不过从实际结果看，即使这条没成功，前两步已经足够把目录修到可写状态。

### 5. 验证日志目录恢复可写

执行命令：

```powershell
$probe = "C:\Users\AAA\AppData\Local\Docker\log\host\permission_test.tmp"
Set-Content -Path $probe -Value "ok" -Encoding UTF8
Get-Item $probe
Remove-Item $probe -Force
```

作用：

- 验证当前用户是否已经可以正常写、读、删 Docker 的日志目录。

结果：

- 成功创建 `permission_test.tmp`
- 成功读取
- 成功删除

结论：

- 第一层问题，也就是目录权限异常，已经修复。

## 为什么后来手动输入 `docker-desktop://dashboard` 还是打不开

修复权限后继续做了更底层测试：

执行命令：

```powershell
& 'C:\Users\AAA\AppData\Local\Programs\DockerDesktop\resources\Docker Desktop.exe' 'docker-desktop://dashboard'
```

得到日志：

```text
received request to handle url: docker-desktop://dashboard
failed to open url 'docker-desktop://dashboard': unhandled path for docker-desktop://dashboard
```

又测试了：

```powershell
& 'C:\Users\AAA\AppData\Local\Programs\DockerDesktop\resources\Docker Desktop.exe' 'docker-desktop://'
```

得到：

```text
received request to handle url: docker-desktop:
failed to open url 'docker-desktop:': unhandled path for docker-desktop:
```

这说明：

- `docker-desktop://` 协议本身已经能到 Docker 的 URL Handler
- 但 `dashboard` 和空路径这两种写法不被当前版本识别

所以：

- 这不是“系统坏了”
- 而是“手动输入的 URL 不是这版 Docker Desktop 支持的 deeplink”

## 为什么网页按钮可能还能成功

在日志里可以看到 Docker Desktop 的内部记录：

```text
Open app://dd/dashboard/login?utm_source=login_page - source: second-instance
```

这说明 Docker 网页真正使用的，很可能是某种更具体的登录 deeplink 或跳转链，而不是简单的：

```text
docker-desktop://dashboard
```

因此：

- 手动输入 `docker-desktop://dashboard` 失败
- 不等于网页按钮一定失败

网页按钮有可能拼的是另一个 Docker 自己认识的 URL。

## 整体结论

这次排查最终确认了两个事实：

1. 目录权限异常是真问题，而且已经修复  
   证据是日志目录可以重新正常写入，早期的 `Access is denied` 已经不再出现。

2. 手动输入的测试 URL 不是有效 deeplink  
   证据是 Docker 自己的 URL Handler 明确报 `unhandled path`。

所以后续再验证时，应该区分两种测试：

- 验证 Docker Desktop 是否能启动：直接启动主程序
- 验证网页登录按钮是否有效：回到原网页点 `Proceed to Docker Desktop`

而不应该再用 `docker-desktop://dashboard` 或 `docker-desktop://` 作为“是否修好”的唯一判断标准。

## 建议的最终验证命令

### 验证 Docker Desktop 主程序是否可正常启动

```powershell
Start-Process "C:\Users\AAA\AppData\Local\Programs\DockerDesktop\Docker Desktop.exe"
```

作用：

- 直接验证桌面端本体是否正常。

### 验证 Docker 本地目录仍然可写

```powershell
$probe = "C:\Users\AAA\AppData\Local\Docker\log\host\permission_test.tmp"
Set-Content -Path $probe -Value "ok" -Encoding UTF8
Get-Item $probe
Remove-Item $probe -Force
```

作用：

- 验证权限修复没有回退。

### 验证网页按钮的真实 deeplink

建议方式：

1. 打开最初那个 Docker 网页
2. 点击 `Proceed to Docker Desktop`
3. 观察浏览器是否弹“打开 Docker Desktop”确认框
4. 如仍失败，抓浏览器实际发起的 `docker-desktop://...` 完整 URL，再继续针对那个真实 URL 排查

## 本次用到的关键命令速查

### 查询安装信息

```powershell
Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' |
Where-Object { $_.DisplayName -like 'Docker Desktop*' } |
Select-Object DisplayName, DisplayVersion, InstallLocation
```

作用：确认 Docker Desktop 是否已安装、版本是多少、安装在哪。

### 查询协议注册

```powershell
Get-ItemProperty 'Registry::HKEY_CLASSES_ROOT\docker-desktop\shell\open\command'
Get-ItemProperty 'Registry::HKEY_CURRENT_USER\Software\Classes\docker-desktop\shell\open\command'
```

作用：确认 `docker-desktop://` 协议注册是否存在，以及它绑定到哪个可执行文件。

### 查看 Docker 进程

```powershell
Get-Process 'Docker Desktop','com.docker.backend'
```

作用：确认 Docker Desktop 前端和后台是否存活。

### 停掉 Docker

```powershell
Get-Process 'Docker Desktop','com.docker.backend' -ErrorAction SilentlyContinue | Stop-Process -Force
```

作用：为修 ACL 做准备。

### 改 owner

```powershell
takeown /F "C:\Users\AAA\AppData\Local\Docker" /R /D Y
```

作用：把 Docker 用户目录的所有权交还给当前用户。

### 重新开启继承

```powershell
icacls "C:\Users\AAA\AppData\Local\Docker" /inheritance:e
```

作用：修复异常 ACL 链。

### 显式授予权限

```powershell
icacls "C:\Users\AAA\AppData\Local\Docker" /grant:r "${env:USERNAME}:(OI)(CI)F" /T
```

作用：递归授予当前用户完全控制权限。注意这是一条更稳妥的写法。

### 本地写入验证

```powershell
$probe = "C:\Users\AAA\AppData\Local\Docker\log\host\permission_test.tmp"
Set-Content -Path $probe -Value "ok" -Encoding UTF8
Get-Item $probe
Remove-Item $probe -Force
```

作用：确认当前用户对 Docker 日志目录已具备读写删除能力。

### 直接调用 URL Handler

```powershell
& 'C:\Users\AAA\AppData\Local\Programs\DockerDesktop\resources\Docker Desktop.exe' 'docker-desktop://dashboard'
```

作用：绕过浏览器，直接让 Docker 的 URL Handler 处理 deeplink，便于抓取真实错误。

## 最后判断

当前状态可以这样理解：

- `C:\Users\AAA\AppData\Local\Docker` 权限问题已经修复
- Docker Desktop URL Handler 已经能被系统成功调用
- 手动输入的 `docker-desktop://dashboard` 不是有效 deeplink

后续如果还要继续追网页按钮问题，下一步就不是再修权限，而是抓网页按钮实际触发的那条 `docker-desktop://...` 地址。
