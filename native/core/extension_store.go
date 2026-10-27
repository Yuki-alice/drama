package core

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
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
	// 端到端/parity 测试用 httptest（127.0.0.1）作合成站点；测试引擎通过
	// allowLocalExtensionHost 显式打开豁免，生产引擎永远为 false。
	if !h.d.allowLocalExtensionHost {
		if err := validateExtensionAddress(parsed); err != nil {
			return nil, err
		}
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
	response, err := h.client().Do(httpRequest)
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

// validateExtensionAddress 拒绝指向本机或私网的扩展请求。
//
// 扩展不签名，安装即获得宿主网络栈；不设边界的话，一个扩展就能探测
// 本机端口（如 127.0.0.1 的播放流服务器）或内网服务。CDN 路径已有同类
// 校验（validateCDNAddresses），这里对 IP 字面量做同样判定；域名解析结果
// 由 DNS 解析器在连接阶段复核。
func validateExtensionAddress(parsed *url.URL) error {
	host := strings.Trim(parsed.Hostname(), "[]")
	if host == "" {
		return errors.New("扩展请求的地址无效")
	}
	if strings.EqualFold(host, "localhost") || strings.HasSuffix(strings.ToLower(host), ".localhost") {
		return errors.New("扩展不能访问本机地址")
	}
	if ip := net.ParseIP(host); ip != nil {
		if address, ok := netip.AddrFromSlice(ip); ok {
			address = address.Unmap()
			if address.IsLoopback() || address.IsPrivate() || address.IsLinkLocalUnicast() || address.IsLinkLocalMulticast() || address.IsUnspecified() {
				return errors.New("扩展不能访问本机或内网地址")
			}
		}
	}
	return nil
}

// extensionClient 返回扩展专用客户端：共享宿主网络栈，但每次重定向都重新
// 校验目标地址。只校验初始 URL 会被 302 到 127.0.0.1 绕过。
func (h *extensionHost) client() *http.Client {
	return &http.Client{
		Transport: h.d.client.Transport,
		Timeout:   h.d.client.Timeout,
		CheckRedirect: func(request *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return errors.New("扩展请求重定向次数过多")
			}
			if err := validateExtensionAddress(request.URL); err != nil {
				return err
			}
			return nil
		},
	}
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
	values, _, err := h.d.extensions.storageValues(source)
	return values, err
}

func (h *extensionHost) StorageSave(source string, values map[string]string) error {
	return h.d.extensions.saveStorage(source, values)
}

// extensionStore 管理已安装扩展：磁盘布局与运行时缓存。
type extensionStore struct {
	d        *Downloader
	mu       sync.Mutex
	registry *ext.Registry
	loaded   map[string]*ext.Extension
	records  map[string]ext.Installed
	// storage 是每源 KV 的进程内副本。扩展在热路径上频繁读写
	// （hg.storage.get 每次请求都会触发，黄豆每个成功响应还会写一次 host），
	// 每次都落盘会让目录请求变成多次文件 I/O。加载一次后常驻，写入时才落盘。
	storage map[string]map[string]string
}

func extensionRoot(dataDir string) string { return filepath.Join(dataDir, "extensions") }

// storageValues 返回某源的 KV 副本与是否命中缓存。
func (s *extensionStore) storageValues(source string) (map[string]string, bool, error) {
	s.mu.Lock()
	if values, ok := s.storage[source]; ok {
		copied := make(map[string]string, len(values))
		for key, value := range values {
			copied[key] = value
		}
		s.mu.Unlock()
		return copied, true, nil
	}
	s.mu.Unlock()
	values, err := loadExtensionStorage(s.d.cfg.dataDir, source)
	if err != nil {
		return nil, false, err
	}
	s.mu.Lock()
	s.storage[source] = values
	copied := make(map[string]string, len(values))
	for key, value := range values {
		copied[key] = value
	}
	s.mu.Unlock()
	return copied, false, nil
}

// saveStorage 落盘并更新内存副本；值未变化时不重复写盘。
func (s *extensionStore) saveStorage(source string, values map[string]string) error {
	s.mu.Lock()
	previous, known := s.storage[source]
	s.mu.Unlock()
	if known && equalStorageValues(previous, values) {
		return nil
	}
	if err := saveExtensionStorage(s.d.cfg.dataDir, source, values); err != nil {
		return err
	}
	s.mu.Lock()
	copied := make(map[string]string, len(values))
	for key, value := range values {
		copied[key] = value
	}
	s.storage[source] = copied
	s.mu.Unlock()
	return nil
}

func equalStorageValues(first, second map[string]string) bool {
	if len(first) != len(second) {
		return false
	}
	for key, value := range first {
		if other, ok := second[key]; !ok || other != value {
			return false
		}
	}
	return true
}

// forgetStorage 在卸载时清掉内存副本，避免重新安装后读到旧数据。
func (s *extensionStore) forgetStorage(source string) {
	s.mu.Lock()
	delete(s.storage, source)
	s.mu.Unlock()
}

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
	store := &extensionStore{d: d, registry: ext.NewRegistry(&extensionHost{d: d}), loaded: map[string]*ext.Extension{}, records: map[string]ext.Installed{}, storage: map[string]map[string]string{}}
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
	delete(s.storage, source)
	s.saveLocked()
	return os.RemoveAll(filepath.Join(extensionRoot(s.d.cfg.dataDir), source))
}

// extensionIndexURL 是官方扩展仓库的索引地址。
//
// 发布时用 `-ldflags "-X duanjuapp/native/core.extensionIndexURL=<真实地址>"`
// 覆盖，不需要改代码（scripts/build_native.py 与 build_ios.py 已透传该参数）。
// 保留占位的默认值而不是留空：空值会让错误信息变得难以诊断。
var extensionIndexURL = "https://raw.githubusercontent.com/hongguojian/hongguojian-extensions/main/index.json"

// extensionIndexPlaceholder 标记"还没换成真实地址"的默认值。
// 命中时 RemoteIndex 直接返回空列表而不发网络请求——占位域名不可达，
// 每次进站源页都等一次超时是纯损失。
const extensionIndexPlaceholder = "https://raw.githubusercontent.com/hongguojian/hongguojian-extensions/main/index.json"

// RemoteIndex 拉取官方扩展索引；成功后缓存到磁盘供离线回退。
func (s *extensionStore) RemoteIndex(ctx context.Context) (any, error) {
	if strings.TrimSpace(extensionIndexURL) == extensionIndexPlaceholder {
		// 尚未配置真实仓库：只用随包扩展，不报错也不请求。
		return map[string]any{"entries": []any{}, "unconfigured": true}, nil
	}
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
			"vip":              manifest.VIP,
			"danmaku":          manifest.Danmaku,
			"detailFields":     append([]string{}, manifest.DetailFields...),
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
			"vip":          record.VIP,
			"danmaku":      record.Danmaku,
			"detailFields": append([]string{}, record.DetailFields...),
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
