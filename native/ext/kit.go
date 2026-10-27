package ext

import (
	_ "embed"
	"strings"
)

// hgkit 按层拆分后逐个内嵌；注入顺序即依赖顺序，后者可以使用前者的能力。
// 拆分的理由：单文件超过 500 行后，新增能力时改动面与评审成本都过高，
// 且每个 helper 难以单独测试。

//go:embed kit-core.js
var kitCoreSource string

//go:embed kit-html.js
var kitHtmlSource string

//go:embed kit-normalize.js
var kitNormalizeSource string

//go:embed kit-net.js
var kitNetSource string

//go:embed kit-maccms.js
var kitMaccmsSource string

//go:embed kit.js
var kitAssembleSource string

// hostKitFile 是一段工具库源码及其文件名（文件名用于 goja 报错定位）。
type hostKitFile struct {
	name   string
	source string
}

// hostKitSources 是按注入顺序排列的工具库片段。
//
// kit-core 负责建立 globalThis.hgkit 命名空间，其余片段假定它已存在；
// kit.js 最后注入，把能力挂到 source 上。
var hostKitSources = []hostKitFile{
	{"kit-core.js", kitCoreSource},
	{"kit-html.js", kitHtmlSource},
	{"kit-normalize.js", kitNormalizeSource},
	{"kit-net.js", kitNetSource},
	{"kit-maccms.js", kitMaccmsSource},
	{"kit.js", kitAssembleSource},
}

// hostKitSource 返回拼接后的工具库源码，供测试与诊断使用。
func hostKitSource() string {
	parts := make([]string, 0, len(hostKitSources))
	for _, file := range hostKitSources {
		parts = append(parts, file.source)
	}
	return strings.Join(parts, "\n")
}
