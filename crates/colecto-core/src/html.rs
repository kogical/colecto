//! Untrusted HTML email sanitization and safe inline image (`cid:`) resolution.
use base64::Engine;
use chacha20poly1305::aead::{OsRng, rand_core::RngCore};
use std::{
    collections::{BTreeMap, HashSet},
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
};

/// An inline MIME image part referenced by `cid:<content-id>`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InlineImage {
    pub content_type: String,
    pub data: Vec<u8>,
}

/// Options controlling HTML sanitization.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SanitizeOptions {
    /// Whether to preserve remote `http://` / `https://` / `//` image sources.
    /// Off by default to block tracking pixels.
    pub allow_remote_images: bool,
}

/// Sanitized HTML output ready for sandboxed rendering.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SanitizedHtml {
    pub html: String,
    pub blocked_remote_images: usize,
}

/// Only safe raster formats may be inlined as `data:` URIs (never SVG).
pub(crate) fn is_safe_raster_mime(content_type: &str) -> bool {
    matches!(
        content_type.trim().to_ascii_lowercase().as_str(),
        "image/png"
            | "image/jpeg"
            | "image/jpg"
            | "image/gif"
            | "image/webp"
            | "image/avif"
            | "image/bmp"
            | "image/x-icon"
            | "image/vnd.microsoft.icon"
    )
}

/// Normalize a `Content-ID` header value or `cid:` URI component.
pub(crate) fn normalize_cid(value: &str) -> String {
    let trimmed = value.trim();
    let stripped = trimmed
        .strip_prefix('<')
        .and_then(|s| s.strip_suffix('>'))
        .unwrap_or(trimmed);
    stripped.trim().to_ascii_lowercase()
}

fn has_scheme(value: &str, scheme: &str) -> bool {
    value
        .get(..scheme.len())
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case(scheme))
}

fn is_remote_url(value: &str) -> bool {
    has_scheme(value, "http://") || has_scheme(value, "https://") || value.starts_with("//")
}

/// Safe, URL-free CSS properties allowed inside inline `style="..."` attributes.
///
/// Deliberately excludes properties that can load external resources (`background`,
/// `background-image`, `list-style`, `list-style-image`, `cursor`, `content`,
/// `mask`, `mask-image`, `filter`, `clip-path`) or escape the message container
/// (`position`, `z-index`, `top`, `right`, `bottom`, `left`, `transform`).
const SAFE_STYLE_PROPERTIES: &[&str] = &[
    // Sizing & box model
    "width",
    "max-width",
    "min-width",
    "height",
    "max-height",
    "min-height",
    "display",
    "box-sizing",
    "overflow",
    "overflow-x",
    "overflow-y",
    "vertical-align",
    "float",
    "clear",
    "margin",
    "margin-top",
    "margin-right",
    "margin-bottom",
    "margin-left",
    "padding",
    "padding-top",
    "padding-right",
    "padding-bottom",
    "padding-left",
    // Tables
    "border-collapse",
    "border-spacing",
    "table-layout",
    // Colors & borders (no `background` shorthand or `background-image`)
    "color",
    "background-color",
    "border",
    "border-top",
    "border-right",
    "border-bottom",
    "border-left",
    "border-color",
    "border-top-color",
    "border-right-color",
    "border-bottom-color",
    "border-left-color",
    "border-width",
    "border-top-width",
    "border-right-width",
    "border-bottom-width",
    "border-left-width",
    "border-style",
    "border-top-style",
    "border-right-style",
    "border-bottom-style",
    "border-left-style",
    "border-radius",
    "border-top-left-radius",
    "border-top-right-radius",
    "border-bottom-left-radius",
    "border-bottom-right-radius",
    "opacity",
    "visibility",
    // Typography
    "font",
    "font-family",
    "font-size",
    "font-weight",
    "font-style",
    "font-variant",
    "line-height",
    "letter-spacing",
    "word-spacing",
    "text-align",
    "text-decoration",
    "text-indent",
    "text-transform",
    "white-space",
    "word-break",
    "word-wrap",
    "overflow-wrap",
    "list-style-type",
    "direction",
];

fn strip_css_comments(css: &str) -> String {
    let mut out = String::with_capacity(css.len());
    let bytes = css.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if i + 1 < bytes.len() && bytes[i] == b'/' && bytes[i + 1] == b'*' {
            i += 2;
            while i + 1 < bytes.len() && !(bytes[i] == b'*' && bytes[i + 1] == b'/') {
                i += 1;
            }
            i = (i + 2).min(bytes.len());
        } else {
            let ch = css[i..].chars().next().unwrap();
            out.push(ch);
            i += ch.len_utf8();
        }
    }
    out
}

/// Sanitize an extracted `<style>` stylesheet so corporate email layouts
/// (`.preheader { display: none }`, `@media` queries, table/button classes)
/// render accurately inside a sandboxed WebView/iframe while preventing
/// remote resource fetches, tag breakouts, or viewport hijacking.
fn sanitize_stylesheet(raw_css: &str) -> String {
    // Remove comments, backslashes (escape smuggling), and angle brackets (tag breakouts).
    let no_comments = strip_css_comments(raw_css);
    let cleaned: String = no_comments
        .chars()
        .filter(|&c| !matches!(c, '\\' | '<' | '>'))
        .collect();

    let mut out = String::with_capacity(cleaned.len());
    let mut rest = cleaned.as_str();
    while !rest.is_empty() {
        let trimmed = rest.trim_start();
        if trimmed.is_empty() {
            break;
        }
        let lower = trimmed.to_ascii_lowercase();
        // Drop @import, @charset, @namespace (terminated by `;` or newline).
        if lower.starts_with("@import")
            || lower.starts_with("@charset")
            || lower.starts_with("@namespace")
        {
            if let Some(semi) = trimmed.find(';') {
                rest = &trimmed[semi + 1..];
            } else {
                break;
            }
            continue;
        }
        // Drop @font-face blocks (remote font fetches).
        if lower.starts_with("@font-face") {
            if let Some(open) = trimmed.find('{') {
                let mut depth = 0usize;
                let mut end = trimmed.len();
                for (idx, ch) in trimmed[open..].char_indices() {
                    if ch == '{' {
                        depth += 1;
                    } else if ch == '}' {
                        depth -= 1;
                        if depth == 0 {
                            end = open + idx + 1;
                            break;
                        }
                    }
                }
                rest = &trimmed[end..];
            } else {
                break;
            }
            continue;
        }

        // Preserve @media blocks by recursively sanitizing their inner rules.
        if lower.starts_with("@media") {
            if let Some(open) = trimmed.find('{') {
                let header = trimmed[..open].trim();
                let mut depth = 0usize;
                let mut end = trimmed.len();
                for (idx, ch) in trimmed[open..].char_indices() {
                    if ch == '{' {
                        depth += 1;
                    } else if ch == '}' {
                        depth -= 1;
                        if depth == 0 {
                            end = open + idx + 1;
                            break;
                        }
                    }
                }
                let inner = &trimmed[open + 1..end.saturating_sub(1)];
                let safe_inner = sanitize_stylesheet(inner);
                if !safe_inner.is_empty() {
                    out.push_str(header);
                    out.push('{');
                    out.push_str(&safe_inner);
                    out.push('}');
                }
                rest = &trimmed[end..];
                continue;
            } else {
                break;
            }
        }

        // Regular CSS rule: `selector { declarations }`
        let Some(open) = trimmed.find('{') else {
            break;
        };
        let Some(rel_close) = trimmed[open + 1..].find('}') else {
            break;
        };
        let close = open + 1 + rel_close;
        let selector = trimmed[..open].trim();
        let body = &trimmed[open + 1..close];
        rest = &trimmed[close + 1..];

        if selector.is_empty() || selector.starts_with('@') {
            continue;
        }
        let targets_root = selector.split(',').any(|s| {
            let s = s.trim().to_ascii_lowercase();
            s == "body" || s == "html"
        });

        let mut safe_decls = Vec::new();
        for decl in body.split(';') {
            let decl = decl.trim();
            if decl.is_empty() {
                continue;
            }
            let Some((prop, val)) = decl.split_once(':') else {
                continue;
            };
            let prop_l = prop.trim().to_ascii_lowercase();
            let val_l = val.trim().to_ascii_lowercase();
            // Reject any URL / script / overlay / remote-fetch constructs.
            if val_l.contains("url(")
                || val_l.contains("image-set(")
                || val_l.contains("expression(")
                || prop_l == "behavior"
                || prop_l == "-moz-binding"
                || prop_l == "content"
                || prop_l == "background-image"
                || (prop_l == "position" && (val_l.contains("fixed") || val_l.contains("sticky")))
            {
                continue;
            }
            if targets_root
                && ((prop_l == "display" && val_l.contains("none"))
                    || (prop_l == "visibility" && val_l.contains("hidden")))
            {
                continue;
            }
            safe_decls.push(format!("{}:{}", prop.trim(), val.trim()));
        }
        if !safe_decls.is_empty() {
            out.push_str(selector);
            out.push('{');
            out.push_str(&safe_decls.join(";"));
            out.push('}');
        }
    }
    out
}

/// Extract and sanitize all `<style>...</style>` blocks from `raw_html`.
fn extract_sanitized_styles(raw_html: &str) -> String {
    let lower = raw_html.to_ascii_lowercase();
    let mut combined = String::new();
    let mut cursor = 0usize;
    while let Some(rel_start) = lower[cursor..].find("<style") {
        let tag_start = cursor + rel_start;
        let Some(rel_gt) = lower[tag_start..].find('>') else {
            break;
        };
        let content_start = tag_start + rel_gt + 1;
        let Some(rel_end) = lower[content_start..].find("</style") else {
            break;
        };
        let content_end = content_start + rel_end;
        let sanitized = sanitize_stylesheet(&raw_html[content_start..content_end]);
        if !sanitized.is_empty() {
            combined.push_str(&sanitized);
        }
        cursor = content_end + "</style".len();
    }
    combined
}

/// Sanitize untrusted HTML email markup:
/// - strips scripts, forms, iframes, objects, SVGs, and inline event handlers
/// - extracts and sanitizes `<style>` blocks (preserving `.preheader` / `@media` layout rules while stripping `@import`, `@font-face`, `url(...)`, and `position:fixed`)
/// - preserves a strict allowlist of URL-free inline CSS properties in `style` attributes
/// - drops `javascript:`, `vbscript:`, and untrusted `data:` URLs
/// - blocks remote images unless `options.allow_remote_images` is true, counting blocked ones
/// - rewrites valid `cid:` image references to safe raster `data:` URIs after sanitization
pub fn sanitize(
    raw_html: &str,
    inline_images: &BTreeMap<String, InlineImage>,
    options: SanitizeOptions,
) -> SanitizedHtml {
    let safe_css = extract_sanitized_styles(raw_html);
    let mut nonce_bytes = [0u8; 16];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce: String = nonce_bytes.iter().map(|b| format!("{b:02x}")).collect();

    let blocked_remote_images = Arc::new(AtomicUsize::new(0));
    let blocked_cb = Arc::clone(&blocked_remote_images);
    let replacements: Arc<Mutex<Vec<(String, String)>>> = Arc::new(Mutex::new(Vec::new()));
    let replacements_cb = Arc::clone(&replacements);
    let allow_remote = options.allow_remote_images;
    let valid_cids: HashSet<String> = inline_images
        .iter()
        .filter(|(_, img)| is_safe_raster_mime(&img.content_type))
        .map(|(cid, _)| normalize_cid(cid))
        .collect();

    // Keep ammonia's conservative default tag allowlist (excludes form, input, button, textarea, select, meta, base, link).
    let mut builder = ammonia::Builder::default();
    builder.clean_content_tags(HashSet::from([
        "script", "style", "iframe", "object", "embed", "noscript", "svg", "math", "template",
    ]));
    builder.url_schemes(HashSet::from(["http", "https", "mailto", "cid"]));
    builder.url_relative(ammonia::UrlRelative::Deny);
    builder.link_rel(Some("noopener noreferrer"));
    builder.add_generic_attributes(["style", "class", "id"]);
    builder.filter_style_properties(SAFE_STYLE_PROPERTIES.iter().copied().collect());
    for tag in ["div", "p", "h1", "h2", "h3", "h4", "h5", "h6"] {
        builder.add_tag_attributes(tag, ["align"]);
    }
    builder.rm_generic_attributes(["srcset", "poster", "background"]);
    builder.attribute_filter(move |element, attribute, value| {
        let trimmed = value.trim();
        if element == "img" && attribute == "src" {
            if has_scheme(trimmed, "cid:") {
                let cid = normalize_cid(&trimmed[4..]);
                if !valid_cids.contains(&cid) {
                    return None;
                }
                let mut guard = replacements_cb.lock().unwrap_or_else(|e| e.into_inner());
                let sentinel = format!("https://cid.colecto.invalid/{nonce}/{}/", guard.len());
                guard.push((sentinel.clone(), cid));
                return Some(sentinel.into());
            }
            if is_remote_url(trimmed) {
                if allow_remote {
                    return Some(trimmed.to_owned().into());
                }
                blocked_cb.fetch_add(1, Ordering::Relaxed);
                return None;
            }
            return None;
        }
        if element == "a" && attribute == "href" {
            if has_scheme(trimmed, "http://")
                || has_scheme(trimmed, "https://")
                || has_scheme(trimmed, "mailto:")
            {
                return Some(trimmed.to_owned().into());
            }
            return None;
        }
        if matches!(attribute, "srcset" | "poster" | "background") {
            return None;
        }
        Some(value.into())
    });

    let mut html = builder.clean(raw_html).to_string();
    drop(builder);
    let pending: Vec<(String, String)> = replacements
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .drain(..)
        .collect();
    for (sentinel, cid) in pending {
        let img = inline_images.get(&cid).or_else(|| {
            inline_images
                .iter()
                .find(|(k, _)| normalize_cid(k) == cid)
                .map(|(_, v)| v)
        });
        if let Some(img) = img {
            let mime = img.content_type.trim().to_ascii_lowercase();
            let encoded = base64::engine::general_purpose::STANDARD.encode(&img.data);
            let data_uri = format!("data:{mime};base64,{encoded}");
            html = html.replace(&sentinel, &data_uri);
        }
    }

    if !safe_css.is_empty() {
        html = format!("<style>{safe_css}</style>{html}");
    }

    SanitizedHtml {
        html,
        blocked_remote_images: blocked_remote_images.load(Ordering::Relaxed),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_dangerous_tags_handlers_and_urls() {
        let dirty = r#"
            <script>alert(1)</script>
            <style>body{display:none}</style>
            <iframe src="https://evil.test"></iframe>
            <form action="https://evil.test"><input type="password"><button>Go</button></form>
            <p onclick="alert(1)">Hello</p>
            <img src="x" onerror="alert(1)">
            <a href="javascript:alert(1)">Bad Link</a>
            <a href="https://example.test/ok">Good Link</a>
            <a href="mailto:hi@example.test">Mail</a>
        "#;
        let sanitized = sanitize(dirty, &BTreeMap::new(), SanitizeOptions::default());
        let out = &sanitized.html;
        assert!(!out.contains("<script"));
        assert!(!out.contains("alert(1)"));
        assert!(!out.contains("body{display:none}"));
        assert!(!out.contains("<iframe"));
        assert!(!out.contains("<form"));
        assert!(!out.contains("<input"));
        assert!(!out.contains("<button"));
        assert!(!out.contains("onclick"));
        assert!(!out.contains("onerror"));
        assert!(!out.contains("javascript:"));
        assert!(out.contains("<p>Hello</p>"));
        assert!(out.contains(r#"href="https://example.test/ok""#));
        assert!(out.contains(r#"rel="noopener noreferrer""#));
        assert!(out.contains(r#"href="mailto:hi@example.test""#));
    }

    #[test]
    fn strips_untrusted_data_uris_even_when_remote_images_allowed() {
        let dirty = r#"
            <img src="data:image/svg+xml,<svg onload=alert(1)>">
            <img src="data:image/png;base64,AAAA">
            <a href="data:text/html,<script>alert(1)</script>">Click</a>
        "#;
        let sanitized = sanitize(
            dirty,
            &BTreeMap::new(),
            SanitizeOptions {
                allow_remote_images: true,
            },
        );
        assert!(!sanitized.html.contains("data:"));
        assert_eq!(sanitized.blocked_remote_images, 0);
    }

    #[test]
    fn blocks_and_counts_remote_images_by_default_and_allows_when_enabled() {
        let html =
            r#"<p>Look:</p><img src="https://track.test/p.gif"><img src="http://cdn.test/a.png">"#;
        let blocked = sanitize(html, &BTreeMap::new(), SanitizeOptions::default());
        assert_eq!(blocked.blocked_remote_images, 2);
        assert!(!blocked.html.contains("track.test"));
        assert!(!blocked.html.contains("cdn.test"));

        let allowed = sanitize(
            html,
            &BTreeMap::new(),
            SanitizeOptions {
                allow_remote_images: true,
            },
        );
        assert_eq!(allowed.blocked_remote_images, 0);
        assert!(allowed.html.contains(r#"src="https://track.test/p.gif""#));
        assert!(allowed.html.contains(r#"src="http://cdn.test/a.png""#));
    }

    #[test]
    fn resolves_valid_raster_cid_images_and_rejects_svg_or_missing_cids() {
        let mut inline = BTreeMap::new();
        inline.insert(
            "logo@example".into(),
            InlineImage {
                content_type: "image/png".into(),
                data: b"PNGDATA".to_vec(),
            },
        );
        inline.insert(
            "vector@example".into(),
            InlineImage {
                content_type: "image/svg+xml".into(),
                data: b"<svg/>".to_vec(),
            },
        );
        let html = r#"
            <img src="CID:Logo@Example" alt="Logo">
            <img src="cid:vector@example" alt="SVG">
            <img src="cid:missing@example" alt="Missing">
            <a href="cid:logo@example">Link</a>
        "#;
        let sanitized = sanitize(html, &inline, SanitizeOptions::default());
        assert!(
            sanitized
                .html
                .contains(r#"src="data:image/png;base64,UE5HREFUQQ==""#)
        );
        assert!(!sanitized.html.contains("svg+xml"));
        assert!(!sanitized.html.contains("missing@example"));
        assert!(!sanitized.html.contains(r#"href="cid:"#));
        assert!(!sanitized.html.contains("cid.colecto.invalid"));
    }

    #[test]
    fn resolves_twelve_or_more_inline_cid_images_without_prefix_collision() {
        let mut inline = BTreeMap::new();
        let mut html = String::new();
        for i in 0..12 {
            let cid = format!("img{i}@example");
            inline.insert(
                cid.clone(),
                InlineImage {
                    content_type: "image/png".into(),
                    data: format!("IMG-{i:02}").into_bytes(),
                },
            );
            html.push_str(&format!(r#"<img src="cid:{cid}">"#));
        }
        let sanitized = sanitize(&html, &inline, SanitizeOptions::default());
        assert!(!sanitized.html.contains("cid.colecto.invalid"));
        for i in 0..12 {
            let encoded =
                base64::engine::general_purpose::STANDARD.encode(format!("IMG-{i:02}").as_bytes());
            let expected = format!(r#"src="data:image/png;base64,{encoded}""#);
            assert!(
                sanitized.html.contains(&expected),
                "missing expected data URI for image {i} in {}",
                sanitized.html
            );
        }
    }

    #[test]
    fn preserves_safe_inline_styles_and_strips_dangerous_css_properties() {
        let dirty = r##"
            <div style="display:none; max-height:0px; overflow:hidden;">Preheader</div>
            <table width="600" bgcolor="#ffffff" style="background-color:#ffffff; border-radius:8px; background-image:url(https://track.test/bg.png); position:fixed; z-index:9999;">
              <tr>
                <td align="center" style="padding:16px; color:#24292f; background:url(https://track.test/cell.gif) no-repeat;">
                  <img src="https://cdn.test/logo.png" width="32" height="32" style="width:32px; height:32px; border-radius:50%;">
                  <a href="https://example.test/run" style="display:inline-block; background-color:#2da44e; color:#ffffff; padding:8px 16px; border-radius:6px; text-decoration:none;">View run</a>
                </td>
              </tr>
            </table>
        "##;
        let sanitized = sanitize(dirty, &BTreeMap::new(), SanitizeOptions::default());
        let out = &sanitized.html;

        // Safe layout, sizing, typography, and hidden-preheader styles survive.
        assert!(
            out.contains("display:none"),
            "expected display:none in {out}"
        );
        assert!(
            out.contains("background-color:#ffffff"),
            "expected background-color in {out}"
        );
        assert!(
            out.contains("border-radius:8px"),
            "expected border-radius in {out}"
        );
        assert!(out.contains("padding:16px"), "expected padding in {out}");
        assert!(out.contains("color:#24292f"), "expected color in {out}");
        assert!(out.contains("width:32px"), "expected width in {out}");
        assert!(out.contains("height:32px"), "expected height in {out}");
        assert!(
            out.contains(r#"width="32""#),
            "expected width attr in {out}"
        );
        assert!(
            out.contains(r#"height="32""#),
            "expected height attr in {out}"
        );

        // Dangerous/tracking CSS properties are stripped.
        assert!(!out.contains("track.test"), "leaked CSS tracker URL: {out}");
        assert!(
            !out.contains("background-image"),
            "leaked background-image: {out}"
        );
        assert!(
            !out.contains("position:fixed"),
            "leaked position:fixed: {out}"
        );
        assert!(!out.contains("z-index"), "leaked z-index: {out}");
        assert_eq!(sanitized.blocked_remote_images, 1);
    }

    #[test]
    fn sanitizes_style_blocks_preserving_preheader_and_media_queries_safely() {
        let dirty = r##"
            <style>
              @import url("https://track.test/evil.css");
              @font-face { font-family: Evil; src: url(https://track.test/font.woff2); }
              /* comment */
              body { display: none; color: #202124; }
              .preheader { display: none; max-height: 0; overflow: hidden; }
              .hero { background-image: url(https://track.test/bg.png); color: #1a73e8; position: fixed; }
              @media (max-width: 600px) {
                .col { width: 100%; background: url(https://track.test/m.gif); }
              }
            </style>
            <div class="preheader">Learn more about your plan</div>
            <div class="hero">Welcome</div>
        "##;
        let sanitized = sanitize(dirty, &BTreeMap::new(), SanitizeOptions::default());
        let out = &sanitized.html;

        assert!(
            out.contains("<style>"),
            "expected sanitized <style> in {out}"
        );
        assert!(
            out.contains(".preheader{display:none;max-height:0;overflow:hidden}"),
            "expected .preheader rule in {out}"
        );
        assert!(
            out.contains(r#"class="preheader""#),
            "expected class attribute preserved in {out}"
        );
        assert!(
            out.contains("@media (max-width: 600px){.col{width:100%}}"),
            "expected safe @media rule in {out}"
        );
        assert!(
            out.contains("color:#1a73e8"),
            "expected safe color in {out}"
        );
        assert!(!out.contains("track.test"), "leaked tracker URL: {out}");
        assert!(!out.contains("@import"), "leaked @import: {out}");
        assert!(!out.contains("@font-face"), "leaked @font-face: {out}");
        assert!(
            !out.contains("position:fixed"),
            "leaked position:fixed: {out}"
        );
        assert!(
            !out.contains("body{display:none"),
            "leaked body display:none: {out}"
        );
    }
}
