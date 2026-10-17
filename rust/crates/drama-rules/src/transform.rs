//! 过滤器：对取出的原始值做归一化。
//!
//! ## 封闭集合
//!
//! 过滤器名是**白名单**——校验器会在安装期拒绝未知名字。
//! 新增过滤器 = 改这里 + 更新校验白名单 + 补测试，没有第三条路。

use std::sync::OnceLock;

/// 过滤器错误。
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum FilterError {
    #[error("未知过滤器: {0}")]
    Unknown(String),
    #[error("过滤器 {0} 参数无效: {1}")]
    BadArgument(&'static str, String),
    #[error("正则无效: {0}")]
    BadRegex(String),
}

/// 应用过滤器链（按序）。
pub fn apply_chain(
    input: &str,
    filters: &[String],
    base_url: Option<&url::Url>,
) -> Result<String, FilterError> {
    let mut value = input.to_owned();
    for filter in filters {
        value = apply_one(&value, filter, base_url)?;
    }
    Ok(value)
}

/// 应用单个过滤器。
///
/// 带参数的过滤器写成 `name:arg`（如 `truncate:512`、`replace:A:B`）。
pub fn apply_one(
    input: &str,
    filter: &str,
    base_url: Option<&url::Url>,
) -> Result<String, FilterError> {
    // `re:<pattern>:<group>` —— 正则提取。
    //
    // 放在过滤器链里（而不是只放 `from`）是必要的：MacCMS 的 id 要从
    // `href="/vod/49477.html"` 里抠出 `49477`，先取值再提取是最自然的写法。
    if let Some(rest) = filter.trim().strip_prefix("re:") {
        return apply_regex(input, rest);
    }
    let (name, arg) = match filter.split_once(':') {
        Some((n, a)) => (n.trim(), a.trim()),
        None => (filter.trim(), ""),
    };
    let value = match name {
        "strip_tags" => strip_tags(input),
        "unescape" => unescape_html(input),
        "collapse_ws" => collapse_ws(input),
        "truncate" => {
            let limit = arg.parse::<usize>().map_err(|e| {
                FilterError::BadArgument("truncate", format!("{arg}: {e}"))
            })?;
            truncate_chars(input, limit)
        }
        "absolutize" => absolutize(input, base_url),
        "episode_number" => episode_number(input).map(|n| n.to_string()).unwrap_or_default(),
        "status_map" => status_map(input).to_owned(),
        "date_normalize" => date_normalize(input).unwrap_or_default(),
        "views_normalize" => views_normalize(input),
        "first_non_empty" => first_non_empty(input),
        "lowercase" => input.to_lowercase(),
        "uppercase" => input.to_uppercase(),
        "trim" => input.trim().to_owned(),
        "replace" => {
            let (from, to) = arg
                .split_once(':')
                .ok_or_else(|| FilterError::BadArgument("replace", arg.to_owned()))?;
            input.replace(from, to)
        }
        "trim_suffix" => {
            // `trim_suffix:,` → 去掉尾随逗号（MacCMS 的 m3u8 常见脏数据）。
            let mut value = input.trim().to_owned();
            while !arg.is_empty() && value.ends_with(arg) {
                value.truncate(value.len() - arg.len());
            }
            value
        }
        "trim_prefix" => {
            let mut value = input.trim().to_owned();
            while !arg.is_empty() && value.starts_with(arg) {
                value = value[arg.len()..].to_owned();
            }
            value
        }
        "after" => {
            // `after:第` → 取第一次出现之后的全部。
            match input.find(arg) {
                Some(index) => input[index + arg.len()..].to_owned(),
                None => input.to_owned(),
            }
        }
        "before" => {
            match input.find(arg) {
                Some(index) => input[..index].to_owned(),
                None => input.to_owned(),
            }
        }
        "digits" => input.chars().filter(char::is_ascii_digit).collect(),
        "url_path" => {
            // 取 URL 的路径部分（用于从封面推媒体地址）。
            url::Url::parse(input.trim())
                .map(|parsed| parsed.path().to_owned())
                .unwrap_or_else(|_| input.to_owned())
        }
        "replace_ext" => {
            // `replace_ext:index.m3u8` → 把文件名的扩展部分换成给定值。
            // 例：`/video1/1.jpg` + `index.m3u8` → `/video1/index.m3u8`
            match input.rfind('/') {
                Some(index) => {
                    let (dir, _) = input.split_at(index + 1);
                    format!("{dir}{arg}")
                }
                None => arg.to_owned(),
            }
        }
        "unescape_js" => crate::extract::unescape_js_string(input),
        "split_tags" => {
            // 结果用 `|` 连接（Drama.tags 的中间表示）。
            let sep = if arg.is_empty() { "," } else { arg };
            input
                .split(sep)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join("|")
        }
        _ => return Err(FilterError::Unknown(name.to_owned())),
    };
    Ok(value)
}

/// 正则提取：`<pattern>:<group>`。
///
/// `group` 省略时取 1（有捕获组就取第一组，比取整段更常用）；
/// `group` 非数字时当作 `pattern` 的一部分（比如 `re:a:b` 里的 `b`）。
fn apply_regex(input: &str, spec: &str) -> Result<String, FilterError> {
    // 从右往左找「冒号 + 纯数字」作为 group。
    let (pattern, group) = match spec.rsplit_once(':') {
        Some((pattern, group)) if !group.is_empty() && group.chars().all(|c| c.is_ascii_digit()) => {
            (pattern, group.parse::<usize>().unwrap_or(1))
        }
        _ => (spec, 1),
    };
    let regex = regex::Regex::new(pattern).map_err(|e| FilterError::BadRegex(e.to_string()))?;
    let captures = regex
        .captures(input)
        .ok_or_else(|| FilterError::BadArgument("re", format!("未匹配: {pattern}")))?;
    // 指定组不存在时回落到整段匹配（作者常忘记数括号）。
    captures
        .get(group)
        .or_else(|| captures.get(0))
        .map(|m| m.as_str().to_owned())
        .ok_or_else(|| FilterError::BadArgument("re", "无捕获内容".to_owned()))
}

/// 全部过滤器名（校验白名单）。
pub fn all_names() -> &'static [&'static str] {
    static NAMES: OnceLock<Vec<&'static str>> = OnceLock::new();
    NAMES.get_or_init(|| {
        vec![
            "strip_tags",
            "unescape",
            "collapse_ws",
            "truncate",
            "absolutize",
            "episode_number",
            "status_map",
            "date_normalize",
            "views_normalize",
            "first_non_empty",
            "lowercase",
            "uppercase",
            "trim",
            "replace",
            "split_tags",
            "trim_suffix",
            "trim_prefix",
            "after",
            "before",
            "digits",
            "url_path",
            "replace_ext",
            "unescape_js",
            // `re:<pattern>:<group>` 在 apply_one 里前置处理。
            "re",
        ]
    })
}

/// 去掉 HTML 标签。
pub fn strip_tags(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut depth = 0usize;
    for c in input.chars() {
        match c {
            '<' => depth += 1,
            '>' => depth = depth.saturating_sub(1),
            _ if depth == 0 => out.push(c),
            _ => {}
        }
    }
    out
}

/// 反转义常见 HTML 实体。
pub fn unescape_html(input: &str) -> String {
    input
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
}

/// 折叠空白（换行/制表/连续空格 → 单空格）。
pub fn collapse_ws(input: &str) -> String {
    input
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// 按字符截断（不是字节）。
pub fn truncate_chars(input: &str, limit: usize) -> String {
    input.chars().take(limit).collect()
}

/// 相对地址补全为绝对地址。
pub fn absolutize(input: &str, base_url: Option<&url::Url>) -> String {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        return trimmed.to_owned();
    }
    // 协议相对地址：补 `https://`（join 会把 `//cdn` 误当相对段，
    // 解析成 `https:cdn/...`——少了 `//`，这不是合法的协议相对 URL）。
    if let Some(rest) = trimmed.strip_prefix("//") {
        return format!("https://{rest}");
    }
    match base_url {
        Some(base) => base
            .join(trimmed)
            .map(|u| u.to_string())
            .unwrap_or_else(|_| trimmed.to_owned()),
        None => trimmed.to_owned(),
    }
}

/// 从「更新至第 12 集 / 共 80 集 / 第3集」这类文案里提取集数。
///
/// 优先匹配「更新至/共/全 N 集」，再退到「第 N 集」。
pub fn episode_number(input: &str) -> Option<u32> {
    static PATTERNS: OnceLock<Vec<regex::Regex>> = OnceLock::new();
    let patterns = PATTERNS.get_or_init(|| {
        vec![
            // 更新至 12 集 / 共 80 集 / 全 24 集
            regex::Regex::new(r"(?:更新至|共|全)\s*0*(\d+)\s*集").expect("valid"),
            // 第 3 集 / 第03话 / 第 5 期
            regex::Regex::new(r"第\s*0*(\d+)\s*(?:集|话|期)").expect("valid"),
            // 12集 / 80集
            regex::Regex::new(r"(\d+)\s*集").expect("valid"),
        ]
    });
    for pattern in patterns {
        if let Some(caps) = pattern.captures(input)
            && let Some(digits) = caps.get(1)
            && let Ok(n) = digits.as_str().parse::<u32>()
            && n > 0
        {
            return Some(n);
        }
    }
    None
}

/// 状态映射：文案 → `ongoing` / `finished`。
///
/// 「未完结/更新至/连载」优先于「完结」——`"更新至第10集 已完结"` 这类
/// 矛盾文案按连载处理（保守：用户会看到更新提醒，而不是错过更新）。
pub fn status_map(input: &str) -> &'static str {
    if input.contains("未完结") || input.contains("更新至") || input.contains("连载") {
        return "ongoing";
    }
    if input.contains("完结") || input.contains("大结局") || input.contains("全集") {
        return "finished";
    }
    // 无法判断时按完结（不弹更新提醒）。
    "finished"
}

/// 日期归一化：提取 `YYYY-M-D` 并补零为 `YYYY-MM-DD`。
///
/// 年份限定 2000..=2100，月份 1..=12，日期 1..=31——超出范围的
/// 视为不是日期（返回空），而不是硬凑一个。
pub fn date_normalize(input: &str) -> Option<String> {
    static PATTERN: OnceLock<regex::Regex> = OnceLock::new();
    let pattern = PATTERN.get_or_init(|| {
        regex::Regex::new(r"(\d{4})-(\d{1,2})-(\d{1,2})").expect("valid")
    });
    let caps = pattern.captures(input)?;
    let year: u32 = caps.get(1)?.as_str().parse().ok()?;
    let month: u32 = caps.get(2)?.as_str().parse().ok()?;
    let day: u32 = caps.get(3)?.as_str().parse().ok()?;
    if !(2000..=2100).contains(&year) || !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    Some(format!("{year:04}-{month:02}-{day:02}"))
}

/// 播放量归一化：`12.3万次播放` → `12.3万`。
pub fn views_normalize(input: &str) -> String {
    static PATTERN: OnceLock<regex::Regex> = OnceLock::new();
    let pattern = PATTERN.get_or_init(|| {
        // `w`/`W`/`万` 三种单位都出现（站源大小写不规范）。
        regex::Regex::new(r"(?i)([0-9]+(?:\.[0-9]+)?)\s*([w万]?)\s*次播放").expect("valid")
    });
    pattern
        .captures(input)
        .and_then(|caps| {
            let number = caps.get(1)?.as_str();
            let unit = caps.get(2).map(|m| m.as_str()).unwrap_or("");
            Some(format!("{number}{unit}"))
        })
        .unwrap_or_default()
}

/// 取 `|` 分隔的第一段非空值。
pub fn first_non_empty(input: &str) -> String {
    input
        .split('|')
        .map(str::trim)
        .find(|s| !s.is_empty())
        .unwrap_or("")
        .to_owned()
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn strip_tags_removes_markup() {
        assert_eq!(strip_tags("<p>hello</p>"), "hello");
        assert_eq!(strip_tags("a<b>c</b>d"), "acd");
        assert_eq!(strip_tags("no tags"), "no tags");
        // 嵌套。
        assert_eq!(strip_tags("<div><span>x</span></div>"), "x");
    }

    #[test]
    fn unescape_common_entities() {
        assert_eq!(unescape_html("a&amp;b"), "a&b");
        assert_eq!(unescape_html("&lt;p&gt;"), "<p>");
        assert_eq!(unescape_html("&quot;x&quot;"), "\"x\"");
        assert_eq!(unescape_html("&nbsp;x"), " x");
        assert_eq!(unescape_html("&#39;q&#39;"), "'q'");
    }

    #[test]
    fn collapse_whitespace() {
        assert_eq!(collapse_ws("a\n\tb   c"), "a b c");
        assert_eq!(collapse_ws("  "), "");
    }

    #[test]
    fn truncate_counts_chars_not_bytes() {
        // 中文 3 字符 = 9 字节，截 2 应得到 2 个中文字符。
        assert_eq!(truncate_chars("都市甜宠", 2), "都市");
        assert_eq!(truncate_chars("abc", 10), "abc");
    }

    #[test]
    fn absolutize_variants() {
        let base = url::Url::parse("https://www.x.com/list/").expect("base");
        assert_eq!(absolutize("https://a.com/x", Some(&base)), "https://a.com/x");
        assert_eq!(absolutize("//cdn/x.jpg", Some(&base)), "https://cdn/x.jpg");
        assert_eq!(absolutize("/vod/1.html", Some(&base)), "https://www.x.com/vod/1.html");
        assert_eq!(absolutize("img/a.jpg", Some(&base)), "https://www.x.com/list/img/a.jpg");
        // 无 base 时原样返回。
        assert_eq!(absolutize("/x", None), "/x");
        assert_eq!(absolutize("  ", Some(&base)), "");
    }

    #[test]
    fn episode_number_patterns() {
        assert_eq!(episode_number("更新至第12集"), Some(12));
        assert_eq!(episode_number("共80集"), Some(80));
        assert_eq!(episode_number("全24集"), Some(24));
        assert_eq!(episode_number("第3集"), Some(3));
        assert_eq!(episode_number("第03话"), Some(3));
        assert_eq!(episode_number("第 5 期"), Some(5));
        assert_eq!(episode_number("12集全"), Some(12));
        assert_eq!(episode_number("无集数"), None);
        assert_eq!(episode_number("第0集"), None, "0 是无效集数");
    }

    #[test]
    fn status_map_ongoing_wins_over_finished() {
        // 矛盾文案按连载处理。
        assert_eq!(status_map("更新至第10集 已完结"), "ongoing");
        assert_eq!(status_map("未完结"), "ongoing");
        assert_eq!(status_map("连载中"), "ongoing");
        assert_eq!(status_map("已完结"), "finished");
        assert_eq!(status_map("大结局"), "finished");
        assert_eq!(status_map("40集全"), "finished");
        assert_eq!(status_map("随便什么"), "finished");
    }

    #[test]
    fn date_normalize_pads_and_validates() {
        assert_eq!(date_normalize("上线于 2024-1-5 发布"), Some("2024-01-05".to_owned()));
        assert_eq!(date_normalize("2024-12-31"), Some("2024-12-31".to_owned()));
        // 非法范围 → 不是日期。
        assert_eq!(date_normalize("2024-13-01"), None);
        assert_eq!(date_normalize("1999-01-01"), None);
        assert_eq!(date_normalize("2110-01-01"), None);
        assert_eq!(date_normalize("没有日期"), None);
    }

    #[test]
    fn views_normalize_extracts_metric() {
        assert_eq!(views_normalize("12.3万次播放"), "12.3万");
        assert_eq!(views_normalize("456W次播放"), "456W");
        assert_eq!(views_normalize("789 次播放"), "789");
        assert_eq!(views_normalize("没有播放量"), "");
    }

    #[test]
    fn first_non_empty_picks_first() {
        assert_eq!(first_non_empty("|a|b"), "a");
        assert_eq!(first_non_empty("  |b"), "b");
        assert_eq!(first_non_empty("||"), "");
    }

    #[test]
    fn replace_and_case() {
        let base = url::Url::parse("https://x.com/").expect("base");
        assert_eq!(
            apply_one("a.b.c", "replace:.:-", None).expect("ok"),
            "a-b-c"
        );
        assert_eq!(apply_one("AbC", "lowercase", None).expect("ok"), "abc");
        assert_eq!(apply_one("abc", "uppercase", None).expect("ok"), "ABC");
        assert_eq!(apply_one("  x  ", "trim", None).expect("ok"), "x");
        assert_eq!(apply_one("a,b,c", "split_tags:,", None).expect("ok"), "a|b|c");
        let _ = base;
    }

    #[test]
    fn chain_applies_in_order() {
        let base = url::Url::parse("https://x.com/list/").expect("base");
        let value = apply_chain(
            "  <p>更新至第12集</p>  ",
            &[
                "strip_tags".to_owned(),
                "trim".to_owned(),
                "episode_number".to_owned(),
            ],
            Some(&base),
        )
        .expect("chain");
        assert_eq!(value, "12");
    }

    #[test]
    fn unknown_filter_is_an_error() {
        assert_eq!(
            apply_one("x", "no_such_filter", None).unwrap_err(),
            FilterError::Unknown("no_such_filter".to_owned())
        );
    }

    #[test]
    fn bad_arguments_are_reported() {
        assert!(apply_one("x", "truncate:abc", None).is_err());
        assert!(apply_one("x", "replace:nocolon", None).is_err());
    }

    #[test]
    fn all_names_are_implemented() {
        // 白名单里的每个过滤器都必须能跑通（防止加了名字忘了实现）。
        // 需要参数的过滤器用合法的示例参数。
        let sample_args: &[(&str, &str)] = &[
            ("truncate", "truncate:5"),
            ("replace", "replace:a:b"),
            ("split_tags", "split_tags:,"),
            // `re` 需要参数，给一个能匹配 "test" 的模式。
            ("re", "re:es:0"),
        ];
        let base = url::Url::parse("https://x.com/").expect("base");
        for name in all_names() {
            let expr = sample_args
                .iter()
                .find(|(n, _)| *n == *name)
                .map(|(_, expr)| (*expr).to_owned())
                .unwrap_or_else(|| (*name).to_owned());
            let result = apply_one("test", &expr, Some(&base));
            assert!(result.is_ok(), "filter {expr} is not implemented: {result:?}");
        }
    }
}
