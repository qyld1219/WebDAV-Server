package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

// Server 负责内置 webdav 服务进程的生命周期。
type Server struct {
	mu      sync.Mutex
	cmd     *exec.Cmd
	running bool
	port    int
	dir     string
	logs    *LogRing
	appLog  *LogRing
}

func newServer(logs *LogRing) *Server { return &Server{logs: logs, appLog: logs} }

func (s *Server) configPath() string { return filepath.Join(configDir(), "config.yml") }

// writeConfig 生成 hacdias/webdav 的配置文件。
func (s *Server) writeConfig(st Settings) error {
	perm := "CRUD"
	if st.ReadOnly {
		perm = "R"
	}
	var users string
	if st.AllowAnon {
		users = "  - username: \"\"\n    password: \"\"\n    permissions: " + perm + "\n  - username: " +
			yamlQuote(st.Username) + "\n    password: " + yamlQuote(st.Password) + "\n    permissions: " + perm + "\n"
	} else {
		users = "  - username: " + yamlQuote(st.Username) + "\n    password: " + yamlQuote(st.Password) +
			"\n    permissions: " + perm + "\n"
	}
	body := fmt.Sprintf(`# 由 WebDAV 服务器自动生成，改动会在下次启动时被覆盖
address: 0.0.0.0
port: %d
directory: %s
permissions: %s
prefix: /
debug: false
noSniff: false
behindProxy: false
listing:
  enabled: %t
  show_path: true
log:
  format: console
  colors: false
  outputs:
    - stderr
cors:
  enabled: true
  credentials: true
  allowed_hosts:
    - "*"
users:
%s`, st.Port, yamlQuote(st.ShareDir), perm, st.Listing, users)
	if err := os.WriteFile(s.configPath(), []byte(body), 0o600); err != nil {
		return err
	}
	os.MkdirAll(st.ShareDir, 0o755)
	return nil
}

func (s *Server) Start(st Settings) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.running {
		return errors.New("服务已在运行")
	}
	if !portFree(st.Port) {
		s.logs.Add("服务", fmt.Sprintf("端口 %d 已被占用，无法启动", st.Port))
		return fmt.Errorf("端口 %d 已被占用", st.Port)
	}
	if err := s.writeConfig(st); err != nil {
		s.logs.Add("服务", "写入配置失败："+err.Error())
		return err
	}
	// 清理上次残留（例如异常退出后仍占着端口的旧服务）
	bin := childBinary("webdav")
	if _, err := os.Stat(bin); err != nil {
		s.logs.Add("服务", "找不到内置 webdav 程序："+bin)
		return fmt.Errorf("找不到内置 webdav 程序：%s", bin)
	}
	if reaped := reapLeftovers("webdav.exe"); reaped > 0 {
		s.logs.Add("服务", fmt.Sprintf("回收了 %d 个上次残留的服务进程", reaped))
	}
	cmd := exec.Command(bin, "-c", s.configPath())
	cmd.Dir = filepath.Dir(bin)
	stderr, _ := cmd.StderrPipe()
	stdout, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		s.logs.Add("服务", "启动失败："+err.Error())
		return err
	}
	s.cmd = cmd
	s.running = true
	s.port = st.Port
	s.dir = st.ShareDir
	s.logs.Add("服务", fmt.Sprintf("已启动服务进程（PID %d），监听 0.0.0.0:%d", cmd.Process.Pid, st.Port))

	pump := func(r io.Reader) {
		sc := bufio.NewScanner(r)
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for sc.Scan() {
			s.logs.Add("服务", sc.Text())
		}
	}
	go pump(stderr)
	go pump(stdout)

	// 健康检查：最多等 6 秒确认端口可连
	go func(port int) {
		for i := 0; i < 24; i++ {
			if portOpen(port) {
				s.logs.Add("服务", fmt.Sprintf("服务已就绪：http://127.0.0.1:%d/", port))
				return
			}
			time.Sleep(250 * time.Millisecond)
			if !s.isRunning() {
				return
			}
		}
		s.logs.Add("服务", "启动超时：端口未在预期时间内可连接")
	}(st.Port)

	go func() {
		cmd.Wait()
		s.mu.Lock()
		if s.cmd == cmd {
			s.cmd = nil
			if s.running {
				s.running = false
				s.logs.Add("服务", "服务进程已退出")
			}
		}
		s.mu.Unlock()
	}()
	return nil
}

func (s *Server) Stop() {
	s.mu.Lock()
	cmd := s.cmd
	s.cmd = nil
	wasRunning := s.running
	s.running = false
	s.mu.Unlock()
	if cmd != nil {
		killGracefully(cmd)
	}
	// 兜底：确保没有同类进程继续占用端口
	if reaped := reapLeftovers("webdav.exe"); reaped > 0 {
		s.logs.Add("服务", fmt.Sprintf("停止后回收了 %d 个残留服务进程", reaped))
	}
	if wasRunning {
		s.logs.Add("服务", "共享已停止")
	}
	s.appLog = s.logs
}

func (s *Server) isRunning() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.running
}

func (s *Server) Status() map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	state := "stopped"
	if s.running {
		if portOpen(s.port) {
			state = "running"
		} else {
			state = "starting"
		}
	}
	return map[string]any{
		"state":   state,
		"port":    s.port,
		"dir":     s.dir,
		"running": s.running,
	}
}
