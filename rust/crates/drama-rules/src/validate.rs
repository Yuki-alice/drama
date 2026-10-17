//! 安装校验：结构 + 语义。
//!
//! ## 校验为什么重要
//!
//! 规则包是**外部输入**。一个拼写错误的 CSS 选择器、一个不存在的模板变量、
//! 一个装不上的内置 codec 依赖——这些如果拖到运行期才报错，用户看到的是
//! 「装了个源但是空的」。校验把失败前移到安装那一刻。
//!
//! ## 失败语义
//!
//! **任一步失败都不落盘**：已安装的同 id 源在新包校验失败时保持原样。
//! 「更新失败把能用的源搞坏」是最糟的失败模式。

use std::collections::HashSet;

use crate::extract;
use crate::manifest::{Auth, Manifest, Method, Pagination};
use crate::template;

/// 校验错误集合。
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ValidationError {
    #[error("源 id 无效（应为 [a-z0-9][a-z0-9-]{{0,63}}）: {0}")]
    BadId(String),
    #[error("源 id 不能覆盖内置主源")]
    ReservedId,
    #[error("schema 版本 {0} 不受支持（当前支持 1）")]
    BadSchema(u32),
    #[error("base 地址无效: {0}")]
    BadBase(String),
    #[error("name 不能为空")]
    EmptyName,
    #[error("模板变量不存在: {0}")]
    UnknownVariable(String),
    #[error("CSS 选择器无效: {0}")]
    BadSelector(String),
    #[error("正则无效: {0}")]
    BadRegex(String),
    #[error("依赖的内置 codec 不存在: {0}")]
    MissingRequirement(String),
    #[error("声明了 {0} 能力但没有对应的 ops 定义")]
    MissingOperation(&'static str),
    #[error("鉴权配置无效: {0}")]
    BadAuth(String),
}

/// 已知内置 codec 白名单。
///
/// 当前一个都没有——所有需要特殊解码的源都在逃生舱清单里，
/// 由内置 crate 实现，规则引擎不负责。
pub const KNOWN_REQUIREMENTS: &[&str] = &[];

/// 校验结果：全部错误（不只是第一个）。
///
/// 一次报出所有问题比逐次修复体验好得多——作者改一个错、装一次、
/// 再看下一个错，来回三轮才装上一个包。
pub fn validate(manifest: &Manifest, allowed_size: usize) -> Vec<ValidationError> {
    let mut errors = Vec::new();

    // 1. schema 版本。
    if manifest.schema != 1 {
        errors.push(ValidationError::BadSchema(manifest.schema));
    }

    // 2. id 形状与保留字。
    if !is_valid_id(&manifest.id) {
        errors.push(ValidationError::BadId(manifest.id.clone()));
    }
    if manifest.id == "hongguo" {
        errors.push(ValidationError::ReservedId);
    }

    // 3. 名称与 base。
    if manifest.name.trim().is_empty() {
        errors.push(ValidationError::EmptyName);
    }
    if !is_valid_base(&manifest.base) {
        errors.push(ValidationError::BadBase(manifest.base.clone()));
    }

    // 4. 依赖的内置 codec。
    for requirement in &manifest.requires {
        if !KNOWN_REQUIREMENTS.contains(&requirement.as_str()) {
            errors.push(ValidationError::MissingRequirement(requirement.clone()));
        }
    }

    // 5. 能力声明与 ops 对应。
    let caps = manifest.effective_caps();
    if caps.catalog && manifest.ops.catalog.is_none() {
        errors.push(ValidationError::MissingOperation("catalog"));
    }
    if caps.search && manifest.ops.search.is_none() {
        errors.push(ValidationError::MissingOperation("search"));
    }
    if caps.detail && manifest.ops.detail.is_none() {
        errors.push(ValidationError::MissingOperation("detail"));
    }
    if caps.playback && manifest.ops.playback.is_none() {
        errors.push(ValidationError::MissingOperation("playback"));
    }

    // 6. 语义校验：模板变量、选择器、正则。
    check_auth(&manifest.auth, &mut errors);
    for (op_name, op) in [
        ("catalog", manifest.ops.catalog.as_ref()),
        ("search", manifest.ops.search.as_ref()),
        ("suggest", manifest.ops.suggest.as_ref()),
        ("ranking", manifest.ops.ranking.as_ref()),
        ("detail", manifest.ops.detail.as_ref()),
    ] {
        if let Some(op) = op {
            check_operation(op_name, op, &manifest.headers, &mut errors);
        }
    }
    if let Some(playback) = &manifest.ops.playback {
        if let Some(request) = &playback.request {
            check_request(
                op_url_context("playback"),
                request,
                &manifest
                    .headers
                    .iter()
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect::<Vec<_>>(),
                &mut errors,
            );
        }
        if let Some(css) = playback.extract.as_ref().and_then(|e| match e {
            crate::manifest::Extract::Html { css } => Some(css.clone()),
            crate::manifest::Extract::HtmlAttr { css, .. } => Some(css.clone()),
            _ => None,
        }) && scraper::Selector::parse(strip_json_suffix(&css)).is_err()
        {
            errors.push(ValidationError::BadSelector(css));
        }
        if let Some(crate::manifest::Extract::Regex { pattern, .. }) = &playback.extract
            && regex::Regex::new(pattern).is_err()
        {
            errors.push(ValidationError::BadRegex(pattern.clone()));
        }
    }

    // 7. 包体积（防塞大字典）。
    if let Ok(json) = manifest.to_canonical_json()
        && json.len() > allowed_size
    {
        errors.push(ValidationError::BadBase(format!(
            "规则包超过大小上限（{} 字节）",
            allowed_size
        )));
    }

    errors
}

/// 最大包体积。
pub const MAX_PACKAGE_BYTES: usize = 256 * 1024;

/// 便捷入口：用默认体积上限校验。
pub fn validate_default(manifest: &Manifest) -> Vec<ValidationError> {
    validate(manifest, MAX_PACKAGE_BYTES)
}

/// `ops` 上下文名（用于错误信息）。
fn op_url_context(op: &str) -> String {
    op.to_owned()
}

fn is_valid_id(id: &str) -> bool {
    let bytes = id.as_bytes();
    if bytes.is_empty() || bytes.len() > 64 {
        return false;
    }
    if !(bytes[0].is_ascii_lowercase() || bytes[0].is_ascii_digit()) {
        return false;
    }
    bytes
        .iter()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
}

fn is_valid_base(base: &str) -> bool {
    matches!(url::Url::parse(base), Ok(parsed)
        if matches!(parsed.scheme(), "http" | "https") && parsed.host_str().is_some_and(|h| !h.is_empty()))
}

/// 剥掉 CSS 表达式里的 `::json:` 后缀（后缀部分不是选择器）。
fn strip_json_suffix(selector: &str) -> &str {
    selector.split("::json:").next().unwrap_or(selector)
}

/// 校验鉴权步骤。
fn check_auth(auth: &[Auth], errors: &mut Vec<ValidationError>) {
    for step in auth {
        match step {
            Auth::Login { request, .. } => {
                check_request("auth.login".to_owned(), request, &[], errors);
            }
            Auth::Sign { algo, template, output, .. } => {
                check_template(template, errors);
                let _ = (algo, output);
            }
            Auth::Hmac { key, data, .. } => {
                check_template(key, errors);
                check_template(data, errors);
            }
            Auth::Aes { key, iv, .. } => {
                check_template(key, errors);
                check_template(iv, errors);
            }
            Auth::StaticHeaders { headers } => {
                for value in headers.values() {
                    check_template_value(value, errors);
                }
            }
            Auth::RuneMap { .. } | Auth::Base64 { .. } | Auth::UriKey { .. } => {}
        }
    }
}

/// 校验单个请求规格。
fn check_request(
    context: String,
    request: &crate::manifest::RequestSpec,
    global_headers: &[(String, String)],
    errors: &mut Vec<ValidationError>,
) {
    let _ = &context;
    let mut known: Vec<(&str, &str)> = KNOWN_VARS.iter().map(|(k, v)| (*k, *v)).collect();
    for (k, v) in global_headers {
        known.push((k.as_str(), v.as_str()));
    }
    // 请求 URL 的变量是必须的（其余上下文可缺省）。
    let rendered = template::render_with_report(&request.url, &known);
    for name in rendered.missing {
        // `{{page}}`、`{{query}}` 这类运行期变量是合法的，不在 KNOWN_VARS 里。
        if !RUNTIME_VARS.contains(&name.as_str()) {
            errors.push(ValidationError::UnknownVariable(name));
        }
    }
    for value in request.headers.values() {
        check_template_value(value, errors);
    }
    if let Some(body) = &request.body {
        check_template(body, errors);
    }
}

/// 静态变量（`base` 总是可用）。
const KNOWN_VARS: &[(&str, &str)] = &[("base", "")];

/// 运行期变量（每次请求时由引擎注入）。
const RUNTIME_VARS: &[&str] = &[
    "page",
    "query",
    "id",
    "episode",
    "vid",
    "category",
    "index",
];

/// 校验一个 operation。
fn check_operation(
    op_name: &str,
    op: &crate::manifest::Operation,
    global_headers: &std::collections::BTreeMap<String, String>,
    errors: &mut Vec<ValidationError>,
) {
    let context = format!("ops.{op_name}");
    check_request(context, &op.request, &global_headers.iter().map(|(k, v)| (k.clone(), v.clone())).collect::<Vec<_>>(), errors);

    // items 的 HTML 选择器。
    if op.items.starts_with("css:") {
        let selector = op.items.trim_start_matches("css:").trim();
        if scraper::Selector::parse(strip_json_suffix(selector)).is_err() {
            errors.push(ValidationError::BadSelector(selector.to_owned()));
        }
    }

    // 字段映射的表达式与过滤器。
    for (field, map) in &op.map {
        if let extract::Source::Css { selector, .. } = extract::parse_source(&map.from)
            && scraper::Selector::parse(strip_json_suffix(&selector)).is_err()
        {
            errors.push(ValidationError::BadSelector(selector));
        }
        for filter in &map.filters {
            let name = filter.split(':').next().unwrap_or(filter).trim();
            if !crate::transform::all_names().contains(&name) {
                errors.push(ValidationError::MissingRequirement(format!(
                    "filter.{name}"
                )));
            }
        }
        let _ = field;
    }

    // 分集规格。
    if let Some(chapters) = &op.chapters {
        if !chapters.items.is_empty()
            && chapters.items.starts_with("css:")
            && scraper::Selector::parse(strip_json_suffix(
                chapters.items.trim_start_matches("css:"),
            ))
            .is_err()
        {
            errors.push(ValidationError::BadSelector(chapters.items.clone()));
        }
        check_template_value(&chapters.title_template, errors);
    }
}

/// 校验模板（忽略运行期变量）。
fn check_template(template_text: &str, errors: &mut Vec<ValidationError>) {
    check_template_value(template_text, errors)
}

fn check_template_value(value: &str, errors: &mut Vec<ValidationError>) {
    for name in template::variables(value) {
        if !RUNTIME_VARS.contains(&name.as_str()) && !KNOWN_VARS.iter().any(|(k, _)| *k == name) {
            errors.push(ValidationError::UnknownVariable(name));
        }
    }
}

/// 分页配置的额外校验（游标模式必须有 param）。
pub fn validate_pagination(pagination: &Pagination) -> Vec<ValidationError> {
    let mut errors = Vec::new();
    if let Pagination::Cursor { path, param } = pagination
        && (path.trim().is_empty() || param.trim().is_empty())
    {
        errors.push(ValidationError::BadAuth(
            "游标分页需要 path 与 param".to_owned(),
        ));
    }
    errors
}

/// 校验请求方法是受支持的。
pub fn method_supported(method: &Method) -> bool {
    matches!(method, Method::Get | Method::Post)
}

/// 收集去重后的变量名（诊断辅助）。
pub fn collect_variables(manifest: &Manifest) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    let mut push = |text: &str| {
        for name in template::variables(text) {
            if seen.insert(name.clone()) {
                out.push(name);
            }
        }
    };
    for (_, op) in [
        ("catalog", manifest.ops.catalog.as_ref()),
        ("search", manifest.ops.search.as_ref()),
        ("suggest", manifest.ops.suggest.as_ref()),
        ("ranking", manifest.ops.ranking.as_ref()),
        ("detail", manifest.ops.detail.as_ref()),
    ] {
        if let Some(op) = op {
            push(&op.request.url);
            if let Some(body) = &op.request.body {
                push(body);
            }
            for (field, map) in &op.map {
                push(&map.from);
                let _ = field;
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::Manifest;

    const GOOD: &str = r#"
schema: 1
id: wuguo
name: 伍果
base: https://www.duanju55.com
ops:
  catalog:
    request:
      url: "{{base}}{{category}}/page/{{page}}.html"
    items: "css:.public-list-box"
    map:
      title:
        from: "a@title"
    pagination:
      type: page
      size: 24
"#;

    fn good() -> Manifest {
        Manifest::from_yaml(GOOD).expect("load")
    }

    #[test]
    fn good_manifest_passes() {
        assert!(validate_default(&good()).is_empty(), "expected no errors");
    }

    #[test]
    fn rejects_reserved_id() {
        let mut manifest = good();
        manifest.id = "hongguo".to_owned();
        let errors = validate_default(&manifest);
        assert!(errors.iter().any(|e| matches!(e, ValidationError::ReservedId)));
    }

    #[test]
    fn rejects_bad_id_shapes() {
        for bad in ["", "UPPER", "with space", "a/b", "x".repeat(65).as_str()] {
            let mut manifest = good();
            manifest.id = bad.to_owned();
            assert!(
                validate_default(&manifest)
                    .iter()
                    .any(|e| matches!(e, ValidationError::BadId(_))),
                "id {bad:?} should be rejected"
            );
        }
    }

    #[test]
    fn accepts_valid_ids() {
        for good_id in ["a", "wuguo", "huang-guo-video", "a1"] {
            let mut manifest = good();
            manifest.id = good_id.to_owned();
            assert!(
                !validate_default(&manifest)
                    .iter()
                    .any(|e| matches!(e, ValidationError::BadId(_))),
                "id {good_id} should pass"
            );
        }
    }

    #[test]
    fn rejects_bad_schema() {
        let mut manifest = good();
        manifest.schema = 2;
        assert!(
            validate_default(&manifest)
                .iter()
                .any(|e| matches!(e, ValidationError::BadSchema(2)))
        );
    }

    #[test]
    fn rejects_bad_base() {
        let mut manifest = good();
        manifest.base = "not a url".to_owned();
        assert!(
            validate_default(&manifest)
                .iter()
                .any(|e| matches!(e, ValidationError::BadBase(_)))
        );
        manifest.base = "ftp://x.com".to_owned();
        assert!(
            validate_default(&manifest)
                .iter()
                .any(|e| matches!(e, ValidationError::BadBase(_)))
        );
    }

    #[test]
    fn rejects_empty_name() {
        let mut manifest = good();
        manifest.name = "  ".to_owned();
        assert!(
            validate_default(&manifest)
                .iter()
                .any(|e| matches!(e, ValidationError::EmptyName))
        );
    }

    #[test]
    fn reports_unknown_template_variables() {
        let yaml = r#"
schema: 1
id: typo
name: 拼写错误
base: https://a.com
ops:
  catalog:
    request:
      url: "{{base}}/list/{{pag}}.html"
"#;
        let manifest = Manifest::from_yaml(yaml).expect("load");
        let errors = validate_default(&manifest);
        // `{{pag}}` 是 `{{page}}` 的拼写错误。
        assert!(
            errors
                .iter()
                .any(|e| matches!(e, ValidationError::UnknownVariable(v) if v == "pag")),
            "expected UnknownVariable(pag), got {errors:?}"
        );
    }

    #[test]
    fn accepts_runtime_variables() {
        let yaml = r#"
schema: 1
id: runtime
name: 运行期变量
base: https://a.com
ops:
  search:
    request:
      url: "{{base}}/search?kw={{query}}&p={{page}}"
"#;
        let manifest = Manifest::from_yaml(yaml).expect("load");
        assert!(validate_default(&manifest).is_empty());
    }

    #[test]
    fn rejects_bad_css_selector() {
        let yaml = r#"
schema: 1
id: badsel
name: 坏选择器
base: https://a.com
ops:
  catalog:
    request:
      url: "{{base}}/list"
    items: "css:a[[["
"#;
        let manifest = Manifest::from_yaml(yaml).expect("load");
        assert!(
            validate_default(&manifest)
                .iter()
                .any(|e| matches!(e, ValidationError::BadSelector(_)))
        );
    }

    #[test]
    fn reports_all_errors_at_once() {
        let yaml = r#"
schema: 2
id: BAD_ID
name: ""
base: "nope"
ops: {}
"#;
        let manifest = Manifest::from_yaml(yaml).expect("load");
        let errors = validate_default(&manifest);
        assert!(errors.len() >= 3, "expected multiple errors: {errors:?}");
    }

    #[test]
    fn rejects_unknown_dependency() {
        let mut manifest = good();
        manifest.requires = vec!["codec.aaencode".to_owned()];
        assert!(
            validate_default(&manifest)
                .iter()
                .any(|e| matches!(e, ValidationError::MissingRequirement(_)))
        );
    }

    #[test]
    fn size_limit() {
        let manifest = good();
        // 用极小的上限触发体积错误。
        assert!(
            validate(&manifest, 10)
                .iter()
                .any(|e| matches!(e, ValidationError::BadBase(_)))
        );
    }

    #[test]
    fn pagination_cursor_needs_both_fields() {
        let yaml = r#"
schema: 1
id: cursor
name: 游标
base: https://a.com
ops:
  catalog:
    request:
      url: "{{base}}/list"
    pagination:
      type: cursor
      path: ""
      param: ""
"#;
        let manifest = Manifest::from_yaml(yaml).expect("load");
        let op = manifest.ops.catalog.expect("op");
        assert!(!validate_pagination(&op.pagination).is_empty());
    }

    #[test]
    fn collects_all_variables() {
        let manifest = good();
        let vars = collect_variables(&manifest);
        assert!(vars.contains(&"base".to_owned()));
        assert!(vars.contains(&"category".to_owned()));
        assert!(vars.contains(&"page".to_owned()));
    }
}
