package core

// 站源与红果网页共用的文本抓取通道。
// 站源解析逻辑已迁到 JS 扩展（扩展经 hg.fetch 走同一套网络栈），
// 这里保留红果网页与封面补全需要的最小实现。

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
)

// fetchProviderText 抓取文本资源，带重试、退避与响应体上限。
func (d *Downloader) fetchProviderText(ctx context.Context, rawURL, referer string) (string, error) {
	retries := d.cfg.Retries
	if retries <= 0 {
		retries = 3
	}
	if referer == "" {
		referer = rawURL
	}
	var lastErr error
	for attempt := 1; attempt <= retries; attempt++ {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		if attempt > 1 {
			select {
			case <-time.After(time.Duration(attempt) * time.Second):
			case <-ctx.Done():
				return "", ctx.Err()
			}
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
		if err != nil {
			return "", err
		}
		req.Header.Set("User-Agent", userAgent)
		if agent, ok := ctx.Value(providerTextUserAgentKey{}).(string); ok && agent != "" {
			req.Header.Set("User-Agent", agent)
		}
		req.Header.Set("Referer", referer)
		req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
		if noCache, _ := ctx.Value(providerTextNoCacheKey{}).(bool); noCache {
			req.Header.Set("Cache-Control", "no-cache")
		}
		resp, err := d.doCatalogRequestWithTimeout(req, providerTimeout)
		if err != nil {
			lastErr = err
			var backoff *requestBackoff
			if errors.As(err, &backoff) {
				break
			}
			continue
		}
		body, readErr := io.ReadAll(io.LimitReader(resp.Body, providerMaxBodyBytes+1))
		closeErr := resp.Body.Close()
		if readErr != nil {
			lastErr = readErr
			continue
		}
		if closeErr != nil {
			lastErr = closeErr
			continue
		}
		if len(body) > providerMaxBodyBytes {
			lastErr = fmt.Errorf("response exceeds %d bytes", providerMaxBodyBytes)
			continue
		}
		if resp.StatusCode < 200 || resp.StatusCode >= 300 || catalogResponseBlockReason(resp, body) != "" {
			lastErr = d.catalogResponseError(req, resp, body)
			if catalogResponseBlockReason(resp, body) != "" || resp.StatusCode >= 400 && resp.StatusCode < 500 && resp.StatusCode != 408 {
				break
			}
			continue
		}
		rememberPlaybackResponseURL(ctx, rawURL, resp)
		return string(body), nil
	}
	return "", lastErr
}
