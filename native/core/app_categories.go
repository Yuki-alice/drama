package core

import (
	"context"
	"errors"
	"regexp"
	"strings"
)

type nativeCategory struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

var nativeAICategories = []nativeCategory{
	{ID: "ai-duanju", Name: "AI 短剧"},
	{ID: "ai-manju", Name: "AI 漫剧"},
	{ID: "ai-huanlian", Name: "AI 换脸"},
	{ID: "ai-mogai", Name: "AI 魔改"},
}

func nativeCatalogKey(source, category string) string {
	source = canonicalProviderSource(source)
	if category = strings.TrimSpace(category); category != "" {
		return source + "|" + category
	}
	return source
}

func validNativeCategory(source, category string) bool {
	if category == "" {
		return true
	}
	if len(category) > 128 || strings.ContainsAny(category, "|/\\\x00\r\n") {
		return false
	}
	registry := sourceRegistry()
	if registry == nil {
		// 引擎尚未挂载（启动早期或隔离测试）：字符集校验已通过，
		// 具体分类由随后的 provider 调用裁决。
		return true
	}
	if provider, ok := registry.get(source); ok {
		return provider.ValidCategory(category)
	}
	return false
}

// sourceRegistry 返回当前生效的 provider 注册表；引擎未就绪时返回 nil。
// 请求入口的分类校验在引擎挂载前也可能被调用，此时由调用方决定放行。
func sourceRegistry() *providerRegistry {
	nativeState.Lock()
	defer nativeState.Unlock()
	if engine := nativeState.engine; engine != nil && engine.downloader != nil {
		return engine.downloader.providers
	}
	return nil
}

func (engine *nativeEngine) nativeCategories(ctx context.Context, source string, force bool) ([]nativeCategory, error) {
	source = canonicalProviderSource(source)
	provider, ok := engine.downloader.providers.get(source)
	if !ok {
		return nil, errors.New("请选择有效站源")
	}
	// 静态分类的源（红果/黄果 AI/黄豆）不进入磁盘缓存。
	options, err := provider.Categories(ctx, force)
	if err != nil {
		return nil, err
	}
	all := append([]nativeCategory{{Name: "全部"}}, options...)
	if len(all) == 1 {
		return nil, errors.New("站源暂未返回内容分类，请稍后重试")
	}
	engine.mu.Lock()
	if engine.categoryOptions == nil {
		engine.categoryOptions = map[string][]nativeCategory{}
	}
	engine.categoryOptions[source] = all
	engine.writeCatalogDiskLocked()
	engine.mu.Unlock()
	return all, nil
}

var categoryAnchorPattern = regexp.MustCompile(`(?is)<a\b([^>]*)>(.*?)</a>`)
var categoryTextPattern = regexp.MustCompile(`(?s)<[^>]*>`)
