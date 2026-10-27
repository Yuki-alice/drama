package core

import "errors"

// coreProtocolVersion 标识 Dart/Go 请求协议版本，用于诊断日志。
const coreProtocolVersion = "0.2.17"

var errNativeBuildSource = errors.New("当前版本不包含此站源")

// nativeSourceAvailable：红果是唯一内置源，恒可用；其余站源均按扩展安装表放行。
func nativeSourceAvailable(source string) bool {
	source = canonicalProviderSource(source)
	if source == sourceHongguo {
		return true
	}
	nativeState.Lock()
	defer nativeState.Unlock()
	if engine := nativeState.engine; engine != nil && engine.downloader != nil && engine.downloader.extensions != nil {
		return engine.downloader.extensions.Installed(source)
	}
	return false
}

func nativeDramaAvailable(drama nativeDrama) bool {
	source, _, valid := splitProviderDramaID(drama.ID)
	return valid && nativeSourceAvailable(source) &&
		(drama.Source == "" || canonicalProviderSource(drama.Source) == source)
}

func nativeChapterAvailable(drama nativeDrama, chapter Chapter) bool {
	if !nativeDramaAvailable(drama) {
		return false
	}
	source, _, _ := splitProviderDramaID(drama.ID)
	if chapter.Source != "" && canonicalProviderSource(chapter.Source) != source {
		return false
	}
	if chapterSource, _, valid := splitProviderDramaID(chapter.ID); valid && chapterSource != source {
		return false
	}
	return true
}

func nativeDownloadAvailable(job nativeDownloadJob) bool {
	return nativeChapterAvailable(job.Drama, job.Chapter)
}

func nativeAuthorizeInput(input nativeInput) error {
	switch input.Action {
	case "recommendations", "cachedRecommendations", "suggestions", "danmaku":
		if !nativeSourceAvailable(sourceHongguo) {
			return errNativeBuildSource
		}
	case "rankings":
		// 榜单表在运行期由内置榜单与已装扩展共同构成，本函数不持有 engine；
		// 归属与可用性由 nativeRanking 统一校验。
		if input.Board == "" {
			return errNativeBuildSource
		}
	case "catalog", "cached", "categories", "sourceStatus", "sourceJob", "cancelSourceJob",
		"sourceSettings", "saveSourceSetting":
		if !nativeSourceAvailable(input.Source) {
			return errNativeBuildSource
		}
		if input.Action == "sourceJob" && input.Drama.ID != "" &&
			(!nativeDramaAvailable(input.Drama) || sourceFromDramaID(input.Drama.ID) != canonicalProviderSource(input.Source)) {
			return errNativeBuildSource
		}
	case "cover", "prepareCover", "detail", "metadata", "followCheck", "resolve", "preload", "prepareHandoff", "enqueueDownloads", "localPlayback":
		if !nativeDramaAvailable(input.Drama) {
			return errNativeBuildSource
		}
		if (input.Action == "resolve" || input.Action == "preload" || input.Action == "prepareHandoff") && !nativeChapterAvailable(input.Drama, input.Chapter) {
			return errNativeBuildSource
		}
	}
	return nil
}
