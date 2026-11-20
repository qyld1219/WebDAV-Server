package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math/rand"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type App struct {
	settings Settings
	logs     *LogRing
	server   *Server
	tunnel   *Tunnel
	ddns     *DDNS
	token    string
}

func main() {
	rand.Seed(time.Now().UnixNano())
	var (
		noBrowser  = flag.Bool("no-browser", false, "不自动打开浏览器")
		panelPort  = flag.Int("panel-port", 7788, "控制台端口")
		hideWindow = flag.Bool("hide", false, "启动后立即返回（供快捷方式使用）")
		cfgDirFlag = flag.String("config-dir", "", "配置目录（默认系统配置目录）")
	)
	flag.Parse()
	_ = hideWindow
	if *cfgDirFlag != "" {
		configDirOverride = *cfgDirFlag
	}

	logs := newLogRing(1200)
	app := &App{settings: loadSettings(), logs: logs, token: randToken()}
	app.server = newServer(logs)
	app.tunnel = newTunnel(logs)
	app.ddns = newDDNS(logs)

	addr := fmt.Sprintf("127.0.0.1:%d", *panelPort)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		// 已有实例在跑：把浏览器指向它
		tok, _ := os.ReadFile(filepath.Join(configDir(), "panel.token"))
		url := fmt.Sprintf("http://%s/?t=%s", addr, strings.TrimSpace(string(tok)))
		openBrowser(url)
		return
	}
	os.WriteFile(filepath.Join(configDir(), "panel.token"), []byte(app.token), 0o600)

	logs.Add("应用", fmt.Sprintf("控制台已启动：http://%s", addr))
	logs.Add("应用", "共享目录："+app.settings.ShareDir)
	url := fmt.Sprintf("http://%s/?t=%s", addr, app.token)
	if !*noBrowser {
		openBrowser(url)
	} else {
		fmt.Println("控制台地址：" + url)
	}

	if app.settings.AutoStartSrv {
		if err := app.server.Start(app.settings); err == nil && app.settings.TunnelMode != "none" {
			go app.tunnel.Start(app.settings)
		}
	}
	go app.ddnsLoop()

	mux := http.NewServeMux()
	mux.HandleFunc("/", app.page)
	mux.HandleFunc("/api/state", app.auth(app.apiState))
	mux.HandleFunc("/api/settings", app.auth(app.apiSettings))
	mux.HandleFunc("/api/server", app.auth(app.apiServer))
	mux.HandleFunc("/api/tunnel", app.auth(app.apiTunnel))
	mux.HandleFunc("/api/ddns", app.auth(app.apiDDNS))
	mux.HandleFunc("/api/logs", app.auth(app.apiLogs))
	mux.HandleFunc("/api/open", app.auth(app.apiOpen))
	mux.HandleFunc("/api/portstatus", app.auth(app.apiPortStatus))

	srv := &http.Server{Handler: mux}
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig
	app.shutdown()
}

func (a *App) shutdown() {
	a.logs.Add("应用", "正在退出，清理子进程…")
	a.tunnel.Stop()
	a.server.Stop()
}

func randToken() string {
	const pool = "abcdefghijkmnpqrstuvwxyz23456789"
	b := make([]byte, 24)
	for i := range b {
		b[i] = pool[rand.Intn(len(pool))]
	}
	return string(b)
}

func (a *App) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		t := r.Header.Get("X-Token")
		if t == "" {
			t = r.URL.Query().Get("t")
		}
		if t != a.token {
			http.Error(w, "unauthorized", http.StatusForbidden)
			return
		}
		next(w, r)
	}
}

func (a *App) page(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	if r.URL.Query().Get("t") != a.token {
		http.Error(w, "请通过启动后自动打开的链接访问控制台（地址中带访问令牌）", http.StatusForbidden)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, dashboardHTML(a.token))
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(v)
}

func (a *App) apiState(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]any{
		"settings": a.settings,
		"server":   a.server.Status(),
		"tunnel":   a.tunnel.Status(),
		"ddns":     a.ddns.Status(),
	})
}

func (a *App) apiSettings(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	var s Settings
	if err := json.NewDecoder(r.Body).Decode(&s); err != nil {
		writeJSON(w, map[string]any{"ok": false, "error": "参数解析失败"})
		return
	}
	oldPort := a.settings.Port
	wasRunning := a.server.isRunning()
	a.settings = s
	if err := saveSettings(s); err != nil {
		writeJSON(w, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	a.logs.Add("应用", "设置已保存")
	if wasRunning && oldPort != s.Port {
		a.server.Stop()
		a.tunnel.Stop()
		if err := a.server.Start(a.settings); err != nil {
			writeJSON(w, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		a.logs.Add("应用", "端口已变更，服务已重启")
	}
	writeJSON(w, map[string]any{"ok": true})
}

func (a *App) apiServer(w http.ResponseWriter, r *http.Request) {
	action := r.URL.Query().Get("action")
	switch action {
	case "start":
		if err := a.server.Start(a.settings); err != nil {
			writeJSON(w, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if a.settings.TunnelMode != "none" {
			go a.tunnel.Start(a.settings)
		}
		writeJSON(w, map[string]any{"ok": true})
	case "stop":
		a.tunnel.Stop()
		a.server.Stop()
		writeJSON(w, map[string]any{"ok": true})
	default:
		writeJSON(w, map[string]any{"ok": false, "error": "未知操作"})
	}
}

func (a *App) apiTunnel(w http.ResponseWriter, r *http.Request) {
	action := r.URL.Query().Get("action")
	switch action {
	case "start":
		if err := a.tunnel.Start(a.settings); err != nil {
			writeJSON(w, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, map[string]any{"ok": true})
	case "stop":
		a.tunnel.Stop()
		writeJSON(w, map[string]any{"ok": true})
	default:
		writeJSON(w, map[string]any{"ok": false, "error": "未知操作"})
	}
}

func (a *App) apiDDNS(w http.ResponseWriter, r *http.Request) {
	action := r.URL.Query().Get("action")
	switch action {
	case "verify":
		msg, err := a.ddns.Verify(a.settings.CFToken, a.settings.Zone)
		if err != nil {
			writeJSON(w, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, map[string]any{"ok": true, "message": msg})
	case "sync":
		ip, err := a.ddns.SyncNow(a.settings.CFToken, a.settings.Zone, a.settings.Record, a.logs)
		if err != nil {
			writeJSON(w, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, map[string]any{"ok": true, "ip": ip})
	default:
		writeJSON(w, map[string]any{"ok": false, "error": "未知操作"})
	}
}

func (a *App) apiLogs(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("clear") == "1" {
		a.logs.Clear()
	}
	writeJSON(w, a.logs.Snapshot())
}

func (a *App) apiOpen(w http.ResponseWriter, r *http.Request) {
	target := r.URL.Query().Get("target")
	if target == "share" {
		openFolder(a.settings.ShareDir)
	}
	writeJSON(w, map[string]any{"ok": true})
}

func (a *App) apiPortStatus(w http.ResponseWriter, r *http.Request) {
	port := a.settings.Port
	free := portFree(port)
	msg := "端口可用"
	if !free {
		if a.server.isRunning() && a.server.Status()["port"] == port {
			msg = "服务正在使用该端口"
		} else {
			msg = "端口已被其它程序占用"
		}
	}
	writeJSON(w, map[string]any{"free": free, "message": msg})
}

// ddnsLoop 按设置的间隔检查公网 IP 变化
func (a *App) ddnsLoop() {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	last := time.Time{}
	for range t.C {
		s := a.settings
		if !s.DDNSEnabled || s.CFToken == "" || s.Zone == "" || s.Record == "" {
			continue
		}
		iv := time.Duration(s.IntervalMin) * time.Minute
		if time.Since(last) < iv {
			continue
		}
		last = time.Now()
		if _, err := a.ddns.SyncNow(s.CFToken, s.Zone, s.Record, a.logs); err != nil {
			a.logs.Add("DDNS", "同步失败："+err.Error())
		}
	}
}
