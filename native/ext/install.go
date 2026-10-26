package ext

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// Installed 是磁盘上已安装扩展的记录。
type Installed struct {
	Manifest
	InstalledAt int64 `json:"installedAt"`
}

// IndexEntry 是官方仓库 index.json 的一项。
// 元数据与脚本头部一致，索引只额外携带下载地址、摘要与更新说明。
type IndexEntry struct {
	Manifest
	URL        string `json:"url"`
	SHA256     string `json:"sha256,omitempty"`
	Changelog  string `json:"changelog,omitempty"`
	KillSwitch bool   `json:"killSwitch,omitempty"`
}

// ParseIndex 解析官方仓库 index.json（JSON 数组）。
func ParseIndex(data []byte) ([]IndexEntry, error) {
	var entries []IndexEntry
	if err := json.Unmarshal(data, &entries); err != nil {
		return nil, fmt.Errorf("扩展索引无法解析: %w", err)
	}
	if len(entries) > 128 {
		return nil, errors.New("扩展索引条目过多")
	}
	seen := map[string]bool{}
	for index := range entries {
		entry := &entries[index]
		if err := entry.Manifest.Validate(); err != nil {
			return nil, fmt.Errorf("扩展索引第 %d 项无效: %w", index+1, err)
		}
		if strings.TrimSpace(entry.URL) == "" {
			return nil, fmt.Errorf("扩展索引第 %d 项缺少下载地址", index+1)
		}
		if digest := strings.TrimSpace(entry.SHA256); digest != "" && !validSHA256(digest) {
			return nil, fmt.Errorf("扩展索引第 %d 项摘要无效", index+1)
		}
		if seen[entry.ID] {
			return nil, fmt.Errorf("扩展索引包含重复 ID: %s", entry.ID)
		}
		seen[entry.ID] = true
	}
	return entries, nil
}

func validSHA256(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, r := range value {
		switch {
		case r >= '0' && r <= '9', r >= 'a' && r <= 'f', r >= 'A' && r <= 'F':
		default:
			return false
		}
	}
	return true
}
