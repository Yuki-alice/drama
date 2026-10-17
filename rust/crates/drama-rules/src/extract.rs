//! 取值：从 JSON 响应或 HTML 文档里拿出需要的值。
//!
//! ## 两种取值器
//!
//! - **JSON 点路径**：`data.video_data`。支持 `|` 别名回退
//!   （`series_id_str|series_id`）——同一字段在不同接口里名字不一样，
//!   这是短剧站最常见的差异。
//! - **HTML**：CSS 选择器 + 可选属性（`a@title` 表示 `<a>` 的 `title` 属性）。
//!
//! ## 刻意不做的
//!
//! 不支持通配符、过滤器表达式、递归下降——需要这些的源进逃生舱。

use scraper::{Html, Selector};

/// 取值错误。
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ExtractError {
    #[error("JSON 路径无法解析: {0}")]
    BadPath(String),
    #[error("CSS 选择器无效: {0}")]
    BadSelector(String),
}

/// 从 JSON 值按点路径取值。
///
/// 路径形如 `a.b.c`；支持 `|` 分隔的别名回退（取第一个命中的）。
/// 数组索引用 `a.0.b`。
pub fn json_path<'a>(value: &'a serde_json::Value, path: &str) -> Option<&'a serde_json::Value> {
    let path = path.trim();
    if path.is_empty() {
        return Some(value);
    }
    // 别名回退：任一别名命中即返回。
    for alias in path.split('|') {
        let alias = alias.trim();
        if alias.is_empty() {
            continue;
        }
        let mut current = value;
        let mut hit = true;
        for segment in alias.split('.') {
            match current {
                serde_json::Value::Object(map) => {
                    match map.get(segment) {
                        Some(next) => current = next,
                        None => {
                            hit = false;
                            break;
                        }
                    }
                }
                serde_json::Value::Array(items) => {
                    match segment.parse::<usize>() {
                        Ok(index) if index < items.len() => current = &items[index],
                        _ => {
                            hit = false;
                            break;
                        }
                    }
                }
                _ => {
                    hit = false;
                    break;
                }
            }
        }
        if hit {
            return Some(current);
        }
    }
    None
}

/// 取字符串值（数字/布尔转字符串；null/缺失返回 `None`）。
pub fn json_string(value: &serde_json::Value, path: &str) -> Option<String> {
    match json_path(value, path)? {
        serde_json::Value::String(s) => Some(s.clone()),
        serde_json::Value::Number(n) => Some(n.to_string()),
        serde_json::Value::Bool(b) => Some(b.to_string()),
        _ => None,
    }
}

/// 取整数值。
pub fn json_int(value: &serde_json::Value, path: &str) -> Option<i64> {
    match json_path(value, path)? {
        serde_json::Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        serde_json::Value::String(s) => s
            .trim()
            .parse::<i64>()
            .ok()
            .or_else(|| s.trim().parse::<f64>().ok().map(|f| f as i64)),
        _ => None,
    }
}

/// 取数组值。
pub fn json_array<'a>(value: &'a serde_json::Value, path: &str) -> Option<&'a [serde_json::Value]> {
    match json_path(value, path)? {
        serde_json::Value::Array(items) => Some(items),
        _ => None,
    }
}

/// 解析 `from` 表达式：JSON 路径或 `css@attr`。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    /// JSON 点路径。
    JsonPath(String),
    /// CSS 选择器 + 属性（`attr` 为空表示取文本）。
    Css { selector: String, attr: String },
}

/// 解析 `from` 表达式。
///
/// `css:` 前缀显式声明 HTML；`@` 分隔选择器与属性。
pub fn parse_source(expr: &str) -> Source {
    let expr = expr.trim();
    if let Some(rest) = expr.strip_prefix("css:") {
        return split_attr(rest.trim());
    }
    // JSON 路径里不会出现 `@`；出现即视为 HTML 表达式。
    if expr.contains('@') && !expr.contains('.') {
        return split_attr(expr);
    }
    Source::JsonPath(expr.to_owned())
}

fn split_attr(expr: &str) -> Source {
    match expr.split_once('@') {
        Some((selector, attr)) => Source::Css {
            selector: selector.trim().to_owned(),
            attr: attr.trim().to_owned(),
        },
        None => Source::Css {
            selector: expr.to_owned(),
            attr: String::new(),
        },
    }
}

/// 从 JSON 条目按 `from` 表达式取字符串。
pub fn value_from_json(item: &serde_json::Value, expr: &str) -> Option<String> {
    match parse_source(expr) {
        Source::JsonPath(path) => json_string(item, &path),
        Source::Css { .. } => None, // JSON 条目里没有 HTML 可选。
    }
}

/// 从 HTML 文档按 CSS 选择器取**第一个**匹配的文本或属性。
pub fn html_first(document: &Html, selector: &str, attr: &str) -> Option<String> {
    let selector = Selector::parse(selector)
        .map_err(|_| ExtractError::BadSelector(selector.to_owned()))
        .ok()?;
    let element = document.select(&selector).next()?;
    Some(if attr.is_empty() {
        element.text().collect::<String>()
    } else {
        element.value().attr(attr).unwrap_or("").to_owned()
    })
}

/// 从 HTML 文档按 CSS 选择器取**全部**匹配。
pub fn html_all<'a>(
    document: &'a Html,
    selector: &str,
) -> Result<Vec<scraper::ElementRef<'a>>, ExtractError> {
    let selector = Selector::parse(selector)
        .map_err(|_| ExtractError::BadSelector(selector.to_owned()))?;
    Ok(document.select(&selector).collect())
}

/// 从单个 HTML 元素按 `from` 表达式取值。
pub fn value_from_element(
    element: scraper::ElementRef<'_>,
    expr: &str,
    base_url: Option<&url::Url>,
) -> Option<String> {
    // 元素上下文里的表达式始终是 HTML 语义：
    // - 有 `@` → 选择器@属性；
    // - 无 `@` → 选择器取文本（`a` 即「`<a>` 的文本」）。
    // 这与 JSON 上下文不同（那里无 `css:` 前缀的点路径优先）。
    let css_expr = if expr.contains('@') {
        expr.to_owned()
    } else {
        format!("css:{expr}")
    };
    match parse_source(&css_expr) {
        Source::JsonPath(_) => None,
        Source::Css { selector, attr } => {
            let selector = Selector::parse(&selector).ok()?;
            let inner = element.select(&selector).next()?;
            Some(if attr.is_empty() {
                inner.text().collect::<String>()
            } else {
                let raw = inner.value().attr(&attr).unwrap_or("");
                // `href`/`src` 之类需要补全为绝对地址。
                if matches!(attr.as_str(), "href" | "src" | "data-src" | "data-original")
                    && let Some(base) = base_url
                    && let Ok(resolved) = base.join(raw)
                {
                    return Some(resolved.to_string());
                }
                raw.to_owned()
            })
        }
    }
}

/// 从 HTML 按 `items` 表达式取条目列表。
///
/// `items` 以 `css:` 开头时按选择器切条目；否则按 JSON 路径取数组。
pub fn items_from_html<'a>(
    document: &'a Html,
    items: &str,
) -> Result<Vec<scraper::ElementRef<'a>>, ExtractError> {
    let selector = items.trim().strip_prefix("css:").unwrap_or(items).trim();
    html_all(document, selector)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn json_path_walks_objects() {
        let value = json!({"data": {"list": [{"id": 1}, {"id": 2}]}});
        assert_eq!(
            json_path(&value, "data.list.1.id"),
            Some(&json!(2))
        );
    }

    #[test]
    fn json_path_missing_returns_none() {
        let value = json!({"a": 1});
        assert!(json_path(&value, "a.b.c").is_none());
        assert!(json_path(&value, "").is_some(), "空路径返回自身");
    }

    #[test]
    fn json_path_array_index_out_of_bounds() {
        let value = json!({"list": [1]});
        assert!(json_path(&value, "list.5").is_none());
        // 非数字索引在数组上无效。
        assert!(json_path(&value, "list.name").is_none());
    }

    #[test]
    fn json_path_alias_fallback() {
        let a = json!({"series_id_str": "111"});
        assert_eq!(json_string(&a, "series_id_str|series_id"), Some("111".to_owned()));
        let b = json!({"series_id": "222"});
        assert_eq!(json_string(&b, "series_id_str|series_id"), Some("222".to_owned()));
        let c = json!({});
        assert_eq!(json_string(&c, "series_id_str|series_id"), None);
    }

    #[test]
    fn json_string_coerces_types() {
        assert_eq!(json_string(&json!({"n": 42}), "n"), Some("42".to_owned()));
        assert_eq!(json_string(&json!({"b": true}), "b"), Some("true".to_owned()));
        assert_eq!(json_string(&json!({"s": "x"}), "s"), Some("x".to_owned()));
        assert_eq!(json_string(&json!({"z": null}), "z"), None);
    }

    #[test]
    fn json_int_parses_strings() {
        assert_eq!(json_int(&json!({"n": "42"}), "n"), Some(42));
        assert_eq!(json_int(&json!({"n": 42.0}), "n"), Some(42));
        assert_eq!(json_int(&json!({"n": "abc"}), "n"), None);
    }

    #[test]
    fn source_parsing() {
        assert_eq!(
            parse_source("data.title"),
            Source::JsonPath("data.title".to_owned())
        );
        assert_eq!(
            parse_source("css:.title"),
            Source::Css { selector: ".title".to_owned(), attr: String::new() }
        );
        assert_eq!(
            parse_source("css:a@title"),
            Source::Css { selector: "a".to_owned(), attr: "title".to_owned() }
        );
        // `@` 且无点 → HTML。
        assert_eq!(
            parse_source("a@title"),
            Source::Css { selector: "a".to_owned(), attr: "title".to_owned() }
        );
    }

    #[test]
    fn html_first_extracts_text_and_attr() {
        let document = Html::parse_document(r#"<div><a class="t" title="标题" href="/x/1">文本</a></div>"#);
        assert_eq!(html_first(&document, "a.t", ""), Some("文本".to_owned()));
        assert_eq!(html_first(&document, "a.t", "title"), Some("标题".to_owned()));
        assert_eq!(html_first(&document, "a.missing", ""), None);
    }

    #[test]
    fn html_first_bad_selector_is_none() {
        let document = Html::parse_document("<div></div>");
        assert!(html_first(&document, "a[[[", "").is_none());
    }

    #[test]
    fn value_from_element_resolves_relative_urls() {
        let document =
            Html::parse_document(r#"<html><body><div class="card"><a href="/vod/1.html">剧</a></div></body></html>"#);
        let card = html_all(&document, ".card").expect("cards").remove(0);
        let base = url::Url::parse("https://www.example.com/list/").expect("base");
        let href = value_from_element(card, "a@href", Some(&base)).expect("href");
        assert_eq!(href, "https://www.example.com/vod/1.html");
        // 文本不需要补全。
        let text = value_from_element(
            html_all(&document, ".card").expect("cards").remove(0),
            "a",
            None,
        );
        assert_eq!(text, Some("剧".to_owned()));
    }

    #[test]
    fn items_from_html_selects_entries() {
        let document = Html::parse_document(
            r#"<ul><li class="i">1</li><li class="i">2</li><li>3</li></ul>"#,
        );
        let items = items_from_html(&document, "css:li.i").expect("items");
        assert_eq!(items.len(), 2);
    }

    #[test]
    fn items_from_html_rejects_bad_selector() {
        let document = Html::parse_document("<div></div>");
        assert!(items_from_html(&document, "css:a[[[").is_err());
    }
}
