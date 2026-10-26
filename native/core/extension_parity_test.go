package core

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/md5"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
)

// installTestExtension 从官方仓库读取单文件扩展并安装到测试引擎。
func installTestExtension(t *testing.T, engine *nativeEngine, sourceID string) {
	t.Helper()
	path := filepath.Join("..", "..", "extensions-repo", "extensions", sourceID+".js")
	code, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取扩展脚本失败: %v", err)
	}
	if _, err := engine.downloader.extensions.InstallScript(code, sourceID); err != nil {
		t.Fatalf("安装扩展失败: %v", err)
	}
}

// parityContext 返回带测试 host 注入的 ctx，扩展 JS 以 ctx.host 取代 baseURL。
func parityContext(server *httptest.Server) context.Context {
	return context.WithValue(context.Background(), extensionTestHostKey{}, server.URL)
}

const guipianListPage = `<!doctype html><html><body>
<ul class="row video-list video-film-list">
<a class="video-link" href="/nv/1001.html" title="山村老尸">
<div class="video-duration">HD高清</div>
<div data-original="https://img.example.test/1001.jpg"></div>
</a>
<a class="video-link" href="/nv/1002.html" title="笔仙惊魂">
<div class="video-duration">正片</div>
<div data-original="https://img.example.test/1002.jpg"></div>
</a>
</ul>
<div class="page"><a href="/list/3_2.html">下一页</a></div>
</body></html>`

const guipianListPage2 = `<!doctype html><html><body>
<ul class="row video-list video-film-list">
<a class="video-link" href="/nv/1003.html" title="咒怨">
<div data-original="https://img.example.test/1003.jpg"></div>
</a>
</ul>
</body></html>`

const guipianDetailPage = `<!doctype html><html><body>
<title>《山村老尸》全集 - 鬼片网</title>
<h1 class="media-title">山村老尸</h1>
<div class="detail-img"><img src="https://img.example.test/1001.jpg"></div>
<ul>
<li>简介：经典港产恐怖片。</li>
<li>年份：<span>2000</span></li>
<li>导演：<span>郑保瑞</span></li>
<li>主演：<span><a href="#">钱升玮</a><a href="#">吴镇宇</a></span></li>
<li>地区：<span><a href="#">香港</a></span></li>
<li>状态：<span>完结</span></li>
</ul>
<ul class="ewave-tab-list">
<li class="swiper-slide ewave-tab" data-target="#ewave-playlist-1">线路一</li>
<li class="swiper-slide ewave-tab" data-target="#ewave-playlist-2">备用</li>
</ul>
<div id="ewave-playlist-1"><ul>
<li><a title='第02集' href='/play/1001-1-2.html'>第02集</a></li>
<li><a title='第01集' href='/play/1001-1-1.html'>第01集</a></li>
</ul></div>
<div class="playlist-slide" id="ewave-playlist-2"><ul>
<li><a title='第01集' href='/play/1001-2-1.html'>第01集</a></li>
</ul></div>
</body></html>`

func guipianPlayPage(host string) string {
	return `<html><head><script>var now="` + host + `/video/1001-1.m3u8?sign=a%2Fb";</script></head></html>`
}

const fixturePlaylist = "#EXTM3U\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n"

const guipianRSS = `<rss><channel>
<item><title>山村老尸</title><link>https://guipianwu.com/nv/1001.html</link></item>
<item><title>咒怨</title><link>https://guipianwu.com/nv/1003.html</link></item>
</channel></rss>`

func guipianFixtureServer(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/list/3.html":
			_, _ = w.Write([]byte(guipianListPage))
		case r.URL.Path == "/list/3_2.html":
			_, _ = w.Write([]byte(guipianListPage2))
		case r.URL.Path == "/nv/1001.html":
			_, _ = w.Write([]byte(guipianDetailPage))
		case strings.HasPrefix(r.URL.Path, "/play/"):
			_, _ = w.Write([]byte(guipianPlayPage("http://" + r.Host)))
		case r.URL.Path == "/xml/rss.xml":
			_, _ = w.Write([]byte(guipianRSS))
		case r.URL.Path == "/video/1001-1.m3u8":
			_, _ = w.Write([]byte(fixturePlaylist))
		default:
			http.NotFound(w, r)
		}
	}))
}

// TestGuipianExtensionParity：同一份 fixture 上，JS 扩展包与
// Go 内置源的目录/详情输出一致；播放解析提取同一 m3u8。
func TestGuipianExtensionParity(t *testing.T) {
	server := guipianFixtureServer(t)
	t.Cleanup(server.Close)
	// 两侧都经真实 fixture 服务器（默认 transport），保证 m3u8 预取等
	// 深层请求与页面请求走同一份路由。
	forward := func(request *http.Request) (*http.Response, error) {
		return http.DefaultTransport.RoundTrip(request)
	}

	// Go 内置源已移除：这里只校验扩展本身在固定 fixture 上的输出。
	engine := sourceFixtureEngine(t, forward)
	installTestExtension(t, engine, "guipian")
	provider, ok := engine.downloader.providers.get("guipian")
	if !ok {
		t.Fatal("guipian 扩展未注册")
	}
	jsProvider, isExtension := provider.(*extensionProvider)
	if !isExtension {
		t.Fatal("guipian provider 不是扩展实现")
	}
	ctx := parityContext(server)

	// —— 目录 ——
	items, more, err := jsProvider.CatalogPage(ctx, 1, "3", "")
	if err != nil {
		t.Fatal("extension catalog:", err)
	}
	if len(items) != 2 || !more {
		t.Fatalf("catalog shape = %d(%v), want 2(true)", len(items), more)
	}
	if items[0].ID != "guipian:1001" || items[0].Title != "山村老尸" {
		t.Fatalf("catalog[0] mismatch: %+v", items[0])
	}
	if cover, _ := items[0].Cover.(string); cover != "https://img.example.test/1001.jpg" {
		t.Fatalf("catalog[0] cover = %q", cover)
	}

	// —— 搜索（RSS 标题匹配）——
	search, searchMore, err := jsProvider.CatalogPage(ctx, 1, "", "老尸")
	if err != nil {
		t.Fatal("extension search:", err)
	}
	if len(search) != 1 || searchMore {
		t.Fatalf("search shape = %d(%v), want 1(false)", len(search), searchMore)
	}
	if search[0].ID != "guipian:1001" {
		t.Fatalf("search[0] = %+v", search[0])
	}

	// —— 详情 ——
	drama, chapters, err := jsProvider.Detail(ctx, "1001")
	if err != nil {
		t.Fatal("extension detail:", err)
	}
	if drama.Title != "山村老尸" {
		t.Fatalf("detail title = %q", drama.Title)
	}
	if len(drama.Tags) == 0 || len(chapters) == 0 {
		t.Fatalf("detail tags/chapters empty: %v / %d", drama.Tags, len(chapters))
	}
	for index, chapter := range chapters {
		if chapter.Title == "" || chapter.PageURL == "" {
			t.Fatalf("chapter[%d] incomplete: %+v", index, chapter)
		}
	}

	// —— 播放解析：JS 从 fixture 播放页提取 m3u8，并经 m3u8 fixture 完成预取。
	// resolve 的 pageUrl 在测试态指向 fixture 播放页；
	// 生产态为站点绝对地址，展开逻辑与详情解析一致。
	jsMedia, err := jsProvider.ResolveMedia(parityContext(server), Task{
		DramaID: "guipian:1001",
		Chapter: Chapter{
			ID:      chapters[0].ID,
			PageURL: server.URL + "/play/1001-1-1.html",
			Source:  "guipian",
		},
	})
	if err != nil {
		t.Fatal("extension resolve:", err)
	}
	if jsMedia.URL != server.URL+"/video/1001-1.m3u8?sign=a%2Fb" {
		t.Fatalf("resolve url mismatch: %q", jsMedia.URL)
	}
	if !strings.Contains(jsMedia.Playlist, "#EXTM3U") {
		t.Fatalf("resolve did not prefetch playlist: %q", jsMedia.Playlist)
	}
}

func guipianRouteBody(request *http.Request) string {
	switch {
	case request.URL.Path == "/list/3.html":
		return guipianListPage
	case request.URL.Path == "/list/3_2.html":
		return guipianListPage2
	case request.URL.Path == "/nv/1001.html":
		return guipianDetailPage
	case strings.HasPrefix(request.URL.Path, "/play/"):
		return guipianPlayPage("http://" + request.Host)
	case request.URL.Path == "/xml/rss.xml":
		return guipianRSS
	}
	return ""
}

const hxqListPage = `<!doctype html><html><body>
<div class="module-item">
<a href="/hanxiaoquan/5001.html" title="来自星星的你" class="module-item-pic">
<img data-src="https://img.example.test/5001.jpg">
</a>
<a href="/hanxiaoquan/5001.html" class="module-item-title">来自星星的你</a>
<div class="module-item-text">2024-01-01</div>
</div>
<div class="module-item">
<a href="/hanxiaoquan/5002.html" title="太阳的后裔" class="module-item-pic">
<img data-src="https://img.example.test/5002.jpg">
</a>
<a href="/hanxiaoquan/5002.html" class="module-item-title">太阳的后裔</a>
<div class="module-item-text">更新至16集</div>
</div>
<a href="/hxq/1-2.html">下一页</a>
</body></html>`

const hxqDetailPage = `<!doctype html><html><head>
<meta property="og:image" content="https://img.example.test/5001.jpg">
</head><body>
<h1 class="page-title">来自星星的你</h1>
<span class="video-info-itemtitle">剧情：</span><div class="video-info-item">外星人 romance@广告词@。</div>
<span class="video-info-itemtitle">上映：</span><div class="video-info-item">2013</div>
<span class="video-info-itemtitle">导演：</span><div class="video-info-item">张太维</div>
<span class="video-info-itemtitle">主演：</span><div class="video-info-item">金秀贤 全智贤</div>
<span class="video-info-itemtitle">更新：</span><div class="video-info-item">2024-01-01</div>
<a href="#playlist1"><i class="icon"></i>线路一</a>
<a href="#playlist2"><i class="icon"></i>备用</a>
<div id="playlist1">
<a title="第21集" href="/play/5001-1-21.html">第21集</a>
<a title="第01集" href="/play/5001-1-1.html">第01集</a>
</div>
<div id="playlist2">
<a title="第01集" href="/play/5001-2-1.html">第01集</a>
</div>
</body></html>`

func hxqPlayPage(host string) string {
	return `<html><head><script>var now="` + host + `/hxq/5001-1.m3u8";</script></head></html>`
}

func hxqRouteBody(request *http.Request) string {
	switch {
	case request.URL.Path == "/hxq/1.html":
		return hxqListPage
	case request.URL.Path == "/hanxiaoquan/5001.html":
		return hxqDetailPage
	case strings.HasPrefix(request.URL.Path, "/play/"):
		return hxqPlayPage("http://" + request.Host)
	case request.URL.Path == "/search.php":
		return hxqListPage
	case request.URL.Path == "/hxq/5001-1.m3u8":
		return fixturePlaylist
	}
	return ""
}

// TestHanxiaoquanExtensionParity：JS 扩展包与 Go 内置源
// 在同一 fixture 上的目录/详情/搜索输出一致。
func TestHanxiaoquanExtensionParity(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(hxqRouteBody(r)))
	}))
	t.Cleanup(server.Close)
	forward := func(request *http.Request) (*http.Response, error) {
		return http.DefaultTransport.RoundTrip(request)
	}

	d := sourceFixtureDownloader(t, forward)
	d.cfg.HanxiaoquanURL = server.URL

	engine := sourceFixtureEngine(t, forward)
	engine.downloader.cfg.HanxiaoquanURL = server.URL
	installTestExtension(t, engine, "hanxiaoquan")
	provider, ok := engine.downloader.providers.get("hanxiaoquan")
	if !ok {
		t.Fatal("hanxiaoquan 扩展未注册")
	}
	jsProvider := provider.(*extensionProvider)
	ctx := parityContext(server)

	// —— 目录 ——
	items, more, err := jsProvider.CatalogPage(ctx, 1, "1", "")
	if err != nil {
		t.Fatal("extension catalog:", err)
	}
	if len(items) != 2 || !more {
		t.Fatalf("catalog shape = %d(%v), want 2(true)", len(items), more)
	}
	if items[0].Title != "来自星星的你" || items[0].SourceID == "" {
		t.Fatalf("catalog[0] = %+v", items[0])
	}

	// —— 搜索 ——
	search, _, err := jsProvider.CatalogPage(ctx, 1, "", "星星")
	if err != nil {
		t.Fatal("extension search:", err)
	}
	if len(search) != 2 {
		t.Fatalf("search hit %d rows, want 2", len(search))
	}

	// —— 详情（多线路取最长列表）——
	drama, chapters, err := jsProvider.Detail(ctx, "5001")
	if err != nil {
		t.Fatal("extension detail:", err)
	}
	if drama.Title != "来自星星的你" {
		t.Fatalf("detail title = %q", drama.Title)
	}
	if len(chapters) != 2 {
		t.Fatalf("chapters = %d, want 2 (%+v)", len(chapters), chapters)
	}
	for index, chapter := range chapters {
		if chapter.Title == "" || chapter.PageURL == "" {
			t.Fatalf("chapter[%d] incomplete: %+v", index, chapter)
		}
	}

	// —— 播放解析 ——
	jsMedia, err := jsProvider.ResolveMedia(parityContext(server), Task{
		DramaID: "hanxiaoquan:5001",
		Chapter: Chapter{
			ID:      chapters[0].ID,
			PageURL: server.URL + "/play/5001-1-1.html",
			Source:  "hanxiaoquan",
		},
	})
	if err != nil {
		t.Fatal("extension resolve:", err)
	}
	if jsMedia.URL != server.URL+"/hxq/5001-1.m3u8" {
		t.Fatalf("resolve url mismatch: %q", jsMedia.URL)
	}
}

const soraniListPayload = `{"code":200,"data":{"records":[
{"id":9001,"title":"葬送的芙莉莲","summary":"魔法使的旅途。","cover":"https://img.example.test/9001.jpg","episodeCount":28,"categoryName":"TV动画","tags":["奇幻","冒险"],"year":"2023-09","actors":"种崎敦美"},
{"id":9002,"title":"铃芽之旅","summary":"关门之旅。","coverLarge":"//img.example.test/9002.jpg","totalEpisode":1,"category":"剧场版","area":"日本"}
],"total":30}}`

const soraniDetailPayload = `{"code":200,"data":{"id":9001,"title":"葬送的芙莉莲","summary":"魔法使的旅途。","cover":"https://img.example.test/9001.jpg","episodeCount":28,"categoryName":"TV动画","tags":["奇幻"],"episodes":[
{"episodeId":80002,"episodeOrder":2,"episodeLabel":"第2话"},
{"episodeId":80001,"episodeOrder":1,"episodeLabel":"第1话"},
{"episodeId":80003,"episodeOrder":3,"enabled":false,"episodeLabel":"预告"}
]}}`

const soraniPlayPayload = `{"code":200,"data":{"playUrl":"%PLAYLIST%"}}`

func soraniRouteBody(request *http.Request) string {
	switch {
	case request.URL.Path == "/video":
		return soraniListPayload
	case request.URL.Path == "/video/9001":
		return soraniDetailPayload
	case strings.HasPrefix(request.URL.Path, "/video/episode/"):
		return strings.ReplaceAll(soraniPlayPayload, "%PLAYLIST%", "http://"+request.Host+"/sorani/80001.m3u8")
	case request.URL.Path == "/sorani/80001.m3u8":
		return fixturePlaylist
	}
	return ""
}

// TestSoraniExtensionParity：纯 JSON API 源的 fixture 验收。
func TestSoraniExtensionParity(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(soraniRouteBody(r)))
	}))
	t.Cleanup(server.Close)
	forward := func(request *http.Request) (*http.Response, error) {
		return http.DefaultTransport.RoundTrip(request)
	}

	d := sourceFixtureDownloader(t, forward)
	d.cfg.SoraniURL = server.URL
	d.cfg.SoraniAPIURL = server.URL

	engine := sourceFixtureEngine(t, forward)
	engine.downloader.cfg.SoraniURL = server.URL
	engine.downloader.cfg.SoraniAPIURL = server.URL
	installTestExtension(t, engine, "sorani")
	provider, ok := engine.downloader.providers.get("sorani")
	if !ok {
		t.Fatal("sorani 扩展未注册")
	}
	jsProvider := provider.(*extensionProvider)
	ctx := parityContext(server)

	// —— 目录（total 翻页与字段归一）——
	items, more, err := jsProvider.CatalogPage(ctx, 1, "1", "")
	if err != nil {
		t.Fatal("extension catalog:", err)
	}
	if len(items) == 0 || !more {
		t.Fatalf("catalog shape = %d(%v), want non-empty(true)", len(items), more)
	}
	for index, item := range items {
		if item.ID == "" || item.Title == "" {
			t.Fatalf("catalog[%d] incomplete: %+v", index, item)
		}
	}

	// —— 详情（分集排序、enabled 过滤）——
	drama, chapters, err := jsProvider.Detail(ctx, "9001")
	if err != nil {
		t.Fatal("extension detail:", err)
	}
	if drama.Title == "" || len(chapters) == 0 {
		t.Fatalf("detail incomplete: %q / %d chapters", drama.Title, len(chapters))
	}
	for index := 1; index < len(chapters); index++ {
		previous, current := chapterEpisodeNumber(chapters[index-1], index), chapterEpisodeNumber(chapters[index], index+1)
		if current < previous {
			t.Fatalf("chapters not sorted: %d then %d", previous, current)
		}
	}

	// —— 播放解析（episodeId 换直链 + m3u8 预取）——
	jsMedia, err := jsProvider.ResolveMedia(parityContext(server), Task{
		DramaID: "sorani:9001",
		Chapter: Chapter{ID: chapters[0].ID, Source: "sorani"},
	})
	if err != nil {
		t.Fatal("extension resolve:", err)
	}
	if jsMedia.URL != server.URL+"/sorani/80001.m3u8" {
		t.Fatalf("resolve url mismatch: %q", jsMedia.URL)
	}
	if !strings.Contains(jsMedia.Playlist, "#EXTM3U") {
		t.Fatalf("resolve did not prefetch playlist: %q", jsMedia.Playlist)
	}
}

const huangjuDramasPayload = `{"items":[
{"id":"77","slug":"sample-drama","title":"剧果样本","description":"样本简介。","coverUrl":"https://img.example.test/hj77.jpg","totalEpisodes":2,"status":"completed","categories":[{"name":"热播"}],"region":"大陆","year":"2026","score":"8.5"},
{"id":"78","slug":"another-drama","title":"另一部","totalEpisodes":1,"status":"ongoing"}
],"page":1,"pageSize":20,"total":2}`

const huangjuDetailPayload = `{"id":"77","slug":"sample-drama","title":"剧果样本","description":"样本简介。","coverUrl":"https://img.example.test/hj77.jpg","totalEpisodes":2,"status":"completed","categories":[{"name":"热播"}],"region":"大陆","year":"2026","score":"8.5","episodes":[
{"id":"ep-2","epNo":2,"playable":true},
{"id":"ep-1","epNo":1},
{"id":"ep-3","epNo":3,"playable":false}
]}`

const huangjuPlayBody = `{"url":"%MEDIA%","expiresAt":4102444800}`

func huangjuRouteResponse(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/auth/guest":
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"token":"guest-token-fixture"}}`))
	case r.URL.Path == "/categories":
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`[{"slug":"romance","name":"甜宠"},{"slug":"hot","name":"热门"}]`))
	case r.URL.Path == "/dramas":
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(huangjuDramasPayload))
	case r.URL.Path == "/dramas/sample-drama-77":
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(huangjuDetailPayload))
	case strings.HasPrefix(r.URL.Path, "/play/"):
		w.Header().Set("Content-Type", "application/json")
		w.Header().Add("Set-Cookie", "CloudFront-Policy=policy-fixture; Path=/; Secure")
		w.Header().Add("Set-Cookie", "CloudFront-Signature=sig-fixture; Path=/; Secure")
		w.Header().Add("Set-Cookie", "CloudFront-Key-Pair-Id=key-fixture; Path=/; Secure")
		_, _ = w.Write([]byte(strings.ReplaceAll(huangjuPlayBody, "%MEDIA%", "http://"+r.Host+"/hj/media.m3u8")))
	case r.URL.Path == "/hj/media.m3u8":
		_, _ = w.Write([]byte(fixturePlaylist))
	default:
		http.NotFound(w, r)
	}
}

// TestHuangjuExtensionParity：带访客令牌与 CloudFront
// 签名凭证的 API 源 fixture 验收（凭证经 resolve 契约透传宿主）。
func TestHuangjuExtensionParity(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(huangjuRouteResponse))
	t.Cleanup(server.Close)
	forward := func(request *http.Request) (*http.Response, error) {
		return http.DefaultTransport.RoundTrip(request)
	}

	d := sourceFixtureDownloader(t, forward)
	d.cfg.HuangjuURL = server.URL
	d.cfg.HuangjuAPIURL = server.URL

	engine := sourceFixtureEngine(t, forward)
	engine.downloader.cfg.HuangjuURL = server.URL
	engine.downloader.cfg.HuangjuAPIURL = server.URL
	installTestExtension(t, engine, "huangju")
	provider, ok := engine.downloader.providers.get("huangju")
	if !ok {
		t.Fatal("huangju 扩展未注册")
	}
	jsProvider := provider.(*extensionProvider)
	ctx := parityContext(server)

	// —— 分类 ——
	categories, err := jsProvider.Categories(ctx, false)
	if err != nil {
		t.Fatal("extension categories:", err)
	}
	if len(categories) != 2 || categories[0].ID != "@new" || categories[1].ID != "romance" {
		t.Fatalf("categories = %+v, want [@new 最新, romance 甜宠]", categories)
	}

	// —— 目录 ——
	items, more, err := jsProvider.CatalogPage(ctx, 1, "", "")
	if err != nil {
		t.Fatal("extension catalog:", err)
	}
	if len(items) != 2 || more {
		t.Fatalf("catalog shape = %d(%v), want 2(false)", len(items), more)
	}
	for index, item := range items {
		if item.ID == "" || item.Title == "" {
			t.Fatalf("catalog[%d] incomplete: %+v", index, item)
		}
	}

	// —— 详情（slug-id 组合、playable 过滤）——
	drama, chapters, err := jsProvider.Detail(ctx, "sample-drama-77")
	if err != nil {
		t.Fatal("extension detail:", err)
	}
	if drama.SourceID != "sample-drama-77" || drama.Title == "" {
		t.Fatalf("detail meta mismatch: %+v", drama)
	}
	if len(chapters) == 0 || len(chapters) > 2 {
		t.Fatalf("chapters = %d, want 1..2 after playable filter: %+v", len(chapters), chapters)
	}
	for index, chapter := range chapters {
		if chapter.Title == "" {
			t.Fatalf("chapter[%d] missing title: %+v", index, chapter)
		}
	}

	// —— 播放解析：CloudFront 凭证透传 + 带 Cookie 的 m3u8 预取 ——
	jsMedia, err := jsProvider.ResolveMedia(parityContext(server), Task{
		DramaID: "huangju:sample-drama-77",
		Chapter: Chapter{ID: chapters[0].ID, Source: "huangju"},
	})
	if err != nil {
		t.Fatal("extension resolve:", err)
	}
	if jsMedia.URL != server.URL+"/hj/media.m3u8" {
		t.Fatalf("resolve url mismatch: %q", jsMedia.URL)
	}
	if !strings.Contains(jsMedia.Playlist, "#EXTM3U") {
		t.Fatalf("resolve did not prefetch playlist: %q", jsMedia.Playlist)
	}
	if jsMedia.credentials == nil || !strings.Contains(jsMedia.credentials.cookie, "CloudFront-Policy=policy-fixture") {
		t.Fatalf("credentials not carried: %+v", jsMedia.credentials)
	}
}

// —— 野果：配置发现 + 签名 + AES-CBC 解密链路 ——

func yeguoEntryScript(host string) string {
	return `
import { config, apiBaseURL } from "./chunks/config.js";
const baseURL=()=>"` + host + `"
export { baseURL };
`
}

const yeguoConfigScript = `
export const config = { version: 'v0', mode: 'CBC', padding: 'Pkcs7',
  key: '0123456789abcdef', iv: 'abcdef0123456789', sign_key: 'sign-key-fixture' };
`

func yeguoPageHTML(host string) string {
	return `<!doctype html><html><head>
<script type="module" src="/assets/entry.js"></script>
<script id="__NUXT_DATA__" type="application/json">[{"apiBaseURL":1},"` + host + `"]</script>
</head><body></body></html>`
}

func yeguoEncrypt(t *testing.T, plain string, key, iv []byte) string {
	t.Helper()
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	pad := aes.BlockSize - len(plain)%aes.BlockSize
	data := append([]byte(plain), bytes.Repeat([]byte{byte(pad)}, pad)...)
	out := make([]byte, len(data))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(out, data)
	return base64.StdEncoding.EncodeToString(out)
}

func yeguoSignedEnvelope(t *testing.T, payload map[string]any, signKey []byte) string {
	t.Helper()
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	var envelope map[string]any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(&envelope); err != nil {
		t.Fatal(err)
	}
	names := make([]string, 0, len(envelope))
	for name := range envelope {
		if name != "sign" && name != "_ver" {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	pieces := make([]string, 0, len(names))
	for _, name := range names {
		var field string
		switch value := envelope[name].(type) {
		case string:
			field = value
		case json.Number:
			field = value.String()
		case bool:
			field = strconv.FormatBool(value)
		}
		if name == "data" {
			field = strings.ReplaceAll(field, " ", "+")
		}
		pieces = append(pieces, name+"="+field)
	}
	digest := sha256.Sum256(append([]byte(strings.Join(pieces, "&")), signKey...))
	signature := md5.Sum([]byte(hex.EncodeToString(digest[:])))
	envelope["sign"] = hex.EncodeToString(signature[:])
	raw, err = json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func yeguoRouteResponse(t *testing.T, w http.ResponseWriter, r *http.Request) {
	key := []byte("0123456789abcdef")
	iv := []byte("abcdef0123456789")
	signKey := []byte("sign-key-fixture")
	respond := func(payload map[string]any, encrypted bool) {
		w.Header().Set("Content-Type", "application/json")
		if encrypted {
			raw, _ := json.Marshal(payload)
			payload = map[string]any{"status": "1", "data": yeguoEncrypt(t, string(raw), key, iv)}
		}
		_, _ = w.Write([]byte(yeguoSignedEnvelope(t, payload, signKey)))
	}
	switch {
	case r.URL.Path == "/":
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(yeguoPageHTML("http://" + r.Host)))
	case r.URL.Path == "/assets/entry.js":
		_, _ = w.Write([]byte(yeguoEntryScript("http://" + r.Host)))
	case r.URL.Path == "/assets/chunks/config.js":
		_, _ = w.Write([]byte(yeguoConfigScript))
	case r.URL.Path == "/api/home/contentOptions":
		respond(map[string]any{"video_filter": map[string]any{
			"theme": map[string]any{"list": []any{
				map[string]any{"value": "0", "name": "全部"},
				map[string]any{"value": "12", "name": "甜宠"},
			}},
			"time": map[string]any{"list": []any{
				map[string]any{"value": "3", "name": "2026"},
			}},
		}}, true)
	case r.URL.Path == "/api/theater/exploreList":
		respond(map[string]any{
			"list": []any{
				map[string]any{"video_id": "301", "title": "野果样本", "episode_count": "12",
					"serialize_status": "2", "tags": []any{"甜宠", "重生"}, "play_count_text": "3.4万",
					"published_at": "2026-09-23T10:20:30+08:00", "is_vip": "1",
					"cover": "https://img.example.test/yg301.jpg"},
			},
			"page": 1, "limit": 20, "total": 1, "has_more": "0",
		}, true)
	case r.URL.Path == "/api/playlet/detail":
		respond(map[string]any{
			"video_id": "301", "title": "野果样本", "episode_count": "12", "serialize_status": "2",
			"episodes": []any{
				map[string]any{"id": "901", "sort": "1", "title": "第1集"},
				map[string]any{"id": "902", "sort": "2"},
				map[string]any{"id": "903", "sort": "3", "is_adv": "1"},
			},
		}, true)
	case r.URL.Path == "/api/playlet/play":
		respond(map[string]any{
			"playlet_id": "301", "id": "901", "episode_sort": "1", "resolution": "1280x720",
			"video_url":      "http://" + r.Host + "/yg/301-1.m3u8",
			"video_url_h265": "http://" + r.Host + "/yg/301-1-h265.m3u8",
		}, true)
	case r.URL.Path == "/yg/301-1.m3u8":
		_, _ = w.Write([]byte(fixturePlaylist))
	default:
		http.NotFound(w, r)
	}
}

// TestYeguoExtensionParity：野果的配置发现、签名校验与
// AES-CBC 解密链路在 JS 与 Go 两侧一致。
func TestYeguoExtensionParity(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		yeguoRouteResponse(t, w, r)
	}))
	t.Cleanup(server.Close)
	forward := func(request *http.Request) (*http.Response, error) {
		return http.DefaultTransport.RoundTrip(request)
	}

	d := sourceFixtureDownloader(t, forward)
	d.cfg.YeguoURL = server.URL
	d.cfg.YeguoAPIURL = ""

	engine := sourceFixtureEngine(t, forward)
	engine.downloader.cfg.YeguoURL = server.URL
	engine.downloader.cfg.YeguoAPIURL = ""
	installTestExtension(t, engine, "yeguo")
	provider, ok := engine.downloader.providers.get("yeguo")
	if !ok {
		t.Fatal("yeguo 扩展未注册")
	}
	jsProvider := provider.(*extensionProvider)
	ctx := parityContext(server)

	// —— 分类（含加密响应解码）：断言 fixture 定义的分类集合 ——
	// 分类/目录以 fixture 期望值断言，字段映射由后续详情/解析断言覆盖。
	jsCategories, err := jsProvider.Categories(ctx, false)
	if err != nil {
		t.Fatal("extension categories:", err)
	}
	wantCategories := []nativeCategory{{ID: "theme:12", Name: "甜宠"}, {ID: "time:3", Name: "2026"}}
	if len(jsCategories) != len(wantCategories) {
		t.Fatalf("categories mismatch: js=%v want=%v", jsCategories, wantCategories)
	}
	for index := range wantCategories {
		if jsCategories[index].ID != wantCategories[index].ID || jsCategories[index].Name != wantCategories[index].Name {
			t.Fatalf("categories[%d] mismatch: %+v vs %+v", index, jsCategories[index], wantCategories[index])
		}
	}

	// —— 目录 ——
	jsItems, jsMore, err := jsProvider.CatalogPage(ctx, 1, "theme:12", "")
	if err != nil {
		t.Fatal("extension catalog:", err)
	}
	if len(jsItems) != 1 || jsItems[0].ID != "yeguo:301" || jsItems[0].Title != "野果样本" {
		t.Fatalf("catalog mismatch: %+v", jsItems)
	}
	if jsMore {
		t.Fatal("catalog hasMore should be false from has_more=0")
	}
	if jsItems[0].ReleaseStatus != "finished" || jsItems[0].OnlineDate != "2026-09-23" {
		t.Fatalf("catalog metadata mismatch: %+v", jsItems[0])
	}
	if len(jsItems[0].Tags) != 2 || jsItems[0].Tags[0] != "甜宠" || jsItems[0].Tags[1] != "重生" {
		t.Fatalf("catalog tags mismatch: %v", jsItems[0].Tags)
	}
	if jsItems[0].VIP == nil || !*jsItems[0].VIP {
		t.Fatal("catalog vip flag mismatch")
	}

	// —— 详情（广告集过滤、编号排序）——
	jsDrama, jsChapters, err := jsProvider.Detail(ctx, "301")
	if err != nil {
		t.Fatal("extension detail:", err)
	}
	if jsDrama.Title != "野果样本" || jsDrama.SourceID != "301" {
		t.Fatalf("detail meta mismatch: %+v", jsDrama)
	}
	if len(jsChapters) != 2 {
		t.Fatalf("advertisement episode not filtered: %+v", jsChapters)
	}
	if jsChapters[0].Title != "第1集" || jsChapters[1].Title != "第 2 集" {
		t.Fatalf("chapters mismatch: %+v", jsChapters)
	}

	// —— 播放解析（H.264 优先 + 清晰度 + 预取）——
	jsMedia, err := jsProvider.ResolveMedia(parityContext(server), Task{
		DramaID: "yeguo:301",
		Chapter: Chapter{ID: jsChapters[0].ID, Source: "yeguo"},
	})
	if err != nil {
		t.Fatal("extension resolve:", err)
	}
	if jsMedia.URL != server.URL+"/yg/301-1.m3u8" || jsMedia.Quality != 720 {
		t.Fatalf("resolve mismatch: url=%q quality=%d", jsMedia.URL, jsMedia.Quality)
	}
	if !strings.Contains(jsMedia.Playlist, "#EXTM3U") {
		t.Fatalf("resolve did not prefetch playlist: %q", jsMedia.Playlist)
	}
}

// —— 帝果（HTML 站 + aaencode 播放签名）——

const dsdHomePage = `<!doctype html><html><body>
<a href="/index.php/vod/type/id/9.html">都市</a>
<a href="/index.php/vod/type/id/11.html">古装</a>
</body></html>`

const dsdCatalogPage1 = `<!doctype html><html><body>
<main class="lists">
<a class="video-item" href="/index.php/vod/play/id/456/sid/1/nid/1.html" title="帝果样本">
<img data-src="/upload/vod/20260101-1/fixture.jpg">
<span class="video-desc">帝果样本</span>
<span class="video-item-tag-hits">1234次</span>
<span class="video-item-tag-is-vip"></span>
</a>
<a class="video-item" href="/index.php/vod/play/id/457/sid/1/nid/1.html">
<span class="video-title">免费样本</span>
<img data-original="/upload/vod/20260101-2/fixture.jpg">
</a>
</main>
<div class="el-pagination"><span class="number active">1</span><a href="/index.php/vod/type/id/9/page/2.html">2</a></div>
</body></html>`

const dsdCatalogPage2 = `<!doctype html><html><body>
<main class="lists">
<a class="video-item" href="/index.php/vod/play/id/458/sid/1/nid/1.html"><span class="video-title">第二页样本</span></a>
</main>
<div class="el-pagination"><span class="number active">2</span></div>
</body></html>`

// dsdDetailPage 的播放器参数以 player_xxx = {...} 形式出现，并带 link_pre/link_next。
const dsdDetailPage = `<!doctype html><html><body>
<div class="video-info"><h1>帝果样本</h1><div class="desc">帝果样本简介</div>
<div class="labels"><a>都市</a><a>逆袭</a></div>
<div class="btn-favs" data-id="456"></div>
</div>
<div class="video-box"><div class="img-bg" style="background-image:url('/upload/vod/20260101-1/1.jpg')"></div></div>
<script type="text/javascript">
var player_fixture = {"id":"456","sid":1,"nid":3,"url":"%MEDIA%","encrypt":"0","poster":"/upload/vod/20260101-1/1.jpg","link_pre":"/index.php/vod/play/id/456/sid/1/nid/2.html","link_next":"/index.php/vod/play/id/456/sid/1/nid/4.html","vod_data":{"vod_name":"帝果样本","vod_class":"都市,逆袭"}};
</script>
</body></html>`

const dsdEpisodePageTemplate = `<!doctype html><html><body>
<div class="video-box"></div>
<script type="text/javascript">
var player_fixture = {"id":"456","sid":1,"nid":%EPISODE%,"url":"%MEDIA%","encrypt":"0","vod_data":{"vod_name":"帝果样本"}};
</script>
</body></html>`

// dsdVplayerPage 是 vplayer 签名页：aaencode 段解出 var vPath = "...sign=..."。
func dsdVplayerBody(signedPath string) string {
	encode := func(octal string) string {
		parts := make([]string, 0, len(octal))
		for _, digit := range octal {
			switch digit {
			case '0':
				parts = append(parts, "(c^_^o)")
			case '1':
				parts = append(parts, "(ﾟΘﾟ)")
			case '3':
				parts = append(parts, "(o^_^o)")
			case '4':
				parts = append(parts, "(ﾟｰﾟ)")
			default:
				parts = append(parts, string(digit))
			}
		}
		return "(ﾟДﾟ)[ﾟεﾟ]+" + strings.Join(parts, "+")
	}
	payload := `var vPath = "` + signedPath + `";`
	encoded := "(ﾟДﾟ) ['_'] ( (ﾟДﾟ) ['_']"
	for _, char := range payload {
		encoded += encode(strconv.FormatInt(int64(char), 8))
	}
	encoded += "+ (ﾟДﾟ)[ﾟoﾟ]"
	return `<html><body><script type="text/javascript">` + encoded + `</script></body></html>`
}

func dsdRouteResponse(w http.ResponseWriter, r *http.Request) {
	media := "https://" + r.Host + "/dsd/video/456/1000k/index.m3u8"
	switch {
	case r.URL.Path == "/":
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(dsdHomePage))
	case strings.HasPrefix(r.URL.Path, "/index.php/vod/type/id/"):
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if strings.Contains(r.URL.Path, "/page/2.") {
			_, _ = w.Write([]byte(dsdCatalogPage2))
			return
		}
		_, _ = w.Write([]byte(dsdCatalogPage1))
	case strings.HasPrefix(r.URL.Path, "/index.php/vod/play/id/456/"):
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if strings.Contains(r.URL.Path, "nid/1.html") {
			_, _ = w.Write([]byte(strings.ReplaceAll(dsdDetailPage, "%MEDIA%", media)))
			return
		}
		episode := "2"
		if strings.Contains(r.URL.Path, "nid/3.html") {
			episode = "3"
		}
		_, _ = w.Write([]byte(strings.ReplaceAll(strings.ReplaceAll(dsdEpisodePageTemplate, "%EPISODE%", episode), "%MEDIA%", media)))
	case r.URL.Path == "/addons/vplayer/":
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(dsdVplayerBody("/dsd/video/456/1000k/index.m3u8?sign=fixture-sign")))
	case strings.HasPrefix(r.URL.Path, "/dsd/video/456/"):
		_, _ = w.Write([]byte(fixturePlaylist))
	case strings.HasPrefix(r.URL.Path, "/upload/"):
		w.Header().Set("Content-Type", "image/jpeg")
		_, _ = w.Write([]byte("fixture-image"))
	default:
		http.NotFound(w, r)
	}
}

// TestDSDExtensionParity：HTML 站 + 多线路分集 + aaencode 签名对拍。
func TestDSDExtensionParity(t *testing.T) {
	// 帝果的 resolveProviderURL 会把 http 升级成 https，fixture 必须走 TLS。
	server := httptest.NewTLSServer(http.HandlerFunc(dsdRouteResponse))
	t.Cleanup(server.Close)
	forward := func(request *http.Request) (*http.Response, error) {
		return server.Client().Transport.RoundTrip(request)
	}

	engine := sourceFixtureEngine(t, forward)
	installTestExtension(t, engine, "dsd")
	provider, ok := engine.downloader.providers.get("dsd")
	if !ok {
		t.Fatal("dsd 扩展未注册")
	}
	jsProvider, isExtension := provider.(*extensionProvider)
	if !isExtension {
		t.Fatal("dsd provider 不是扩展实现")
	}
	ctx := parityContext(server)

	// —— 分类 ——
	categories, err := jsProvider.Categories(ctx, true)
	if err != nil {
		t.Fatal("extension categories:", err)
	}
	if len(categories) != 2 || categories[0].ID != "9" || categories[0].Name != "都市" {
		t.Fatalf("categories = %+v, want [9 都市, 11 古装]", categories)
	}

	// —— 分类目录 ——
	items, more, err := jsProvider.CatalogPage(ctx, 1, "9", "")
	if err != nil {
		t.Fatal("extension catalog:", err)
	}
	if len(items) != 2 || !more {
		t.Fatalf("catalog shape = %d(%v), want 2(true)", len(items), more)
	}
	first := nativeNormalize(items[0])
	if first.ID != "dsd:456" || first.Title != "帝果样本" {
		t.Fatalf("catalog[0] = %+v", first)
	}
	if first.Views != "1234" || first.Cover == "" || first.VIP == nil {
		t.Fatalf("catalog[0] views/cover/vip = %q/%q/%v", first.Views, first.Cover, first.VIP)
	}

	// —— 详情（多线路分集、link_pre/link_next、排序）——
	drama, chapters, err := jsProvider.Detail(ctx, "456")
	if err != nil {
		t.Fatal("extension detail:", err)
	}
	if drama.Title != "帝果样本" || len(chapters) != 3 {
		t.Fatalf("detail = %q with %d chapters, want 帝果样本/3", drama.Title, len(chapters))
	}
	if len(drama.Tags) != 2 {
		t.Fatalf("detail tags = %v, want 2", drama.Tags)
	}
	for index := 1; index < len(chapters); index++ {
		previous := chapterEpisodeNumber(chapters[index-1], index)
		current := chapterEpisodeNumber(chapters[index], index+1)
		if current < previous {
			t.Fatalf("chapters not sorted: %d then %d", previous, current)
		}
	}

	// —— 播放解析（vplayer 签名）——
	jsMedia, err := jsProvider.ResolveMedia(ctx, Task{DramaID: "dsd:456", Chapter: chapters[0], Index: 1})
	if err != nil {
		t.Fatal("extension resolve:", err)
	}
	if jsMedia.URL != server.URL+"/dsd/video/456/1000k/index.m3u8?sign=fixture-sign" {
		t.Fatalf("resolve url = %q", jsMedia.URL)
	}
	if jsMedia.Referer != server.URL+"/addons/vplayer/" {
		t.Fatalf("resolve referer = %q", jsMedia.Referer)
	}
	if !strings.Contains(jsMedia.Playlist, "#EXTM3U") {
		t.Fatalf("resolve did not prefetch playlist: %q", jsMedia.Playlist)
	}
}

// —— 黄果系（视频 / AI / 旧版）——

const huangguoVideoListPage = `<!doctype html><html><body>
<nav><a href="/videos?category=2">都市</a><a href="/videos?category=5">悬疑</a></nav>
<article class="video-card"><a href="/series/abc123"><img data-src="/img/abc123.jpg"><span class="bg-black/55">更新至 12 集</span></a></article>
<article class="video-card"><a href="/video/def456"><img src="/img/def456.jpg"></a></article>
</body></html>`

const huangguoVideoDetailPage = `<!doctype html><html><head>
<meta property="og:title" content="黄果系列剧样本">
<meta property="og:image" content="/img/abc123.jpg">
<meta name="description" content="黄果系列剧简介">
</head><body>
<h1 class="hg-web-detail__title">黄果系列剧样本</h1>
<span class="hg-tag">都市</span><span class="hg-tag">逆袭</span>
<article class="video-card" data-hls="%MEDIA1%"><a href="/video/abc123-ep1">第1集</a></article>
<article class="video-card" data-hls="%MEDIA2%"><a href="/video/abc123-ep2">第2集</a></article>
</body></html>`

const huangguoAIListPayload = `{"code":0,"data":{"list":[
{"id":"ai-sample-1","title":"AI 样本一","cover":"/img/ai1.jpg","totalEpisode":8,"is_finished":"0","view_count":"1.2万"},
{"id":"ai-sample-2","title":"AI 样本二","cover":"/img/ai2.jpg","totalEpisode":6,"score":"8.6"}
]}}`

const huangguoAIDetailPage = `<!doctype html><html><head>
<meta property="og:title" content="AI 样本一"><meta property="og:image" content="/img/ai1.jpg">
</head><body>
<h1>AI 样本一</h1><span class="hg-tag">AI 换脸</span>
<a href="/video/ai-sample-1/ep-1" title="第1集">第1集</a>
<a href="/video/ai-sample-1/ep-2" title="第2集">第2集</a>
</body></html>`

const huangguoAIEpisodePage = `<!doctype html><html><body>
<script id="videoInitialData" type="application/json">{"videoSrc":"%MEDIA%","ep":"1"}</script>
</body></html>`

const huangguoRankPage = `<html><head><script type="application/ld+json">
{"@graph":[{"@type":"BreadcrumbList","itemListElement":[]},
{"@type":"ItemList","@id":"https://huangguoai.com/ranks/potential/#itemlist","itemListElement":[
{"position":1,"name":"榜单样本一","url":"https://huangguoai.com/detail/rank-1/"},
{"position":2,"name":"榜单样本二","url":"https://huangguoai.com/detail/rank-2/"}]}]}
</script></head><body></body></html>`

func huangguoRouteResponse(w http.ResponseWriter, r *http.Request) {
	media1 := "https://" + r.Host + "/hg/abc123-ep1.m3u8"
	media2 := "https://" + r.Host + "/hg/abc123-ep2.m3u8"
	switch {
	case r.URL.Path == "/videos":
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(huangguoVideoListPage))
	case r.URL.Path == "/series/abc123":
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		page := strings.ReplaceAll(huangguoVideoDetailPage, "%MEDIA1%", media1)
		page = strings.ReplaceAll(page, "%MEDIA2%", media2)
		_, _ = w.Write([]byte(page))
	case strings.HasPrefix(r.URL.Path, "/api/videos/category/"):
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(huangguoAIListPayload))
	case r.URL.Path == "/detail/ai-sample-1/":
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(huangguoAIDetailPage))
	case r.URL.Path == "/video/ai-sample-1/ep-1":
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		page := strings.ReplaceAll(huangguoAIEpisodePage, "%MEDIA%", "https://"+r.Host+"/hg/ai-ep1.m3u8")
		_, _ = w.Write([]byte(page))
	case strings.HasPrefix(r.URL.Path, "/ranks/"):
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(huangguoRankPage))
	case strings.HasPrefix(r.URL.Path, "/hg/"), strings.HasPrefix(r.URL.Path, "/img/"):
		if strings.HasSuffix(r.URL.Path, ".m3u8") {
			_, _ = w.Write([]byte(fixturePlaylist))
			return
		}
		w.Header().Set("Content-Type", "image/jpeg")
		_, _ = w.Write([]byte("fixture-image"))
	default:
		http.NotFound(w, r)
	}
}

// TestHuangguoVideoExtensionParity：HTML 卡片目录 + data-hls 分集对拍。
func TestHuangguoVideoExtensionParity(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(huangguoRouteResponse))
	t.Cleanup(server.Close)
	forward := server.Client().Transport.RoundTrip

	engine := sourceFixtureEngine(t, forward)
	installTestExtension(t, engine, "huangguo-video")
	provider, ok := engine.downloader.providers.get("huangguo-video")
	if !ok {
		t.Fatal("huangguo-video 扩展未注册")
	}
	jsProvider, isExtension := provider.(*extensionProvider)
	if !isExtension {
		t.Fatal("huangguo-video provider 不是扩展实现")
	}
	ctx := parityContext(server)

	// 目录：HTML 卡片解析，series/video 两种路径都保留。
	items, more, err := jsProvider.CatalogPage(ctx, 1, "", "")
	if err != nil {
		t.Fatal("extension catalog:", err)
	}
	if len(items) != 2 || more {
		t.Fatalf("catalog shape = %d(%v), want 2(false)", len(items), more)
	}
	if items[0].SourceID != "series/abc123" || items[0].Remark != "更新至 12 集" {
		t.Fatalf("catalog[0] = %+v", items[0])
	}

	// 详情：分集从 data-hls 读取。
	drama, chapters, err := jsProvider.Detail(ctx, "series/abc123")
	if err != nil {
		t.Fatal("extension detail:", err)
	}
	if len(chapters) != 2 {
		t.Fatalf("chapters = %d, want 2: %+v", len(chapters), chapters)
	}
	if drama.Title != "黄果系列剧样本" {
		t.Fatalf("detail title = %q", drama.Title)
	}
	for index, chapter := range chapters {
		if chapter.VideoURL == "" {
			t.Fatalf("chapter[%d] missing data-hls media: %+v", index, chapter)
		}
	}

	// 播放解析：章节已带 videoUrl，直接使用。
	jsMedia, err := jsProvider.ResolveMedia(ctx, Task{DramaID: "huangguo-video:series/abc123", Chapter: chapters[0], Index: 1})
	if err != nil {
		t.Fatal("extension resolve:", err)
	}
	if jsMedia.URL != chapters[0].VideoURL {
		t.Fatalf("resolve reused chapter media: %q vs %q", jsMedia.URL, chapters[0].VideoURL)
	}
	if !strings.Contains(jsMedia.Playlist, "#EXTM3U") {
		t.Fatalf("resolve did not prefetch playlist")
	}
}

// TestHuangguoAIExtensionParity：JSON 目录 + videoInitialData 分集对拍。
func TestHuangguoAIExtensionParity(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(huangguoRouteResponse))
	t.Cleanup(server.Close)
	forward := server.Client().Transport.RoundTrip

	engine := sourceFixtureEngine(t, forward)
	installTestExtension(t, engine, "huangguoai")
	provider, ok := engine.downloader.providers.get("huangguoai")
	if !ok {
		t.Fatal("huangguoai 扩展未注册")
	}
	jsProvider, isExtension := provider.(*extensionProvider)
	if !isExtension {
		t.Fatal("huangguoai provider 不是扩展实现")
	}
	ctx := parityContext(server)

	// 分类：静态分类表（4 个 AI 分类）。
	categories, err := jsProvider.Categories(ctx, false)
	if err != nil {
		t.Fatal("extension categories:", err)
	}
	want := []nativeCategory{
		{ID: "ai-duanju", Name: "AI 短剧"},
		{ID: "ai-manju", Name: "AI 漫剧"},
		{ID: "ai-huanlian", Name: "AI 换脸"},
		{ID: "ai-mogai", Name: "AI 魔改"},
	}
	if len(categories) != len(want) {
		t.Fatalf("categories = %+v, want %+v", categories, want)
	}
	for index := range want {
		if categories[index].ID != want[index].ID || categories[index].Name != want[index].Name {
			t.Fatalf("categories[%d] = %+v, want %+v", index, categories[index], want[index])
		}
	}

	// 目录：指定单一分类时只拉一路。
	jsItems, _, err := jsProvider.CatalogPage(ctx, 1, "ai-duanju", "")
	if err != nil {
		t.Fatal("extension catalog:", err)
	}
	if len(jsItems) != 2 {
		t.Fatalf("catalog items = %d, want 2: %+v", len(jsItems), jsItems)
	}
	normalized := nativeNormalize(jsItems[0])
	if normalized.ID != "huangguoai:ai-sample-1" || normalized.Title != "AI 样本一" || normalized.Episodes != 8 {
		t.Fatalf("catalog row mismatch: %+v", normalized)
	}
	if !strings.Contains(normalized.Heat+normalized.Views, "1.2万") {
		t.Fatalf("views not normalized: heat=%q views=%q", normalized.Heat, normalized.Views)
	}

	// 详情：分集来自 /video/{id}/ep-N 链接。
	jsDrama, jsChapters, err := jsProvider.Detail(ctx, "ai-sample-1")
	if err != nil {
		t.Fatal("extension detail:", err)
	}
	if len(jsChapters) != 2 {
		t.Fatalf("chapters = %d, want 2: %+v", len(jsChapters), jsChapters)
	}
	if jsDrama.Title != "AI 样本一" || len(jsDrama.Tags) != 1 {
		t.Fatalf("detail meta mismatch: %+v", jsDrama)
	}

	// 播放解析：从 videoInitialData 读取地址。
	jsMedia, err := jsProvider.ResolveMedia(ctx, Task{DramaID: "huangguoai:ai-sample-1", Chapter: jsChapters[0], Index: 1})
	if err != nil {
		t.Fatal("extension resolve:", err)
	}
	if !strings.HasSuffix(jsMedia.URL, "/hg/ai-ep1.m3u8") {
		t.Fatalf("resolve url = %q", jsMedia.URL)
	}
}

// —— 黄果旧版（加密 API）——

// fixtureLegacyProtocol 是与扩展测试共用的接口参数（真实站点由官网脚本下发）。
var fixtureLegacyProtocol = struct {
	InterfaceKey string
	ParamKey     string
	ParamIV      string
}{"fixture-interface", "0123456789abcdef", "fedcba9876543210"}

// legacyEncryptResponse 生成 hash=true 的加密响应，供 JS 侧解密对拍。
func legacyEncryptResponse(interfaceKey, paramKey, paramIV string, payload any) (string, error) {
	plain, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	// 12 字节随机 IV 前缀 + 派生密钥加密（Go decryptResponse 的逆运算）。
	iv := make([]byte, 12)
	for index := range iv {
		iv[index] = byte(index*7 + 3)
	}
	key := []byte(interfaceKey)
	r := append(append([]byte{}, key...), iv...)
	l := len(r) >> 1
	sSum := sha256.Sum256(r)
	s := sSum[8:24]
	c := append(append([]byte{}, s...), r[:l]...)
	a := append(append([]byte{}, r[l:]...), s...)
	dSum := sha256.Sum256(c)
	fSum := sha256.Sum256(a)
	d, f := dSum[:], fSum[:]
	m := append(append(append([]byte{}, d[:8]...), f[8:24]...), d[24:]...)
	p := append(append(append([]byte{}, f[:4]...), d[12:20]...), f[28:]...)
	block, err := aes.NewCipher(m)
	if err != nil {
		return "", err
	}
	padded := pkcs7Pad(plain, block.BlockSize())
	out := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, p).CryptBlocks(out, padded)
	return base64.StdEncoding.EncodeToString(append(iv, out...)), nil
}

func legacyParityResponse(w http.ResponseWriter, r *http.Request, payload any, encrypt bool) {
	if !encrypt {
		body, _ := json.Marshal(map[string]any{"code": 200, "hash": false, "data": payload})
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
		return
	}
	encrypted, err := legacyEncryptResponse(fixtureLegacyProtocol.InterfaceKey, fixtureLegacyProtocol.ParamKey, fixtureLegacyProtocol.ParamIV, payload)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	body, _ := json.Marshal(map[string]any{"code": 200, "hash": true, "data": encrypted})
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(body)
}

// TestCloudFrontExtensionParity：加密请求参数 + 加密响应对拍。
func TestCloudFrontExtensionParity(t *testing.T) {
	var sawEncryptedParam atomic.Bool
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/":
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = w.Write([]byte(`<script src="/js/main-fixture.js"></script>`))
		case "/js/main-fixture.js":
			_, _ = w.Write([]byte(`t(F,"interfaceKey","` + fixtureLegacyProtocol.InterfaceKey +
				`");t(F,"parameterKey","` + fixtureLegacyProtocol.ParamKey +
				`");t(F,"parameterIv","` + fixtureLegacyProtocol.ParamIV + `")`))
		case "/api/app/mine/login/h5":
			var body struct {
				Data string `json:"data"`
			}
			if json.NewDecoder(r.Body).Decode(&body) != nil || body.Data == "" {
				http.Error(w, "encrypted login required", http.StatusBadRequest)
				return
			}
			sawEncryptedParam.Store(true)
			legacyParityResponse(w, r, map[string]string{"token": "parity-session"}, false)
		case "/api/app/playlet-tab/all":
			if r.Header.Get("Authorization") != "parity-session" {
				http.Error(w, "missing session", http.StatusUnauthorized)
				return
			}
			legacyParityResponse(w, r, map[string]any{"list": []map[string]string{{"id": "tab-1", "name": "当前分类"}}}, true)
		case "/api/app/playlet/home/tab/tab-1":
			if r.URL.Query().Get("data") == "" {
				http.Error(w, "params must be encrypted", http.StatusBadRequest)
				return
			}
			sawEncryptedParam.Store(true)
			legacyParityResponse(w, r, map[string]any{"list": []map[string]any{
				{"id": "drama-a", "title": "旧版样本", "totalEpisode": 3, "cover": "/upload/cover.jpg"},
			}}, true)
		case "/api/app/playlet/detail/drama-a":
			legacyParityResponse(w, r, map[string]any{
				"title":    "旧版样本",
				"chapters": []map[string]any{{"id": "ep-1", "videoUrl": "opaque-video-id"}, {"id": "ep-2", "videoUrl": "opaque-video-id-2"}},
			}, true)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	forward := server.Client().Transport.RoundTrip

	engine := sourceFixtureEngine(t, forward)
	installTestExtension(t, engine, "cloudfront")
	provider, ok := engine.downloader.providers.get("cloudfront")
	if !ok {
		t.Fatal("cloudfront 扩展未注册")
	}
	jsProvider, isExtension := provider.(*extensionProvider)
	if !isExtension {
		t.Fatal("cloudfront provider 不是扩展实现")
	}
	// 扩展从 hg.storage 读协议缓存；测试直接注入避免依赖官网脚本发现。
	ctx := parityContext(server)

	// —— 分类（解密响应）——
	categories, err := jsProvider.Categories(ctx, false)
	if err != nil {
		t.Fatal("extension categories:", err)
	}
	if len(categories) != 1 || categories[0].ID != "tab-1" || categories[0].Name != "当前分类" {
		t.Fatalf("categories = %+v, want [tab-1 当前分类]", categories)
	}

	// —— 目录（加密请求参数 + 解密响应）——
	items, _, err := jsProvider.CatalogPage(ctx, 1, "", "")
	if err != nil {
		t.Fatal("extension catalog:", err)
	}
	if len(items) != 1 {
		t.Fatalf("catalog = %d rows, want 1", len(items))
	}
	entry := nativeNormalize(items[0])
	if entry.ID != "cloudfront:drama-a" || entry.Title != "旧版样本" || entry.Episodes != 3 {
		t.Fatalf("catalog row = %+v", entry)
	}
	if entry.Cover == "" {
		t.Fatal("catalog row lost its cover")
	}

	// —— 详情（分集与 episode 编号）——
	detail, chapters, err := jsProvider.Detail(ctx, "drama-a")
	if err != nil {
		t.Fatal("extension detail:", err)
	}
	if len(chapters) != 2 {
		t.Fatalf("chapters = %d, want 2: %+v", len(chapters), chapters)
	}
	if detail.Title != "旧版样本" {
		t.Fatalf("detail title = %q", detail.Title)
	}
	for index, chapter := range chapters {
		if chapter.EpisodeString(index+1) != strconv.Itoa(index+1) {
			t.Fatalf("chapter[%d] episode = %q", index, chapter.EpisodeString(index+1))
		}
		if chapter.Title != "第"+strconv.Itoa(index+1)+"集" {
			t.Fatalf("chapter[%d] title = %q", index, chapter.Title)
		}
	}

	if !sawEncryptedParam.Load() {
		t.Fatal("fixture never received an encrypted request parameter")
	}
}

// —— 黄豆（设备签名 + gzip + AES 四层协议）——

// decodeHuangdouRequest 校验并解开黄豆的请求体，返回业务 data。
func decodeHuangdouRequest(t *testing.T, r *http.Request) map[string]any {
	t.Helper()
	blob, err := io.ReadAll(r.Body)
	if err != nil {
		t.Error(err)
		return nil
	}
	if len(blob) < 32 {
		t.Errorf("request body too short: %d", len(blob))
		return nil
	}
	requestID := r.Header.Get("requestId")
	hexID := strings.ReplaceAll(requestID, "-", "")
	rawID, err := hex.DecodeString(hexID)
	if err != nil || len(rawID) != 16 {
		t.Errorf("bad requestId %q", requestID)
		return nil
	}
	mac := hmac.New(sha256.New, []byte(huangdouPlatformKey))
	mac.Write(rawID)
	key := mac.Sum(nil)
	iv, cipherText := blob[:16], blob[16:]
	plain, err := aesCBCDecrypt(cipherText, key, iv)
	if err != nil {
		t.Errorf("decrypt request: %v", err)
		return nil
	}
	if len(plain) >= 2 && plain[0] == 0x1f && plain[1] == 0x8b {
		reader, err := gzip.NewReader(bytes.NewReader(plain))
		if err != nil {
			t.Errorf("gzip request: %v", err)
			return nil
		}
		plain, _ = io.ReadAll(reader)
		_ = reader.Close()
	}
	var envelope struct {
		Token    string         `json:"token"`
		DeviceID string         `json:"deviceId"`
		Data     map[string]any `json:"data"`
	}
	if err := json.Unmarshal(plain, &envelope); err != nil {
		t.Errorf("request json: %v (%s)", err, plain)
		return nil
	}
	// 签名校验：sha256("Dart|sessionId|requestId|time|path")-time
	path := strings.TrimPrefix(r.URL.Path, "/api")
	timestamp := r.Header.Get("time")
	expected := sha256.Sum256([]byte("Dart|" + r.Header.Get("sessionId") + "|" + requestID + "|" + timestamp + "|" + path))
	if r.Header.Get("sign") != hex.EncodeToString(expected[:])+"-"+timestamp {
		t.Errorf("signature mismatch for %s", path)
	}
	return envelope.Data
}

// encodeHuangdouResponse 生成加密响应（IV + AES-CBC(gzip(JSON))）。
func encodeHuangdouResponse(request *http.Request, payload any) []byte {
	requestID := request.Header.Get("requestId")
	rawID, _ := hex.DecodeString(strings.ReplaceAll(requestID, "-", ""))
	mac := hmac.New(sha256.New, []byte(huangdouPlatformKey))
	mac.Write(rawID)
	key := mac.Sum(nil)
	plain, _ := json.Marshal(payload)
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	_, _ = writer.Write(plain)
	_ = writer.Close()
	iv := []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	cipherText, _ := aesCBCEncrypt(compressed.Bytes(), key, iv)
	return append(append([]byte{}, iv...), cipherText...)
}

func huangdouParityServer(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/hd/media.m3u8" {
			_, _ = w.Write([]byte(fixturePlaylist))
			return
		}
		if r.Method != http.MethodPost || !strings.HasPrefix(r.URL.Path, "/api/") {
			http.NotFound(w, r)
			return
		}
		data := decodeHuangdouRequest(t, r)
		if data == nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		switch strings.TrimPrefix(r.URL.Path, "/api") {
		case "/drama/list":
			_, _ = w.Write(encodeHuangdouResponse(r, map[string]any{"data": map[string]any{"list": []map[string]any{
				{"id": "rp_drama-1", "name": "黄豆样本一", "episode_count": "3", "img_y": "/cover/1.jpg", "is_vip": "1", "hot_rate": "98", "click": "1200", "update_label": "全3集"},
				{"id": "rp_drama-2", "name": "黄豆样本二", "episode_count": "2", "is_vip": "0", "pay_type": "free"},
			}}}))
		case "/drama/detail":
			from := strings.TrimPrefix(fmt.Sprint(data["id"]), "rp_")
			_, _ = w.Write(encodeHuangdouResponse(r, map[string]any{"data": map[string]any{
				"id": "rp_" + from, "name": "黄豆样本一", "episode_count": "3",
				"pay_type": "vip", "free_episodes": "1", "vip_episodes": []any{2, 3},
				"episodes": []map[string]any{
					{"seq": "1", "name": "第1集"},
					{"seq": "3", "name": "第3集"},
					{"seq": "2", "name": "第2集", "type": "vip"},
				},
			}}))
		case "/drama/play":
			media := "https://" + r.Host + "/hd/media.m3u8"
			_, _ = w.Write(encodeHuangdouResponse(r, map[string]any{"data": map[string]any{
				"m3u8": media, "hls_key": "00112233445566778899aabbccddeeff", "duration": "125.5",
			}}))
		case "/drama/rank":
			_, _ = w.Write(encodeHuangdouResponse(r, map[string]any{"data": map[string]any{"list": []map[string]any{
				{"id": "rp_drama-1", "name": "黄豆样本一", "hot_rate": "98"},
			}}}))
		default:
			http.NotFound(w, r)
		}
	}))
}

// TestHuangdouExtensionParity：四层协议（签名 + gzip + AES + 解密）对拍。
func TestHuangdouExtensionParity(t *testing.T) {
	server := huangdouParityServer(t)
	t.Cleanup(server.Close)
	forward := server.Client().Transport.RoundTrip

	d := sourceFixtureDownloader(t, forward)
	d.cfg.HuangdouURL = server.URL

	engine := sourceFixtureEngine(t, forward)
	engine.downloader.cfg.HuangdouURL = server.URL
	installTestExtension(t, engine, "huangdou")
	provider, ok := engine.downloader.providers.get("huangdou")
	if !ok {
		t.Fatal("huangdou 扩展未注册")
	}
	jsProvider, isExtension := provider.(*extensionProvider)
	if !isExtension {
		t.Fatal("huangdou provider 不是扩展实现")
	}
	ctx := parityContext(server)

	// —— 目录（完整加密链路：签名 + gzip + AES + 解密）——
	items, more, err := jsProvider.CatalogPage(ctx, 1, "", "")
	if err != nil {
		t.Fatal("extension catalog:", err)
	}
	if len(items) != 2 || more {
		t.Fatalf("catalog shape = %d(%v), want 2(false)", len(items), more)
	}
	first := nativeNormalize(items[0])
	if first.ID != "huangdou:drama-1" || first.Title != "黄豆样本一" || first.Episodes != 3 {
		t.Fatalf("catalog[0] = %+v", first)
	}
	if first.VIP == nil || !*first.VIP || first.Heat != "98" || first.Views != "1200次播放" {
		t.Fatalf("catalog[0] vip/heat/views = %v/%q/%q", first.VIP, first.Heat, first.Views)
	}

	// —— 详情（VIP 分集判定、集数排序）——
	drama, chapters, err := jsProvider.Detail(ctx, "drama-1")
	if err != nil {
		t.Fatal("extension detail:", err)
	}
	if len(chapters) != 3 {
		t.Fatalf("chapters = %d, want 3: %+v", len(chapters), chapters)
	}
	if drama.Title != "黄豆样本一" {
		t.Fatalf("detail title = %q", drama.Title)
	}
	// free_episodes=1：第 1 集免费，第 2、3 集 VIP。
	for index, chapter := range chapters {
		want := index > 0
		if chapter.VIP != want {
			t.Fatalf("chapter[%d] vip = %v, want %v", index, chapter.VIP, want)
		}
		if chapter.EpisodeString(index+1) != strconv.Itoa(index+1) {
			t.Fatalf("chapter[%d] episode = %q", index, chapter.EpisodeString(index+1))
		}
	}

	// —— 播放（HLS 密钥透传）——
	jsMedia, err := jsProvider.ResolveMedia(ctx, Task{DramaID: "huangdou:drama-1", Chapter: chapters[0], Index: 1})
	if err != nil {
		t.Fatal("extension resolve:", err)
	}
	if !strings.HasSuffix(jsMedia.URL, "/hd/media.m3u8") {
		t.Fatalf("resolve url = %q", jsMedia.URL)
	}
	if len(jsMedia.HLSKey) != 16 {
		t.Fatalf("hls key not passed through: %x", jsMedia.HLSKey)
	}
	if !bytes.Equal(jsMedia.HLSKey, mustHex("00112233445566778899aabbccddeeff")) {
		t.Fatalf("hls key = %x", jsMedia.HLSKey)
	}
}

// huangdouPlatformKey 与扩展侧一致的平台密钥（站点协议常量）。
const huangdouPlatformKey = "7961beb44246e3012ce228d6b5ced05a"

// mustHex 解析 hex 字符串，测试辅助。
func mustHex(value string) []byte {
	decoded, err := hex.DecodeString(value)
	if err != nil {
		panic(err)
	}
	return decoded
}

// setExtensionBaseURL 让已装扩展把站点根指向测试服务器。
// 扩展支持 hg.storage 的 baseURL 覆盖，用于镜像与测试。
func setExtensionBaseURL(t *testing.T, engine *nativeEngine, source, address string) {
	t.Helper()
	host := &extensionHost{d: engine.downloader}
	values, err := host.StorageLoad(source)
	if err != nil {
		t.Fatal(err)
	}
	values["baseURL"] = address
	if err := host.StorageSave(source, values); err != nil {
		t.Fatal(err)
	}
}
