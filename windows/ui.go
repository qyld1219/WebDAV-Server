package main

import "strings"

const htmlTemplate = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>WebDAV 服务器（Windows）</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root { --bg:#f5f6f8; --card:#ffffff; --line:#e3e6eb; --text:#1b1f24; --muted:#6b7280; --brand:#2563eb; --ok:#15803d; --warn:#b45309; --err:#b91c1c; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font:14px/1.5 -apple-system,"Segoe UI","Microsoft YaHei",sans-serif; }
  .wrap { max-width:980px; margin:0 auto; padding:28px 20px 60px; }
  header { display:flex; align-items:center; justify-content:space-between; margin-bottom:18px; }
  h1 { font-size:20px; margin:0; font-weight:600; }
  .sub { color:var(--muted); font-size:13px; }
  .pill { padding:4px 10px; border-radius:999px; font-size:12px; border:1px solid var(--line); background:#fff; }
  .pill.ok { color:var(--ok); border-color:#bbf7d0; background:#f0fdf4; }
  .pill.err { color:var(--err); border-color:#fecaca; background:#fef2f2; }
  .pill.warn { color:var(--warn); border-color:#fed7aa; background:#fffbeb; }
  .tabs { display:flex; gap:6px; margin-bottom:14px; }
  .tabs button { border:1px solid var(--line); background:#fff; padding:8px 16px; border-radius:8px; cursor:pointer; font-size:13px; color:var(--muted); }
  .tabs button.active { color:var(--text); border-color:#c7d2fe; background:#eef2ff; font-weight:600; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:18px 20px; margin-bottom:16px; }
  .card h2 { font-size:15px; margin:0 0 12px; font-weight:600; }
  label { display:block; font-size:12px; color:var(--muted); margin:10px 0 4px; }
  input[type=text],input[type=password],input[type=number],select { width:100%; padding:8px 10px; border:1px solid var(--line); border-radius:8px; font-size:13px; background:#fff; }
  .row { display:flex; gap:12px; }
  .row > div { flex:1; }
  .actions { display:flex; gap:10px; margin-top:16px; flex-wrap:wrap; }
  button.primary { background:var(--brand); color:#fff; border:none; padding:9px 16px; border-radius:8px; cursor:pointer; font-size:13px; }
  button.ghost { background:#fff; color:var(--text); border:1px solid var(--line); padding:9px 16px; border-radius:8px; cursor:pointer; font-size:13px; }
  button.link { background:none; border:none; color:var(--brand); cursor:pointer; font-size:12px; padding:0; }
  .check { display:flex; align-items:center; gap:8px; margin:10px 0 0; font-size:13px; }
  .check input { width:16px; height:16px; }
  .hint { font-size:12px; color:var(--muted); margin-top:6px; }
  .addr { font-family:ui-monospace,Menlo,Consolas,monospace; font-size:13px; background:#f8fafc; border:1px solid var(--line); border-radius:8px; padding:8px 10px; word-break:break-all; }
  #logs { font-family:ui-monospace,Menlo,Consolas,monospace; font-size:12px; background:#0f172a; color:#cbd5e1; border-radius:10px; padding:12px; height:320px; overflow:auto; white-space:pre-wrap; }
  .hidden { display:none; }
  .toast { position:fixed; right:20px; bottom:20px; background:#111827; color:#fff; padding:10px 14px; border-radius:8px; font-size:13px; opacity:0; transition:.2s; }
  .toast.show { opacity:1; }
  table.kv { width:100%; font-size:13px; border-collapse:collapse; }
  table.kv td { padding:6px 0; border-bottom:1px dashed var(--line); }
  table.kv td:first-child { color:var(--muted); width:120px; }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div>
      <h1>WebDAV 服务器</h1>
      <div class="sub">内置 hacdias/webdav + cloudflared · Windows 版</div>
    </div>
    <div id="serverPill" class="pill">读取中…</div>
  </header>

  <div class="tabs">
    <button data-tab="share" class="active">共享设置</button>
    <button data-tab="remote">远程访问</button>
    <button data-tab="logs">运行日志</button>
    <button data-tab="help">使用帮助</button>
  </div>

  <div id="tab-share">
    <div class="card">
      <h2>共享</h2>
      <div class="row">
        <div style="flex:3">
          <label>共享目录</label>
          <input type="text" id="shareDir">
        </div>
        <div style="flex:1">
          <label>端口</label>
          <input type="number" id="port">
          <div class="hint" id="portHint">—</div>
        </div>
      </div>
      <div class="actions">
        <button class="ghost" onclick="act('open')">打开共享目录</button>
        <button class="primary" id="btnServer" onclick="toggleServer()">开始共享</button>
      </div>
      <div class="addr" style="margin-top:14px" id="lanAddr">—</div>
      <div class="hint">其它设备用 WebDAV 客户端连接上面的地址，账号密码见下方。</div>
    </div>

    <div class="card">
      <h2>访问控制</h2>
      <div class="row">
        <div>
          <label>用户名</label>
          <input type="text" id="username">
        </div>
        <div>
          <label>密码</label>
          <input type="text" id="password">
        </div>
      </div>
      <div class="check"><input type="checkbox" id="readOnly"><span>只读共享（客户端只能下载）</span></div>
      <div class="check"><input type="checkbox" id="listing"><span>对外提供网页文件列表（浏览器直接打开地址即可浏览）</span></div>
      <div class="check"><input type="checkbox" id="allowAnon"><span>允许匿名访问（不推荐）</span></div>
      <div class="check"><input type="checkbox" id="autoStart"><span>打开应用时自动开始共享</span></div>
      <div class="actions"><button class="primary" onclick="saveSettings()">保存设置</button></div>
    </div>
  </div>

  <div id="tab-remote" class="hidden">
    <div class="card">
      <h2>远程访问方式</h2>
      <label>模式</label>
      <select id="tunnelMode" onchange="onModeChange()">
        <option value="none">关闭（只用局域网）</option>
        <option value="quick">Cloudflare 快速隧道（免账号，地址随机）</option>
        <option value="named">自有域名（Cloudflare 命名隧道）</option>
      </select>
      <div id="namedBox" class="hidden">
        <label>隧道 Token（Cloudflare Zero Trust 创建隧道时给出）</label>
        <input type="text" id="tunnelToken" placeholder="eyJhIjoi…">
        <label>对外域名</label>
        <input type="text" id="tunnelHost" placeholder="dav.example.com">
        <div class="hint">在 Cloudflare 该隧道的 Public Hostname 里把域名指向 HTTP localhost:8080（端口与应用一致）。</div>
      </div>
      <div class="actions">
        <button class="primary" id="btnTunnel" onclick="toggleTunnel()">开启隧道</button>
        <button class="ghost" onclick="saveSettings()">保存设置</button>
      </div>
      <div style="margin-top:14px" id="tunnelStatusBox">
        <table class="kv">
          <tr><td>状态</td><td id="tState">未开启</td></tr>
          <tr><td>公网地址</td><td id="tUrl">—</td></tr>
          <tr><td>协议</td><td id="tProto">—</td></tr>
          <tr><td>提示</td><td id="tErr">—</td></tr>
        </table>
      </div>
    </div>

    <div class="card">
      <h2>DDNS（Cloudflare A 记录自动更新）</h2>
      <div class="check" style="margin-top:0"><input type="checkbox" id="ddnsEnabled"><span>启用 DDNS</span></div>
      <label>Cloudflare API Token（需 Zone:DNS:Edit + Zone:Zone:Read）</label>
      <input type="text" id="cfToken" placeholder="Token">
      <div class="row">
        <div>
          <label>根域名</label>
          <input type="text" id="zone" placeholder="example.com">
        </div>
        <div>
          <label>记录名</label>
          <input type="text" id="record" placeholder="home.example.com">
        </div>
        <div style="flex:0 0 130px">
          <label>检查间隔（分钟）</label>
          <input type="number" id="intervalMin">
        </div>
      </div>
      <div class="actions">
        <button class="ghost" onclick="ddnsAction('verify')">验证凭据</button>
        <button class="primary" onclick="ddnsAction('sync')">立即同步</button>
        <button class="ghost" onclick="saveSettings()">保存设置</button>
      </div>
      <table class="kv" style="margin-top:12px">
        <tr><td>当前公网 IP</td><td id="dIP">—</td></tr>
        <tr><td>上次同步</td><td id="dLast">—</td></tr>
      </table>
      <div class="hint">DDNS 只负责改 DNS 记录；对外访问还需要在路由器上把端口映射到本机（例如外网 8080 → 本机 8080）。</div>
    </div>
  </div>

  <div id="tab-logs" class="hidden">
    <div class="card">
      <h2>运行日志</h2>
      <div id="logs"></div>
      <div class="actions"><button class="ghost" onclick="clearLogs()">清空</button></div>
    </div>
  </div>

  <div id="tab-help" class="hidden">
    <div class="card">
      <h2>三步开始共享</h2>
      <div class="hint" style="line-height:1.9">
        1. 选好共享目录与端口，保存设置；<br>
        2. 点「开始共享」，状态变为运行中；<br>
        3. 其它设备用 WebDAV 客户端打开显示的局域网地址，账号密码见「访问控制」。<br><br>
        Windows 资源管理器挂载：右键「此电脑」→ 映射网络驱动器 → 输入地址；<br>
        macOS 访达：前往 → 连接服务器；手机：用支持 WebDAV 的文件管理器 App。<br><br>
        远程访问优先用快速隧道（自动 HTTPS、免端口映射）；需要固定地址就用自有域名 + 命名隧道；<br>
        家里有公网 IP 才考虑 DDNS + 端口映射，且 HTTP 明文暴露有风险，务必设密码。
      </div>
    </div>
  </div>
</div>
<div class="toast" id="toast"></div>
<script>
const TOKEN = "__TOKEN__";
let state = null;

function api(path, opts) {
  opts = opts || {};
  opts.headers = Object.assign({"X-Token": TOKEN, "Content-Type": "application/json"}, opts.headers || {});
  opts.cache = "no-store";
  return fetch(path, opts).then(r => r.json());
}
function toast(msg) {
  const el = document.getElementById("toast");
  el.textContent = msg; el.classList.add("show");
  setTimeout(() => el.classList.remove("show"), 2200);
}
document.querySelectorAll(".tabs button").forEach(b => {
  b.onclick = () => {
    document.querySelectorAll(".tabs button").forEach(x => x.classList.remove("active"));
    b.classList.add("active");
    ["share","remote","logs","help"].forEach(t => {
      document.getElementById("tab-" + t).classList.toggle("hidden", t !== b.dataset.tab);
    });
  };
});

function fillForm(s) {
  document.getElementById("shareDir").value = s.shareDir;
  document.getElementById("port").value = s.port;
  document.getElementById("username").value = s.username;
  document.getElementById("password").value = s.password;
  document.getElementById("readOnly").checked = s.readOnly;
  document.getElementById("listing").checked = s.listing;
  document.getElementById("allowAnon").checked = s.allowAnon;
  document.getElementById("autoStart").checked = s.autoStartServer;
  document.getElementById("tunnelMode").value = s.tunnelMode || "none";
  document.getElementById("tunnelToken").value = s.tunnelToken || "";
  document.getElementById("tunnelHost").value = s.tunnelHost || "";
  document.getElementById("ddnsEnabled").checked = s.ddnsEnabled;
  document.getElementById("cfToken").value = s.cfToken || "";
  document.getElementById("zone").value = s.zone || "";
  document.getElementById("record").value = s.record || "";
  document.getElementById("intervalMin").value = s.intervalMin;
  onModeChange();
}

function readForm() {
  return {
    shareDir: document.getElementById("shareDir").value.trim(),
    port: parseInt(document.getElementById("port").value) || 8080,
    username: document.getElementById("username").value,
    password: document.getElementById("password").value,
    readOnly: document.getElementById("readOnly").checked,
    listing: document.getElementById("listing").checked,
    allowAnon: document.getElementById("allowAnon").checked,
    autoStartServer: document.getElementById("autoStart").checked,
    tunnelMode: document.getElementById("tunnelMode").value,
    tunnelToken: document.getElementById("tunnelToken").value.trim(),
    tunnelHost: document.getElementById("tunnelHost").value.trim(),
    ddnsEnabled: document.getElementById("ddnsEnabled").checked,
    cfToken: document.getElementById("cfToken").value.trim(),
    zone: document.getElementById("zone").value.trim(),
    record: document.getElementById("record").value.trim(),
    intervalMin: parseInt(document.getElementById("intervalMin").value) || 10
  };
}

function onModeChange() {
  const m = document.getElementById("tunnelMode").value;
  document.getElementById("namedBox").classList.toggle("hidden", m !== "named");
}

function saveSettings() {
  const body = readForm();
  api("/api/settings", {method: "POST", body: JSON.stringify(body)}).then(r => {
    if (r.ok) { toast("设置已保存"); refresh(); } else { toast("保存失败：" + r.error); }
  });
}

function toggleServer() {
  const running = state && state.server.state === "running";
  api("/api/server?action=" + (running ? "stop" : "start"), {method: "POST"}).then(r => {
    if (!r.ok) toast(r.error); else toast(running ? "已停止共享" : "已开始共享");
    refresh();
  });
}
function toggleTunnel() {
  const on = state && (state.tunnel.state === "starting" || state.tunnel.state === "online");
  if (!on) saveSettings();
  api("/api/tunnel?action=" + (on ? "stop" : "start"), {method: "POST"}).then(r => {
    if (!r.ok) toast(r.error); else toast(on ? "隧道已关闭" : "正在建立隧道…");
    refresh();
  });
}
function ddnsAction(a) {
  if (a === "verify") saveSettings();
  api("/api/ddns?action=" + a).then(r => {
    if (r.ok) toast(r.message || ("已同步，公网 IP " + r.ip)); else toast("失败：" + r.error);
    refresh();
  });
}
function act(a) { api("/api/open?target=share"); toast("已在资源管理器中打开"); }
function clearLogs() { api("/api/logs?clear=1"); loadLogs(); }

function pill(el, text, kind) {
  el.textContent = text;
  el.className = "pill " + (kind || "");
}

function refresh() {
  api("/api/state").then(s => {
    state = s;
    const running = s.server.state === "running";
    pill(document.getElementById("serverPill"), running ? "运行中" : (s.server.state === "starting" ? "正在启动…" : "已停止"), running ? "ok" : "");
    document.getElementById("btnServer").textContent = running ? "停止共享" : "开始共享";
    document.getElementById("lanAddr").textContent = running
      ? "http://" + (s.server.dir ? "" : "") + "127.0.0.1:" + s.server.port + "  （局域网请用本机 IP，如 http://192.168.1.x:" + s.server.port + "）"
      : "服务未运行";
    document.getElementById("tState").textContent = ({off:"未开启",starting:"正在建立隧道…",online:"已连接",failed:"失败"})[s.tunnel.state] || s.tunnel.state;
    document.getElementById("tUrl").textContent = s.tunnel.url || (s.tunnel.hostname ? "https://" + s.tunnel.hostname : "—");
    document.getElementById("tProto").textContent = s.tunnel.protocol || "—";
    document.getElementById("tErr").textContent = s.tunnel.error || "—";
    document.getElementById("btnTunnel").textContent = (s.tunnel.state === "starting" || s.tunnel.state === "online") ? "关闭隧道" : "开启隧道";
    document.getElementById("dIP").textContent = s.ddns.ip || "—";
    document.getElementById("dLast").textContent = s.ddns.lastSync || "—";
  }).catch(() => {});
  api("/api/portstatus").then(p => {
    const h = document.getElementById("portHint");
    h.textContent = p.message;
    h.style.color = p.free ? "#15803d" : "#b45309";
  }).catch(() => {});
  loadLogs();
}

function loadLogs() {
  api("/api/logs").then(lines => {
    const box = document.getElementById("logs");
    box.textContent = (lines || []).join("\n");
    box.scrollTop = box.scrollHeight;
  }).catch(() => {});
}

api("/api/state").then(s => { state = s; fillForm(s.settings); refresh(); });
setInterval(refresh, 2000);
</script>
</body>
</html>`

func dashboardHTML(token string) string {
	return strings.ReplaceAll(htmlTemplate, "__TOKEN__", token)
}
