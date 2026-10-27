package ext

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dop251/goja"
)

type fakeHost struct {
	mu       sync.Mutex
	stored   map[string]map[string]string
	fetches  []Request
	logs     []string
	response *Response
}

func (h *fakeHost) Fetch(ctx context.Context, source string, request Request) (*Response, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.fetches = append(h.fetches, request)
	if h.response != nil {
		return h.response, nil
	}
	return &Response{Status: 200, Body: "<html><body><a class=\"item\" href=\"/d/1\">剧名A</a></body></html>"}, nil
}

func (h *fakeHost) Log(source, message string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.logs = append(h.logs, source+": "+message)
}

func (h *fakeHost) StorageLoad(source string) (map[string]string, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.stored == nil {
		return map[string]string{}, nil
	}
	out := map[string]string{}
	for key, value := range h.stored[source] {
		out[key] = value
	}
	return out, nil
}

func (h *fakeHost) StorageSave(source string, values map[string]string) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.stored == nil {
		h.stored = map[string]map[string]string{}
	}
	h.stored[source] = values
	return nil
}

const sampleSource = `// ==HongguoExtension==
// @id fixture
// @name 测试源
// @version 1.0.0
// @apiLevel 1
// ==/HongguoExtension==

globalThis.source = {
  baseURL: 'https://example.test',
  onlineSearch: true,
  categories(ctx, force) {
    hg.log('列出分类');
    return [{id: 'hot', name: '热门'}];
  },
  validCategory(category) { return category === 'hot'; },
  catalog(ctx, page, category, query) {
    const page1 = hg.fetch(hg.storage.get('pageBase') || source.baseURL + '/list?page=' + page);
    const doc = hg.html.parse(page1.body);
    const links = hg.html.findAll(doc, 'a.item');
    const items = [];
    for (const link of links) {
      items.push({
        sourceId: hg.html.attr(link, 'href').replace('/d/', ''),
        title: hg.html.text(link),
      });
    }
    return {items: items, hasMore: false};
  },
  detail(ctx, id) {
    const md5 = hg.crypto.md5hex(id);
    return {drama: {sourceId: id, title: '剧名' + id, description: 'md5=' + md5}, chapters: [{id: id + ':1', title: '第1集'}]};
  },
};
`

func newTestExtension(t *testing.T, host *fakeHost) *Extension {
	t.Helper()
	registry := NewRegistry(host)
	manifest, err := ParseScript(sampleSource)
	if err != nil {
		t.Fatal(err)
	}
	extension, err := NewExtension(manifest, sampleSource, registry)
	if err != nil {
		t.Fatal(err)
	}
	return extension
}

func TestExtensionContractAndLifecycle(t *testing.T) {
	host := &fakeHost{}
	extension := newTestExtension(t, host)

	categories, err := extension.runtime.Call("categories", []any{map[string]any{}, false})
	if err != nil {
		t.Fatal(err)
	}
	rows, ok := categories.([]any)
	if !ok || len(rows) != 1 {
		t.Fatalf("categories returned %T %v", categories, categories)
	}
	first := rows[0].(map[string]any)
	if first["id"] != "hot" || first["name"] != "热门" {
		t.Fatalf("category row mismatch: %v", first)
	}
	if len(host.logs) != 1 || !strings.Contains(host.logs[0], "fixture: 列出分类") {
		t.Fatalf("hg.log not routed: %v", host.logs)
	}

	if _, err := extension.runtime.Call("validCategory", []any{"hot"}); err != nil {
		t.Fatal(err)
	}

	if _, err := extension.runtime.Call("catalog", []any{map[string]any{}, 1, "", ""}); err != nil {
		t.Fatal(err)
	}
	if len(host.fetches) != 1 || host.fetches[0].URL != "https://example.test/list?page=1" {
		t.Fatalf("hg.fetch not invoked: %+v", host.fetches)
	}
	host.mu.Lock()
	host.stored = map[string]map[string]string{"fixture": {"pageBase": "https://mirror.test/base"}}
	host.mu.Unlock()
	if _, err := extension.runtime.Call("catalog", []any{map[string]any{}, 2, "", ""}); err != nil {
		t.Fatal(err)
	}
	// storage 里存有 pageBase 时 `||` 短路，直接取存储值。
	if host.fetches[1].URL != "https://mirror.test/base" {
		t.Fatalf("storage-backed fetch URL: %s", host.fetches[1].URL)
	}

	detail, err := extension.runtime.Call("detail", []any{map[string]any{}, "42"})
	if err != nil {
		t.Fatal(err)
	}
	row := detail.(map[string]any)
	drama := row["drama"].(map[string]any)
	if drama["sourceId"] != "42" || !strings.HasPrefix(drama["description"].(string), "md5=") {
		t.Fatalf("detail contract mismatch: %v", drama)
	}
}

func TestExtensionContextCancelInterruptsScript(t *testing.T) {
	host := &fakeHost{}
	extension := newTestExtension(t, host)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := extension.call(ctx, "categories", []any{map[string]any{}, false}); err == nil {
		t.Fatal("canceled context should fail the script call")
	}
	// 取消后锁释放、runtime 未损坏：后续调用仍可用。
	if _, err := extension.call(context.Background(), "categories", []any{map[string]any{}, false}); err != nil {
		t.Fatalf("runtime unusable after cancel: %v", err)
	}
}

func scriptWithHeader(header, body string) string {
	return "// ==HongguoExtension==\n" + header + "\n// ==/HongguoExtension==\n\n" + body
}

// 回归：调用 context 曾保存在共享 Registry 上，跨扩展并发调用会互相覆盖，
// 导致 A 源的 fetch 拿到 B 源的 context（取消串源、race detector 报警）。
func TestConcurrentExtensionsDoNotShareCallContext(t *testing.T) {
	registry := NewRegistry(&fakeHost{})
	build := func(id string) *Extension {
		code := scriptWithHeader(
			"// @id "+id+"\n// @name 并发源\n// @version 1.0.0\n// @apiLevel 1",
			`globalThis.source = {
  catalog(ctx, page) {
    hg.fetch('https://example.test/' + page);
    hg.fetch('https://example.test/' + page + '?next=1');
    return {items: [], hasMore: false};
  },
};`,
		)
		manifest, err := ParseScript(code)
		if err != nil {
			t.Fatal(err)
		}
		extension, err := NewExtension(manifest, code, registry)
		if err != nil {
			t.Fatal(err)
		}
		return extension
	}
	first, second := build("concurrent-a"), build("concurrent-b")
	var group sync.WaitGroup
	for index := 0; index < 4; index++ {
		group.Add(2)
		go func() {
			defer group.Done()
			if _, err := first.Call(context.Background(), "catalog", []any{map[string]any{}, 1, "", ""}); err != nil {
				t.Errorf("a: %v", err)
			}
		}()
		go func() {
			defer group.Done()
			if _, err := second.Call(context.Background(), "catalog", []any{map[string]any{}, 2, "", ""}); err != nil {
				t.Errorf("b: %v", err)
			}
		}()
	}
	group.Wait()
}

// 回归：没有 deadline 的调用也必须能退出，否则死循环脚本会永久持有 e.mu。
func TestScriptCallWatchdogInterruptsLoop(t *testing.T) {
	code := scriptWithHeader(
		"// @id spinner\n// @name 死循环源\n// @version 1.0.0\n// @apiLevel 1",
		`globalThis.source = { catalog(ctx, page) { for (;;) {} } };`,
	)
	manifest, err := ParseScript(code)
	if err != nil {
		t.Fatal(err)
	}
	extension, err := NewExtension(manifest, code, NewRegistry(&fakeHost{}))
	if err != nil {
		t.Fatal(err)
	}
	// 用短 context 模拟看门狗提前触发（真跑 20 秒不适合测试）。
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if _, err := extension.Call(ctx, "catalog", []any{map[string]any{}, 1, "", ""}); err == nil {
		t.Fatal("死循环脚本应当被中断")
	}
	// 中断后锁已释放、运行时已重建，可以继续服务（该脚本仍是死循环，故继续报错）。
	if _, err := extension.Call(ctx, "catalog", []any{map[string]any{}, 1, "", ""}); err == nil {
		t.Fatal("死循环脚本重建后仍应超时")
	}
}

func TestScriptManifestValidation(t *testing.T) {
	cases := []struct {
		name    string
		header  string
		wantErr bool
	}{
		{"valid", "// @id abc\n// @name 源\n// @version 1.0.0\n// @apiLevel 1", false},
		{"defaults", "// @id abc\n// @name 源\n// @version 1.0.0", false},
		{"bad-id", "// @id A_B\n// @name 源\n// @version 1.0.0\n// @apiLevel 1", true},
		{"future-api", "// @id abc\n// @name 源\n// @version 1.0.0\n// @apiLevel 99", true},
		{"bad-version", "// @id abc\n// @name 源\n// @version ！\n// @apiLevel 1", true},
		{"long-name", "// @id abc\n// @name " + strings.Repeat("长", 25) + "\n// @version 1.0.0\n// @apiLevel 1", true},
		{"orphan-group", "// @id abc\n// @name 源\n// @version 1.0.0\n// @groupName 分组", true},
	}
	for _, testCase := range cases {
		_, err := ParseScript(scriptWithHeader(testCase.header, "globalThis.source = {};"))
		if (err != nil) != testCase.wantErr {
			t.Fatalf("%s: err=%v wantErr=%v", testCase.name, err, testCase.wantErr)
		}
	}
	if _, err := ParseScript("globalThis.source = {};"); err == nil {
		t.Fatal("script without header accepted")
	}
}

func TestManifestMetadata(t *testing.T) {
	manifest, err := ParseScript(scriptWithHeader(`// @id abc
// @name 源
// @version 1.0.0
// @restricted true
// @description 描述
// @group huangguo
// @groupName 黄果
// @entryName 视频
// @onlineSearch true
// @pagedSearch true`, "globalThis.source = {};"))
	if err != nil {
		t.Fatal(err)
	}
	if !manifest.Restricted || manifest.Description != "描述" || manifest.Group != "huangguo" ||
		manifest.GroupName != "黄果" || manifest.EntryName != "视频" ||
		!manifest.OnlineSearch || !manifest.PagedSearch || manifest.APILevel != CurrentAPILevel {
		t.Fatalf("metadata mismatch: %+v", manifest)
	}
}

// 能力声明（vip / danmaku / detailFields）必须能被解析与校验，
// 它们是宿主用来替代按源 ID 硬编码的唯一依据。
func TestManifestCapabilities(t *testing.T) {
	manifest, err := ParseScript(scriptWithHeader(`// @id abc
// @name 源
// @version 1.0.0
// @vip true
// @danmaku true
// @detailFields vip, Heat ,onlineDate`, "globalThis.source = {};"))
	if err != nil {
		t.Fatal(err)
	}
	if !manifest.VIP || !manifest.Danmaku {
		t.Fatalf("capability flags lost: %+v", manifest)
	}
	want := []string{"vip", "heat", "onlinedate"}
	if len(manifest.DetailFields) != len(want) {
		t.Fatalf("detailFields mismatch: %v", manifest.DetailFields)
	}
	for index, field := range want {
		if manifest.DetailFields[index] != field {
			t.Fatalf("detailFields[%d]=%q want %q", index, manifest.DetailFields[index], field)
		}
	}

	// 无效字段、重复字段、超量字段都必须拒绝。
	for _, header := range []string{
		"// @id abc\n// @name 源\n// @version 1.0.0\n// @detailFields vip,unknown",
		"// @id abc\n// @name 源\n// @version 1.0.0\n// @detailFields vip,vip",
		"// @id abc\n// @name 源\n// @version 1.0.0\n// @detailFields vip,heat,views,onlineDate,description,tags,releaseStatus",
	} {
		if _, err := ParseScript(scriptWithHeader(header, "globalThis.source = {};")); err == nil {
			t.Fatalf("invalid detailFields accepted: %s", header)
		}
	}
	// 未声明时三者都应保持关闭。
	plain, err := ParseScript(scriptWithHeader("// @id abc\n// @name 源\n// @version 1.0.0", "globalThis.source = {};"))
	if err != nil {
		t.Fatal(err)
	}
	if plain.VIP || plain.Danmaku || len(plain.DetailFields) != 0 {
		t.Fatalf("capabilities defaulted to true: %+v", plain)
	}
}

func TestParseIndex(t *testing.T) {
	entries, err := ParseIndex([]byte(`[{"id":"fixture","name":"测试源","version":"1.0.0","apiLevel":1,"url":"https://example.test/fixture.js","sha256":"` + strings.Repeat("a", 64) + `"}]`))
	if err != nil || len(entries) != 1 || entries[0].URL == "" {
		t.Fatalf("index parse mismatch: %v %v", entries, err)
	}
	for _, raw := range []string{
		`[{"id":"fixture","name":"测试源","version":"1.0.0","apiLevel":99,"url":"https://example.test/fixture.js"}]`,
		`[{"id":"fixture","name":"测试源","version":"1.0.0","apiLevel":1,"url":"https://example.test/fixture.js"},{"id":"fixture","name":"重复","version":"1.0.0","apiLevel":1,"url":"https://example.test/fixture.js"}]`,
		`[{"id":"fixture","name":"测试源","version":"1.0.0","apiLevel":1,"url":"https://example.test/fixture.js","sha256":"abc"}]`,
		`[{"id":"fixture","name":"测试源","version":"1.0.0","apiLevel":1,"url":""}]`,
	} {
		if _, err := ParseIndex([]byte(raw)); err == nil {
			t.Fatalf("invalid index accepted: %s", raw)
		}
	}
	if entries, err := ParseIndex([]byte(`[]`)); err != nil || len(entries) != 0 {
		t.Fatalf("empty index rejected: %v %v", entries, err)
	}
}

// TestBinaryHostAPIRoundTrip 锁定二进制安全的宿主能力：
// 黄豆一类的协议要求请求体（IV+密文）与响应体（密文）按原始字节处理，
// 任何 UTF-8 往返都会破坏字节，因此必须以 base64 视图存取。
func TestBinaryHostAPIRoundTrip(t *testing.T) {
	host := &fakeHost{}
	registry := NewRegistry(host)
	code := scriptWithHeader(`// @id binary
// @name 二进制源
// @version 1.0.0`, `
globalThis.source = {
  categories() { return []; },
  validCategory() { return true; },
  catalog() { return {items: [], hasMore: false}; },
  detail() { return {drama: {sourceId: '1', title: '二进制'}, chapters: [{id: '1'}]}; },
  probe() {
    // 0x00..0xFF 全字节：任何文本转换都会破坏高位字节。
    let allHex = '';
    for (let i = 0; i < 256; i++) {
      allHex += (i < 16 ? '0' : '') + i.toString(16);
    }
    const encoded = hg.crypto.hexdecodeBytes(allHex);
    const keyHex = '000102030405060708090a0b0c0d0e0f';
    const iv = hg.crypto.base64encode('0123456789abcdef');
    const cipher = hg.crypto.aesCBCEncryptBytes(encoded, keyHex, iv);
    const plain = hg.crypto.aesCBCDecryptBytes(cipher, keyHex, iv);
    const joined = hg.crypto.concatBytes(iv, cipher);
    const head = hg.crypto.sliceBytes(joined, 0, 16);
    const tail = hg.crypto.sliceBytes(joined, 16, 0);
    const packed = hg.crypto.gzipBytes(encoded);
    const unpacked = hg.crypto.gunzipBytes(packed);
    const mac = hg.crypto.hmacSha256KeyBytes(iv, encoded);
    const digest = hg.crypto.sha256Bytes(encoded);
    const hex = hg.crypto.hexencodeBytes(encoded);
    const restored = hg.crypto.hexdecodeBytes(hex);
    hg.fetch(source.baseURL + '/upload', {method: 'POST', bodyBase64: joined});
    return {
      base64Identical: plain === encoded,
      unpackedIdentical: unpacked === encoded,
      restoredIdentical: restored === encoded,
      headIsIv: head === iv,
      tailIsCipher: tail === cipher,
      macHexLength: hg.crypto.hexencodeBytes(mac).length,
      digestLength: digest.length,
      rawHexLength: hg.crypto.hexencodeBytes(encoded).length,
    };
  },
};
`)
	manifest, err := ParseScript(code)
	if err != nil {
		t.Fatal(err)
	}
	extension, err := NewExtension(manifest, code, registry)
	if err != nil {
		t.Fatal(err)
	}
	result, err := extension.Call(context.Background(), "probe", nil)
	if err != nil {
		t.Fatal(err)
	}
	row := result.(map[string]any)
	for _, field := range []string{"base64Identical", "unpackedIdentical", "restoredIdentical", "headIsIv", "tailIsCipher"} {
		if row[field] != true {
			t.Fatalf("%s = %v", field, row[field])
		}
	}
	if row["macHexLength"] != int64(64) {
		t.Fatalf("hmac output should be 32 raw bytes (64 hex chars), got %v", row["macHexLength"])
	}
	if row["digestLength"] != int64(64) {
		t.Fatalf("sha256 hex length = %v", row["digestLength"])
	}
	if row["rawHexLength"] != int64(512) {
		t.Fatalf("binary payload should be 256 bytes (512 hex chars), got %v", row["rawHexLength"])
	}
	host.mu.Lock()
	defer host.mu.Unlock()
	if len(host.fetches) != 1 || host.fetches[0].BodyBase64 == "" || host.fetches[0].Body != "" {
		t.Fatalf("binary fetch request not routed through BodyBase64: %+v", host.fetches)
	}
}

func TestHostKitHelpers(t *testing.T) {
	host := &fakeHost{
		response: &Response{Status: 200, Body: `{"ok":true}`},
		stored:   map[string]map[string]string{"kit": {"host": "https://fallback.test"}},
	}
	registry := NewRegistry(host)
	code := scriptWithHeader(`// @id kit
// @name 工具源
// @version 1.0.0`, `
globalThis.source = hgkit.defineSource({
  name: '工具源',
  baseURL: 'https://example.test',
  fallbackHostKey: 'host',
  pageSize: 2,
  categories: [{id: '1', name: '分类'}],
  catalog(ctx, page) { return source.page([], page, {hasMore: false}); },
  detail(ctx, id) { return {drama: {sourceId: id, title: 'x'}, chapters: []}; },
  probe() {
    const drama = source.drama({
      id: '9', title: ' <b>剧名</b> ', cover: '/c.jpg', episodes: '3', categoryName: '类',
    }, {
      validID: (id) => /^\d+$/.test(id),
      tagValues: () => ['标签', '标签', ''],
    });
    return {
      version: hgkit.version,
      category: [source.validCategory(''), source.validCategory('1'), source.validCategory('bad')],
      categories: source.categories({}, false),
      page: source.page([{id: '1'}, {id: '2'}], 1, {total: 3}),
      drama: drama,
      chapters: source.chapters([
        {id: 'b', episode: 2, title: ''},
        {id: 'a', episode: 1, title: '一'},
        {id: 'a', episode: 3, title: '重复'},
      ]).map((item) => item.id + ':' + item.episode + ':' + item.title),
      url: source.url('/a'),
      media: source.mediaURL('//media.test/v.m3u8'),
      cover: source.cover('/c.jpg'),
      base: source.base({host: 'https://mirror.test'}),
      fallbackBase: source.base({}),
      first: source.first(['', '值']),
      meta: source.meta('<meta property="og:title" content="标题">', 'og:title'),
      mediaFlag: [source.isMediaURL('https://media.test/v.m3u8'), source.isMediaURL('https://media.test/page.html')],
      json: source.getJSON({}, '/api').ok,
      resolve: source.resolve({}, {videoUrl: 'https://media.test/v.m3u8'}),
      cloud: hgkit.cloudFrontCredentials(
        {'Set-Cookie': 'CloudFront-Policy=policy; Path=/; Secure, CloudFront-Signature=sig; Path=/, CloudFront-Key-Pair-Id=key; Path=/'},
        'https://media.test/v.m3u8',
        {label: '工具源', referer: 'https://example.test/', expiresAt: 4102444800},
      ),
    };
  },
});
`)
	manifest, err := ParseScript(code)
	if err != nil {
		t.Fatal(err)
	}
	extension, err := NewExtension(manifest, code, registry)
	if err != nil {
		t.Fatal(err)
	}
	result, err := extension.Call(context.Background(), "probe", nil)
	if err != nil {
		t.Fatal(err)
	}
	if accepted, err := extension.Call(context.Background(), "validCategory", []any{"1"}); err != nil || accepted != true {
		t.Fatalf("host-invoked validCategory = %v, %v", accepted, err)
	}
	row := result.(map[string]any)
	if row["version"] != int64(1) {
		t.Fatalf("kit version = %v", row["version"])
	}
	category := row["category"].([]any)
	if category[0] != true || category[1] != true || category[2] != false {
		t.Fatalf("validCategory = %v", category)
	}
	categories := row["categories"].([]any)
	if len(categories) != 1 || categories[0].(map[string]any)["id"] != "1" {
		t.Fatalf("categories = %v", categories)
	}
	page := row["page"].(map[string]any)
	if page["hasMore"] != true {
		t.Fatalf("page = %v", page)
	}
	drama := row["drama"].(map[string]any)
	if drama["sourceId"] != "9" || drama["title"] != "剧名" || drama["cover"] != "https://example.test/c.jpg" ||
		drama["episodes"] != int64(3) || drama["category"] != "类" {
		t.Fatalf("drama = %v", drama)
	}
	tags := drama["tags"].([]any)
	if len(tags) != 1 || tags[0] != "标签" {
		t.Fatalf("tags = %v", tags)
	}
	chapters := row["chapters"].([]any)
	if len(chapters) != 2 || chapters[0] != "a:1:一" || chapters[1] != "b:2:第 2 集" {
		t.Fatalf("chapters = %v", chapters)
	}
	if row["url"] != "https://example.test/a" || row["media"] != "https://media.test/v.m3u8" ||
		row["cover"] != "https://example.test/c.jpg" || row["base"] != "https://mirror.test" ||
		row["fallbackBase"] != "https://fallback.test" || row["first"] != "值" || row["meta"] != "标题" || row["json"] != true {
		t.Fatalf("url helpers = %v", row)
	}
	mediaFlag := row["mediaFlag"].([]any)
	if mediaFlag[0] != true || mediaFlag[1] != false {
		t.Fatalf("isMediaURL = %v", mediaFlag)
	}
	resolve := row["resolve"].(map[string]any)
	if resolve["url"] != "https://media.test/v.m3u8" || resolve["referer"] != "https://fallback.test/" {
		t.Fatalf("default resolve = %v", resolve)
	}
	cloud := row["cloud"].(map[string]any)
	if cloud["cookie"] != "CloudFront-Policy=policy; CloudFront-Signature=sig; CloudFront-Key-Pair-Id=key" ||
		cloud["origin"] != "https://media.test" || cloud["referer"] != "https://example.test/" ||
		cloud["expiresAt"] != int64(4102444800) {
		t.Fatalf("cloudfront credentials = %v", cloud)
	}
}

// source.cards 把"找卡片→取字段→去重→限上限"的骨架沉到宿主，
// 6 个扩展此前各写一份同构的 parseCards。这里覆盖三种取值方式。
func TestHostKitCards(t *testing.T) {
	host := &fakeHost{}
	code := scriptWithHeader(`// @id cards
// @name 卡片源
// @version 1.0.0`, `
globalThis.source = hgkit.defineSource({
  name: '卡片源',
  baseURL: 'https://example.test',
  catalog(ctx, page) { return source.page([], page); },
  detail(ctx, id) { return {drama: {sourceId: id, title: 'x'}, chapters: []}; },
  probe() {
    const body = '<ul class="list">' +
      '<li><a class="card" href="/v/11.html" title=" 剧名A ">' +
      '<img data-src="/c/11.jpg"><span class="note">更新至12集</span></a></li>' +
      '<li><a class="card" href="/v/22.html" title="剧名B">' +
      '<img data-src="/c/22.jpg"><span class="note">完结</span></a></li>' +
      '<li><a class="card" href="/v/11.html" title="重复条目"></a></li>' +
      '</ul>';
    const rows = source.cards(body, {
      container: 'ul.list',
      item: 'a.card',
      id: /\/v\/(\d+)\.html/,
      title: 'attr:title',
      cover: 'img@data-src',
      remark: '.note',
      defaultCategory: '影视',
    });
    // 窗口模式：只取卡片后续 N 字符，模拟 hanxiaoquan 的写法。
    const windowed = source.cards(
      '<a href="/v/33.html" title="窗口剧">' + 'x'.repeat(700) +
      '<img data-src="/c/wrong.jpg"></a>',
      {
        item: 'a',
        id: /\/v\/(\d+)\.html/,
        title: 'attr:title',
        cover: 'img@data-src',
        window: 300,
      },
    );
    return {
      count: rows.length,
      first: rows[0],
      second: rows[1],
      windowedCover: windowed.length ? windowed[0].cover : '',
    };
  },
});
`)
	manifest, err := ParseScript(code)
	if err != nil {
		t.Fatal(err)
	}
	extension, err := NewExtension(manifest, code, NewRegistry(host))
	if err != nil {
		t.Fatal(err)
	}
	result, err := extension.Call(context.Background(), "probe", nil)
	if err != nil {
		t.Fatal(err)
	}
	row := result.(map[string]any)

	// 重复 ID 应被去掉：3 张卡片只留 2 条。
	if row["count"] != int64(2) {
		t.Fatalf("cards count = %v", row["count"])
	}
	first := row["first"].(map[string]any)
	if first["sourceId"] != "11" || first["title"] != "剧名A" {
		t.Fatalf("first card = %v", first)
	}
	// 相对封面应解析成绝对地址并通过媒体地址校验。
	if first["cover"] != "https://example.test/c/11.jpg" {
		t.Fatalf("cover = %v", first["cover"])
	}
	if first["remark"] != "更新至12集" || first["category"] != "影视" {
		t.Fatalf("first card remark/category = %v", first)
	}
	// 窗口模式：只取前 300 字符，后面的 img 不该被读到。
	if row["windowedCover"] != "" {
		t.Fatalf("window should hide trailing cover, got %v", row["windowedCover"])
	}
}

// source.macPlaylist 覆盖苹果 CMS 的两种播放页形态。
func TestHostKitMacPlaylist(t *testing.T) {
	host := &fakeHost{}
	code := scriptWithHeader(`// @id mac
// @name MacCMS 源
// @version 1.0.0`, `
globalThis.source = hgkit.defineSource({
  name: 'MacCMS 源',
  baseURL: 'https://example.test',
  catalog(ctx, page) { return source.page([], page); },
  detail(ctx, id) { return {drama: {sourceId: id, title: 'x'}, chapters: []}; },
  probe() {
    const now = source.macPlaylist({}, '/play/1-1-1.html', {
      body: '<script>var now="https://media.test/v/1.m3u8";</script>',
    });
    const direct = source.macPlaylist({}, '/play/1-1-1.html', {
      body: '<div>https://media.test/direct/2.mp4?token=a</div>',
    });
    let missing = '';
    try {
      source.macPlaylist({}, '/play/1-1-1.html', {body: '<div>no media here</div>'});
    } catch (error) {
      missing = error.message;
    }
    return {now: now.url, nowReferer: now.referer, direct: direct.url, missing: missing};
  },
});
`)
	manifest, err := ParseScript(code)
	if err != nil {
		t.Fatal(err)
	}
	extension, err := NewExtension(manifest, code, NewRegistry(host))
	if err != nil {
		t.Fatal(err)
	}
	result, err := extension.Call(context.Background(), "probe", nil)
	if err != nil {
		t.Fatal(err)
	}
	row := result.(map[string]any)
	if row["now"] != "https://media.test/v/1.m3u8" {
		t.Fatalf("var now extraction = %v", row["now"])
	}
	if row["nowReferer"] != "https://example.test/" {
		t.Fatalf("referer = %v", row["nowReferer"])
	}
	if row["direct"] != "https://media.test/direct/2.mp4?token=a" {
		t.Fatalf("direct url = %v", row["direct"])
	}
	if missing, _ := row["missing"].(string); !strings.Contains(missing, "暂无可用播放地址") {
		t.Fatalf("missing media should error, got %q", missing)
	}
}

// source.int 是 7 个扩展此前各自实现的 integer() 的统一版本。
// 语义固定为"非负整数，超上限返回 null"，这里锁定边界。
func TestHostKitIntBoundaries(t *testing.T) {
	code := scriptWithHeader(`// @id ints
// @name 整数源
// @version 1.0.0`, `
globalThis.source = hgkit.defineSource({
  name: '整数源', baseURL: 'https://e.test',
  catalog(ctx, p) { return source.page([], p); },
  detail(ctx, i) { return {drama: {sourceId: i, title: 'x'}, chapters: []}; },
  probe() {
    return {
      number: source.int(42, 100),
      numericText: source.int(' 42 ', 100),
      zero: source.int(0, 100),
      negative: source.int(-1, 100),
      overLimit: source.int(101, 100),
      notNumber: source.int('abc', 100),
      decimal: source.int(1.9, 100),
      empty: source.int('', 100),
    };
  },
});
`)
	manifest, err := ParseScript(code)
	if err != nil {
		t.Fatal(err)
	}
	extension, err := NewExtension(manifest, code, NewRegistry(&fakeHost{}))
	if err != nil {
		t.Fatal(err)
	}
	result, err := extension.Call(context.Background(), "probe", nil)
	if err != nil {
		t.Fatal(err)
	}
	row := result.(map[string]any)
	// 有效值：数字、带空格的数字串、0；小数向下取整。
	if row["number"] != int64(42) || row["numericText"] != int64(42) || row["zero"] != int64(0) {
		t.Fatalf("valid ints = %v", row)
	}
	if row["decimal"] != int64(1) {
		t.Fatalf("decimal should floor, got %v", row["decimal"])
	}
	// 无效值：负数、超限、非数字、空串一律 null。
	for _, key := range []string{"negative", "overLimit", "notNumber", "empty"} {
		if row[key] != nil {
			t.Fatalf("%s should be nil, got %v", key, row[key])
		}
	}
}

// hgkit 按层拆分后，注入顺序就是依赖顺序。若有人在 kit-core 里引用
// 上层能力（例如 cleanText 依赖 hg.html），运行时会得到 undefined。
// 这里逐层加载并断言公开面在每一步之后都成立。
func TestHostKitLayerOrder(t *testing.T) {
	if len(hostKitSources) < 2 {
		t.Fatal("工具库应至少拆成两层")
	}
	// 每层必须声明自己的文件名，便于 goja 报错定位。
	for _, file := range hostKitSources {
		if file.name == "" || file.source == "" {
			t.Fatalf("工具库片段缺少名称或内容: %+v", file.name)
		}
	}
	// 顺序断言：core 建立命名空间 → ... → kit.js 最后装配。
	if hostKitSources[0].name != "kit-core.js" {
		t.Fatalf("首层应为 kit-core.js，实际 %s", hostKitSources[0].name)
	}
	if last := hostKitSources[len(hostKitSources)-1].name; last != "kit.js" {
		t.Fatalf("末层应为 kit.js，实际 %s", last)
	}

	// 逐层加载：任何一层单独失败都会在这里暴露，而不是等到扩展运行期。
	vm := goja.New()
	for _, file := range hostKitSources {
		program, err := goja.Compile(file.name, file.source, false)
		if err != nil {
			t.Fatalf("%s 编译失败: %v", file.name, err)
		}
		if _, err := vm.RunProgram(program); err != nil {
			t.Fatalf("%s 执行失败: %v", file.name, err)
		}
	}
	kit := vm.Get("hgkit")
	if kit == nil || goja.IsUndefined(kit) {
		t.Fatal("hgkit 命名空间未建立")
	}
	object, ok := kit.(*goja.Object)
	if !ok {
		t.Fatal("hgkit 必须是对象")
	}
	// 装配完成后，扩展会用到的公开面必须齐全。
	for _, name := range []string{
		"defineSource", "url", "text", "int", "pick", "first",
		"cleanText", "tags", "mediaURL", "isMediaURL", "coverURL",
		"metaContent", "page", "chapters", "drama", "fetchText", "fetchJSON",
		"cloudFrontCredentials", "extractMacMedia", "cards", "fieldValue",
	} {
		if value := object.Get(name); value == nil || goja.IsUndefined(value) {
			t.Fatalf("hgkit.%s 缺失", name)
		}
	}
}
