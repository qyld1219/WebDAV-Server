import SwiftUI
import AppKit

// MARK: - 通用组件

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }
}

struct StatusPill: View {
    let state: ServerState

    private var color: Color {
        switch state {
        case .running: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(state.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct FieldRow<Content: View>: View {
    let title: String
    var width: CGFloat = 92
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: width, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 根视图

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            addressSection
                .padding(.horizontal, 24)
                .padding(.top, 16)
            tabBar
                .padding(.horizontal, 24)
                .padding(.top, 18)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 12)
            footer
        }
        .frame(minWidth: 940, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showQR) {
            QRSheet(model: model)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.primary.opacity(0.85)))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .padding(.bottom, 44)
                    .transition(.opacity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("WebDAV 服务器")
                    .font(.system(size: 19, weight: .semibold))
                Text(model.settings.sharePath)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            StatusPill(state: model.server.state)
            Button {
                model.toggleServer()
            } label: {
                Text(model.server.state.isActive ? "停止共享" : "开始共享")
                    .frame(width: 76)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(model.server.state.isActive ? .red : .accentColor)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var addressSection: some View {
        VStack(spacing: 0) {
            AddressRow(
                title: "局域网",
                symbol: "wifi.router",
                value: model.lanAddress,
                placeholder: "未检测到局域网地址",
                tint: .blue,
                model: model
            )
            Divider().padding(.leading, 36).opacity(0.5)
            AddressRow(
                title: "外网",
                symbol: "globe.asia.australia",
                value: model.remoteAddress,
                placeholder: "未开启远程访问，可前往「远程访问」设置",
                tint: .teal,
                model: model
            )
            Divider().padding(.leading, 36).opacity(0.5)
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(model.settings.allowAnonymous
                     ? "匿名访问（无需密码）"
                     : "账号 \(model.settings.username) · 密码 \(model.settings.password)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("复制连接信息") {
                    model.copy(model.connectionSummary, feedback: "连接信息已复制")
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                Button {
                    model.selectedTab = index
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbol).font(.system(size: 12))
                        Text(tab.title).font(.system(size: 12.5, weight: model.selectedTab == index ? .semibold : .regular))
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(model.selectedTab == index ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                    .foregroundStyle(model.selectedTab == index ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var tabs: [(title: String, symbol: String)] {
        [("共享设置", "folder.badge.gearshape"),
         ("远程访问", "globe"),
         ("运行日志", "list.bullet.rectangle"),
         ("使用帮助", "questionmark.circle")]
    }

    @ViewBuilder
    private var content: some View {
        switch model.selectedTab {
        case 0: SettingsTab(model: model, settings: model.settings)
        case 1: RemoteTab(model: model, settings: model.settings)
        case 2: LogTab(model: model)
        default: HelpTab(model: model)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text("内置开源组件：hacdias/webdav (MIT) · cloudflared (Apache-2.0) · 本应用为本地封装")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
            if model.server.state.isActive {
                Text("服务运行时已阻止系统休眠")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

struct AddressRow: View {
    let title: String
    let symbol: String
    let value: String?
    let placeholder: String
    let tint: Color
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(value == nil ? Color.secondary : tint)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            if let value {
                Text(value)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(placeholder)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if let value {
                Button { model.copy(value) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("复制地址")

                Button { model.presentQR(for: value) } label: {
                    Image(systemName: "qrcode")
                }
                .buttonStyle(.borderless)
                .help("显示二维码")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

// MARK: - 共享设置

struct SettingsTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "共享位置")
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        FieldRow(title: "文件夹", width: 62) {
                            Text(settings.sharePath)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Button("选择…") { model.chooseShareFolder() }
                                .controlSize(.small)
                            Button("打开") { model.openShareFolder() }
                                .controlSize(.small)
                        }
                        FieldRow(title: "端口", width: 62) {
                            TextField("", value: $settings.port, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 78)
                                .multilineTextAlignment(.leading)
                            Text(model.portStatus)
                                .font(.system(size: 11))
                                .foregroundStyle(model.portStatusWarning ? Color.red : Color.secondary)
                        }
                        Text("改动会自动保存；服务运行中修改会立即重启生效。")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                SectionHeader(title: "访问控制")
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        FieldRow(title: "用户名", width: 62) {
                            TextField("", text: $settings.username)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                                .disabled(settings.allowAnonymous)
                        }
                        FieldRow(title: "密码", width: 62) {
                            SecureField("", text: $settings.password)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                                .disabled(settings.allowAnonymous)
                            Button("随机生成") {
                                settings.password = AppSettings.randomPassword()
                                model.showToast("已生成新密码")
                            }
                            .controlSize(.small)
                            .disabled(settings.allowAnonymous)
                        }
                        Divider().opacity(0.4)
                        Toggle("允许匿名访问（无需账号密码）", isOn: $settings.allowAnonymous)
                            .font(.system(size: 12.5))
                        if settings.allowAnonymous {
                            Label("匿名模式下同一网络内任何人都能访问，只建议在完全可信的网络里使用。", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                        Toggle("只读共享（客户端只能下载，不能上传/修改）", isOn: $settings.readOnly)
                            .font(.system(size: 12.5))
                    }
                }

                SectionHeader(title: "运行方式")
                Card {
                    VStack(alignment: .leading, spacing: 13) {
                        Toggle("对外提供网页文件列表（浏览器直接打开地址即可浏览下载）", isOn: $settings.showListing)
                            .font(.system(size: 12.5))
                        Toggle("服务运行期间阻止 Mac 休眠（外网访问不中断）", isOn: $settings.keepAwake)
                            .font(.system(size: 12.5))
                            .onChange(of: settings.keepAwake) { _, _ in
                                model.server.refreshAwakeState()
                            }
                        Toggle("打开应用时自动开始共享", isOn: $settings.autoStartServer)
                            .font(.system(size: 12.5))
                        Toggle("登录时自动打开本应用", isOn: $settings.launchAtLogin)
                            .font(.system(size: 12.5))
                            .onChange(of: settings.launchAtLogin) { _, newValue in
                                if let error = model.setLaunchAtLogin(newValue) {
                                    model.showToast(error)
                                } else {
                                    model.showToast(newValue ? "已添加登录启动项" : "已移除登录启动项")
                                }
                            }
                        Text("提示：Mac 合盖或断网时外网访问会中断，长期远程访问建议插电并保持唤醒。")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                SectionHeader(title: "高级：HTTPS")
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("使用自备 TLS 证书启用 HTTPS（局域网直连更安全）", isOn: $settings.useTLS)
                            .font(.system(size: 12.5))
                        if settings.useTLS {
                            FieldRow(title: "证书", width: 62) {
                                Text(settings.certPath.isEmpty ? "未选择" : settings.certPath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(settings.certPath.isEmpty ? .tertiary : .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Button("选择…") {
                                    if let path = model.chooseFile(message: "选择 PEM 格式证书文件") {
                                        settings.certPath = path
                                    }
                                }
                                .controlSize(.small)
                            }
                            FieldRow(title: "私钥", width: 62) {
                                Text(settings.keyPath.isEmpty ? "未选择" : settings.keyPath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(settings.keyPath.isEmpty ? .tertiary : .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Button("选择…") {
                                    if let path = model.chooseFile(message: "选择 PEM 格式私钥文件") {
                                        settings.keyPath = path
                                    }
                                }
                                .controlSize(.small)
                            }
                        } else {
                            Text("使用 Cloudflare 隧道时无需自己配证书，隧道已提供 HTTPS。")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

}

// MARK: - 远程访问

struct RemoteTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                Picker("", selection: $settings.tunnelMode) {
                    ForEach(TunnelMode.allCases) { mode in
                        Text(mode.shortTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch settings.tunnelMode {
                case .lan: lanPanel
                case .quick: quickPanel
                case .named: namedPanel
                }

                Text("安全提醒：对外暴露时请务必设置密码，优先使用隧道（自动 HTTPS）；直接端口映射的 HTTP 地址在公网上是明文传输。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 20)
            }
        }
    }

    // MARK: 局域网 / 端口映射

    private var lanPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("同一 Wi-Fi / 局域网内的设备（iPhone、iPad、另一台电脑）可以直接用上面的局域网地址连接，无需任何额外设置。")
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                    if let lan = model.lanAddress {
                        HStack(spacing: 10) {
                            Text(lan)
                                .font(.system(size: 12.5, design: .monospaced))
                                .textSelection(.enabled)
                            Button("复制") { model.copy(lan) }
                                .controlSize(.small)
                            Button("二维码") { model.presentQR(for: lan) }
                                .controlSize(.small)
                        }
                    }
                }
            }

            SectionHeader(title: "公网 IP 与端口映射")
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    FieldRow(title: "公网 IP", width: 62) {
                        Text(model.ddns.publicIP ?? "未获取")
                            .font(.system(size: 12.5, design: .monospaced))
                        Button("刷新") { model.refreshPublicIP() }
                            .controlSize(.small)
                    }
                    Text("要让外网直接访问，需要在路由器上把公网端口映射到本机 \(String(settings.port)) 端口，并确保公网 IP 未被运营商 CGNAT 屏蔽。若 IP 是 100.x / 无公网 IP，请改用 Cloudflare 隧道。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SectionHeader(title: "Cloudflare DDNS（固定域名 + 自动更新 IP）")
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("启用 DDNS：公网 IP 变化时自动更新 A 记录", isOn: $settings.ddnsEnabled)
                        .font(.system(size: 12.5))
                    FieldRow(title: "API Token", width: 78) {
                        SecureField("需要 Zone:DNS:Edit 与 Zone:Zone:Read 权限", text: $settings.cfToken)
                            .textFieldStyle(.roundedBorder)
                    }
                    FieldRow(title: "根域名", width: 78) {
                        TextField("例如 example.com", text: $settings.cfZone)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                        Text("已添加到 Cloudflare 的域名")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    FieldRow(title: "记录名", width: 78) {
                        TextField("例如 home.example.com", text: $settings.cfRecord)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                    FieldRow(title: "检查间隔", width: 78) {
                        TextField("", value: $settings.ddnsIntervalMinutes, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.leading)
                        Text("分钟")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("（修改后重新开关一次 DDNS 生效）")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 10) {
                        Button("验证凭据") { model.verifyDDNS() }
                            .controlSize(.small)
                            .disabled(model.ddnsVerifying)
                        Button("立即同步") {
                            model.ddns.refreshNow(force: true)
                        }
                        .controlSize(.small)
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(ddnsColor)
                                .frame(width: 7, height: 7)
                            Text(model.ddns.message)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !model.ddnsVerifyResult.isEmpty {
                        Text(model.ddnsVerifyResult)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    DisclosureGroup("如何获取 API Token / 配置端口映射？") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. 打开 dash.cloudflare.com → My Profile → API Tokens → Create Token。").font(.system(size: 11))
                            Text("2. 权限选择 Zone → DNS → Edit，以及 Zone → Zone → Read，Zone Resources 选具体域名。").font(.system(size: 11))
                            Text("3. 复制生成的 Token 粘贴到上方（只显示一次）。").font(.system(size: 11))
                            Text("4. 路由器后台把外部端口 \(String(settings.port)) 转发到本机 \(String(settings.port))，再把域名解析交给 DDNS 自动维护。").font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }

    private var ddnsColor: Color {
        switch model.ddns.phase {
        case .ok: return .green
        case .error: return .red
        case .working: return .orange
        case .idle: return .blue
        case .off: return .secondary
        }
    }

    // MARK: 快速隧道

    private var quickPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Label("免账号、免端口映射，一键生成公网 HTTPS 地址", systemImage: "bolt.horizontal.circle")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("由 Cloudflare 免费提供。适合临时把文件分享给外网的人：家里/公司网络没有公网 IP、不会配路由器也能用。地址由 Cloudflare 随机分配，隧道重启后会变化。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            model.applyTunnel()
                        } label: {
                            Text(model.tunnel.status.isActive ? "关闭隧道" : "开启快速隧道")
                                .frame(width: 110)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.server.state.isActive && model.tunnel.status.isActive == false)

                        TunnelStatusView(model: model)
                    }
                    if let url = model.remoteAddress {
                        HStack(spacing: 10) {
                            Text(url)
                                .font(.system(size: 12.5, design: .monospaced))
                                .textSelection(.enabled)
                            Button("复制") { model.copy(url) }
                                .controlSize(.small)
                            Button("二维码") { model.presentQR(for: url) }
                                .controlSize(.small)
                        }
                        Text("在手机「文件」App 或电脑浏览器里直接打开这个地址即可。")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    if case .failed(let message) = model.tunnel.status {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: 命名隧道

    private var namedPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    FieldRow(title: "隧道 Token", width: 78) {
                        SecureField("粘贴 Cloudflare 隧道 Token", text: $settings.tunnelToken)
                            .textFieldStyle(.roundedBorder)
                    }
                    FieldRow(title: "访问域名", width: 78) {
                        TextField("例如 dav.example.com", text: $settings.publicHostname)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                        Text("用于显示和二维码")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 12) {
                        Button {
                            model.applyTunnel()
                        } label: {
                            Text(model.tunnel.status.isActive ? "关闭隧道" : "开启命名隧道")
                                .frame(width: 110)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.server.state.isActive == false)
                        TunnelStatusView(model: model)
                    }
                    if let url = model.remoteAddress {
                        HStack(spacing: 10) {
                            Text(url)
                                .font(.system(size: 12.5, design: .monospaced))
                                .textSelection(.enabled)
                            Button("复制") { model.copy(url) }
                                .controlSize(.small)
                            Button("二维码") { model.presentQR(for: url) }
                                .controlSize(.small)
                        }
                    }
                    if case .failed(let message) = model.tunnel.status {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SectionHeader(title: "在自己的域名上开通（推荐长期使用）")
            Card {
                VStack(alignment: .leading, spacing: 7) {
                    stepText("1", "登录 dash.cloudflare.com → Zero Trust → Networks → Tunnels → Create a tunnel，类型选 Cloudflared。")
                    stepText("2", "创建后复制命令里 --token 后面的整串 Token，粘贴到上方。")
                    stepText("3", "进入该隧道的 Public Hostname 页签：添加主机名 dav.example.com，服务类型选 HTTP，URL 填 localhost:\(String(settings.port))。")
                    stepText("4", "保存后回到本应用开启命名隧道，用上方的域名访问即可（Cloudflare 自动提供 HTTPS，无需端口映射）。")
                }
            }
        }
    }

    private func stepText(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor.opacity(0.14)))
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TunnelStatusView: View {
    @ObservedObject var model: AppModel

    private var color: Color {
        switch model.tunnel.status {
        case .online: return .green
        case .starting: return .orange
        case .failed: return .red
        case .off: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if case .starting = model.tunnel.status {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(model.tunnel.status.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 日志

struct LogTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(model.log.lines.count) 行")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("清空") { model.log.clear() }
                    .controlSize(.small)
                Button("保存为文件") { saveLog() }
                    .controlSize(.small)
            }
            .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if model.log.lines.isEmpty {
                            Text("暂无日志。启动服务后这里会显示访问记录与错误信息。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                        }
                        ForEach(Array(model.log.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 10.8, design: .monospaced))
                                .foregroundStyle(line.contains("ERR") || line.contains("error") || line.contains("Error") ? Color.red.opacity(0.85) : Color.primary.opacity(0.8))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(12)
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )
                .onChange(of: model.log.lines.count) { _, count in
                    if count > 0 {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(count - 1, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 16)
    }

    private func saveLog() {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        panel.nameFieldStringValue = "webdav-log-\(formatter.string(from: Date())).txt"
        panel.message = "保存运行日志"
        if panel.runModal() == .OK, let url = panel.url {
            try? model.log.exportText().write(to: url, atomically: true, encoding: .utf8)
            model.showToast("日志已保存")
        }
    }
}

// MARK: - 帮助

struct HelpTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "客户端怎么连接")
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        helpBlock("Mac 访达", "按 ⌘K 打开「连接服务器」，输入局域网地址（如 \(model.lanAddress ?? "http://192.168.1.5:8080")），选择「注册的用户」并填账号密码，即可在访达里当磁盘用。")
                        helpBlock("iPhone / iPad", "打开「文件」App → 右上角 … → 连接服务器 → 服务器地址填上方地址 → 输入账号密码。")
                        helpBlock("Windows 资源管理器", "右键「此电脑」→ 映射网络驱动器 → 输入地址；若提示，选择「使用其他凭据」填账号密码。")
                        helpBlock("其他 App", "Obsidian、笔记软件、下载工具等支持 WebDAV 的应用，填入地址 + 账号 + 密码即可。")
                    }
                }

                SectionHeader(title: "首次启动注意事项")
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("macOS 会弹窗询问「是否允许接受传入的网络连接」，必须点「允许」，否则其他设备连不上。", systemImage: "checkmark.shield")
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        Label("合盖、休眠、断网都会让远程访问中断；长期远程访问建议插电并开启「阻止休眠」。", systemImage: "moon.zzz")
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        Label("没有公网 IP（运营商 CGNAT，IP 形如 100.x.x.x）时，路由器端口映射无效，请使用 Cloudflare 隧道。", systemImage: "network.slash")
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SectionHeader(title: "安全建议")
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("· 定期更换密码，不要把带账号密码的链接发给别人。").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("· 公网访问优先走隧道（自动 HTTPS）；直接 HTTP 端口映射会明文传输密码。").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("· 不需要远程时关闭隧道，减少暴露面。").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("· 共享文件夹只放需要共享的内容，敏感资料建议单独建目录。").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }

                SectionHeader(title: "关于本应用")
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WebDAV 服务器（本地封装版）1.0").font(.system(size: 12, weight: .medium))
                        Text("服务端来自开源项目 hacdias/webdav（MIT 许可），隧道能力来自 Cloudflare cloudflared（Apache-2.0）。本应用负责任务栏界面、账号管理、进程守护、DDNS 与隧道编排，所有文件都在你自己的 Mac 上，不经过第三方服务器（隧道流量加密转发除外）。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("配置与日志位置：~/Library/Application Support/WebDAVServer/")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    private func helpBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 二维码

struct QRSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Text("扫码连接")
                .font(.system(size: 16, weight: .semibold))
            if let image = QRCodeGenerator.image(text: model.qrPayload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            } else {
                Text("二维码生成失败").foregroundStyle(.red)
            }
            Text(model.qrPayload)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            HStack(spacing: 10) {
                Button("复制地址") { model.copy(model.qrPayload) }
                Button("关闭") { model.showQR = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
