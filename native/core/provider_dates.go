package core

// 站源日期归一：站点可能给 RFC3339、纯日期或 Unix 时间戳。
// 保留在 Go 侧是因为红果榜单与详情仍由内置实现解析。

import (
	"strconv"
	"strings"
	"time"
)

// providerReleaseDate 归一上线日期为 YYYY-MM-DD；无法识别或超出合理范围时返回空。
func providerReleaseDate(value string) string {
	value = strings.TrimSpace(value)
	if stamp, err := time.Parse(time.RFC3339Nano, value); err == nil {
		value = stamp.In(providerChinaTime).Format("2006-01-02")
	}
	date := normalizeDate(value)
	if parsed, err := time.Parse("2006-01-02", date); err != nil || parsed.Year() < 2000 || parsed.Year() > 2100 {
		return ""
	}
	return date
}

// providerTimestampDate 把 Unix 时间戳（秒或毫秒）归一为 YYYY-MM-DD。
func providerTimestampDate(value string) string {
	stamp, err := strconv.ParseInt(strings.TrimSpace(value), 10, 64)
	if err != nil || stamp <= 0 {
		return ""
	}
	if stamp > 100_000_000_000 {
		stamp /= 1000
	}
	date := time.Unix(stamp, 0).In(providerChinaTime)
	if date.Year() < 2000 || date.Year() > 2100 {
		return ""
	}
	return date.Format("2006-01-02")
}
