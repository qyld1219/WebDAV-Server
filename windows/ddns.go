package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

const cfBase = "https://api.cloudflare.com/client/v4"

var httpClient = &http.Client{Timeout: 12 * time.Second}

type CFResult struct {
	Success bool              `json:"success"`
	Errors  []struct{ Code int; Message string } `json:"errors"`
	Result  json.RawMessage   `json:"result"`
}

func cfCall(token, method, path string, body any) (*CFResult, error) {
	var buf io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		buf = bytes.NewReader(data)
	}
	req, err := http.NewRequest(method, cfBase+path, buf)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var r CFResult
	if err := json.Unmarshal(raw, &r); err != nil {
		return nil, fmt.Errorf("无法解析 Cloudflare 响应（HTTP %d）", resp.StatusCode)
	}
	if !r.Success {
		msg := "调用失败"
		if len(r.Errors) > 0 {
			msg = r.Errors[0].Message
		}
		return &r, fmt.Errorf("%s", msg)
	}
	return &r, nil
}

func publicIP() (string, error) {
	for _, u := range []string{"https://api.ipify.org", "https://ifconfig.me/ip", "https://ipv4.icanhazip.com"} {
		resp, err := httpClient.Get(u)
		if err != nil {
			continue
		}
		raw, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		ip := strings.TrimSpace(string(raw))
		if ip != "" && strings.Count(ip, ".") == 3 {
			return ip, nil
		}
	}
	return "", fmt.Errorf("无法获取公网 IP")
}

type DDNS struct {
	mu       sync.Mutex
	token    string
	zone     string
	record   string
	lastIP   string
	lastSync string
	lastErr  string
	logs     *LogRing
	stop     chan struct{}
}

func newDDNS(logs *LogRing) *DDNS { return &DDNS{logs: logs} }

func (d *DDNS) Verify(token, zone string) (string, error) {
	if token == "" {
		return "", fmt.Errorf("请先填写 Cloudflare API Token")
	}
	if _, err := cfCall(token, "GET", "/user/tokens/verify", nil); err != nil {
		return "", fmt.Errorf("Token 无效或权限不足：%w", err)
	}
	zones, err := cfCall(token, "GET", "/zones?per_page=50", nil)
	if err != nil {
		return "", err
	}
	var list []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	if err := json.Unmarshal(zones.Result, &list); err != nil {
		return "", err
	}
	names := make([]string, 0, len(list))
	for _, z := range list {
		names = append(names, z.Name)
	}
	if zone != "" {
		for _, z := range list {
			if z.Name == zone {
				return "Token 有效，已找到域名 " + zone, nil
			}
		}
		return "", fmt.Errorf("Token 有效，但账号下没有域名 %s（可用：%s）", zone, strings.Join(names, "、"))
	}
	return "Token 有效，可管理域名：" + strings.Join(names, "、"), nil
}

func (d *DDNS) zoneID(token, zone string) (string, error) {
	r, err := cfCall(token, "GET", "/zones?name="+zone, nil)
	if err != nil {
		return "", err
	}
	var list []struct{ ID string `json:"id"`; Name string `json:"name"` }
	if err := json.Unmarshal(r.Result, &list); err != nil {
		return "", err
	}
	if len(list) == 0 {
		return "", fmt.Errorf("找不到域名 %s", zone)
	}
	return list[0].ID, nil
}

// SyncNow 取当前公网 IP 并更新（或创建）A 记录。
func (d *DDNS) SyncNow(token, zone, record string, logs *LogRing) (string, error) {
	if token == "" || zone == "" || record == "" {
		return "", fmt.Errorf("请先填写 Token、域名与记录名")
	}
	ip, err := publicIP()
	if err != nil {
		return "", err
	}
	zid, err := d.zoneID(token, zone)
	if err != nil {
		return "", err
	}
	if !strings.HasSuffix(record, zone) {
		record = strings.TrimSuffix(record, ".") + "." + zone
	}
	type rec struct {
		ID      string `json:"id"`
		Name    string `json:"name"`
		Content string `json:"content"`
		Type    string `json:"type"`
	}
	r, err := cfCall(token, "GET", "/zones/"+zid+"/dns_records?type=A&name="+record, nil)
	if err != nil {
		return "", err
	}
	var recs []rec
	json.Unmarshal(r.Result, &recs)
	if len(recs) > 0 {
		if recs[0].Content == ip {
			d.markSync(ip, record, logs)
			return ip, nil
		}
		_, err = cfCall(token, "PATCH", "/zones/"+zid+"/dns_records/"+recs[0].ID,
			map[string]any{"content": ip, "proxied": false, "ttl": 120})
		if err != nil {
			d.setErr(err.Error())
			return "", err
		}
	} else {
		_, err = cfCall(token, "POST", "/zones/"+zid+"/dns_records",
			map[string]any{"type": "A", "name": record, "content": ip, "ttl": 120, "proxied": false})
		if err != nil {
			d.setErr(err.Error())
			return "", err
		}
	}
	d.markSync(ip, record, logs)
	return ip, nil
}

func (d *DDNS) markSync(ip, record string, logs *LogRing) {
	d.mu.Lock()
	d.lastIP = ip
	d.lastSync = time.Now().Format("2006-01-02 15:04:05")
	d.lastErr = ""
	d.mu.Unlock()
	if logs != nil {
		logs.Add("DDNS", fmt.Sprintf("%s 已指向 %s", record, ip))
	}
}

func (d *DDNS) setErr(msg string) {
	d.mu.Lock()
	d.lastErr = msg
	d.mu.Unlock()
}

func (d *DDNS) Status() map[string]any {
	d.mu.Lock()
	defer d.mu.Unlock()
	return map[string]any{"ip": d.lastIP, "lastSync": d.lastSync, "error": d.lastErr}
}
