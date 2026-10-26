package core

import (
	"context"
	"crypto/aes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"duanjuapp/native/ext"
)

// extensionProvider 把 ext.Extension 的 JS 契约适配为 sourceProvider，
// 注册进 M2 的 provider registry。安全边界：
//   - JS 返回的 drama/chapter 的 source 与 ID 前缀一律由宿主强制覆写，
//     扩展不能伪造其他站源的条目；
//   - 目录/详情结果经 nativeNormalize 与既有校验通道。
type extensionProvider struct {
	d      *Downloader
	source string
	// rankings 缓存扩展声明的榜单；rankingsOnce 保证只查询一次。
	rankingsOnce sync.Once
	rankings     []rankingBoard
}

// registerExtensionProvider 把已装扩展注册进 registry（幂等）。
func registerExtensionProvider(d *Downloader, source string) {
	if d == nil || d.providers == nil {
		return
	}
	if !validExtensionSourceID(source) {
		return
	}
	d.providers.register(source, &extensionProvider{d: d, source: source})
}

// register 允许动态加入站源（registry 内部 map 加锁保护）。
// 同名内置源允许被扩展临时顶替：迁移期用扩展修站源、灰度验证都依赖这一点。
// 回退由 unregister 负责；扩展包本身不能伪造其他源，前缀覆写在 provider 内。
func (r *providerRegistry) register(source string, provider sourceProvider) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.providers[source] = provider
}

// unregister 移除动态注册的源；若该 ID 有内置实现则回退到内置版本，
// 避免卸载扩展后站源彻底失效（迁移期同名扩展的常见场景）。
func (r *providerRegistry) unregister(source string) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if builtin, ok := r.builtins[source]; ok {
		r.providers[source] = builtin
		return
	}
	delete(r.providers, source)
}

// runtime 解析扩展运行时；未安装或加载失败返回错误。
func (p *extensionProvider) runtime(ctx context.Context) (*ext.Extension, error) {
	if p.d.extensions == nil {
		return nil, errors.New("扩展系统未就绪")
	}
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
	}
	return p.d.extensions.runtime(p.source)
}

func (p *extensionProvider) BaseURL() string {
	if p.d == nil {
		return ""
	}
	return strings.TrimRight(p.d.providerBaseURL(p.source), "/")
}

func (p *extensionProvider) SupportsOnlineSearch() bool {
	return true
}

func (p *extensionProvider) ValidCategory(category string) bool {
	if category == "" {
		return true
	}
	if len(category) > 128 || strings.ContainsAny(category, "|/\\\x00\r\n") {
		return false
	}
	loaded, err := p.runtime(context.Background())
	if err != nil {
		return false
	}
	result, err := loaded.Call(context.Background(), "validCategory", []any{category})
	if err != nil {
		return false
	}
	accepted, _ := result.(bool)
	return accepted
}

func (p *extensionProvider) Categories(ctx context.Context, force bool) ([]nativeCategory, error) {
	loaded, err := p.runtime(ctx)
	if err != nil {
		return nil, err
	}
	result, err := loaded.Call(ctx, "categories", []any{extensionContext(ctx), force})
	if err != nil {
		return nil, err
	}
	rows, ok := result.([]any)
	if !ok {
		if result == nil {
			return nil, nil
		}
		return nil, errors.New("扩展分类格式无效")
	}
	options := make([]nativeCategory, 0, len(rows))
	for _, row := range rows {
		entry, ok := row.(map[string]any)
		if !ok {
			continue
		}
		id, name := mapString(entry, "id"), mapString(entry, "name")
		if id == "" || name == "" || len(id) > 64 || len([]rune(name)) > 24 {
			continue
		}
		options = append(options, nativeCategory{ID: id, Name: name})
	}
	return options, nil
}

// extensionTestHostKey 让端到端测试把合成服务器地址传给 JS 契约的 ctx.host。
type extensionTestHostKey struct{}

func extensionContext(ctx context.Context) map[string]any {
	payload := map[string]any{}
	if host, ok := ctx.Value(extensionTestHostKey{}).(string); ok {
		payload["host"] = host
	}
	return payload
}

type extensionCatalogResult struct {
	Items   []extensionDrama `json:"items"`
	HasMore bool             `json:"hasMore"`
}

type extensionDrama struct {
	SourceID      string   `json:"sourceId"`
	Title         string   `json:"title"`
	Description   string   `json:"description,omitempty"`
	Cover         string   `json:"cover,omitempty"`
	Remark        string   `json:"remark,omitempty"`
	Episodes      int      `json:"episodes,omitempty"`
	Category      string   `json:"category,omitempty"`
	VIP           *bool    `json:"vip,omitempty"`
	Heat          string   `json:"heat,omitempty"`
	Views         string   `json:"views,omitempty"`
	OnlineDate    string   `json:"onlineDate,omitempty"`
	Tags          []string `json:"tags,omitempty"`
	ReleaseStatus string   `json:"releaseStatus,omitempty"`
}

func (row extensionDrama) toDrama(source string) Drama {
	drama := Drama{
		ID:            providerDramaID(source, row.SourceID),
		Source:        source,
		SourceID:      row.SourceID,
		Title:         strings.TrimSpace(row.Title),
		Desc:          row.Description,
		Cover:         row.Cover,
		Remark:        row.Remark,
		Episodes:      row.Episodes,
		Category:      row.Category,
		VIP:           row.VIP,
		Heat:          row.Heat,
		Views:         row.Views,
		OnlineDate:    row.OnlineDate,
		Tags:          row.Tags,
		ReleaseStatus: row.ReleaseStatus,
	}
	// 标题允许为空：与内置 provider 一致，由 nativeNormalize 的
	// DisplayTitle 统一兜底（空标题 → "短剧"），不在扩展侧各写一套文案。
	if !validExtensionItemID(row.SourceID) {
		return Drama{}
	}
	if cover, ok := drama.Cover.(string); ok && cover != "" && !isProviderHTTPMediaURL(cover) {
		drama.Cover = ""
	}
	return drama
}

func (p *extensionProvider) CatalogPage(ctx context.Context, page int, category, query string) ([]Drama, bool, error) {
	if page < 1 || page > 10000 {
		return nil, false, errors.New("扩展目录页码无效")
	}
	loaded, err := p.runtime(ctx)
	if err != nil {
		return nil, false, err
	}
	result, err := loaded.Call(ctx, "catalog", []any{extensionContext(ctx), page, category, query})
	if err != nil {
		return nil, false, err
	}
	raw, err := json.Marshal(result)
	if err != nil {
		return nil, false, errors.New("扩展目录结果无法序列化")
	}
	var parsed extensionCatalogResult
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return nil, false, errors.New("扩展目录格式无效")
	}
	items := make([]Drama, 0, len(parsed.Items))
	for _, row := range parsed.Items {
		if drama := row.toDrama(p.source); drama.ID != "" {
			items = append(items, drama)
		}
	}
	return items, parsed.HasMore, nil
}

type extensionChapter struct {
	ID       string `json:"id"`
	Title    string `json:"title"`
	VideoURL string `json:"videoUrl,omitempty"`
	PageURL  string `json:"pageUrl,omitempty"`
	Episode  int    `json:"episode,omitempty"`
	Referer  string `json:"referer,omitempty"`
	// VIP 标记该集需要站点会员：详情页与下载选择器都要据此提示。
	VIP bool `json:"vip,omitempty"`
}

func (row extensionChapter) toChapter(source string, index int) Chapter {
	title := strings.TrimSpace(row.Title)
	order := row.Episode
	if order <= 0 {
		order = index
	}
	if title == "" {
		title = "第" + strconv.Itoa(order) + "集"
	}
	// 章节 ID 由扩展自定（如 "1-2"、"series/12:3"），只需通过安全性校验；
	// 保持 source:rawKey 两段式：resolve 收到的 chapterId 必须与扩展原始 ID 一致。
	key := strings.TrimPrefix(strings.TrimSpace(row.ID), source+":")
	if !validExtensionItemID(key) {
		key = strconv.Itoa(index)
	}
	return Chapter{
		ID:             source + ":" + key,
		Source:         source,
		Title:          title,
		VideoURL:       row.VideoURL,
		PageURL:        row.PageURL,
		Referer:        row.Referer,
		VIP:            row.VIP,
		CurrentEpisode: rawEpisode(order),
	}
}

type extensionDetail struct {
	Drama    extensionDrama     `json:"drama"`
	Chapters []extensionChapter `json:"chapters"`
}

func (p *extensionProvider) Detail(ctx context.Context, id string) (Drama, []Chapter, error) {
	if !validExtensionItemID(id) {
		return Drama{}, nil, errors.New("扩展剧集 ID 无效")
	}
	loaded, err := p.runtime(ctx)
	if err != nil {
		return Drama{}, nil, err
	}
	result, err := loaded.Call(ctx, "detail", []any{extensionContext(ctx), id})
	if err != nil {
		return Drama{}, nil, err
	}
	raw, err := json.Marshal(result)
	if err != nil {
		return Drama{}, nil, errors.New("扩展详情结果无法序列化")
	}
	var parsed extensionDetail
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return Drama{}, nil, errors.New("扩展详情格式无效")
	}
	drama := parsed.Drama.toDrama(p.source)
	if drama.ID == "" {
		return Drama{}, nil, errors.New("扩展详情缺少有效剧集")
	}
	if len(parsed.Chapters) == 0 || len(parsed.Chapters) > 100000 {
		return Drama{}, nil, errors.New("扩展未返回可播放分集")
	}
	chapters := make([]Chapter, 0, len(parsed.Chapters))
	for index, row := range parsed.Chapters {
		chapters = append(chapters, row.toChapter(p.source, index+1))
	}
	drama.Episodes = len(chapters)
	return drama, chapters, nil
}

// ResolveMedia 扩展播放解析：返回的 URL 必须是合法 HTTP 媒体地址。
func (p *extensionProvider) ResolveMedia(ctx context.Context, task Task) (providerMedia, error) {
	_, sourceID, valid := splitProviderDramaID(task.DramaID)
	if !valid {
		return providerMedia{}, errors.New("扩展剧集 ID 无效")
	}
	loaded, err := p.runtime(ctx)
	if err != nil {
		return providerMedia{}, err
	}
	// chapterId 传 JS 原始 ID（宿主在 Chapter.ID 上加的源前缀剥掉）。
	result, err := loaded.Call(ctx, "resolve", []any{extensionContext(ctx), map[string]any{
		"dramaId":   sourceID,
		"chapterId": strings.TrimPrefix(task.Chapter.ID, p.source+":"),
		"episode":   task.Index,
		"pageUrl":   task.Chapter.PageURL,
		"videoUrl":  task.Chapter.VideoURL,
	}})
	if err != nil {
		if strings.Contains(err.Error(), "扩展未实现 resolve") {
			return providerMedia{}, errProviderNotHandled
		}
		return providerMedia{}, err
	}
	raw, _ := json.Marshal(result)
	var parsed struct {
		URL       string            `json:"url"`
		Referer   string            `json:"referer,omitempty"`
		Quality   int               `json:"quality,omitempty"`
		Qualities []int             `json:"qualities,omitempty"`
		Headers   map[string]string `json:"headers,omitempty"`
		// HLSKey 是 16 字节密钥的 hex：加密 HLS 的站源（黄豆）在响应里下发密钥。
		HLSKey string `json:"hlsKey,omitempty"`
		// credentials 透传签名 Cookie 等播放凭证（宿主在媒体请求上应用）。
		Credentials *struct {
			Cookie     string `json:"cookie"`
			Origin     string `json:"origin"`
			Referer    string `json:"referer"`
			UserAgent  string `json:"userAgent"`
			ExpiresAt  int64  `json:"expiresAt,omitempty"`
			ExpiresISO string `json:"expiresAtISO,omitempty"`
		} `json:"credentials,omitempty"`
	}
	if json.Unmarshal(raw, &parsed) != nil {
		return providerMedia{}, errors.New("扩展播放格式无效")
	}
	if parsed.URL == "" {
		return providerMedia{}, fmt.Errorf("%s 未返回有效播放地址", p.source)
	}
	if !isProviderHTTPMediaURL(parsed.URL) {
		return providerMedia{}, fmt.Errorf("%s 返回的播放地址无效", p.source)
	}
	media := providerMedia{URL: parsed.URL, Referer: parsed.Referer, Quality: parsed.Quality}
	if parsed.HLSKey != "" {
		key, err := hex.DecodeString(parsed.HLSKey)
		if err != nil || len(key) != aes.BlockSize {
			return providerMedia{}, fmt.Errorf("%s 返回了无效的 HLS 密钥", p.source)
		}
		media.HLSKey = key
	}
	if !isProviderHTTPMediaURL(media.Referer) {
		media.Referer = ""
	}
	if credentials := parsed.Credentials; credentials != nil {
		expires := time.Time{}
		if credentials.ExpiresAt > 0 && credentials.ExpiresAt <= 253402300799000 {
			if credentials.ExpiresAt > 100000000000 {
				expires = time.UnixMilli(credentials.ExpiresAt)
			} else {
				expires = time.Unix(credentials.ExpiresAt, 0)
			}
		} else if credentials.ExpiresISO != "" {
			expires, _ = time.Parse(time.RFC3339Nano, credentials.ExpiresISO)
		}
		media.credentials = &providerMediaCredentials{
			cookie: credentials.Cookie, origin: credentials.Origin,
			referer: credentials.Referer, userAgent: credentials.UserAgent,
			expires: expires,
		}
	}
	return p.d.finalizeProviderMedia(ctx, media, p.source)
}

// CoverAddress 实现 coverResolver：重新拉详情读取封面。
func (p *extensionProvider) CoverAddress(ctx context.Context, drama nativeDrama, id string) (string, error) {
	return p.extensionCover(ctx, drama, id)
}

// extensionCover 从扩展详情拉取封面。
func (p *extensionProvider) extensionCover(ctx context.Context, drama nativeDrama, id string) (string, error) {
	// cover 契约简化为：重新拉详情读取封面，防止实现漂移。
	fresh, _, err := p.Detail(ctx, id)
	if err != nil {
		return "", err
	}
	if cover, ok := fresh.Cover.(string); ok {
		return cover, nil
	}
	return "", errors.New("扩展详情未返回海报地址")
}

// —— rankings 契约：扩展自行声明榜单并返回条目 ——

type extensionRankingBoard struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	// Data 是扩展自定义的榜单标识，宿主原样回传给 rankings()。
	Data string `json:"data,omitempty"`
}

type extensionRankingResult struct {
	Items       []extensionDrama `json:"items"`
	HasMore     bool             `json:"hasMore"`
	TotalPages  int              `json:"totalPages,omitempty"`
	UpdatedText string           `json:"updatedText,omitempty"`
}

// RankingBoards 读取扩展声明的榜单；未实现 rankings 契约时返回空。
// 结果按扩展缓存，避免每帧一次脚本调用。
func (p *extensionProvider) RankingBoards() []rankingBoard {
	p.rankingsOnce.Do(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		loaded, err := p.runtime(ctx)
		if err != nil {
			return
		}
		result, err := loaded.Call(ctx, "rankingBoards", []any{extensionContext(ctx)})
		if err != nil {
			return
		}
		raw, err := json.Marshal(result)
		if err != nil {
			return
		}
		var rows []extensionRankingBoard
		if json.Unmarshal(raw, &rows) != nil {
			return
		}
		boards := make([]rankingBoard, 0, len(rows))
		for _, row := range rows {
			id, name := strings.TrimSpace(row.ID), strings.TrimSpace(row.Name)
			if id == "" || name == "" || len(id) > 64 || len([]rune(name)) > 32 {
				continue
			}
			boards = append(boards, rankingBoard{
				ID: id, Source: p.source, Name: name,
				Description: strings.TrimSpace(row.Description), path: row.Data,
			})
		}
		p.rankings = boards
	})
	return append([]rankingBoard{}, p.rankings...)
}

// RankingPage 拉取扩展榜单的一页。
func (p *extensionProvider) RankingPage(ctx context.Context, board rankingBoard, page int) (rankingPage, error) {
	if page < 1 || page > 500 {
		return rankingPage{}, errors.New("榜单页码无效")
	}
	loaded, err := p.runtime(ctx)
	if err != nil {
		return rankingPage{}, err
	}
	result, err := loaded.Call(ctx, "rankings", []any{extensionContext(ctx), board.ID, board.path, page})
	if err != nil {
		return rankingPage{}, err
	}
	raw, err := json.Marshal(result)
	if err != nil {
		return rankingPage{}, errors.New("扩展榜单结果无法序列化")
	}
	var parsed extensionRankingResult
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return rankingPage{}, errors.New("扩展榜单格式无效")
	}
	items := make([]rankingItem, 0, len(parsed.Items))
	for index, row := range parsed.Items {
		drama := row.toDrama(p.source)
		if drama.ID == "" {
			return rankingPage{}, errors.New("扩展榜单包含无效条目")
		}
		items = append(items, rankingItem{Rank: (page-1)*20 + index + 1, Drama: rankingDramaWithoutImages(drama)})
	}
	return rankingPage{
		BoardID: board.ID, Page: page, Items: items, HasMore: parsed.HasMore,
		TotalPages: parsed.TotalPages, UpdatedText: parsed.UpdatedText,
	}, nil
}
