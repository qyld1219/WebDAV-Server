# WebDAV 服务器（Android 版）使用说明

把安卓手机的存储变成一台标准 WebDAV 服务器，同一 Wi-Fi 下的电脑、平板可以直接读写手机里的文件；再点一下「快速隧道」，还能从任何网络用 HTTPS 地址访问。

- 服务端内核：hacdias/webdav v5.17.3（MIT，`linux-arm64` 官方静态二进制，以 `libwebdav.so` 形式随 APK 打包）
- 隧道内核：cloudflared 2026.10.7（Apache-2.0，`linux-arm64`，以 `libcloudflared.so` 形式打包）
- 外壳：纯平台控件 + 前台服务，无 AndroidX / Compose 依赖，APK 只有内核体积

> 适用范围：**arm64-v8a 机型**（近几年的绝大多数手机）。x86 模拟器上跑不了这两个内核，本版未提供 x86 版本。
>
> 与 Mac / Windows 版的关系：协议内核和配置格式一致；安卓端目前只做「手机当服务器 + 快速隧道」，**没有做 DDNS 与命名隧道**（那两条需要固定域名，更适合放在 24 小时开机的电脑上）。

---

## 一、安装

1. 把 `WebDAV服务器-android-arm64.apk` 传到手机（微信/QQ/数据线/网盘均可），在手机上点开安装。系统会提示「未知来源」，允许对应 App 安装即可。
2. 打开 App，第一次会弹通知权限，允许它——服务运行期间靠这个通知常驻后台，关掉通知容易被系统杀进程。

## 二、三步开始共享

1. 点最下方「授予『所有文件访问权限』」，跳到系统设置里给本应用打开「所有文件访问权限」。**只想共享 App 自己的目录可以不授**，但共享手机任意文件夹必须授。
2. 填共享目录（默认 `/storage/emulated/0/WebDAV共享`，不存在会自动创建）、端口（默认 8080）、用户名、密码。
3. 点「开始共享」。状态变「运行中」后，界面上会给出 `http://手机IP:8080/`。

## 三、其它设备怎么连

| 设备 | 操作 |
| --- | --- |
| 电脑浏览器 | 直接打开 `http://手机IP:8080/`，登录后看到文件列表 |
| Windows 资源管理器 | 映射网络驱动器，地址同上 |
| macOS 访达 | 前往 → 连接服务器，地址同上 |
| 手机（另一台） | 用支持 WebDAV 的文件管理器新建连接 |
| iPhone / iPad | 「文件」App → 浏览 → 连接服务器 |

手机 IP 在 App 界面上直接显示，不用去系统设置里找。

## 四、远程访问（快速隧道）

1. 先确保「运行中」；
2. 点「开启快速隧道」，十几秒后界面出现 `https://xxx.trycloudflare.com`；
3. 在任何网络的设备上用这个地址访问，账号密码不变。

说明：

- 地址由 Cloudflare 随机分配，**隧道重启就会变**；长期使用请用电脑版配自有域名。
- 手机 QUIC(UDP 7844) 被运营商或路由器拦截时，App 会自动切到 HTTP/2 重连，界面会标注「（HTTP/2）」。
- 出现「429 限流」是 Cloudflare 侧限制，等 30 秒再开。

## 五、后台常驻（重要）

安卓系统会为了省电杀后台。要长期对外提供访问，请在系统设置里把本应用设为：

- 电池 → 应用耗电管理 → 允许后台活动 / 不限制；
- 最近任务里给应用「加锁」（不同厂商叫法不同：锁定、锁定后台、清理白名单）。

App 已经申请了前台服务与 WakeLock，正常情况下通知栏常驻即可保持运行；被厂商省电策略强杀时，重新打开 App 会恢复。

## 六、常见问题

**1. 开始共享后界面显示「已停止」**
多半是目录不可写或端口被占。看一眼「运行日志」里的报错；换端口或换共享目录再试。

**2. 电脑连不上手机**
- 确认两台设备在同一个 Wi-Fi，且路由器没有开「AP 隔离」；
- 手机连的是访客网络时，通常不允许互访。

**3. 共享目录里看不到手机相册/下载的文件**
默认只共享 `/storage/emulated/0/WebDAV共享`。要共享整个内部存储，需授予「所有文件访问权限」，然后把目录填成 `/storage/emulated/0`。

**4. 隧道一直失败**
先看日志有没有 `Registered tunnel connection`；没有的话通常是手机网络限制，换 Wi-Fi / 开飞行模式再关掉重试。

**5. 想卸载干净**
先在 App 里点「停止共享」，再卸载；配置在 `/Android/data/com.malixi.webdav.android/files/config.yml`，卸载时随应用数据一起清除。

## 七、从源码构建

```bash
cd Android版源码
export JAVA_HOME=<你的 JDK17>
export ANDROID_HOME=<你的 Android SDK>
./gradlew assembleDebug
# 产物：app/build/outputs/apk/debug/app-debug.apk
```

内核文件放在 `app/src/main/jniLibs/arm64-v8a/`：

- `libwebdav.so` ← `https://github.com/hacdias/webdav/releases/download/v5.17.3/linux-arm64-webdav.tar.gz` 解包出的 `webdav`
- `libcloudflared.so` ← `https://github.com/cloudflare/cloudflared/releases/download/2026.10.7/cloudflared-linux-arm64`

二者都是官方静态二进制，改名后原样放入（Android 只允许从 `nativeLibraryDir` 执行可执行文件，这是标准做法）。

## 八、开源组件

| 组件 | 版本 | 许可 |
| --- | --- | --- |
| hacdias/webdav | v5.17.3 | MIT |
| cloudflared | 2026.10.7 | Apache-2.0 |
