# WebDAV 服务器（macOS 版）使用说明

> 本文件是 macOS 版说明。Windows 与 Android 版见 `三平台总览.md`、`使用说明-Windows.md`、`使用说明-Android.md`。

一个原生 macOS 小应用：把 Mac 上的某个文件夹变成标准的 WebDAV 服务器，并自带三条远程访问通道——**Cloudflare 快速隧道、绑定自有域名的命名隧道、DDNS + 端口映射**。

- 服务端内核：[hacdias/webdav](https://github.com/hacdias/webdav) v5.17.3（MIT）
- 隧道内核：[cloudflared](https://github.com/cloudflare/cloudflared) 2026.10.7（Apache-2.0）
- 外壳：原生 SwiftUI，菜单栏常驻，敏感信息存 Keychain

> 兼容性与安全说明：内置组件均为开源上游程序，本应用只是把它们打包进 App 并做了界面与进程管理，未修改其协议实现。共享出去的内容请自行评估风险，公网暴露时务必保留账号密码。

---

## 一、安装与首次启动

1. 把 `WebDAV服务器.app` 拖进「应用程序」文件夹。
2. 因为本版本是**本地 ad-hoc 签名**（没有 Apple 开发者签名与公证），首次打开会被 Gatekeeper 拦一下：
   - 右键点击 App → 选择「打开」→ 在弹窗里再点「打开」；
   - 或者到「系统设置 → 隐私与安全性」页底部点「仍要打开」。
3. 首次启动如果系统弹出「是否允许本应用接受传入的网络连接」，选**允许**，否则局域网内其它设备连不上。

启动后是普通窗口 + 菜单栏图标两种形态；关掉窗口应用仍在菜单栏里运行，点菜单栏图标可以重新打开窗口。

---

## 二、三步把文件共享出去（局域网）

1. 在「共享设置」里选一个要共享的文件夹（默认是 `~/Desktop/WebDAV共享`）。
2. 确认端口（默认 8080）与用户名、密码。密码建议点「随机生成」。
3. 点右上角「开始共享」。状态变成「运行中」后，顶部的局域网地址即可使用。

**其它设备怎么连**

| 设备 | 操作 |
| --- | --- |
| Mac 访达 | 访达 → 「前往」→「连接服务器」→ 输入 `http://192.168.x.x:8080` → 用应用里显示的账号密码登录 |
| iPhone / iPad | 「文件」App → 浏览 → 右上角「…」→「连接服务器」→ 输入 `http://192.168.x.x:8080` |
| 任意浏览器 | 直接打开该地址，会看到文件列表页，可点开下载（需登录） |
| 第三方客户端 | Cyberduck、nPlayer、Documents 等选 WebDAV 协议填地址即可 |

应用顶部还有「二维码」按钮，手机扫码就能看到地址与账号信息，省得手输。

---

## 三、远程访问（三选一）

远程访问都在「远程访问」页里，先选方式，再点下面的开启按钮。

### 方式 A：Cloudflare 快速隧道（免账号，最省事）

点「快速隧道」→「开启快速隧道」，十几秒后会拿到一个 `https://xxx.trycloudflare.com` 地址，这就是公网 HTTPS 地址，手机在任何网络下都能连。

- 优点：不用注册、不用域名、不用配路由器，自动 HTTPS。
- 限制：地址由 Cloudflare 随机分配，**隧道重启后地址会变**，适合临时分享。
- 如果提示「Cloudflare 临时限流（HTTP 429）」，是 Cloudflare 侧对申请频率的限制，等 30 秒左右重开即可。

### 方式 B：绑定自有域名（Cloudflare 命名隧道）

需要你有 Cloudflare 账号，并有一个已托管到 Cloudflare 的域名。

1. 打开 Cloudflare 控制台 → **Zero Trust → Networks → Tunnels** → **Create a tunnel** → 选 **Cloudflared** 类型。
2. 给隧道起个名字，创建后会给出安装命令，复制其中 `--token` 后面那一长串 **Token**。
3. 回到本应用「远程访问 → 自有域名」，把 Token 粘到「隧道 Token」，域名填你想用的地址（如 `dav.example.com`）。
4. 点「开启隧道」。
5. 回到 Cloudflare 该隧道的 **Public Hostname** 页签，添加主机名：
   - Hostname：`dav.example.com`
   - Service：类型 `HTTP`，URL `localhost:8080`（端口跟你应用里设置的一致）
6. 保存后，访问 `https://dav.example.com` 就是你的 WebDAV。

这个地址**固定不变**，隧道重连也不变，适合长期自用。

### 方式 C：DDNS + 路由器端口映射（家里有公网 IP 时）

前提：宽带运营商给了公网 IPv4（不是 100.x 开头的 CGNAT 地址），并且你能进路由器后台。

1. 路由器后台把外部端口转发到本机 `8080`（应用「远程访问」页里也有同样的提示）。
2. 在 Cloudflare 创建一个 **API Token**：My Profile → API Tokens → Create Token，权限给 `Zone:DNS:Edit` 与 `Zone:Zone:Read`。
3. 应用里勾选「启用 DDNS」，填 Token、根域名（如 `example.com`）、记录名（如 `home.example.com`）、检查间隔（默认 10 分钟）。
4. 点「验证凭据」确认无误，再点「立即同步」。之后公网 IP 变了，应用会自动把 A 记录改成新 IP。
5. 访问 `http://home.example.com:端口` 即可（走 443 需要另配证书，见下方「关于 HTTPS」）。

> 说明：DDNS 与命名隧道这两条路径依赖你自己的 Cloudflare 账号与域名，开发者本机没有凭据，因此仅在代码与界面层面完成，未做真机端到端验证；首次使用请先用「验证凭据」确认。

---

## 四、关于 HTTPS 与安全

- 走 **Cloudflare 隧道**时，Cloudflare 边缘到你的 Mac 之间是加密的，对外就是 `https://`，客户端不用装证书。
- 走 **局域网 / 端口映射**时，默认是明文 HTTP。可以在「共享设置」里打开 TLS，选自己的证书与私钥（PEM），这样客户端要用 `https://` 访问并信任该证书。
- 公网暴露时建议：
  - 一定保留账号密码（不要勾「允许匿名访问」）；
  - 只是给别人下载就勾上「只读共享」；
  - 长期暴露优先用方式 B（固定域名 + 命名隧道），隧道断开即不可达，比直接开端口安全。

---

## 五、常见问题

**1. 手机连不上局域网地址**
- 确认两台设备在同一个 Wi-Fi；
- 确认首次启动时允许了「接受传入的网络连接」；
- 路由器若开了「AP 隔离」，同网段设备也互相不可见。

**2. 快速隧道地址打不开 / 一直「正在建立隧道…」**
- 应用已自动处理：若 QUIC（UDP 7844）被拦截，会自动改用 `--protocol http2` 重连；
- 如果本机开着 Surge / Clash 等代理软件，部分规则会拦掉 `*.trycloudflare.com` 的 TLS 连接，可以先临时关掉代理或把该域名设为直连再试；
- 拿到地址后如果 30 秒内仍未连通，界面会提示失败原因，直接再点一次开启即可。

**3. 提示端口被占用**
- 界面会显示占用端口的进程名。如果显示的是 `webdav`，通常是上次应用被强制退出后残留的服务进程——应用下次启动会自动回收它，也可以手动「活动监视器」里结束。

**4. 关机 / 合盖后远程访问断了**
- 默认勾选「服务运行期间阻止 Mac 休眠」，合盖仍会休眠，远程必然中断；长期对外提供服务建议接电源并关闭「合盖休眠」。

**5. 想开机就自动开始共享**
- 「共享设置 → 运行方式」里勾「打开应用时自动开始共享」；
- 另外可以勾「开机自启」，应用会写入 `~/Library/LaunchAgents/com.malixi.webdavserver.plist`。

**6. 换端口后要做什么**
- 服务运行中改端口会自动重启服务；但隧道与路由器端口映射要跟着改（隧道重启一次，路由器规则手动改）。

---

## 六、文件都放在哪

| 内容 | 位置 |
| --- | --- |
| 服务配置（权限 0600） | `~/Library/Application Support/WebDAVServer/config.yml` |
| 共享目录（默认） | `~/Desktop/WebDAV共享` |
| 应用设置 | `~/Library/Preferences/com.malixi.webdavserver.plist` |
| 密码 / 隧道 Token / Cloudflare Token | 钥匙串（服务名 `WebDAVServer`） |
| 开机自启 | `~/Library/LaunchAgents/com.malixi.webdavserver.plist` |

卸载：退出应用 → 删除 App → 按需删除上面的配置文件与钥匙串条目。

---

## 七、源码与重新构建

源码在 `../macos/` 目录，纯 Swift（无 Xcode 工程，用 `build.sh` 直接编译）：

```bash
cd 源码
./build.sh            # 产出 ../WebDAV服务器.app，并 ad-hoc 签名
```

自检（不需要开界面，直接验证服务端协议是否可用）：

```bash
"./WebDAV服务器.app/Contents/MacOS/WebDAVServer" --selftest
# 全部 PASS 时退出码为 0
```

主要文件：

- `main.swift` / `AppDelegate.swift`：入口、菜单栏、主窗口
- `AppModel.swift`：设置聚合、变更防抖重启、开机自启、二维码、toast
- `ServerController.swift`：拉起/守护内置 webdav 进程、健康检查、残留进程回收
- `TunnelController.swift`：快速隧道 / 命名隧道，QUIC→HTTP/2 自动回退、429 提示、进程兜底回收
- `DDNSController.swift` / `CloudflareAPI.swift`：Cloudflare A 记录自动维护
- `Views.swift`：全部界面
- `Support.swift`：Keychain、网络探测、二维码、YAML 转义、路径
- `Resources/`：内置 `webdav` 与 `cloudflared` 两个二进制

---

## 八、内置开源组件与许可

| 组件 | 版本 | 许可 | 用途 |
| --- | --- | --- | --- |
| hacdias/webdav | v5.17.3 | MIT | WebDAV 服务端 |
| cloudflared | 2026.10.7 | Apache-2.0 | Cloudflare 隧道 |

两个二进制原样打包在 `Contents/Resources/` 下，未做修改；相关许可证归各自作者所有。
