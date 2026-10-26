package core

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"sync"
	"time"
)

const rankingCacheTTL = 5 * time.Minute

type rankingBoard struct {
	ID          string `json:"id"`
	Source      string `json:"source"`
	Name        string `json:"name"`
	Description string `json:"description"`
	path        string
	upstreamKey string
}

// builtinRankingBoards 是仍由 Go 核心提供的榜单（目前仅红果）。
// 其余站源的榜单由扩展通过 rankings 契约自行声明，见 rankingProvider。
var builtinRankingBoards = []rankingBoard{
	{ID: "hongguo-hot", Source: sourceHongguo, Name: "总热播榜", Description: "红果观看、互动等综合热度；每日更新。", path: "hot-drama", upstreamKey: "hongguo"},
	{ID: "hongguo-real", Source: sourceHongguo, Name: "真人剧榜", Description: "红果真人剧热播榜；每日更新。", path: "hot-real-drama", upstreamKey: "real"},
	{ID: "hongguo-comic", Source: sourceHongguo, Name: "漫剧榜", Description: "红果漫剧热播榜；每日更新。", path: "hot-comic-drama", upstreamKey: "comic"},
	{ID: "hongguo-ai", Source: sourceHongguo, Name: "AI剧榜", Description: "红果 AI 剧热播榜；每日更新。", path: "hot-ai-drama", upstreamKey: "ai"},
}

type rankingItem struct {
	Rank   int    `json:"rank"`
	Drama  Drama  `json:"drama"`
	Metric string `json:"metric,omitempty"`
}

type rankingPage struct {
	BoardID     string        `json:"boardId"`
	Page        int           `json:"page"`
	Items       []rankingItem `json:"items"`
	HasMore     bool          `json:"hasMore"`
	TotalPages  int           `json:"totalPages,omitempty"`
	UpdatedText string        `json:"updatedText,omitempty"`
	FetchedAt   time.Time     `json:"fetchedAt"`
	Stale       bool          `json:"stale,omitempty"`
	Warning     string        `json:"warning,omitempty"`
}

type rankingCall struct {
	done chan struct{}
	page rankingPage
	err  error
}

type rankingCache struct {
	mu      sync.Mutex
	pages   map[string]rankingPage
	pending map[string]*rankingCall
}

// rankingBoards 汇总当前可用的榜单：内置（红果）在前，扩展源榜单随后。
// 扩展未安装时其榜单自然缺席，与站源可用性保持一致。
func (d *Downloader) rankingBoards() []rankingBoard {
	boards := append([]rankingBoard{}, builtinRankingBoards...)
	if d == nil || d.providers == nil {
		return boards
	}
	seen := map[string]bool{}
	for _, board := range boards {
		seen[board.ID] = true
	}
	for source, provider := range d.providers.all() {
		ext, ok := provider.(rankingProvider)
		if !ok {
			continue
		}
		for _, board := range ext.RankingBoards() {
			if board.ID == "" || seen[board.ID] {
				continue
			}
			// 榜单归属与来源由宿主覆写，扩展不能声明其他源的榜单。
			board.Source = source
			seen[board.ID] = true
			boards = append(boards, board)
		}
	}
	return boards
}

// findRankingBoard 只在内置榜单中查找（目前仅红果）。
// 完整榜单表（内置 + 已装扩展）由 Downloader.rankingBoards 提供。
func findRankingBoard(id string) (rankingBoard, bool) {
	for _, board := range builtinRankingBoards {
		if board.ID == id {
			return board, true
		}
	}
	return rankingBoard{}, false
}

// findRankingBoard 在运行期完整榜单表中查找：内置 + 已装扩展。
func (d *Downloader) findRankingBoard(id string) (rankingBoard, bool) {
	for _, board := range d.rankingBoards() {
		if board.ID == id {
			return board, true
		}
	}
	return rankingBoard{}, false
}

// rankingSource 返回榜单的提供方（内置 Go 或扩展），未找到时返回 nil。
func (d *Downloader) rankingSource(board rankingBoard) (sourceProvider, bool) {
	if d == nil || d.providers == nil {
		return nil, false
	}
	return d.providers.get(board.Source)
}

func cloneRankingPage(page rankingPage) rankingPage {
	page.Items = append([]rankingItem{}, page.Items...)
	return page
}

func rankingDramaWithoutImages(drama Drama) Drama {
	drama.Cover, drama.CoverURL, drama.CoverURLSnake = nil, nil, nil
	drama.Image, drama.ImageURL, drama.ImageURLSnake = nil, nil, nil
	drama.Img, drama.Pic, drama.Picture = nil, nil, nil
	drama.Poster, drama.Thumb, drama.Thumbnail = nil, nil, nil
	return drama
}

func (d *Downloader) loadRankingPage(ctx context.Context, board rankingBoard, page int, refresh bool) (rankingPage, error) {
	key := board.ID + ":" + strconv.Itoa(page)
	cache := &d.rankings
	cache.mu.Lock()
	if cache.pages == nil {
		cache.pages = map[string]rankingPage{}
		cache.pending = map[string]*rankingCall{}
	}
	cached, exists := cache.pages[key]
	if exists && !refresh && time.Since(cached.FetchedAt) >= 0 && time.Since(cached.FetchedAt) < rankingCacheTTL {
		cache.mu.Unlock()
		return cloneRankingPage(cached), nil
	}
	if pending := cache.pending[key]; pending != nil {
		cache.mu.Unlock()
		select {
		case <-ctx.Done():
			return rankingPage{}, ctx.Err()
		case <-pending.done:
			if (errors.Is(pending.err, context.Canceled) || errors.Is(pending.err, context.DeadlineExceeded)) && ctx.Err() == nil {
				return d.loadRankingPage(ctx, board, page, refresh)
			}
			return cloneRankingPage(pending.page), pending.err
		}
	}
	pending := &rankingCall{done: make(chan struct{})}
	cache.pending[key] = pending
	cache.mu.Unlock()

	result, err := d.fetchRankingPage(ctx, board, page)
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if err == nil {
		result.BoardID, result.Page, result.FetchedAt = board.ID, page, time.Now()
		if refresh && page == 1 {
			for cachedKey, old := range cache.pages {
				if old.BoardID == board.ID {
					delete(cache.pages, cachedKey)
				}
			}
		}
		if len(cache.pages) >= 128 {
			oldestKey, oldest := "", time.Now()
			for cachedKey, old := range cache.pages {
				if old.FetchedAt.Before(oldest) {
					oldestKey, oldest = cachedKey, old.FetchedAt
				}
			}
			delete(cache.pages, oldestKey)
		}
		cache.pages[key] = cloneRankingPage(result)
		d.writeRankingCacheLocked()
	} else if exists && ctx.Err() == nil && time.Since(cached.FetchedAt) >= 0 && time.Since(cached.FetchedAt) < 24*time.Hour {
		result = cloneRankingPage(cached)
		result.Stale = true
		result.Warning = "站点暂不可用，显示上次取得的榜单，请稍后刷新。"
		err = nil
	}
	pending.page, pending.err = cloneRankingPage(result), err
	delete(cache.pending, key)
	close(pending.done)
	return result, err
}

// fetchRankingPage 分派榜单拉取：红果走内置实现，其余走扩展的 rankings 契约。
func (d *Downloader) fetchRankingPage(ctx context.Context, board rankingBoard, page int) (rankingPage, error) {
	if board.Source == sourceHongguo {
		return d.fetchHongguoRankingPage(ctx, board, page)
	}
	provider, ok := d.rankingSource(board)
	if !ok {
		return rankingPage{}, errNativeBuildSource
	}
	ext, ok := provider.(rankingProvider)
	if !ok {
		return rankingPage{}, fmt.Errorf("%s 未提供榜单", board.Source)
	}
	result, err := ext.RankingPage(ctx, board, page)
	if err != nil {
		return rankingPage{}, err
	}
	if len(result.Items) > 100 {
		return rankingPage{}, errors.New("榜单条目过多")
	}
	if page != 1 && len(result.Items) == 0 && result.HasMore {
		return rankingPage{}, errors.New("榜单未返回应有的条目，请重试")
	}
	// 主键与来源由宿主强制覆写，扩展不能伪造其他源的条目。
	for index := range result.Items {
		result.Items[index].Drama.Source = board.Source
		result.Items[index].Drama.ID = providerDramaID(board.Source, result.Items[index].Drama.SourceID)
		if result.Items[index].Rank <= 0 {
			result.Items[index].Rank = (page-1)*20 + index + 1
		}
	}
	return result, nil
}
