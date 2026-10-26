package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 引擎构造会经 nativeSourceAvailable 再次取用 nativeState；
// 若 initialize 在持锁状态下构造引擎，带榜单缓存的第二次启动会永久死锁。
func TestInitializeWithRankingCacheReturns(t *testing.T) {
	directory := t.TempDir()
	pages := map[string]rankingPage{
		"hongguo-hot:1": {
			BoardID:   "hongguo-hot",
			Page:      1,
			FetchedAt: time.Now(),
			Items: []rankingItem{
				{Rank: 1, Drama: Drama{ID: "hongguo:1", Source: sourceHongguo, Title: "样本"}},
			},
		},
	}
	body, err := json.Marshal(pages)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "rankings.json"), body, 0600); err != nil {
		t.Fatal(err)
	}
	request, err := json.Marshal(map[string]string{
		"action": "initialize", "directory": directory,
	})
	if err != nil {
		t.Fatal(err)
	}
	results := make(chan string, 1)
	go func() { results <- NativeRequest(string(request)) }()
	select {
	case result := <-results:
		if !strings.Contains(result, `"ok":true`) {
			t.Fatalf("initialize 失败: %s", result)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("initialize 未返回，引擎构造发生死锁")
	}
}
