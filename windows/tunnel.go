package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

var quickURLRe = regexp.MustCompile(`https://[a-z0-9-]+\.trycloudflare\.com`)

type Tunnel struct {
	mu         sync.Mutex
	cmd        *exec.Cmd
	mode       string // none | quick | named
	status     string // off | starting | online | failed
	publicURL  string
	errText    string
	useHTTP2   bool
	retried    bool
	registered bool
	logs       *LogRing
	port       int
	hostname   string
	stopFlag   bool
}

func newTunnel(logs *LogRing) *Tunnel {
	return &Tunnel{logs: logs, status: "off", mode: "none"}
}

func (t *Tunnel) Start(st Settings) error {
	t.mu.Lock()
	if t.cmd != nil {
		t.mu.Unlock()
		return errors.New("隧道已在运行")
	}
	t.mode = st.TunnelMode
	t.status = "starting"
	t.publicURL = ""
	t.errText = ""
	t.registered = false
	t.stopFlag = false
	t.port = st.Port
	t.hostname = st.TunnelHost
	t.mu.Unlock()

	// 启动前清理上次异常退出遗留的 cloudflared
	if reaped := reapLeftovers("cloudflared.exe"); reaped > 0 {
		t.logs.Add("隧道", fmt.Sprintf("发现 %d 个上次残留的隧道进程，正在回收", reaped))
	}
	if st.TunnelMode == "quick" {
		t.logs.Add("隧道", "正在创建 Cloudflare 快速隧道（免账号，地址随机且重启后会变化）…")
	} else {
		t.logs.Add("隧道", "正在连接 Cloudflare 命名隧道…")
	}
	return t.begin(st, false)
}

func (t *Tunnel) begin(st Settings, withHTTP2 bool) error {
	bin := childBinary("cloudflared")
	if _, err := os.Stat(bin); err != nil {
		t.logs.Add("隧道", "找不到内置 cloudflared："+bin)
		t.setFailed("找不到内置 cloudflared 程序")
		return fmt.Errorf("找不到内置 cloudflared：%s", bin)
	}
	var args []string
	if st.TunnelMode == "quick" {
		args = []string{"tunnel", "--no-autoupdate", "--loglevel", "info"}
		if withHTTP2 {
			args = append(args, "--protocol", "http2")
		}
		args = append(args, "--url", fmt.Sprintf("http://127.0.0.1:%d", st.Port))
	} else {
		args = []string{"tunnel", "--no-autoupdate", "--loglevel", "info", "--protocol", "http2",
			"run", "--token", st.TunnelToken}
	}
	cmd := exec.Command(bin, args...)
	cmd.Env = append(os.Environ(), "TUNNEL_ORIGIN_CERT=")
	pipe, err := cmd.StderrPipe()
	if err != nil {
		return err
	}
	stdout, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.logs.Add("隧道", "启动失败："+err.Error())
		t.setFailed("隧道进程启动失败")
		return err
	}
	t.mu.Lock()
	t.cmd = cmd
	t.useHTTP2 = withHTTP2
	t.mu.Unlock()
	t.logs.Add("隧道", fmt.Sprintf("隧道进程已启动（PID %d）", cmd.Process.Pid))

	pump := func(r interface{ Read([]byte) (int, error) }) {
		sc := bufio.NewScanner(r)
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for sc.Scan() {
			line := sc.Text()
			t.logs.Add("隧道", line)
			t.inspect(line)
		}
	}
	go pump(pipe)
	go pump(stdout)

	go func() {
		cmd.Wait()
		t.mu.Lock()
		stale := t.cmd == cmd
		if stale {
			t.cmd = nil
		}
		status := t.status
		wantStop := t.stopFlag
		t.mu.Unlock()
		if stale && !wantStop && (status == "starting" || status == "online") {
			t.logs.Add("隧道", "隧道进程意外退出")
			t.setFailed("隧道进程退出")
		}
	}()

	// 30 秒内未注册成功则判定失败（快速隧道地址可能给了但边缘不通）
	go func() {
		time.Sleep(30 * time.Second)
		t.mu.Lock()
		needFail := t.status == "starting" && !t.registered && !t.stopFlag
		t.mu.Unlock()
		if needFail {
			t.setFailed("隧道 30 秒内未连通，请稍后重试")
			t.Stop()
		}
	}()
	return nil
}

func (t *Tunnel) inspect(line string) {
	lower := strings.ToLower(line)
	switch {
	case strings.Contains(line, "Registered tunnel connection"):
		t.mu.Lock()
		t.registered = true
		t.status = "online"
		url := t.publicURL
		t.mu.Unlock()
		if url != "" {
			t.logs.Add("隧道", "公网地址已连通："+url)
		} else {
			t.logs.Add("隧道", "隧道已连通")
		}
	case quickURLRe.MatchString(line):
		url := quickURLRe.FindString(line)
		t.mu.Lock()
		firstTime := t.publicURL == ""
		t.publicURL = url
		t.mu.Unlock()
		if firstTime {
			t.logs.Add("隧道", "公网地址已分配："+url+"，正在与 Cloudflare 边缘建立连接…")
		}
	case strings.Contains(lower, "429") || strings.Contains(lower, "too many requests"):
		t.logs.Add("隧道", "Cloudflare 拒绝了本次申请（HTTP 429 限流），请等待约 30 秒后重试")
		t.setFailed("Cloudflare 临时限流（HTTP 429），请等待约 30 秒后重新开启")
		go t.Stop()
	case strings.Contains(lower, "no recent network activity") || strings.Contains(lower, "failed to dial a quic connection"):
		t.mu.Lock()
		alreadyRetried := t.retried
		t.retried = true
		t.mu.Unlock()
		if !alreadyRetried {
			t.logs.Add("隧道", "本机 QUIC(UDP 7844) 不可用，自动切换到 HTTP/2 重连…")
			go t.retryHTTP2()
		}
	}
}

func (t *Tunnel) retryHTTP2() {
	t.teardown()
	st := loadSettings()
	t.mu.Lock()
	t.status = "starting"
	t.registered = false
	t.mu.Unlock()
	if err := t.begin(st, true); err != nil {
		t.setFailed("HTTP/2 重连失败：" + err.Error())
	}
}

func (t *Tunnel) setFailed(msg string) {
	t.mu.Lock()
	t.status = "failed"
	t.errText = msg
	t.mu.Unlock()
}

func (t *Tunnel) teardown() {
	t.mu.Lock()
	cmd := t.cmd
	t.cmd = nil
	t.mu.Unlock()
	if cmd != nil {
		killGracefully(cmd)
	}
}

func (t *Tunnel) Stop() {
	t.mu.Lock()
	t.stopFlag = true
	was := t.status != "off"
	url := t.publicURL
	t.mu.Unlock()
	t.teardown()
	if reaped := reapLeftovers("cloudflared.exe"); reaped > 0 {
		t.logs.Add("隧道", fmt.Sprintf("关闭后回收了 %d 个残留隧道进程", reaped))
	}
	if was || url != "" {
		t.logs.Add("隧道", "隧道已关闭")
	}
	t.mu.Lock()
	t.status = "off"
	t.publicURL = ""
	t.errText = ""
	t.mode = "none"
	t.useHTTP2 = false
	t.retried = false
	t.registered = false
	t.mu.Unlock()
}

func (t *Tunnel) Status() map[string]any {
	t.mu.Lock()
	defer t.mu.Unlock()
	return map[string]any{
		"state":     t.status,
		"mode":      t.mode,
		"url":       t.publicURL,
		"hostname":  t.hostname,
		"error":     t.errText,
		"protocol":  map[bool]string{true: "http2", false: "quic"}[t.useHTTP2],
	}
}
