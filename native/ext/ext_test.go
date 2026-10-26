package ext

import (
	"context"
	"strings"
	"sync"
	"testing"
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
