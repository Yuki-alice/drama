//! `{{var}}` 模板渲染。
//!
//! ## 为什么不做表达式
//!
//! 模板里**只有变量替换**，没有算术、没有条件、没有嵌套函数。
//! 需要更复杂逻辑的源进逃生舱（内置实现）。这是规则引擎「可审阅」的前提。
//!
//! ## 未知变量
//!
//! 渲染时遇到未知变量**保留原样**并计入 [`render_with_report`] 的返回值——
//! 这样校验器能在安装期发现拼写错误，而运行期不会因为一个缺失变量
//! 让整页空白。

/// 渲染结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rendered {
    pub text: String,
    /// 模板里出现但上下文没有的变量名。
    pub missing: Vec<String>,
}

/// 渲染模板。
///
/// `context` 里的键按**声明顺序**匹配；同名时后写的覆盖先写的
/// （调用方应保证无重复）。
pub fn render(template: &str, context: &[(&str, &str)]) -> String {
    render_with_report(template, context).text
}

/// 渲染并报告缺失的变量。
pub fn render_with_report(template: &str, context: &[(&str, &str)]) -> Rendered {
    let mut out = String::with_capacity(template.len());
    let mut missing = Vec::new();
    let mut rest = template;

    while let Some(start) = rest.find("{{") {
        out.push_str(&rest[..start]);
        let tail = &rest[start + 2..];
        match tail.find("}}") {
            Some(end) => {
                let name = tail[..end].trim();
                if let Some((_, value)) = context.iter().find(|(k, _)| *k == name) {
                    out.push_str(value);
                } else if name.is_empty() {
                    // `{{}}` 不是合法变量，原样保留。
                    out.push_str("{{}}");
                } else {
                    out.push_str("{{");
                    out.push_str(name);
                    out.push_str("}}");
                    if !missing.iter().any(|m| m == name) {
                        missing.push(name.to_owned());
                    }
                }
                rest = &tail[end + 2..];
            }
            None => {
                // 没有闭合：原样保留剩余部分。
                out.push_str("{{");
                rest = tail;
            }
        }
    }
    out.push_str(rest);
    Rendered { text: out, missing }
}

/// 收集模板里引用的全部变量名（校验用）。
pub fn variables(template: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = template;
    while let Some(start) = rest.find("{{") {
        let tail = &rest[start + 2..];
        match tail.find("}}") {
            Some(end) => {
                let name = tail[..end].trim().to_owned();
                if !name.is_empty() && !out.contains(&name) {
                    out.push(name);
                }
                rest = &tail[end + 2..];
            }
            None => break,
        }
    }
    out
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn replaces_known_variables() {
        assert_eq!(
            render("{{base}}/detail/{{id}}.html", &[("base", "https://a.com"), ("id", "42")]),
            "https://a.com/detail/42.html"
        );
    }

    #[test]
    fn keeps_unknown_variables_and_reports() {
        let rendered = render_with_report("{{base}}/{{unknow}}", &[("base", "x")]);
        assert_eq!(rendered.text, "x/{{unknow}}");
        assert_eq!(rendered.missing, vec!["unknow"]);
    }

    #[test]
    fn reports_each_missing_once() {
        let rendered = render_with_report("{{a}} {{b}} {{a}}", &[]);
        assert_eq!(rendered.missing, vec!["a", "b"]);
    }

    #[test]
    fn no_placeholders_is_identity() {
        assert_eq!(render("plain url", &[]), "plain url");
        assert_eq!(render("", &[("a", "b")]), "");
    }

    #[test]
    fn unclosed_placeholder_is_literal() {
        assert_eq!(render("{{base}/x", &[("base", "y")]), "{{base}/x");
    }

    #[test]
    fn empty_placeholder_is_literal() {
        assert_eq!(render("{{}}", &[]), "{{}}");
        // 空变量不计入 missing。
        let rendered = render_with_report("{{}}", &[]);
        assert!(rendered.missing.is_empty());
    }

    #[test]
    fn variables_extracts_names() {
        assert_eq!(
            variables("{{base}}/{{id}}/{{base}}"),
            vec!["base".to_owned(), "id".to_owned()]
        );
        assert!(variables("no vars").is_empty());
    }

    #[test]
    fn variables_trims_whitespace() {
        assert_eq!(variables("{{ base }}"), vec!["base".to_owned()]);
    }

    #[test]
    fn adjacent_placeholders() {
        assert_eq!(render("{{a}}{{b}}", &[("a", "1"), ("b", "2")]), "12");
    }

    #[test]
    fn chinese_values_pass_through() {
        assert_eq!(
            render("{{base}}/search/{{kw}}", &[("base", "https://x.com"), ("kw", "都市")]),
            "https://x.com/search/都市"
        );
    }
}
