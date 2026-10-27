package core

import (
	"context"
	"errors"
	"time"
)

// sourceSupportsVIP 报告该源是否声明了 VIP 标记能力。
// 红果是内置源、目录不带 VIP，故不声明。
func (engine *nativeEngine) sourceSupportsVIP(source string) bool {
	if source == sourceHongguo {
		return false
	}
	d := engine.downloader
	if d == nil || d.extensions == nil {
		return false
	}
	installed := d.extensions.Manifest(source)
	return installed != nil && installed.VIP
}

// sourceDeclaresDetailField 报告该源是否声明需要补齐某字段。
func (engine *nativeEngine) sourceDeclaresDetailField(source, field string) bool {
	d := engine.downloader
	if d == nil || d.extensions == nil {
		return false
	}
	installed := d.extensions.Manifest(source)
	if installed == nil {
		return false
	}
	for _, declared := range installed.DetailFields {
		if declared == field {
			return true
		}
	}
	return false
}

// nativeNeedsExtraMetadata 判断是否需要再拉一次详情补资料。
//
// 规则由扩展清单的 detailFields 声明（如黄豆声明 vip,heat），不再按源 ID
// 硬编码——否则加一个"详情里才有 VIP"的新源必须改客户端。红果是唯一内置源，
// 其目录缺上线日期，保持内联规则。
func nativeNeedsExtraMetadata(d *Downloader, drama nativeDrama) bool {
	if drama.Source == sourceHongguo {
		return drama.OnlineDate == ""
	}
	if d == nil || d.extensions == nil {
		return false
	}
	installed := d.extensions.Manifest(drama.Source)
	if installed == nil {
		return false
	}
	for _, field := range installed.DetailFields {
		switch field {
		case "vip":
			if drama.VIP == nil {
				return true
			}
		case "heat":
			if drama.Heat == "" {
				return true
			}
		case "views":
			if drama.Views == "" {
				return true
			}
		case "onlinedate":
			if drama.OnlineDate == "" {
				return true
			}
		case "description":
			if drama.Description == "" {
				return true
			}
		case "tags":
			if len(drama.Tags) == 0 {
				return true
			}
		case "releasestatus":
			if drama.ReleaseStatus == "" {
				return true
			}
		}
	}
	return false
}

func (engine *nativeEngine) nativeExtraMetadata(ctx context.Context, drama nativeDrama) (nativeDrama, error) {
	source, id, valid := splitProviderDramaID(drama.ID)
	if !valid {
		return drama, errors.New("剧集信息无效")
	}
	if !nativeNeedsExtraMetadata(engine.downloader, drama) {
		return drama, nil
	}
	ctx, cancel := context.WithTimeout(context.WithValue(ctx, backgroundCatalogKey{}, true), 15*time.Second)
	defer cancel()
	// 红果与扩展都走统一的 provider.Detail：红果是内置 provider，
	// 扩展是 JS 适配器，两者接口一致，无需按源分叉。
	provider, ok := engine.downloader.providers.get(source)
	if !ok {
		return drama, errors.New("站源不可用")
	}
	raw, _, err := provider.Detail(ctx, id)
	if err != nil {
		return drama, err
	}
	if raw.ID == drama.ID {
		drama = mergeNativeDrama(drama, nativeNormalize(raw))
	}
	return drama, ctx.Err()
}

func (engine *nativeEngine) nativeFollowCheck(ctx context.Context, drama nativeDrama) (any, error) {
	ctx, cancel := context.WithTimeout(context.WithValue(ctx, backgroundCatalogKey{}, true), 20*time.Second)
	defer cancel()
	result, err := engine.nativeDetail(ctx, drama)
	if err != nil {
		return nil, err
	}
	return map[string]any{"drama": result.(map[string]any)["drama"]}, nil
}

func (engine *nativeEngine) nativeMetadata(ctx context.Context, drama nativeDrama) (any, error) {
	fresh, err := engine.nativeExtraMetadata(ctx, drama)
	if err != nil {
		return nil, err
	}
	warning := ""
	if err := engine.saveDetailMetadata(fresh); err != nil {
		warning = err.Error()
	}
	return map[string]any{"drama": fresh, "warning": warning}, nil
}
