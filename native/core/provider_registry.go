package core

import (
	"context"
	"errors"
	"strings"
	"sync"
)

// errProviderNotHandled 表示该源没有实现此能力，调用方回退到通用路径。
var errProviderNotHandled = errors.New("provider capability not handled")

// sourceProvider 是站源接入应用的统一抽象：分类、目录/搜索与详情。
// 红果内置源的富语义（搜索提示、feed 分页）保留在分派层；
// JS 扩展源在 M4 中实现同一接口。
type sourceProvider interface {
	BaseURL() string
	ValidCategory(category string) bool
	// SupportsOnlineSearch 表示 query 非空时 CatalogPage 应执行站内在线搜索。
	SupportsOnlineSearch() bool
	Categories(ctx context.Context, force bool) ([]nativeCategory, error)
	// CatalogPage 返回一页目录。query 非空表示在线搜索（此时 category 为空）。
	CatalogPage(ctx context.Context, page int, category, query string) ([]Drama, bool, error)
	Detail(ctx context.Context, id string) (Drama, []Chapter, error)
}

// playbackResolver 由拥有独立播放解析逻辑的站源实现；
// 未实现或返回 errProviderNotHandled 时走通用播放地址解析。
type playbackResolver interface {
	ResolveMedia(ctx context.Context, task Task) (providerMedia, error)
}

// coverResolver 由拥有独立封面补齐接口的站源实现；
// 未实现时默认重新拉取详情并取封面。
type coverResolver interface {
	CoverAddress(ctx context.Context, drama nativeDrama, id string) (string, error)
}

// rankingProvider 由声明了榜单的扩展源实现。
// 榜单描述与分页结果都由扩展给出，宿主只负责缓存、校验与合并剧库资料。
type rankingProvider interface {
	RankingBoards() []rankingBoard
	RankingPage(ctx context.Context, board rankingBoard, page int) (rankingPage, error)
}

// providerRegistry 保存全部已接入站源。
// builtins 保留内置实现的副本：迁移期同名扩展可以临时顶替内置源，
// 卸载后必须回退到内置实现，而不是留下无法解析的空洞。
type providerRegistry struct {
	mu        sync.RWMutex
	providers map[string]sourceProvider
	builtins  map[string]sourceProvider
}

func (r *providerRegistry) get(source string) (sourceProvider, bool) {
	if r == nil {
		return nil, false
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	provider, ok := r.providers[canonicalProviderSource(source)]
	return provider, ok
}

// toleratesEmptyCatalog：目录首页为空时不报错的源（与支持在线搜索的源一致，
// 这些源的分类页可能合法为空，由前端展示空态）。
func (r *providerRegistry) toleratesEmptyCatalog(source string) bool {
	if provider, ok := r.get(source); ok {
		return provider.SupportsOnlineSearch()
	}
	return false
}

func (r *providerRegistry) sources() []string {
	if r == nil {
		return nil
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	names := make([]string, 0, len(r.providers))
	for name := range r.providers {
		names = append(names, name)
	}
	return names
}

// all 返回当前注册的全部站源实现快照，供榜单等跨源能力遍历。
func (r *providerRegistry) all() map[string]sourceProvider {
	if r == nil {
		return nil
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	snapshot := make(map[string]sourceProvider, len(r.providers))
	for name, provider := range r.providers {
		snapshot[name] = provider
	}
	return snapshot
}

// funcProvider 用函数字段拼装站源实现，避免每源一套 struct 样板；
// nil 函数表示该能力走通用路径。
type funcProvider struct {
	d            *Downloader
	source       string
	onlineSearch bool
	baseURLFn    func(d *Downloader) string
	validFn      func(category string) bool
	categoriesFn func(ctx context.Context, d *Downloader, force bool) ([]nativeCategory, error)
	catalogFn    func(ctx context.Context, d *Downloader, page int, category, query string) ([]Drama, bool, error)
	detailFn     func(ctx context.Context, d *Downloader, id string) (Drama, []Chapter, error)
	resolveFn    func(ctx context.Context, d *Downloader, task Task) (providerMedia, error)
	coverFn      func(ctx context.Context, d *Downloader, drama nativeDrama, id string) (string, error)
}

func (p *funcProvider) BaseURL() string { return p.baseURLFn(p.d) }

func (p *funcProvider) SupportsOnlineSearch() bool { return p.onlineSearch }

func (p *funcProvider) ValidCategory(category string) bool {
	if p.validFn == nil {
		return category == ""
	}
	return p.validFn(category)
}

func (p *funcProvider) Categories(ctx context.Context, force bool) ([]nativeCategory, error) {
	return p.categoriesFn(ctx, p.d, force)
}

func (p *funcProvider) CatalogPage(ctx context.Context, page int, category, query string) ([]Drama, bool, error) {
	return p.catalogFn(ctx, p.d, page, category, query)
}

func (p *funcProvider) Detail(ctx context.Context, id string) (Drama, []Chapter, error) {
	return p.detailFn(ctx, p.d, id)
}

func (p *funcProvider) ResolveMedia(ctx context.Context, task Task) (providerMedia, error) {
	if p.resolveFn == nil {
		return providerMedia{}, errProviderNotHandled
	}
	return p.resolveFn(ctx, p.d, task)
}

func (p *funcProvider) CoverAddress(ctx context.Context, drama nativeDrama, id string) (string, error) {
	if p.coverFn != nil {
		return p.coverFn(ctx, p.d, drama, id)
	}
	// 默认封面补齐：重新拉详情，校验后取封面。
	fresh, _, err := p.detailFn(ctx, p.d, id)
	if err != nil {
		return "", err
	}
	if fresh.ID != "" && fresh.ID != drama.ID {
		return "", errors.New("详情与请求剧集不符")
	}
	if cover := nativeNormalize(fresh).Cover; cover != "" {
		return cover, nil
	}
	return "", errors.New("详情暂未返回海报地址")
}

// newProviderRegistry 只注册红果：其余站源全部由 JS 扩展在运行期声明。
//
// 红果留在 Go 里是因为它的请求签名体系（设备号注册、Argus/Ladon 签名、
// 加密章节解析）无法用脚本稳定复现，也不应该随扩展包热更新。
func newProviderRegistry(d *Downloader) *providerRegistry {
	providers := map[string]sourceProvider{}
	register := func(source string, provider *funcProvider) {
		provider.d = d
		provider.source = source
		if provider.baseURLFn == nil {
			provider.baseURLFn = func(d *Downloader) string { return d.providerBaseURL(source) }
		}
		providers[source] = provider
	}

	register(sourceHongguo, &funcProvider{
		validFn: func(category string) bool {
			for _, genre := range hongguoAppGenres {
				if category == genre.key {
					return true
				}
			}
			return false
		},
		categoriesFn: func(ctx context.Context, d *Downloader, force bool) ([]nativeCategory, error) {
			options := make([]nativeCategory, 0, len(hongguoAppGenres))
			for _, genre := range hongguoAppGenres {
				options = append(options, nativeCategory{ID: genre.key, Name: genre.name})
			}
			return options, nil
		},
		detailFn: func(ctx context.Context, d *Downloader, id string) (Drama, []Chapter, error) {
			_, chapters, err := d.GetHuangguoChapters(ctx, sourceHongguo, id)
			return Drama{}, chapters, err
		},
		resolveFn: func(ctx context.Context, d *Downloader, task Task) (providerMedia, error) {
			// 仅加密章节走红果专用解析；普通地址章节回退通用路径。
			if !strings.HasPrefix(task.Chapter.VideoURL, "hongguo-cenc://") {
				return providerMedia{}, errProviderNotHandled
			}
			return d.resolveHongguoMedia(ctx, task)
		},
		coverFn: func(ctx context.Context, d *Downloader, drama nativeDrama, id string) (string, error) {
			if !hongguoNumericID.MatchString(id) {
				return "", errors.New("无效的红果剧集 ID")
			}
			result, err := d.hongguoAppRequest(ctx, "POST", "/novel/player/video_detail/v1/", nil, map[string]any{"series_id": id})
			if err != nil {
				return "", err
			}
			row := nestedMap(result, "data", "video_data")
			if mapString(row, "series_id_str", "series_id") != id {
				return "", errors.New("红果详情与请求剧集不符")
			}
			return hongguoCoverAddress(mapString(row, "series_cover", "cover")), nil
		},
	})

	// builtins 必须是独立副本：providers 会随扩展安装/卸载变化，
	// 两者共用同一 map 会让"内置实现"变成扩展快照。
	builtins := make(map[string]sourceProvider, len(providers))
	for source, provider := range providers {
		builtins[source] = provider
	}
	return &providerRegistry{providers: providers, builtins: builtins}
}
