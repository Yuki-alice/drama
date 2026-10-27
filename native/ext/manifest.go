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
	// VIP 声明该源会返回 VIP 标记：界面据此显示 VIP 筛选与详情状态。
	// 不声明时宿主不会按 VIP 过滤，也不会提示"VIP 状态待补齐"。
	VIP bool `json:"vip,omitempty"`
	// Danmaku 声明该源支持弹幕：播放器据此显示弹幕开关并允许请求弹幕。
	Danmaku bool `json:"danmaku,omitempty"`
	// DetailFields 列出目录里可能缺失、需要拉详情补齐的字段
	// （vip / heat / views / onlineDate / description / tags）。
	// 取代宿主里按源 ID 硬编码的补齐规则。
	DetailFields []string `json:"detailFields,omitempty"`
	// Settings 声明该源的可配置项。宿主据此渲染通用表单，
	// 值存进该源的 hg.storage，扩展用 hg.storage.get(key) 读取。
	// 「镜像地址」（baseURL）是所有扩展都有的内置项，不必声明。
	Settings []Setting `json:"settings,omitempty"`
}

// Setting 是扩展声明的一项可配置设置。
type Setting struct {
	Key         string `json:"key"`
	Title       string `json:"title"`
	Description string `json:"description,omitempty"`
	// Type 决定控件：input（文本）/ toggle（开关）/ choice（单选）。
	Type string `json:"type"`
	// Default 是未设置时的取值。
	Default string `json:"default,omitempty"`
	// Placeholder 仅对 input 有意义。
	Placeholder string `json:"placeholder,omitempty"`
	// Options 仅对 choice 有意义，形如 "a=选项A|b=选项B"。
	Options []SettingOption `json:"options,omitempty"`
}

// SettingOption 是 choice 型设置的一个选项。
type SettingOption struct {
	Value string `json:"value"`
	Label string `json:"label"`
}

// settingTypes 是允许的控件类型。
var settingTypes = map[string]bool{"input": true, "toggle": true, "choice": true}

// BuiltinSettingBaseURL 是宿主为每个扩展提供的内置设置（镜像地址）。
// 扩展不能重复声明；core 侧保存时也用它作为键名。
const BuiltinSettingBaseURL = "baseURL"

// maxSettings 限制每源设置数量，避免表单无限长。
const maxSettings = 6

// detailFieldValues 是 DetailFields 允许的取值（统一小写，扩展可写任意大小写）。
var detailFieldValues = map[string]bool{
	"vip": true, "heat": true, "views": true, "onlinedate": true,
	"description": true, "tags": true, "releasestatus": true,
}

// maxDetailFields 限制补齐字段数量，避免扩展声明一长串导致每次都要拉详情。
const maxDetailFields = 6

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
		VIP:          parseHeaderBool(fields["vip"]),
		Danmaku:      parseHeaderBool(fields["danmaku"]),
		DetailFields: parseDetailFields(fields["detailfields"]),
	}
	if settings, settingsErr := parseSettings(fields["settings"]); settingsErr != nil {
		return Manifest{}, settingsErr
	} else {
		manifest.Settings = settings
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
	if len(manifest.DetailFields) > maxDetailFields {
		return fmt.Errorf("扩展补齐字段不能超过 %d 个", maxDetailFields)
	}
	seen := map[string]bool{}
	for _, field := range manifest.DetailFields {
		if !detailFieldValues[field] {
			return fmt.Errorf("扩展补齐字段 %q 无效", field)
		}
		if seen[field] {
			return fmt.Errorf("扩展补齐字段 %q 重复", field)
		}
		seen[field] = true
	}
	return nil
}

// parseDetailFields 解析逗号分隔的补齐字段列表，大小写与空格不敏感。
func parseDetailFields(raw string) []string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	fields := make([]string, 0, len(parts))
	for _, part := range parts {
		field := strings.ToLower(strings.TrimSpace(part))
		if field != "" {
			fields = append(fields, field)
		}
	}
	return fields
}

// parseSettings 解析 @settings 声明。
//
// 语法（多项用 ; 分隔，每项用 | 分隔字段）：
//
//	// @settings useProxy|使用代理|toggle|false
//	// @settings quality|画质偏好|choice|auto|auto=自动|1080=1080P
//
// 字段顺序：key|title|type|default|其余。
//   - input / toggle：第 5 段是 placeholder。
//   - choice：第 5 段起全部是选项（value=label），没有 placeholder——
//     否则 "24|24=24 条|..." 会把第一个选项当成 placeholder 吃掉。
//
// 用紧凑语法而不是 JSON：文件头是注释，写 JSON 会很难维护。
func parseSettings(raw string) ([]Setting, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	declarations := []string{}
	for _, line := range strings.Split(raw, ";") {
		if line = strings.TrimSpace(line); line != "" {
			declarations = append(declarations, line)
		}
	}
	if len(declarations) > maxSettings {
		return nil, fmt.Errorf("扩展设置项不能超过 %d 个", maxSettings)
	}
	settings := make([]Setting, 0, len(declarations))
	seen := map[string]bool{}
	for _, declaration := range declarations {
		parts := strings.Split(declaration, "|")
		if len(parts) < 3 {
			return nil, fmt.Errorf("扩展设置 %q 需要至少 key|title|type", declaration)
		}
		setting := Setting{
			Key:   strings.TrimSpace(parts[0]),
			Title: strings.TrimSpace(parts[1]),
			Type:  strings.ToLower(strings.TrimSpace(parts[2])),
		}
		if len(parts) > 3 {
			setting.Default = strings.TrimSpace(parts[3])
		}
		rest := parts[min(4, len(parts)):]
		if setting.Type == "choice" {
			for _, option := range rest {
				option = strings.TrimSpace(option)
				if option == "" {
					continue
				}
				value, label, found := strings.Cut(option, "=")
				if !found {
					return nil, fmt.Errorf("扩展设置选项 %q 需要 value=label", option)
				}
				setting.Options = append(setting.Options, SettingOption{
					Value: strings.TrimSpace(value),
					Label: strings.TrimSpace(label),
				})
			}
		} else if len(rest) > 0 {
			setting.Placeholder = strings.TrimSpace(rest[0])
		}
		if err := validateSetting(setting); err != nil {
			return nil, err
		}
		if seen[setting.Key] {
			return nil, fmt.Errorf("扩展设置 %q 重复", setting.Key)
		}
		seen[setting.Key] = true
		settings = append(settings, setting)
	}
	return settings, nil
}

// validateSetting 校验单项设置的字段。
func validateSetting(setting Setting) error {
	key := strings.TrimSpace(setting.Key)
	if key == "" || len(key) > 32 {
		return errors.New("扩展设置 key 需为 1–32 个字符")
	}
	for _, r := range key {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9',
			r == '-', r == '_', r == '.':
		default:
			return fmt.Errorf("扩展设置 key %q 只能包含字母、数字、- _ .", key)
		}
	}
	if key == BuiltinSettingBaseURL {
		return fmt.Errorf("扩展设置 %q 是宿主内置项，不能重复声明", key)
	}
	if title := strings.TrimSpace(setting.Title); title == "" || len([]rune(title)) > 24 {
		return errors.New("扩展设置标题需为 1–24 个字")
	}
	if description := strings.TrimSpace(setting.Description); len([]rune(description)) > 80 {
		return errors.New("扩展设置描述不能超过 80 个字")
	}
	if !settingTypes[setting.Type] {
		return fmt.Errorf("扩展设置 %q 类型无效（input / toggle / choice）", key)
	}
	if setting.Type == "choice" {
		if len(setting.Options) < 2 || len(setting.Options) > 12 {
			return fmt.Errorf("扩展设置 %q 需要 2–12 个选项", key)
		}
		for _, option := range setting.Options {
			if option.Value == "" || option.Label == "" {
				return fmt.Errorf("扩展设置 %q 的选项不能为空", key)
			}
		}
	} else if len(setting.Options) > 0 {
		return fmt.Errorf("扩展设置 %q 只有 choice 类型可以带选项", key)
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
