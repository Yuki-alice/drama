package core

import (
	"errors"
	"net/url"
	"strings"

	"duanjuapp/native/ext"
)

// 每源设置：宿主为每个扩展提供一项内置的「镜像地址」（hgkit 的
// source.base() 读取的 hg.storage['baseURL']），其余设置项由扩展在
// 文件头用 @settings 声明，宿主只负责渲染与存储。
//
// 这样加一项设置不需要改客户端：扩展声明 → 站源页出现对应控件 →
// 值写进 hg.storage，扩展自己读取。

// sourceSettingBaseURL 沿用 ext 包的内置键名，避免两处常量漂移。
const sourceSettingBaseURL = ext.BuiltinSettingBaseURL

// sourceSettings 返回某源在界面上可编辑的设置项（内置项 + 清单声明项）。
func (engine *nativeEngine) sourceSettings(source string) (any, error) {
	source = canonicalProviderSource(source)
	if !validExtensionSourceID(source) {
		return nil, errors.New("扩展 ID 无效")
	}
	if engine.downloader.extensions == nil {
		return nil, errors.New("扩展系统未就绪")
	}
	installed := engine.downloader.extensions.Manifest(source)
	if installed == nil {
		return nil, errors.New("扩展尚未安装")
	}
	values, _, err := engine.downloader.extensions.storageValues(source)
	if err != nil {
		return nil, err
	}
	rows := []any{
		map[string]any{
			"key":         sourceSettingBaseURL,
			"title":       "镜像地址",
			"description": "站点主域名不可访问时填一个同内容的备用地址，留空使用内置默认值。",
			"type":        "input",
			"placeholder": "https://example.com",
			"value":       values[sourceSettingBaseURL],
		},
	}
	for _, setting := range installed.Settings {
		value, found := values[setting.Key]
		if !found {
			value = setting.Default
		}
		row := map[string]any{
			"key":     setting.Key,
			"title":   setting.Title,
			"type":    setting.Type,
			"value":   value,
			"default": setting.Default,
		}
		if setting.Description != "" {
			row["description"] = setting.Description
		}
		if setting.Placeholder != "" {
			row["placeholder"] = setting.Placeholder
		}
		if len(setting.Options) > 0 {
			options := make([]any, 0, len(setting.Options))
			for _, option := range setting.Options {
				options = append(options, map[string]any{
					"value": option.Value,
					"label": option.Label,
				})
			}
			row["options"] = options
		}
		rows = append(rows, row)
	}
	return map[string]any{"source": source, "settings": rows}, nil
}

// saveSourceSetting 写入单项设置；空值表示删除（回落到扩展默认）。
func (engine *nativeEngine) saveSourceSetting(source, key, value string) (any, error) {
	source = canonicalProviderSource(source)
	if !validExtensionSourceID(source) {
		return nil, errors.New("扩展 ID 无效")
	}
	if engine.downloader.extensions == nil {
		return nil, errors.New("扩展系统未就绪")
	}
	installed := engine.downloader.extensions.Manifest(source)
	if installed == nil {
		return nil, errors.New("扩展尚未安装")
	}
	key = strings.TrimSpace(key)
	if key == "" {
		return nil, errors.New("设置项无效")
	}

	// 内置项：镜像地址需要额外校验，其余按声明类型校验。
	if key == sourceSettingBaseURL {
		trimmed := strings.TrimRight(strings.TrimSpace(value), "/")
		if trimmed != "" {
			parsed, err := url.Parse(trimmed)
			if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
				return nil, errors.New("镜像地址必须是 http(s) 网址")
			}
			if err := validateExtensionAddress(parsed); err != nil {
				return nil, err
			}
		}
		return engine.writeSourceSetting(source, key, trimmed)
	}

	var declared *ext.Setting
	for index := range installed.Settings {
		if installed.Settings[index].Key == key {
			declared = &installed.Settings[index]
			break
		}
	}
	if declared == nil {
		return nil, errors.New("不支持的设置项")
	}
	trimmed := strings.TrimSpace(value)
	switch declared.Type {
	case "toggle":
		if trimmed != "true" && trimmed != "false" {
			return nil, errors.New("开关设置只能是 true 或 false")
		}
	case "choice":
		if trimmed != "" && !choiceAllowed(*declared, trimmed) {
			return nil, errors.New("该选项不在允许范围内")
		}
	}
	if len(trimmed) > 4096 {
		return nil, errors.New("设置值过长")
	}
	return engine.writeSourceSetting(source, key, trimmed)
}

func choiceAllowed(setting ext.Setting, value string) bool {
	for _, option := range setting.Options {
		if option.Value == value {
			return true
		}
	}
	return false
}

// writeSourceSetting 落盘并回读，保证界面与存储一致。
func (engine *nativeEngine) writeSourceSetting(source, key, value string) (any, error) {
	values, _, err := engine.downloader.extensions.storageValues(source)
	if err != nil {
		return nil, err
	}
	if value == "" {
		delete(values, key)
	} else {
		values[key] = value
	}
	if err := engine.downloader.extensions.saveStorage(source, values); err != nil {
		return nil, err
	}
	return map[string]any{"source": source, "key": key, "value": value}, nil
}
