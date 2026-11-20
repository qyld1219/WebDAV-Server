# WebDAV 服务器（Windows 版）使用说明

把 Windows 电脑上的一个文件夹变成标准 WebDAV 服务器，并自带三条远程访问通道：Cloudflare 快速隧道、绑定自有域名的命名隧道、DDNS + 端口映射。

- 服务端内核：hacdias/webdav v5.17.3（MIT，`windows-amd64` 官方二进制）
- 隧道内核：cloudflared 2026.10.7（Apache-2.0，`windows-amd64` 官方二进制）
- 外壳：Go 编译的单文件 `WebDAVServer.exe`（约 7.5 MB），界面是本地网页控制台，双击即自动在浏览器里打开

> 与 Mac 版同源：同一套配置格式、同一套隧道/DDNS 逻辑，只是把界面从 SwiftUI 换成了本地网页控制台（不依赖 .NET、Qt、Electron），所以整包只有一个 exe + 两个官方二进制。

---

## 一、安装

1. 解压后把整个 `WebDAV-Server-Windows` 文件夹放到任意位置（例如 `D:\WebDAV服务器\`）。**`resources` 子文件夹必须和 `WebDAVServer.exe` 在一起**，里面是服务端与隧道内核。
2. 双击 `WebDAVServer.exe`：会弹一个黑色命令行窗口，同时浏览器自动打开控制台（形如 `http://127.0.0.1:7788/?t=…`）。**这个命令行窗口不要关**，它就是程序本体；关掉窗口等于退出程序。
3. 首次运行 Windows 会弹出防火墙提示，勾选「专用网络」并允许，否则局域网内其它设备连不上。

想要开机自启：给 `WebDAVServer.exe` 建一个快捷方式放进 `shell:startup`（Win+R 输入 `shell:startup` 回车，把快捷方式拖进打开的文件夹）。在「共享设置」里勾上「打开应用时自动开始共享」即可连服务一起自启。

---

## 二、三步开始共享（局域网）

1. 「共享设置」里填共享目录（默认 `C:\Users\<你>\Documents\WebDAV共享`，不存在会自动创建）、端口（默认 8080）、用户名密码，点「保存设置」。
2. 点「开始共享」，右上角状态变成「运行中」。
3. 其它设备连接：
   - **Windows 资源管理器**：右键「此电脑」→ 映射网络驱动器 → 输入 `http://192.168.x.x:8080`，再输账号密码；
   - **macOS 访达**：前往 → 连接服务器 → 输入同一地址；
   - **手机**：装一个支持 WebDAV 的文件管理器（如 Documents、Solid Explorer），新建 WebDAV 连接；
   - **浏览器**：直接打开地址，能看到文件列表页（需登录）。

> 控制台顶部显示的 `127.0.0.1` 是本机自环地址，局域网其它设备要用本机局域网 IP（`ipconfig` 里那个 192.168 / 10.x 地址）。

---

## 三、远程访问（三选一）

### A. Cloudflare 快速隧道（免账号，最省事）

「远程访问 → 模式」选「Cloudflare 快速隧道」，保存设置后点「开启隧道」。十几秒后拿到 `https://xxx.trycloudflare.com`，任何网络的手机都能连。

- 地址由 Cloudflare 随机分配，**隧道重启就会变**，适合临时分享。
- 本机 QUIC(UDP 7844) 不通时程序会自动切换到 HTTP/2 重连，日志里能看到「自动切换到 HTTP/2」。
- 提示「HTTP 429 限流」是 Cloudflare 侧限制，等 30 秒再开。

### B. 自有域名（Cloudflare 命名隧道）

1. Cloudflare 控制台 → Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared，复制 `--token` 后的 Token。
2. 控制台里选「自有域名」，把 Token 与域名（如 `dav.example.com`）填好，保存。
3. 点「开启隧道」。
4. Cloudflare 该隧道的 Public Hostname 添加一条：Hostname = `dav.example.com`，Service = `HTTP`，URL = `localhost:8080`（端口要和应用里一致）。

这个地址固定不变，适合长期自用。

### C. DDNS + 端口映射

前提：宽带给了公网 IPv4（不是 100.x 的 CGNAT 地址），且能进路由器后台。

1. 路由器把外部端口转发到本机 8080。
2. Cloudflare 创建 API Token，权限 `Zone:DNS:Edit` + `Zone:Zone:Read`。
3. 勾「启用 DDNS」，填 Token、根域名、记录名（如 `home.example.com`），点「验证凭据」再「立即同步」。
4. 之后公网 IP 变化时，程序按设定间隔自动改 A 记录。

> DDNS 只改 DNS；对外访问仍需端口映射。HTTP 明文暴露有风险，务必保留密码。

---

## 四、常见问题

**1. 双击后浏览器打开了但页面报 403**
控制台地址必须带 `?t=<令牌>`。直接手输 `http://127.0.0.1:7788/` 会被拒（防止其它本机程序乱调接口）。关掉程序重开一次即可，令牌每次启动都会换。

**2. 提示端口被占用**
换一个端口保存即可。若是上次异常退出残留的 `webdav.exe`，程序启动和停止时都会自动按进程名回收。

**3. 想让程序后台运行、不留命令行窗口**
目前 exe 是控制台程序（关窗口即退出），可以用任务计划程序「开机时运行」并勾选「不管用户是否登录都运行」。日志在控制台里可看，也可在「运行日志」页导出式查看。

**4. 杀毒软件报毒**
因为是无签名的小众 exe，偶尔会被误报，加白名单即可；源码在 `../windows/`，可自行 `go build` 复核。

**5. 快速隧道地址打不开**
先看「运行日志」里隧道是否出现「Registered tunnel connection」；有「429」就等一会；有代理软件（Clash/Surge 等）拦截 `*.trycloudflare.com` 时先关掉再试。

---

## 五、文件都放在哪

| 内容 | 位置 |
| --- | --- |
| 设置 | `%APPDATA%\WebDAVServer\settings.json` |
| 服务配置（每次启动重写） | `%APPDATA%\WebDAVServer\config.yml` |
| 控制台令牌 | `%APPDATA%\WebDAVServer\panel.token` |
| 共享目录（默认） | `%USERPROFILE%\Documents\WebDAV共享` |

卸载：关掉程序 → 删除文件夹 → 按需删除 `%APPDATA%\WebDAVServer`。

---

## 六、从源码构建

```bash
cd Windows版源码
GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-s -w -H windowsgui" -o WebDAVServer.exe .
```

`resources/` 里的两个 exe 直接取官方发布包：

- `https://github.com/hacdias/webdav/releases/download/v5.17.3/windows-amd64-webdav.zip`
- `https://github.com/cloudflare/cloudflared/releases/download/2026.10.7/cloudflared-windows-amd64.exe`

---

## 七、开源组件

| 组件 | 版本 | 许可 |
| --- | --- | --- |
| hacdias/webdav | v5.17.3 | MIT |
| cloudflared | 2026.10.7 | Apache-2.0 |
