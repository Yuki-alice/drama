package core

import (
	"net/http"
	"testing"
)

func sourceSettingsEngine(t *testing.T) *nativeEngine {
	t.Helper()
	engine := sourceFixtureEngine(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, 200, "ok"), nil
	})
	installTestExtension(t, engine, "huangdou")
	return engine
}

// 镜像地址是 hgkit 的 source.base() 已经支持的覆盖键；此前只有读取没有写入，
// 属于"文档承诺、界面缺失"。这里验证读写链路与校验。
func TestSourceSettingsRoundTrip(t *testing.T) {
	engine := sourceSettingsEngine(t)

	settings, err := engine.sourceSettings("huangdou")
	if err != nil {
		t.Fatal(err)
	}
	rows := settings.(map[string]any)["settings"].([]any)
	if len(rows) != 1 {
		t.Fatalf("设置项数量不符: %+v", rows)
	}
	first := rows[0].(map[string]any)
	if first["key"] != sourceSettingBaseURL || first["value"] != "" {
		t.Fatalf("默认设置不符: %+v", first)
	}

	if _, err := engine.saveSourceSetting("huangdou", sourceSettingBaseURL, "https://mirror.example.test/"); err != nil {
		t.Fatal(err)
	}
	settings, err = engine.sourceSettings("huangdou")
	if err != nil {
		t.Fatal(err)
	}
	value := settings.(map[string]any)["settings"].([]any)[0].(map[string]any)["value"]
	if value != "https://mirror.example.test" {
		t.Fatalf("保存后的镜像地址不符: %v", value)
	}
	// 扩展侧读取同一份存储。
	values, _, err := engine.downloader.extensions.storageValues("huangdou")
	if err != nil {
		t.Fatal(err)
	}
	if values[sourceSettingBaseURL] != "https://mirror.example.test" {
		t.Fatalf("扩展读不到镜像地址: %v", values)
	}

	// 空值表示清除，回落到扩展默认。
	if _, err := engine.saveSourceSetting("huangdou", sourceSettingBaseURL, ""); err != nil {
		t.Fatal(err)
	}
	values, _, err = engine.downloader.extensions.storageValues("huangdou")
	if err != nil {
		t.Fatal(err)
	}
	if _, found := values[sourceSettingBaseURL]; found {
		t.Fatalf("清除后仍残留镜像地址: %v", values)
	}
}

func TestSourceSettingsRejectsInvalidValues(t *testing.T) {
	engine := sourceSettingsEngine(t)

	cases := []struct{ key, value string }{
		{sourceSettingBaseURL, "not-a-url"},
		{sourceSettingBaseURL, "ftp://example.test"},
		{sourceSettingBaseURL, "http://127.0.0.1:8080"},
		{sourceSettingBaseURL, "http://10.0.0.5"},
		{"unknownKey", "https://example.test"},
	}
	for _, testCase := range cases {
		_, err := engine.saveSourceSetting("huangdou", testCase.key, testCase.value)
		if err == nil {
			t.Fatalf("%s=%q 应被拒绝", testCase.key, testCase.value)
		}
	}
	// 未安装的扩展不能读设置。
	if _, err := engine.sourceSettings("notinstalled"); err == nil {
		t.Fatal("未安装扩展应拒绝读取设置")
	}
}

// detailFields 取代了按源 ID 硬编码的补资料规则。
func TestNativeNeedsExtraMetadataFollowsManifest(t *testing.T) {
	engine := sourceSettingsEngine(t)
	d := engine.downloader

	// 黄豆声明 vip,heat：两者任一缺失都应补。
	if !nativeNeedsExtraMetadata(d, nativeDrama{ID: "huangdou:1", Source: sourceHuangdou, VIP: nil, Heat: "100"}) {
		t.Fatal("缺少 VIP 时应补资料")
	}
	if !nativeNeedsExtraMetadata(d, nativeDrama{ID: "huangdou:1", Source: sourceHuangdou, Heat: ""}) {
		t.Fatal("缺少热度时应补资料")
	}
	vip := false
	if nativeNeedsExtraMetadata(d, nativeDrama{ID: "huangdou:1", Source: sourceHuangdou, VIP: &vip, Heat: "100"}) {
		t.Fatal("资料齐备时不应再补")
	}

	// 未声明 detailFields 的源不补：鬼片清单里没有该字段。
	installTestExtension(t, engine, "guipian")
	if nativeNeedsExtraMetadata(d, nativeDrama{ID: "guipian:1", Source: sourceGuipian}) {
		t.Fatal("未声明 detailFields 的源不应补资料")
	}
}

// VIP 能力由清单声明，宿主不再按源 ID 判断。
func TestSourceSupportsVIPFollowsManifest(t *testing.T) {
	engine := sourceSettingsEngine(t)
	if engine.sourceSupportsVIP(sourceHongguo) {
		t.Fatal("内置红果不声明 VIP")
	}
	if !engine.sourceSupportsVIP(sourceHuangdou) {
		t.Fatal("黄豆声明了 VIP")
	}
	installTestExtension(t, engine, "guipian")
	if engine.sourceSupportsVIP(sourceGuipian) {
		t.Fatal("鬼片未声明 VIP")
	}
}

// 每源设置由清单声明，宿主只渲染与存储：加一项设置不需要改客户端。
func TestSourceSettingsFollowManifest(t *testing.T) {
	engine := sourceSettingsEngine(t)

	// 青空声明了 pageSize（choice）；黄豆没有声明额外项。
	installTestExtension(t, engine, "sorani")
	settings, err := engine.sourceSettings("sorani")
	if err != nil {
		t.Fatal(err)
	}
	rows := settings.(map[string]any)["settings"].([]any)
	if len(rows) != 2 {
		t.Fatalf("应为内置镜像 + 声明项共 2 项: %+v", rows)
	}
	declared := rows[1].(map[string]any)
	if declared["key"] != "pageSize" || declared["type"] != "choice" {
		t.Fatalf("声明项不符: %+v", declared)
	}
	// 未设置时应回落到声明默认值。
	if declared["value"] != "24" {
		t.Fatalf("默认值不符: %v", declared["value"])
	}
	if options := declared["options"].([]any); len(options) != 3 {
		t.Fatalf("选项数量不符: %+v", options)
	}

	if _, err := engine.saveSourceSetting("sorani", "pageSize", "48"); err != nil {
		t.Fatal(err)
	}
	values, _, err := engine.downloader.extensions.storageValues("sorani")
	if err != nil {
		t.Fatal(err)
	}
	if values["pageSize"] != "48" {
		t.Fatalf("扩展读不到设置: %v", values)
	}

	// 不在允许范围内的选项应被拒绝。
	if _, err := engine.saveSourceSetting("sorani", "pageSize", "9999"); err == nil {
		t.Fatal("非法选项应被拒绝")
	}
	// 未声明的键也应被拒绝。
	if _, err := engine.saveSourceSetting("sorani", "noSuchKey", "x"); err == nil {
		t.Fatal("未声明的设置项应被拒绝")
	}
}
