package core

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"

	"duanjuapp/native/ext"
)

// scriptWithManifest 拼一个带完整文件头的扩展脚本。
func scriptWithManifest(id, body string) []byte {
	return []byte("// ==HongguoExtension==\n// @id " + id +
		"\n// @name 测试源\n// @version 1.0.0\n// @apiLevel 1\n// @onlineSearch true\n// ==/HongguoExtension==\n\n" + body)
}

// installTestExtensionCode 安装一段内联脚本（不读 extensions-repo）。
func installTestExtensionCode(t *testing.T, engine *nativeEngine, sourceID string, code []byte) {
	t.Helper()
	if _, err := engine.downloader.extensions.InstallScript(code, sourceID); err != nil {
		t.Fatalf("安装扩展失败: %v", err)
	}
}

func extRequest(address string) ext.Request {
	return ext.Request{Method: http.MethodGet, URL: strings.TrimSpace(address)}
}

// 回归：SupportsOnlineSearch 曾无条件返回 true，导致声明不支持站内搜索的
// 扩展（黄豆、黄果系）被路由到脚本的 catalog(query=...)，脚本直接抛错。
// 能力标志必须由清单驱动。
func TestExtensionOnlineSearchFollowsManifest(t *testing.T) {
	engine := sourceFixtureEngine(t, func(request *http.Request) (*http.Response, error) {
		return nil, errors.New("fixture 不应被请求")
	})
	installTestExtension(t, engine, "huangdou")
	installTestExtension(t, engine, "guipian")

	huangdou, ok := engine.downloader.providers.get("huangdou")
	if !ok {
		t.Fatal("黄豆扩展未注册")
	}
	if huangdou.SupportsOnlineSearch() {
		t.Fatal("黄豆清单未声明 onlineSearch，不应支持站内搜索")
	}
	guipian, ok := engine.downloader.providers.get("guipian")
	if !ok {
		t.Fatal("鬼片扩展未注册")
	}
	if !guipian.SupportsOnlineSearch() {
		t.Fatal("鬼片清单声明了 onlineSearch，应支持站内搜索")
	}
}

// 不支持在线搜索的源在收到 query 时必须回落到本地剧库过滤，
// 而不是把 query 丢给脚本。
func TestCatalogQueryFallsBackToLocalLibrary(t *testing.T) {
	engine := sourceFixtureEngine(t, func(request *http.Request) (*http.Response, error) {
		return nil, errors.New("不支持搜索的源不应发起网络请求")
	})
	installTestExtension(t, engine, "huangdou")
	engine.catalogs[sourceHuangdou] = []nativeDrama{
		{ID: "huangdou:1", Source: sourceHuangdou, Title: "落水千金"},
		{ID: "huangdou:2", Source: sourceHuangdou, Title: "无关剧名"},
	}

	result, err := engine.nativeCatalog(context.Background(), nativeInput{
		Source: sourceHuangdou,
		Query:  "落水",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !result.LocalSearch {
		t.Fatal("应标记为本地搜索")
	}
	if len(result.Items) != 1 || result.Items[0].ID != "huangdou:1" {
		t.Fatalf("本地过滤结果不正确: %+v", result.Items)
	}
}

// 回归：扩展请求曾可以访问 127.0.0.1 与私网，安装即获得宿主网络栈的扩展
// 可以借此探测本机播放服务器或内网服务。
func TestExtensionFetchRejectsLocalAddresses(t *testing.T) {
	cases := []struct {
		address string
		blocked bool
	}{
		{"http://127.0.0.1:8080/x", true},
		{"http://localhost/x", true},
		{"http://[::1]/x", true},
		{"http://10.0.0.5/x", true},
		{"http://192.168.1.10/x", true},
		{"http://169.254.169.254/latest/meta-data", true},
		{"https://example.com/x", false},
	}
	// 注意：不能用 sourceFixtureEngine，它会打开本机访问豁免（测试夹具需要）。
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	engine.downloader.client.Transport = roundTripFunc(func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, 200, "ok"), nil
	})
	engine.downloader.limiter = newRequestLimiter(3, 0)
	host := &extensionHost{d: engine.downloader}
	for _, testCase := range cases {
		_, err := host.Fetch(context.Background(), "probe", extRequest(testCase.address))
		if testCase.blocked && err == nil {
			t.Fatalf("%s 应被拒绝", testCase.address)
		}
		if !testCase.blocked && err != nil {
			t.Fatalf("%s 不应被拒绝: %v", testCase.address, err)
		}
	}
}

// roundTripFunc 让测试注入任意传输实现。
type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

func TestExtensionStorageAvoidsRedundantWrites(t *testing.T) {
	engine := sourceFixtureEngine(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, 200, "ok"), nil
	})
	installTestExtension(t, engine, "huangdou")
	host := &extensionHost{d: engine.downloader}

	values := map[string]string{"host": "https://tideember.cc"}
	if err := host.StorageSave("huangdou", values); err != nil {
		t.Fatal(err)
	}
	// 第二次写入相同内容不应改变内存副本的引用（值未变时不落盘）。
	before, _, err := engine.downloader.extensions.storageValues("huangdou")
	if err != nil {
		t.Fatal(err)
	}
	if err := host.StorageSave("huangdou", map[string]string{"host": "https://tideember.cc"}); err != nil {
		t.Fatal(err)
	}
	after, _, err := engine.downloader.extensions.storageValues("huangdou")
	if err != nil {
		t.Fatal(err)
	}
	if !equalStorageValues(before, after) || after["host"] != "https://tideember.cc" {
		t.Fatalf("存储内容不一致: %v → %v", before, after)
	}
}

// 扩展声明的媒体请求头必须真正生效；传输层头不可被覆盖。
func TestResolveHeadersAreAppliedAndSanitized(t *testing.T) {
	code := scriptWithManifest("headertest", `globalThis.source = {
  catalog(ctx, page) { return {items: [], hasMore: false}; },
  detail(ctx, id) { return {drama: {sourceId: id, title: '测试'}, chapters: [{id: '1', title: '第1集'}]}; },
  resolve(ctx, task) {
    return {
      url: 'https://media.test/v.mp4',
      headers: {'X-Token': 'abc', 'Host': 'evil.test', 'Range': 'bytes=0-1'},
    };
  },
};`)
	engine := sourceFixtureEngine(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, 200, "ok"), nil
	})
	installTestExtensionCode(t, engine, "headertest", code)

	provider, ok := engine.downloader.providers.get("headertest")
	if !ok {
		t.Fatal("扩展未注册")
	}
	media, err := provider.(playbackResolver).ResolveMedia(context.Background(), Task{
		DramaID: "headertest:1",
		Chapter: Chapter{ID: "headertest:1", Source: "headertest", Title: "第1集"},
		Index:   1,
	})
	if err != nil {
		t.Fatal(err)
	}
	if media.Headers["X-Token"] != "abc" {
		t.Fatalf("扩展请求头丢失: %+v", media.Headers)
	}
	for _, name := range []string{"Host", "Range"} {
		if _, found := media.Headers[name]; found {
			t.Fatalf("传输层头 %s 不应被扩展设置", name)
		}
	}
}

func TestExtensionAddressValidationAllowsPublicHosts(t *testing.T) {
	engine := sourceFixtureEngine(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, 200, "ok"), nil
	})
	host := &extensionHost{d: engine.downloader}
	if _, err := host.Fetch(context.Background(), "probe", extRequest("https://example.test/a")); err != nil {
		t.Fatalf("公网地址不应被拒绝: %v", err)
	}
}

// 占位索引地址时不应发网络请求：那个域名不可达，每次进站源页
// 等一次超时是纯损失，而且会让"扩展仓库不可用"的报错淹没真正的问题。
func TestRemoteIndexSkipsPlaceholder(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)

	requested := false
	engine.downloader.client.Transport = roundTripFunc(func(request *http.Request) (*http.Response, error) {
		requested = true
		return sourceFixtureResponse(request, 200, "[]"), nil
	})

	previous := extensionIndexURL
	extensionIndexURL = extensionIndexPlaceholder
	t.Cleanup(func() { extensionIndexURL = previous })

	result, err := engine.downloader.extensions.RemoteIndex(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if requested {
		t.Fatal("占位地址不应发起请求")
	}
	payload := result.(map[string]any)
	if payload["unconfigured"] != true {
		t.Fatalf("应标记为未配置: %+v", payload)
	}
	if rows := payload["entries"].([]any); len(rows) != 0 {
		t.Fatalf("不应返回条目: %+v", rows)
	}
}

// 配置了真实地址后必须真的去拉。
func TestRemoteIndexFetchesWhenConfigured(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)

	var requested bool
	engine.downloader.client.Transport = roundTripFunc(func(request *http.Request) (*http.Response, error) {
		requested = true
		body := `[{"id":"demo","name":"示例","version":"1.0.0","apiLevel":1,"url":"https://example.test/demo.js","sha256":"` + strings.Repeat("a", 64) + `"}]`
		return sourceFixtureResponse(request, 200, body), nil
	})

	previous := extensionIndexURL
	extensionIndexURL = "https://example.test/index.json"
	t.Cleanup(func() { extensionIndexURL = previous })

	result, err := engine.downloader.extensions.RemoteIndex(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !requested {
		t.Fatal("配置地址后应发起请求")
	}
	rows := result.(map[string]any)["entries"].([]any)
	if len(rows) != 1 {
		t.Fatalf("条目数量不符: %+v", rows)
	}
}
