// Package ext 承载扩展站源：JS 编写、goja 解释执行、宿主注入网络与存储能力。
//
// 扩展是单个 .js 文件，文件头注释声明元数据；官方仓库只分发 JS 与索引，
// 不再使用 zip/manifest.json/签名包。
package ext

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// CurrentAPILevel 是当前宿主支持的扩展 API 版本；
// 文件头的 apiLevel 高于宿主时拒绝安装，低时按声明的级别加载。
const CurrentAPILevel = 1

// MaxSourceBytes 是单个扩展脚本的大小上限。
const MaxSourceBytes = 512 << 10

const (
	scriptHeaderStart = "==HongguoExtension=="
	scriptHeaderEnd   = "==/HongguoExtension=="
)

// Manifest 是扩展脚本头部的元数据。
//
// 除身份与版本外，元数据还决定站源列表、分组与搜索入口，
// 宿主不再为每个站源维护编译期常量。
type Manifest struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Version  string `json:"version"`
	APILevel int    `json:"apiLevel"`
	// Restricted 表示敏感站源：默认关闭，需用户在站源管理中开启。
	Restricted bool `json:"restricted"`
	// Description 是站源管理页的副标题。
	Description string `json:"description,omitempty"`
	// Group 把多个入口并入同一分组（如黄果系共用「黄果」）。
	Group string `json:"group,omitempty"`
	// GroupName 是分组显示名；Group 非空且未填时回退到 Name。
	GroupName string `json:"groupName,omitempty"`
	// EntryName 是分组内的短名（如「视频」「AI」「旧版」）。
	EntryName string `json:"entryName,omitempty"`
	// OnlineSearch / PagedSearch / Suggestions 声明搜索能力，
	// 决定界面是否显示搜索框、是否支持翻页与联想。
	OnlineSearch bool   `json:"onlineSearch,omitempty"`
	PagedSearch  bool   `json:"pagedSearch,omitempty"`
	Suggestions  bool   `json:"suggestions,omitempty"`
	MinApp       string `json:"minApp,omitempty"`
}

// ParseScript 从扩展脚本的文件头注释中解析并校验元数据。
//
// 头部格式：
//
//	// ==HongguoExtension==
//	// @id example
//	// @name 示例源
//	// @version 1.0.0
//	// @apiLevel 1
//	// ==/HongguoExtension==
func ParseScript(code string) (Manifest, error) {
	if len(code) > MaxSourceBytes {
		return Manifest{}, errors.New("扩展脚本超过 512 KiB 上限")
	}
	fields, err := scriptHeaderFields(code)
	if err != nil {
		return Manifest{}, err
	}
	manifest := Manifest{
		ID:           strings.TrimSpace(fields["id"]),
		Name:         strings.TrimSpace(fields["name"]),
		Version:      strings.TrimSpace(fields["version"]),
		APILevel:     CurrentAPILevel,
		Restricted:   false,
		Description:  strings.TrimSpace(fields["description"]),
		Group:        strings.TrimSpace(fields["group"]),
		GroupName:    strings.TrimSpace(fields["groupname"]),
		EntryName:    strings.TrimSpace(fields["entryname"]),
		OnlineSearch: parseHeaderBool(fields["onlinesearch"]),
		PagedSearch:  parseHeaderBool(fields["pagedsearch"]),
		Suggestions:  parseHeaderBool(fields["suggestions"]),
		MinApp:       strings.TrimSpace(fields["minapp"]),
	}
	if raw := strings.TrimSpace(fields["restricted"]); raw != "" {
		value, err := parseHeaderBoolStrict(raw)
		if err != nil {
			return Manifest{}, errors.New("扩展 restricted 需为 true 或 false")
		}
		manifest.Restricted = value
	}
	if raw := strings.TrimSpace(fields["apilevel"]); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil {
			return Manifest{}, errors.New("扩展 apiLevel 无效")
		}
		manifest.APILevel = value
	}
	if err := manifest.Validate(); err != nil {
		return Manifest{}, err
	}
	return manifest, nil
}

// Validate 校验元数据，供脚本安装与索引解析共用。
func (manifest Manifest) Validate() error {
	if !validSourceID(manifest.ID) {
		return errors.New("扩展 ID 无效（需 2–32 位小写字母、数字或连字符）")
	}
	if name := strings.TrimSpace(manifest.Name); name == "" || len([]rune(name)) > 24 {
		return errors.New("扩展名称需为 1–24 个字")
	}
	if description := strings.TrimSpace(manifest.Description); len([]rune(description)) > 48 {
		return errors.New("扩展描述不能超过 48 个字")
	}
	for _, field := range []struct {
		label string
		value string
		limit int
	}{
		{"分组", manifest.Group, 32},
		{"分组名", manifest.GroupName, 24},
		{"入口名", manifest.EntryName, 16},
	} {
		if value := strings.TrimSpace(field.value); len([]rune(value)) > field.limit {
			return fmt.Errorf("扩展%s不能超过 %d 个字", field.label, field.limit)
		}
	}
	if manifest.GroupName != "" && manifest.Group == "" {
		return errors.New("扩展分组名需要同时声明分组 ID")
	}
	if !validVersion(manifest.Version) {
		return errors.New("扩展版本号无效")
	}
	if manifest.APILevel <= 0 || manifest.APILevel > CurrentAPILevel {
		return fmt.Errorf("扩展 API 级别 %d 超出宿主支持范围（1–%d）", manifest.APILevel, CurrentAPILevel)
	}
	return nil
}

func scriptHeaderFields(code string) (map[string]string, error) {
	start := strings.Index(code, scriptHeaderStart)
	if start < 0 {
		return nil, errors.New("扩展缺少 ==HongguoExtension== 头部")
	}
	rest := code[start+len(scriptHeaderStart):]
	end := strings.Index(rest, scriptHeaderEnd)
	if end < 0 {
		return nil, errors.New("扩展头部缺少 ==/HongguoExtension== 结束标记")
	}
	fields := map[string]string{}
	for _, line := range strings.Split(rest[:end], "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "//") {
			continue
		}
		line = strings.TrimSpace(strings.TrimPrefix(line, "//"))
		if !strings.HasPrefix(line, "@") {
			continue
		}
		key, value, _ := strings.Cut(strings.TrimPrefix(line, "@"), " ")
		key = strings.ToLower(strings.TrimSpace(key))
		if key == "" {
			continue
		}
		fields[key] = strings.TrimSpace(value)
	}
	if len(fields) == 0 {
		return nil, errors.New("扩展头部没有声明任何元数据")
	}
	return fields, nil
}

func parseHeaderBool(value string) bool {
	parsed, _ := parseHeaderBoolStrict(value)
	return parsed
}

func parseHeaderBoolStrict(value string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "false", "0", "no":
		return false, nil
	case "true", "1", "yes":
		return true, nil
	default:
		return false, errors.New("invalid boolean")
	}
}

func validSourceID(id string) bool {
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

func validVersion(version string) bool {
	if len(version) == 0 || len(version) > 32 {
		return false
	}
	for _, r := range version {
		switch {
		case r >= '0' && r <= '9', r == '.', r == '-', r == '+', r >= 'a' && r <= 'z':
		default:
			return false
		}
	}
	return true
}
