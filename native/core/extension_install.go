package core

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"duanjuapp/native/ext"
)

// installExtension 安装一个 JS 扩展：可直接传入脚本（随包内置/本地导入），
// 也可从官方 index 的地址下载；下载时按需校验 SHA-256。
func (engine *nativeEngine) installExtension(ctx context.Context, input nativeInput) (any, error) {
	source := canonicalProviderSource(input.Source)
	if !validExtensionSourceID(source) {
		return nil, errors.New("扩展 ID 无效")
	}
	code := []byte(input.ExtensionCode)
	if len(code) > 0 && strings.TrimSpace(input.ExtensionURL) != "" {
		return nil, errors.New("扩展脚本与下载地址只能提供一项")
	}
	if len(code) == 0 {
		address := strings.TrimSpace(input.ExtensionURL)
		parsed, err := url.Parse(address)
		if err != nil || parsed.Host == "" || !strings.HasSuffix(strings.ToLower(parsed.Path), ".js") {
			return nil, errors.New("扩展脚本地址无效")
		}
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
		if err != nil {
			return nil, err
		}
		response, err := engine.downloader.client.Do(request)
		if err != nil {
			return nil, fmt.Errorf("扩展脚本下载失败: %w", err)
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("扩展脚本下载失败: HTTP %d", response.StatusCode)
		}
		code, err = io.ReadAll(io.LimitReader(response.Body, ext.MaxSourceBytes+1))
		if err != nil {
			return nil, fmt.Errorf("扩展脚本读取失败: %w", err)
		}
		if len(code) > ext.MaxSourceBytes {
			return nil, errors.New("扩展脚本超过 512 KiB 上限")
		}
		if expected := strings.ToLower(strings.TrimSpace(input.ExtensionSHA256)); expected != "" {
			digest := sha256.Sum256(code)
			if hex.EncodeToString(digest[:]) != expected {
				return nil, errors.New("扩展脚本摘要与索引不符")
			}
		}
	}
	manifest, err := engine.downloader.extensions.InstallScript(code, source)
	if err != nil {
		return nil, err
	}
	return map[string]any{"source": source, "name": manifest.Name, "version": manifest.Version}, nil
}

func (engine *nativeEngine) uninstallExtension(source string) (any, error) {
	source = canonicalProviderSource(source)
	if !validExtensionSourceID(source) {
		return nil, errors.New("扩展 ID 无效")
	}
	if err := engine.downloader.extensions.Uninstall(source); err != nil {
		return nil, err
	}
	engine.downloader.providers.unregister(source)
	return map[string]any{"source": source}, nil
}
