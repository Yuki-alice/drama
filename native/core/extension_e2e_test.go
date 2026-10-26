package core

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const endToEndExtension = `// ==HongguoExtension==
// @id e2etest
// @name 端到端测试源
// @version 1.0.0
// @apiLevel 1
// ==/HongguoExtension==

globalThis.source = {
  onlineSearch: true,
  categories(ctx, force) { return [{id: 'top', name: '推荐'}]; },
  validCategory(category) { return category === 'top'; },
  catalog(ctx, page, category, query) {
    const body = hg.fetch(ctx.host + '/list?page=' + page).body;
    const doc = hg.html.parse(body);
    const titles = [];
    for (const link of hg.html.findAll(doc, 'a.drama')) {
      titles.push({sourceId: hg.html.attr(link, 'data-id'), title: hg.html.text(link)});
    }
    return {items: titles, hasMore: page < 3};
  },
  detail(ctx, id) {
    return {drama: {sourceId: id, title: '扩展测试剧 ' + id}, chapters: [
      {id: id + '-1', title: '第1集', videoUrl: 'https://e2e.test/v/1.m3u8'},
      {id: id + '-2', title: '第2集', videoUrl: 'https://e2e.test/v/2.m3u8'},
    ]};
  },
};
`

// TestExtensionEndToEnd 验证完整链路：
// 下载单文件扩展 → 安装落盘 → registry 注册 → nativeDispatch 的 catalog/detail 可用。
func TestExtensionEndToEnd(t *testing.T) {
	code := []byte(endToEndExtension)
	digest := sha256.Sum256(code)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/e2etest.js":
			_, _ = w.Write(code)
		case "/list":
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = w.Write([]byte("<!doctype html><html><body>" +
				`<a class="drama" data-id="e2e-01">扩展测试剧一</a>` +
				"</body></html>"))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)

	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	// nativeSourceAvailable 查询进程级 engine：测试期临时挂载。
	nativeState.Lock()
	previousEngine := nativeState.engine
	nativeState.engine = engine
	nativeState.Unlock()
	t.Cleanup(func() {
		nativeState.Lock()
		nativeState.engine = previousEngine
		nativeState.Unlock()
	})
	engine.downloader.client.Transport = server.Client().Transport

	// 安装前不可用。
	if nativeSourceAvailable("e2etest") {
		t.Fatal("extension should be unavailable before install")
	}
	installed, err := engine.installExtension(context.Background(), nativeInput{
		Source:          "e2etest",
		ExtensionURL:    server.URL + "/e2etest.js",
		ExtensionSHA256: hex.EncodeToString(digest[:]),
	})
	if err != nil {
		t.Fatal(err)
	}
	if name, _ := installed.(map[string]any)["name"].(string); name != "端到端测试源" {
		t.Fatalf("install returned %+v", installed)
	}
	if !nativeSourceAvailable("e2etest") {
		t.Fatal("extension should be available after install")
	}
	if _, ok := engine.downloader.providers.get("e2etest"); !ok {
		t.Fatal("extension provider not registered")
	}

	// 目录：JS 通过 hg.fetch + hg.html 解析宿主网络栈返回的内容。
	if _, ok := engine.downloader.providers.get("e2etest"); !ok {
		t.Fatal("provider missing")
	}
	catalog, err := engine.nativeCatalog(context.WithValue(context.Background(), extensionTestHostKey{}, server.URL), nativeInput{
		Source:   "e2etest",
		Page:     1,
		Category: "",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(catalog.Items) != 1 || catalog.Items[0].ID != "e2etest:e2e-01" || catalog.Items[0].Title != "扩展测试剧一" {
		t.Fatalf("catalog mismatch: %+v", catalog.Items)
	}
	if !catalog.HasMore {
		t.Fatal("hasMore should follow JS contract")
	}

	// 详情：ID 由宿主强制加前缀。
	detail, err := engine.nativeDetail(context.Background(), nativeDrama{ID: "e2etest:e2e-01", Source: "e2etest", Title: "扩展测试剧一"})
	if err != nil {
		t.Fatal(err)
	}
	rows := detail.(map[string]any)
	chapters := rows["chapters"].([]Chapter)
	if len(chapters) != 2 || !strings.HasPrefix(chapters[0].ID, "e2etest:") {
		t.Fatalf("detail chapters mismatch: %+v", chapters)
	}

	// 卸载后目录不可用，扩展目录被清理。
	if _, err := engine.uninstallExtension("e2etest"); err != nil {
		t.Fatal(err)
	}
	if nativeSourceAvailable("e2etest") {
		t.Fatal("extension should be unavailable after uninstall")
	}
	if _, ok := engine.downloader.providers.get("e2etest"); ok {
		t.Fatal("extension provider should be removed from dispatch")
	}
}

// TestExtensionInstallFromCode 验证随包内置/本地导入路径：
// 不经过网络，直接安装脚本并按头部 ID 校验。
func TestExtensionInstallFromCode(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	nativeState.Lock()
	previous := nativeState.engine
	nativeState.engine = engine
	nativeState.Unlock()
	t.Cleanup(func() {
		nativeState.Lock()
		nativeState.engine = previous
		nativeState.Unlock()
	})

	if _, err := engine.installExtension(context.Background(), nativeInput{
		Source:        "wrong",
		ExtensionCode: endToEndExtension,
	}); err == nil {
		t.Fatal("mismatched source code accepted")
	}
	installed, err := engine.installExtension(context.Background(), nativeInput{
		Source:        "e2etest",
		ExtensionCode: endToEndExtension,
	})
	if err != nil {
		t.Fatal(err)
	}
	if installed.(map[string]any)["name"] != "端到端测试源" {
		t.Fatalf("install returned %+v", installed)
	}
	if !nativeSourceAvailable("e2etest") {
		t.Fatal("extension should be available after code install")
	}
	rows := engine.downloader.extensions.installedExtensions()
	if len(rows) != 1 || rows[0].(map[string]any)["id"] != "e2etest" {
		t.Fatalf("installed list mismatch: %+v", rows)
	}
}
