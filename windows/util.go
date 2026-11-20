package main

import (
	"fmt"
	"math/rand"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

func randInt(n int) int {
	return rand.New(rand.NewSource(time.Now().UnixNano())).Intn(n)
}

// ---------- 日志环形缓冲 ----------

type LogRing struct {
	mu    sync.Mutex
	lines []string
	limit int
}

func newLogRing(limit int) *LogRing { return &LogRing{limit: limit} }

func (l *LogRing) Add(source, text string) {
	text = strings.TrimRight(text, "\r\n")
	if strings.TrimSpace(text) == "" {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	stamp := time.Now().Format("15:04:05")
	l.lines = append(l.lines, fmt.Sprintf("[%s] [%s] %s", stamp, source, text))
	if len(l.lines) > l.limit {
		l.lines = l.lines[len(l.lines)-l.limit:]
	}
}

func (l *LogRing) Snapshot() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([]string, len(l.lines))
	copy(out, l.lines)
	return out
}

func (l *LogRing) Clear() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.lines = nil
}

// ---------- 端口 / 网络 ----------

func portFree(port int) bool {
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		return false
	}
	ln.Close()
	return true
}

func portOpen(port int) bool {
	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 800*time.Millisecond)
	if err != nil {
		return false
	}
	c.Close()
	return true
}

// ---------- 进程 ----------

// killGracefully 先温和终止，超时后强杀；两个平台都可用。
func killGracefully(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = cmd.Process.Kill()
	done := make(chan struct{})
	go func() {
		cmd.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
	}
	cmd.Process.Kill()
}

func resourcesDir() string {
	exe, err := os.Executable()
	if err != nil {
		return "resources"
	}
	return filepath.Join(filepath.Dir(exe), "resources")
}

func childBinary(name string) string {
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	return filepath.Join(resourcesDir(), name)
}

// reapLeftovers 清理上次异常退出遗留的同类子进程（按进程名 + 可执行路径匹配）。
func reapLeftovers(binName string) int {
	if runtime.GOOS == "windows" {
		out, err := exec.Command("tasklist", "/FI", "IMAGENAME eq "+binName, "/FO", "CSV", "/NH").CombinedOutput()
		if err != nil {
			return 0
		}
		reaped := 0
		for _, line := range strings.Split(string(out), "\n") {
			fields := strings.Split(strings.TrimSpace(line), ",")
			if len(fields) < 2 {
				continue
			}
			pid := strings.Trim(fields[1], `"`)
			if pid == "" || !isDigits(pid) {
				continue
			}
			if exec.Command("taskkill", "/PID", pid, "/T", "/F").Run() == nil {
				reaped++
			}
		}
		return reaped
	}
	// unix：匹配 bundle 内二进制路径
	bin := childBinary(strings.TrimSuffix(binName, ".exe"))
	out, err := exec.Command("pgrep", "-f", bin).CombinedOutput()
	if err != nil {
		return 0
	}
	reaped := 0
	for _, f := range strings.Fields(string(out)) {
		if isDigits(f) {
			if exec.Command("kill", "-9", f).Run() == nil {
				reaped++
			}
		}
	}
	return reaped
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// openBrowser 打开系统默认浏览器。
func openBrowser(url string) {
	if runtime.GOOS == "windows" {
		exec.Command("cmd", "/c", "start", "", url).Start()
		return
	}
	if runtime.GOOS == "darwin" {
		exec.Command("open", url).Start()
		return
	}
	exec.Command("xdg-open", url).Start()
}

// openInExplorer 打开共享目录。
func openFolder(path string) {
	if runtime.GOOS == "windows" {
		exec.Command("explorer", path).Start()
		return
	}
	if runtime.GOOS == "darwin" {
		exec.Command("open", path).Start()
		return
	}
	exec.Command("xdg-open", path).Start()
}
