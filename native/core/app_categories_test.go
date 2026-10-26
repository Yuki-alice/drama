package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
)

func TestNativeCategoryPaginationStaysIndependent(t *testing.T) {
	engine := sourceFixtureEngine(t, func(request *http.Request) (*http.Response, error) {
		if !strings.HasPrefix(request.URL.Path, "/api/videos/category/ai-") {
			return nil, errors.New("only catalog JSON is permitted")
		}
		category := request.URL.Path[strings.LastIndex(request.URL.Path, "/")+1:]
		page := request.URL.Query().Get("page")
		count := 24
		if page != "1" {
			count = 1
		}
		rows := make([]map[string]any, count)
		for index := range rows {
			rows[index] = map[string]any{"id": fmt.Sprintf("%s-%s-%d", category, page, index), "title": "合成分类剧集"}
		}
		body, _ := json.Marshal(map[string]any{"data": rows})
		return sourceFixtureResponse(request, 200, string(body)), nil
	})
	// 黄果 AI 已迁到 JS 扩展：安装并把站点根指向 fixture。
	installTestExtension(t, engine, "huangguoai")
	setExtensionBaseURL(t, engine, "huangguoai", "https://huangguoai.test")
	for _, input := range []nativeInput{
		{Source: sourceHuangguoAI, Category: "ai-duanju", Page: 1},
		{Source: sourceHuangguoAI, Category: "ai-duanju", Page: 2},
		{Source: sourceHuangguoAI, Category: "ai-manju", Page: 1},
	} {
		if _, err := engine.nativeCatalog(context.Background(), input); err != nil {
			t.Fatal(err)
		}
	}
	short := engine.nativeCached(nativeCatalogKey(sourceHuangguoAI, "ai-duanju"))
	comic := engine.nativeCached(nativeCatalogKey(sourceHuangguoAI, "ai-manju"))
	if short.Page != 2 || short.HasMore || len(short.Items) != 25 || comic.Page != 1 || !comic.HasMore || len(comic.Items) != 24 {
		t.Fatal("category cursors or entries leaked", short.Page, short.HasMore, len(short.Items), comic.Page, comic.HasMore, len(comic.Items))
	}
	for _, row := range comic.Items {
		if !strings.Contains(row.ID, "ai-manju") {
			t.Fatal("another category was merged into the selected list")
		}
	}
	if len(engine.nativeCached(sourceHuangguoAI).Items) != 49 {
		t.Fatal("source management lost categorized titles")
	}
	restored := &nativeEngine{directory: engine.directory, catalogs: map[string][]nativeDrama{}, catalogStates: map[string]nativeCatalogState{}}
	restored.loadCatalogCache()
	if restored.nativeCached(nativeCatalogKey(sourceHuangguoAI, "ai-duanju")).Page != 2 {
		t.Fatal("category position was not persisted")
	}
}
