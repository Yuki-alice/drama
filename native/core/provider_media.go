package core

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"
)

type providerMedia struct {
	credentials *providerMediaCredentials
	URL         string
	Referer     string
	// Headers 是扩展 resolve 契约声明的额外媒体请求头（如自定义鉴权头）。
	// 只允许出现在宿主出站请求上，不下发给播放器。
	Headers  map[string]string
	Duration time.Duration
	Playlist string
	HLSKey   []byte
	CENCKey  []byte
	Quality  int
	Variants []providerMedia
}

// providerBaseURL 返回站源的站点根地址。
// 站源解析已迁到 JS 扩展（扩展自带 baseURL），但宿主侧仍需要站点根：
// 封面请求的 Referer、诊断日志的站点标识都依赖它。
func (d *Downloader) providerBaseURL(source string) string {
	source = canonicalProviderSource(source)
	var configured, fallback string
	switch source {
	case sourceHongguo:
		configured, fallback = d.cfg.HongguoURL, hongguoBaseURL
	case sourceHuangguoAI:
		configured, fallback = d.cfg.HuangguoAIURL, "https://huangguoai.com"
	case sourceHuangguoVideo:
		configured, fallback = d.cfg.HuangguoVideoURL, "https://huangguo.video"
	case sourceHuangdou:
		configured, fallback = d.cfg.HuangdouURL, "https://tideember.cc"
	case sourceHuangju:
		configured, fallback = d.cfg.HuangjuURL, "https://huangju.net"
	case sourceYeguo:
		configured, fallback = d.cfg.YeguoURL, "https://www.yeguodj.com"
	case sourceDSD:
		configured, fallback = d.cfg.DSDURL, "https://www.dsd.com.se"
	case sourceCloudFront:
		fallback = "https://d2pypzndaqisk.cloudfront.net"
	case sourceSorani:
		configured, fallback = d.cfg.SoraniURL, "https://www.sorani.net"
	case sourceGuipian:
		configured, fallback = d.cfg.GuipianURL, "https://guipianwu.com"
	case sourceHanxiaoquan:
		configured, fallback = d.cfg.HanxiaoquanURL, "https://www.jennyhow.com"
	default:
		fallback = "https://d2pypzndaqisk.cloudfront.net"
	}
	return strings.TrimRight(firstNonEmpty(configured, fallback), "/")
}

func (d *Downloader) resolveProviderMedia(ctx context.Context, task Task) (providerMedia, error) {
	chapter := task.Chapter
	chapter.Source = canonicalProviderSource(chapter.Source)
	if chapter.Source == "" {
		chapter.Source = sourceFromDramaID(task.DramaID)
	}
	// 源特定解析优先；未实现或声明不处理时走通用路径。
	if provider, ok := d.providers.get(chapter.Source); ok {
		if resolver, implements := provider.(playbackResolver); implements {
			media, err := resolver.ResolveMedia(ctx, task)
			if !errors.Is(err, errProviderNotHandled) {
				return media, err
			}
		}
	}
	if chapter.PageURL == "" && (chapter.Source == sourceHuangguoAI || chapter.Source == sourceHuangguoVideo) {
		if source, sourceID, valid := splitProviderDramaID(task.DramaID); valid {
			_, chapters, err := d.GetHuangguoChapters(ctx, source, sourceID)
			if err != nil {
				return providerMedia{}, fmt.Errorf("刷新旧任务播放地址失败: %w", err)
			}
			matched := false
			for _, fresh := range chapters {
				if fresh.ID == chapter.ID {
					chapter = fresh
					matched = true
					break
				}
			}
			if !matched {
				return providerMedia{}, fmt.Errorf("原章节已变化，请更新该合集后重新下载")
			}
		}
	}
	media := providerMedia{URL: chapter.VideoURL, Referer: firstNonEmpty(chapter.Referer, d.providerBaseURL(chapter.Source)+"/")}
	return d.finalizeProviderMedia(ctx, media, chapter.Source)
}

// finalizeProviderMedia 校验最终地址并完成 m3u8 播放列表预取，
// 通用路径与扩展源 resolve 共用，保证行为一致。
func (d *Downloader) finalizeProviderMedia(ctx context.Context, media providerMedia, source string) (providerMedia, error) {
	if !isProviderHTTPMediaURL(media.URL) {
		return providerMedia{}, fmt.Errorf("%s 未返回有效播放地址，请刷新章节或确认站点访问权限", source)
	}
	parsed, _ := url.Parse(media.URL)
	path := strings.ToLower(parsed.Path)
	// 部分站点的播放列表接口不带 .m3u8 后缀（如旧版黄果的 /m3u8/{id}）。
	if strings.HasSuffix(path, ".m3u8") || strings.Contains(path, "/m3u8/") {
		if media.credentials != nil {
			ctx = providerMediaContext(ctx, media.credentials)
		}
		playlist, finalURL, err := d.fetchMediaPlaylist(ctx, media.URL, media.Referer, media.Headers)
		if err != nil {
			return providerMedia{}, fmt.Errorf("获取播放列表失败: %w", err)
		}
		if !strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(playlist, "\ufeff")), "#EXTM3U") {
			return providerMedia{}, fmt.Errorf("站点未返回有效 M3U8，可能需要登录或链接已失效")
		}
		if duration := m3u8Duration(playlist); duration > 0 {
			media.Duration = duration
		}
		media.Playlist = playlist
		media.URL = finalURL
	}
	return media, nil
}

// providerSourceForURL 把站点的 URL 归到站源 ID，仅用于网络限流的分桶键。
// 站源解析已迁到扩展，这里只认红果域名；其他站点用主机名分桶。
func providerSourceForURL(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	host := strings.ToLower(parsed.Hostname())
	if host == "hongguoduanju.com" || host == "www.hongguoduanju.com" {
		return sourceHongguo
	}
	return ""
}
