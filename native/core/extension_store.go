package core

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"duanjuapp/native/ext"
)

const extensionSourceFile = "source.js"

// extensionHost 把 core 的网络栈与数据目录暴露给扩展运行时。
type extensionHost struct {
	d *Downloader
}

func (h *extensionHost) Fetch(ctx context.Context, source string, request ext.Request) (*ext.Response, error) {
	address := strings.TrimSpace(request.URL)
	parsed, err := url.Parse(address)
	if err != nil || parsed.Host == "" || !isProviderHTTPMediaURL(address) {
		return nil, errors.New("扩展请求的地址无效")
	}
	if request.Method != http.MethodGet && request.Method != http.MethodPost {
		return nil, errors.New("扩展仅支持 GET/POST 请求")
	}
	if request.Body != "" && request.BodyBase64 != "" {
		return nil, errors.New("扩展请求体不能同时提供文本与二进制形式")
	}
	body := []byte(request.Body)
	if request.BodyBase64 != "" {
		body, err = base64.StdEncoding.DecodeString(request.BodyBase64)
		if err != nil {
			return nil, errors.New("扩展请求体不是有效的 base64")
		}
	}
	if len(body) > 1<<20 {
		return nil, errors.New("扩展请求体超过 1 MiB 上限")
	}
	var reader io.Reader
	if len(body) > 0 {
		reader = bytes.NewReader(body)
	}
	httpRequest, err := http.NewRequestWithContext(ctx, request.Method, address, reader)
	if err != nil {
		return nil, err
	}
	release, err := h.d.limiter.acquire(ctx, httpRequest)
	if err != nil {
		return nil, err
	}
	defer release()
	httpRequest.Header.Set("User-Agent", "Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 Chrome/150.0.0.0 Mobile Safari/537.36")
	for key, value := range request.Headers {
		switch strings.ToLower(strings.TrimSpace(key)) {
		case "host", "content-length", "connection":
			continue
		default:
			httpRequest.Header.Set(key, value)
		}
	}
	response, err := h.d.client.Do(httpRequest)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 8<<20))
	if err != nil {
		return nil, err
	}
	headers := map[string]string{}
	for key, values := range response.Header {
		if len(values) > 0 {
			// Set-Cookie 多值拼接：扩展侧以逗号/分号边界解析 Cookie。
			headers[key] = strings.Join(values, ", ")
		}
	}
	// 二进制协议（黄豆）读 bodyBase64；文本源继续用 body。
	return &ext.Response{
		Status:     response.StatusCode,
		Headers:    headers,
		Body:       string(raw),
		BodyBase64: base64.StdEncoding.EncodeToString(raw),
	}, nil
}

func (h *extensionHost) Log(source, message string) {
	if h.d.diagnostics != nil {
		_ = h.d.diagnostics.write(diagnosticEvent{
			Level:   "info",
			Event:   "extension_log",
			Source:  source,
			Message: message,
		})
	}
}

func (h *extensionHost) StorageLoad(source string) (map[string]string, error) {
	return loadExtensionStorage(h.d.cfg.dataDir, source)
}

func (h *extensionHost) StorageSave(source string, values map[string]string) error {
	return saveExtensionStorage(h.d.cfg.dataDir, source, values)
}

// extensionStore 管理已安装扩展：磁盘布局与运行时缓存。
type extensionStore struct {
	d        *Downloader
	mu       sync.Mutex
	registry *ext.Registry
	loaded   map[string]*ext.Extension
	records  map[string]ext.Installed
}

func extensionRoot(dataDir string) string { return filepath.Join(dataDir, "extensions") }

func loadExtensionStorage(dataDir, source string) (map[string]string, error) {
	raw, err := os.ReadFile(filepath.Join(extensionRoot(dataDir), source, "storage.json"))
	if errors.Is(err, os.ErrNotExist) {
		return map[string]string{}, nil
	}
	if err != nil {
		return nil, errors.New("扩展存储无法读取")
	}
	if len(raw) > 1<<20 {
		return nil, errors.New("扩展存储超过 1 MiB 上限")
	}
	values := map[string]string{}
	if err := json.Unmarshal(raw, &values); err != nil {
		return nil, errors.New("扩展存储损坏")
	}
	return values, nil
}

func saveExtensionStorage(dataDir, source string, values map[string]string) error {
	if !validExtensionSourceID(source) {
		return errors.New("扩展 ID 无效")
	}
	if len(values) > 256 {
		return errors.New("扩展存储键数超过上限")
	}
	total := 0
	for key, value := range values {
		total += len(key) + len(value)
	}
	if total > 900<<10 {
		return errors.New("扩展存储超过 1 MiB 上限")
	}
	directory := filepath.Join(extensionRoot(dataDir), source)
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	raw, err := json.Marshal(values)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(directory, "storage.json"), raw, 0600)
}

// validExtensionSourceID 校验扩展包 ID（同时是目录名与注册表键）：
// 只允许 2–32 位小写字母、数字与连字符。
func validExtensionSourceID(id string) bool {
	if len(id) < 2 || len(id) > 32 {
		return false
	}
	for _, r := range id {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '-':
		default:
			return false
		}
	}
	return !strings.HasPrefix(id, "-") && !strings.HasSuffix(id, "-")
}

// validExtensionItemID 校验扩展返回的剧集/章节 ID。
// 这类 ID 由站源自定义，形态远比包 ID 宽松：黄果视频用 "series/123"，
// 帝果用 "456:1-2"（剧集+线路+集数），黄豆用递增序号。
// 因此只做安全性约束（长度、字符集、无路径与控制字符），不做格式假设。
func validExtensionItemID(id string) bool {
	if id == "" || len(id) > 200 {
		return false
	}
	for _, r := range id {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		case r == ':' || r == '-' || r == '_' || r == '.' || r == '/':
		default:
			return false
		}
	}
	// 拒绝路径穿越片段：ID 会出现在日志与缓存键中。
	if strings.Contains(id, "..") || strings.HasPrefix(id, "/") || strings.HasSuffix(id, "/") {
		return false
	}
	return true
}

// newExtensionStore 加载磁盘上的已装清单并准备运行时注册表。
func newExtensionStore(d *Downloader) *extensionStore {
	store := &extensionStore{d: d, registry: ext.NewRegistry(&extensionHost{d: d}), loaded: map[string]*ext.Extension{}, records: map[string]ext.Installed{}}
	store.reload()
	return store
}

func (s *extensionStore) reload() {
	s.mu.Lock()
	defer s.mu.Unlock()
	raw, err := os.ReadFile(filepath.Join(extensionRoot(s.d.cfg.dataDir), "index.json"))
	if err != nil {
		return
	}
	var records map[string]ext.Installed
	if json.Unmarshal(raw, &records) != nil || len(records) > 64 {
		return
	}
	s.records = records
}

func (s *extensionStore) saveLocked() {
	raw, err := json.Marshal(s.records)
	if err != nil {
		return
	}
	directory := extensionRoot(s.d.cfg.dataDir)
	if err := os.MkdirAll(directory, 0700); err != nil {
		return
	}
	_ = os.WriteFile(filepath.Join(directory, "index.json"), raw, 0600)
}

// Installed 报告扩展是否已安装。
func (s *extensionStore) Installed(source string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.records[source]
	return ok
}

// Sources 返回已安装扩展的 ID 列表。
func (s *extensionStore) Sources() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	names := make([]string, 0, len(s.records))
	for name := range s.records {
		names = append(names, name)
	}
	return names
}

// Manifest 返回扩展元数据；未安装时返回 nil。
func (s *extensionStore) Manifest(source string) *ext.Installed {
	s.mu.Lock()
	defer s.mu.Unlock()
	if record, ok := s.records[source]; ok {
		return &record
	}
	return nil
}

func (s *extensionStore) runtime(source string) (*ext.Extension, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if runtime, ok := s.loaded[source]; ok {
		return runtime, nil
	}
	record, ok := s.records[source]
	if !ok {
		return nil, errors.New("扩展尚未安装")
	}
	directory := filepath.Join(extensionRoot(s.d.cfg.dataDir), source)
	code, err := os.ReadFile(filepath.Join(directory, extensionSourceFile))
	if err != nil {
		return nil, errors.New("扩展脚本无法读取，请重新安装")
	}
	loaded, err := ext.NewExtension(record.Manifest, string(code), s.registry)
	if err != nil {
		delete(s.records, source)
		s.saveLocked()
		return nil, fmt.Errorf("扩展加载失败: %w", err)
	}
	s.loaded[source] = loaded
	return loaded, nil
}

// InstallScript 解析脚本头部并落盘。
// expectedSource 非空时要求头部 ID 与之一致，防止索引与脚本错配。
func (s *extensionStore) InstallScript(code []byte, expectedSource string) (ext.Manifest, error) {
	if len(code) > ext.MaxSourceBytes {
		return ext.Manifest{}, errors.New("扩展脚本超过 512 KiB 上限")
	}
	manifest, err := ext.ParseScript(string(code))
	if err != nil {
		return ext.Manifest{}, err
	}
	expected := strings.TrimSpace(expectedSource)
	if expected != "" && canonicalProviderSource(expected) != manifest.ID {
		return ext.Manifest{}, errors.New("扩展脚本 ID 与安装请求不符")
	}
	directory := filepath.Join(extensionRoot(s.d.cfg.dataDir), manifest.ID)
	if err := os.MkdirAll(directory, 0700); err != nil {
		return ext.Manifest{}, errors.New("扩展目录无法创建")
	}
	if err := os.WriteFile(filepath.Join(directory, extensionSourceFile), code, 0600); err != nil {
		return ext.Manifest{}, err
	}
	// 旧版安装会留下 manifest.json；统一格式后清掉，避免两套元数据并存。
	_ = os.Remove(filepath.Join(directory, "manifest.json"))
	s.mu.Lock()
	s.records[manifest.ID] = ext.Installed{Manifest: manifest, InstalledAt: time.Now().Unix()}
	delete(s.loaded, manifest.ID)
	s.saveLocked()
	s.mu.Unlock()
	// 立即注册到分派 registry，让新扩展无需重启即可使用。
	registerExtensionProvider(s.d, manifest.ID)
	return manifest, nil
}

// Uninstall 移除扩展目录与记录。
func (s *extensionStore) Uninstall(source string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.records[source]; !ok {
		return errors.New("扩展尚未安装")
	}
	delete(s.records, source)
	delete(s.loaded, source)
	s.saveLocked()
	return os.RemoveAll(filepath.Join(extensionRoot(s.d.cfg.dataDir), source))
}

// extensionIndexURL 是官方扩展仓库的索引地址；
// 发布时可通过构建参数覆盖为镜像地址。
var extensionIndexURL = "https://raw.githubusercontent.com/hongguojian/hongguojian-extensions/main/index.json"

// RemoteIndex 拉取官方扩展索引；成功后缓存到磁盘供离线回退。
func (s *extensionStore) RemoteIndex(ctx context.Context) (any, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, extensionIndexURL, nil)
	if err != nil {
		return nil, err
	}
	response, err := s.d.client.Do(request)
	if err != nil {
		if cached := s.LocalIndex(); len(cached["entries"].([]any)) > 0 {
			return cached, nil
		}
		return nil, fmt.Errorf("扩展索引获取失败: %w", err)
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	entries, err := ext.ParseIndex(raw)
	if err != nil {
		return nil, err
	}
	directory := extensionRoot(s.d.cfg.dataDir)
	if err := os.MkdirAll(directory, 0700); err == nil {
		_ = os.WriteFile(filepath.Join(directory, "remote-index.json"), raw, 0600)
	}
	return map[string]any{"entries": s.indexEntries(entries)}, nil
}

// LocalIndex 返回磁盘缓存的远程索引；无缓存时返回空。
func (s *extensionStore) LocalIndex() map[string]any {
	raw, err := os.ReadFile(filepath.Join(extensionRoot(s.d.cfg.dataDir), "remote-index.json"))
	if err != nil {
		return map[string]any{"entries": []any{}}
	}
	entries, err := ext.ParseIndex(raw)
	if err != nil {
		return map[string]any{"entries": []any{}}
	}
	return map[string]any{"entries": s.indexEntries(entries)}
}

// indexEntries 把官方索引转成 Dart 可消费的列表，附带本机安装状态。
// 已安装时以本地清单为准：界面元数据（分组、搜索能力）随包升级而变化，
// 远程索引只负责发现与版本比较。
func (s *extensionStore) indexEntries(entries []ext.IndexEntry) []any {
	rows := make([]any, 0, len(entries))
	for _, entry := range entries {
		installed := s.Manifest(entry.ID)
		manifest := entry.Manifest
		if installed != nil {
			manifest = installed.Manifest
		}
		rows = append(rows, map[string]any{
			"id":        entry.ID,
			"name":      manifest.Name,
			"version":   entry.Version,
			"changelog": entry.Changelog,
			"url":       entry.URL,
			"sha256":    entry.SHA256,
			// killSwitch 来自远程索引：远程下架优先于本地安装状态。
			"killSwitch":       entry.KillSwitch,
			"restricted":       manifest.Restricted,
			"description":      manifest.Description,
			"group":            manifest.Group,
			"groupName":        manifest.GroupName,
			"entryName":        manifest.EntryName,
			"onlineSearch":     manifest.OnlineSearch,
			"pagedSearch":      manifest.PagedSearch,
			"suggestions":      manifest.Suggestions,
			"installed":        installed != nil,
			"installedAt":      installedAt(installed),
			"installedVersion": installedVersion(installed),
			"updateAvailable":  installed != nil && installed.Version != entry.Version,
		})
	}
	return rows
}

// installedExtensions 返回本机已装扩展的完整清单。
// 应用启动后据其构建站源列表（列表不能只依赖进入站源管理页时才拉取的索引）。
func (s *extensionStore) installedExtensions() []any {
	s.mu.Lock()
	records := make([]ext.Installed, 0, len(s.records))
	for _, record := range s.records {
		records = append(records, record)
	}
	s.mu.Unlock()
	rows := make([]any, 0, len(records))
	for _, record := range records {
		rows = append(rows, map[string]any{
			"id":           record.ID,
			"name":         record.Name,
			"version":      record.Version,
			"restricted":   record.Restricted,
			"description":  record.Description,
			"group":        record.Group,
			"groupName":    record.GroupName,
			"entryName":    record.EntryName,
			"onlineSearch": record.OnlineSearch,
			"pagedSearch":  record.PagedSearch,
			"suggestions":  record.Suggestions,
			"installed":    true,
			"installedAt":  record.InstalledAt,
		})
	}
	return rows
}

func installedAt(installed *ext.Installed) int64 {
	if installed == nil {
		return 0
	}
	return installed.InstalledAt
}

func installedVersion(installed *ext.Installed) string {
	if installed == nil {
		return ""
	}
	return installed.Version
}
