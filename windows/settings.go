package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

type Settings struct {
	ShareDir      string `json:"shareDir"`
	Port          int    `json:"port"`
	Username      string `json:"username"`
	Password      string `json:"password"`
	ReadOnly      bool   `json:"readOnly"`
	Listing       bool   `json:"listing"`
	AllowAnon     bool   `json:"allowAnon"`
	TunnelMode    string `json:"tunnelMode"` // none | quick | named
	TunnelToken   string `json:"tunnelToken"`
	TunnelHost    string `json:"tunnelHost"`
	DDNSEnabled   bool   `json:"ddnsEnabled"`
	CFToken       string `json:"cfToken"`
	Zone          string `json:"zone"`
	Record        string `json:"record"`
	IntervalMin   int    `json:"intervalMin"`
	AutoStartSrv  bool   `json:"autoStartServer"`
	PublicIP      string `json:"publicIP"`
	LastSync      string `json:"lastSync"`
}

var configDirOverride string

func configDir() string {
	if configDirOverride != "" {
		os.MkdirAll(configDirOverride, 0o700)
		return configDirOverride
	}
	if d := os.Getenv("WEBDAV_CFG_DIR"); d != "" {
		return d
	}
	base, err := os.UserConfigDir()
	if err != nil {
		base = os.TempDir()
	}
	dir := filepath.Join(base, "WebDAVServer")
	os.MkdirAll(dir, 0o700)
	return dir
}

func defaultShareDir() string {
	home, _ := os.UserHomeDir()
	if runtime.GOOS == "windows" {
		if dir := os.Getenv("USERPROFILE"); dir != "" {
			home = dir
		}
		return filepath.Join(home, "Documents", "WebDAV共享")
	}
	return filepath.Join(home, "Desktop", "WebDAV共享")
}

func defaultSettings() Settings {
	return Settings{
		ShareDir:     defaultShareDir(),
		Port:         8080,
		Username:     "webdav",
		Password:     randomPassword(),
		ReadOnly:     false,
		Listing:      true,
		TunnelMode:   "none",
		IntervalMin:  10,
		AutoStartSrv: false,
	}
}

func settingsPath() string { return filepath.Join(configDir(), "settings.json") }

func loadSettings() Settings {
	s := defaultSettings()
	data, err := os.ReadFile(settingsPath())
	if err == nil {
		json.Unmarshal(data, &s)
	}
	if s.Username == "" {
		s.Username = "webdav"
	}
	if s.Port <= 0 || s.Port > 65535 {
		s.Port = 8080
	}
	if s.IntervalMin <= 0 {
		s.IntervalMin = 10
	}
	if s.ShareDir == "" {
		s.ShareDir = defaultShareDir()
	}
	return s
}

func saveSettings(s Settings) error {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(settingsPath(), data, 0o600)
}

func randomPassword() string {
	const pool = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	b := make([]byte, 12)
	for i := range b {
		b[i] = pool[randInt(len(pool))]
	}
	return string(b)
}

func yamlQuote(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`)
	return `"` + r.Replace(s) + `"`
}
