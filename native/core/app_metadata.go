package core

import (
	"context"
	"errors"
	"time"
)

// nativeNeedsExtraMetadata 判断是否需要再拉一次详情补资料。
// 黄豆的 VIP 与热度只在详情里，缺失时补一次；其余源由目录自带。
func nativeNeedsExtraMetadata(drama nativeDrama) bool {
	return drama.Source == sourceHongguo && drama.OnlineDate == "" ||
		drama.Source == sourceHuangdou && (drama.Heat == "" || drama.VIP == nil)
}

func (engine *nativeEngine) nativeExtraMetadata(ctx context.Context, drama nativeDrama) (nativeDrama, error) {
	source, id, valid := splitProviderDramaID(drama.ID)
	if !valid {
		return drama, errors.New("剧集信息无效")
	}
	if !nativeNeedsExtraMetadata(drama) {
		return drama, nil
	}
	ctx, cancel := context.WithTimeout(context.WithValue(ctx, backgroundCatalogKey{}, true), 15*time.Second)
	defer cancel()
	var raw Drama
	switch source {
	case sourceHongguo:
		// 红果补充资料走内置 provider 的详情接口（与目录共用同一签名通道）。
		provider, ok := engine.downloader.providers.get(sourceHongguo)
		if !ok {
			return drama, errors.New("红果站源不可用")
		}
		fresh, _, err := provider.Detail(ctx, id)
		if err != nil {
			return drama, err
		}
		raw = fresh
	case sourceHuangdou:
		// 黄豆的 VIP/热度在详情接口里；扩展已实现 detail，走统一 provider 通道。
		provider, ok := engine.downloader.providers.get(sourceHuangdou)
		if !ok {
			return drama, errors.New("黄豆站源未安装")
		}
		fresh, _, err := provider.Detail(ctx, id)
		if err != nil {
			return drama, err
		}
		raw = fresh
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
