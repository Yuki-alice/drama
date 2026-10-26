package core

// 站源公共标识与文本工具。
// 站源实现已迁到 JS 扩展，这里保留红果（Go 内置）与宿主侧共用的
// ID 拼装、名称归一与 URL 校验辅助；不含任何具体站点的解析逻辑。

import (
	"context"
	"encoding/json"
	"fmt"
	"html"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// 站源 ID 常量。红果是唯一仍由 Go 实现的站源；其余 ID 用于兼容旧剧集
// 数据、榜单归属与界面分组，解析逻辑全部在 JS 扩展里。
var (
	reEpisodeNumber = regexp.MustCompile(`(?i)(?:第\s*0*(\d+)\s*(?:集|话|期)|(?:更新至|共|全)\s*0*(\d+)\s*(?:集|话|期)|(?:episode|ep)\s*#?\s*0*(\d+))`)
	reDateText      = regexp.MustCompile(`\d{4}-\d{1,2}-\d{1,2}`)
	reViewsText     = regexp.MustCompile(`(?i)[0-9]+(?:\.[0-9]+)?\s*[w万]?\s*次播放`)
	reScoreText     = regexp.MustCompile(`[0-9]+(?:\.[0-9]+)?\s*分`)
)

const (
	sourceHuangguoAI    = "huangguoai"
	sourceHuangguoVideo = "huangguo-video"
	sourceHuangdou      = "huangdou"
	sourceHongguo       = "hongguo"
	sourceHuangju       = "huangju"
	sourceYeguo         = "yeguo"
	sourceDSD           = "dsd"
	sourceCloudFront    = "cloudfront"
	sourceSorani        = "sorani"
	sourceGuipian       = "guipian"
	sourceHanxiaoquan   = "hanxiaoquan"

	providerMaxBodyBytes = 20 * 1024 * 1024
	providerTimeout      = 12 * time.Second
)

func providerDramaID(source, sourceID string) string {
	return source + ":" + strings.TrimSpace(sourceID)
}

func providerChapterID(source, sourceID, chapterKey string) string {
	return source + ":" + strings.TrimSpace(sourceID) + ":" + strings.TrimSpace(chapterKey)
}

func splitProviderDramaID(id string) (source, sourceID string, ok bool) {
	source, sourceID, ok = strings.Cut(strings.TrimSpace(id), ":")
	source = canonicalProviderSource(source)
	if !ok || strings.TrimSpace(sourceID) == "" {
		return "", "", false
	}
	if !isKnownProviderSource(source) && !validExtensionSourceID(source) {
		return "", "", false
	}
	return source, strings.TrimSpace(sourceID), true
}

// isKnownProviderSource 报告 source 是否为项目内置过的站源 ID。
// 它只用于旧数据兼容与 ID 校验，不代表站源可用（扩展是否安装另行判断）。
func isKnownProviderSource(source string) bool {
	switch canonicalProviderSource(source) {
	case sourceHuangguoAI, sourceHuangguoVideo, sourceHuangdou, sourceHongguo, sourceHuangju, sourceYeguo, sourceDSD, sourceCloudFront, sourceSorani, sourceGuipian, sourceHanxiaoquan:
		return true
	default:
		return false
	}
}

func canonicalProviderSource(source string) string {
	switch strings.ToLower(strings.TrimSpace(source)) {
	case "huangguo", "huangguoai", "huangguoai.com":
		return sourceHuangguoAI
	case "huangguo-video", "huangguo.video":
		return sourceHuangguoVideo
	case "huangdou", "tideember.cc", "xqjurgek.top":
		return sourceHuangdou
	case "hongguo", "hongguoduanju.com":
		return sourceHongguo
	case "huangju", "huangju.net", "api.huangju.net":
		return sourceHuangju
	case "yeguo", "ygdj7.com", "www.ygdj7.com", "ygdj15.com", "www.ygdj15.com", "analyze.buxefaex.cc", "delta.ygrwdsgt.cc", "yeguodj.com", "www.yeguodj.com":
		return sourceYeguo
	case "dsd", "dsd.com.se", "www.dsd.com.se":
		return sourceDSD
	case "cloudfront":
		return sourceCloudFront
	case "sorani", "sorani.net", "www.sorani.net", "api.sorani.cc", "sorani.cc":
		return sourceSorani
	case "guipian", "guipianwu.com", "www.guipianwu.com":
		return sourceGuipian
	case "hanxiaoquan", "jennyhow.com", "www.jennyhow.com":
		return sourceHanxiaoquan
	default:
		return strings.TrimSpace(source)
	}
}

func valueEmpty(v any) bool {
	if v == nil {
		return true
	}
	s := strings.TrimSpace(fmt.Sprint(v))
	return s == "" || s == "0" || s == "<nil>"
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func mapString(m map[string]any, keys ...string) string {
	for _, key := range keys {
		if v, ok := m[key]; ok {
			switch x := v.(type) {
			case string:
				if text := strings.TrimSpace(x); text != "" {
					return text
				}
			case bool:
				return strconv.FormatBool(x)
			case float64:
				if x == float64(int64(x)) {
					return strconv.FormatInt(int64(x), 10)
				}
				return strconv.FormatFloat(x, 'f', -1, 64)
			case int:
				return strconv.Itoa(x)
			case json.Number:
				return x.String()
			}
		}
	}
	return ""
}

func mapStringSlice(m map[string]any, keys ...string) []string {
	seen := map[string]bool{}
	var out []string
	add := func(s string) {
		s = strings.TrimSpace(s)
		if s != "" && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	for _, key := range keys {
		v, ok := m[key]
		if !ok {
			continue
		}
		switch x := v.(type) {
		case string:
			for _, part := range strings.FieldsFunc(x, func(r rune) bool { return r == ',' || r == '/' || r == '，' || r == '、' }) {
				add(part)
			}
		case []any:
			for _, item := range x {
				if row, ok := item.(map[string]any); ok {
					// 上游 tags/categoryTags 可能是对象数组（如 [{name:"奇幻",custom:true}]），
					// 直接 fmt.Sprint 会打印成 "map[custom:true name:奇幻]" 这种 Go 内部格式。
					if name := mapString(row, "name", "title", "label", "tag"); name != "" {
						add(name)
					}
					continue
				}
				add(fmt.Sprint(item))
			}
		}
	}
	return out
}

func resolveProviderURL(baseURL, ref string) string {
	ref = strings.TrimSpace(html.UnescapeString(ref))
	if ref == "" {
		return ""
	}
	ref = strings.ReplaceAll(ref, `\/`, `/`)
	if strings.HasPrefix(ref, "//") {
		return "https:" + ref
	}
	u, err := url.Parse(ref)
	if err != nil {
		return ref
	}
	if u.IsAbs() {
		if u.Scheme == "http" {
			u.Scheme = "https"
		}
		return u.String()
	}
	base, err := url.Parse(baseURL)
	if err != nil {
		return ref
	}
	resolved := base.ResolveReference(u)
	if resolved.Scheme == "http" {
		resolved.Scheme = "https"
	}
	return resolved.String()
}

func isProviderHTTPMediaURL(raw string) bool {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	return err == nil && (parsed.Scheme == "http" || parsed.Scheme == "https") && parsed.Hostname() != "" && parsed.User == nil
}

func firstMatchText(re *regexp.Regexp, raw string) string {
	if m := re.FindString(raw); m != "" {
		return strings.TrimSpace(m)
	}
	return ""
}

func normalizeViews(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	if strings.Contains(s, "次播放") {
		return s
	}
	if strings.ContainsAny(strings.ToLower(s), "w万") {
		return s + "次播放"
	}
	n, err := strconv.ParseFloat(s, 64)
	if err != nil || n <= 0 {
		return s
	}
	return strconv.FormatFloat(n, 'f', -1, 64) + "次播放"
}

func normalizeDate(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	matches := reDateText.FindAllString(s, -1)
	for _, m := range matches {
		parts := strings.Split(m, "-")
		if len(parts) != 3 {
			continue
		}
		y, yErr := strconv.Atoi(parts[0])
		mo, moErr := strconv.Atoi(parts[1])
		d, dErr := strconv.Atoi(parts[2])
		if yErr == nil && moErr == nil && dErr == nil && y >= 2000 && y <= 2100 && mo >= 1 && mo <= 12 && d >= 1 && d <= 31 {
			return fmt.Sprintf("%04d-%02d-%02d", y, mo, d)
		}
	}
	return ""
}

func cleanText(s string) string {
	s = regexp.MustCompile(`(?is)<script\b.*?</script>`).ReplaceAllString(s, " ")
	s = regexp.MustCompile(`(?is)<style\b.*?</style>`).ReplaceAllString(s, " ")
	s = regexp.MustCompile(`(?is)<[^>]+>`).ReplaceAllString(s, " ")
	s = html.UnescapeString(s)
	s = spaceChars.ReplaceAllString(s, " ")
	return strings.TrimSpace(s)
}

func rawEpisode(n int) json.RawMessage {
	if n <= 0 {
		n = 1
	}
	return json.RawMessage(strconv.Itoa(n))
}

func episodeIndex(s string, fallback int) int {
	if m := reEpisodeNumber.FindStringSubmatch(s); len(m) > 1 {
		for _, group := range m[1:] {
			if group == "" {
				continue
			}
			if n, err := strconv.Atoi(group); err == nil && n > 0 {
				return n
			}
		}
	}
	return fallback
}

func nextUnusedEpisodeIndex(preferred int, used map[int]bool) int {
	if preferred <= 0 {
		preferred = 1
	}
	if !used[preferred] {
		return preferred
	}
	for i := 1; ; i++ {
		if !used[i] {
			return i
		}
	}
}

func sortProviderChapters(chapters []Chapter) {
	sort.SliceStable(chapters, func(i, j int) bool {
		ei := chapterEpisodeNumber(chapters[i], i+1)
		ej := chapterEpisodeNumber(chapters[j], j+1)
		if ei != ej {
			return ei < ej
		}
		return chapters[i].ID < chapters[j].ID
	})
}

func chapterEpisodeNumber(ch Chapter, fallback int) int {
	if len(ch.CurrentEpisode) > 0 && string(ch.CurrentEpisode) != "null" {
		var n int
		if err := json.Unmarshal(ch.CurrentEpisode, &n); err == nil && n > 0 {
			return n
		}
		var s string
		if err := json.Unmarshal(ch.CurrentEpisode, &s); err == nil {
			return episodeIndex(s, fallback)
		}
	}
	return episodeIndex(ch.Title, fallback)
}

func nonEmptyStrings(values ...string) []string {
	var out []string
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			out = append(out, strings.TrimSpace(v))
		}
	}
	return out
}

func mergeDramaMetadata(base, extra Drama) Drama {
	if base.VIP == nil && extra.VIP != nil {
		value := *extra.VIP
		base.VIP = &value
	}
	if extra.SortMetadata != nil && (base.SortMetadata == nil || extra.SortMetadata.CheckedAt.After(base.SortMetadata.CheckedAt)) {
		base.SortMetadata = extra.SortMetadata
	}
	if strings.TrimSpace(base.ID) == "" {
		base.ID = extra.ID
	}
	if strings.TrimSpace(base.Source) == "" {
		base.Source = extra.Source
	}
	if strings.TrimSpace(base.SourceID) == "" {
		base.SourceID = extra.SourceID
	}
	if strings.TrimSpace(base.Title) == "" {
		base.Title = extra.Title
	}
	if strings.TrimSpace(base.Name) == "" {
		base.Name = extra.Name
	}
	if strings.TrimSpace(base.Desc) == "" {
		base.Desc = extra.Desc
	}
	if strings.TrimSpace(base.Intro) == "" {
		base.Intro = extra.Intro
	}
	if coverPathFromAny(base.Cover) == "" {
		base.Cover = extra.Cover
	}
	if coverPathFromAny(base.CoverURL) == "" {
		base.CoverURL = extra.CoverURL
	}
	if valueEmpty(base.TotalEpisode) {
		base.TotalEpisode = extra.TotalEpisode
	}
	if valueEmpty(base.EpisodeCount) {
		base.EpisodeCount = extra.EpisodeCount
	}
	if strings.TrimSpace(base.ChannelName) == "" {
		base.ChannelName = extra.ChannelName
	}
	if strings.TrimSpace(base.CategoryName) == "" || (base.CategoryName == "首页" && extra.CategoryName != "") {
		base.CategoryName = extra.CategoryName
	}
	if strings.TrimSpace(base.Remark) == "" || base.Remark == "在线观看" {
		base.Remark = extra.Remark
	}
	if strings.TrimSpace(base.Score) == "" {
		base.Score = extra.Score
	}
	if strings.TrimSpace(base.Views) == "" {
		base.Views = extra.Views
	}
	if strings.TrimSpace(base.Heat) == "" {
		base.Heat = extra.Heat
	}
	if strings.TrimSpace(base.OnlineDate) == "" {
		base.OnlineDate = extra.OnlineDate
	}
	if len(base.Tags) == 0 {
		base.Tags = extra.Tags
	}
	if base.ReleaseStatus == "" || base.ReleaseStatus == "unknown" {
		base.ReleaseStatus = extra.ReleaseStatus
	}
	return base
}

func extractAttr(block string, names ...string) string {
	for _, name := range names {
		re := regexp.MustCompile(`(?is)\b` + regexp.QuoteMeta(name) + `\s*=\s*["']([^"']+)["']`)
		if m := re.FindStringSubmatch(block); len(m) > 1 {
			return strings.TrimSpace(html.UnescapeString(m[1]))
		}
	}
	return ""
}

// GetHuangguoChapters 是分集目录的统一入口：红果走内置实现，
// 其余站源走 provider registry（已安装的 JS 扩展）。
func (d *Downloader) GetHuangguoChapters(ctx context.Context, source, sourceID string) (string, []Chapter, error) {
	source = canonicalProviderSource(source)
	if source == sourceHongguo {
		return d.fetchHongguoChapters(ctx, sourceID)
	}
	provider, ok := d.providers.get(source)
	if !ok {
		return "", nil, fmt.Errorf("站源 %s 未安装", source)
	}
	drama, chapters, err := provider.Detail(ctx, sourceID)
	if err != nil {
		return "", nil, err
	}
	return drama.DisplayTitle(), chapters, err
}
