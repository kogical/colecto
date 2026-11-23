//! Real-world-style HTML emails (the demo account's `app/assets/demo/emails`)
//! run through the full MIME → sanitize → preview pipeline.

use std::path::PathBuf;

use colecto_core::mime::sanitized_content;

/// (fixture, start of the inbox preview, a link the reader must keep)
const FIXTURES: &[(&str, &str, &str)] = &[
    (
        "verify-email.html",
        "Confirm your email to finish setting up Northwind.",
        "https://app.northwind.example/verify?token=6f2c9e",
    ),
    (
        "order-receipt.html",
        "Order FL-48213 is on its way \u{2014} arriving Tuesday.",
        "https://tracking.fernleaf.example/FL-48213",
    ),
    (
        "newsletter.html",
        "This week: the quiet return of the hedgerow",
        "https://fieldnotes.example/unsubscribe?u=82731",
    ),
    (
        "ci-run-failed.html",
        "orbit-labs/orbit",
        "https://forge.example/orbit-labs/orbit/actions/runs/91827364",
    ),
    (
        "security-alert.html",
        "New sign-in on Linux from Krak\u{f3}w, Poland. Was this you?",
        "https://accounts.quillmail.example/secure?from=alert",
    ),
];

fn raw_message(html: &str) -> Vec<u8> {
    format!(
        "From: sender@example.test\r\nTo: me@example.test\r\nSubject: Fixture\r\n\
         Message-ID: <fixture@example.test>\r\nMIME-Version: 1.0\r\n\
         Content-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n{html}"
    )
    .into_bytes()
}

fn fixture(name: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../app/assets/demo/emails")
        .join(name);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

#[test]
fn fixtures_sanitize_block_remote_content_and_keep_layout() {
    for &(name, _, link) in FIXTURES {
        let raw = raw_message(&fixture(name));
        let content = sanitized_content(&raw, false).unwrap();
        let html = content.html.expect(name);

        // Tracking pixels, logos and hero images are all remote.
        assert!(content.blocked_remote_images > 0, "{name}: nothing blocked");
        for needle in [
            "<script",
            "javascript:",
            "@import",
            "url(",
            "v:roundrect",
            "<!--",
        ] {
            assert!(!html.contains(needle), "{name}: kept {needle}");
        }
        assert!(
            !html.contains("src=\"https://") && !html.contains("src=\"http://"),
            "{name}: kept a remote src"
        );
        // Layout survives: the email's own styles and tables, and its links.
        assert!(html.contains("<style"), "{name}: lost its <style>");
        assert!(
            html.contains("<table") || html.contains("<div"),
            "{name}: lost layout"
        );
        assert!(
            html.contains(&format!("href=\"{}\"", link.replace('&', "&amp;"))),
            "{name}: lost {link}"
        );

        let allowed = sanitized_content(&raw, true).unwrap();
        assert_eq!(allowed.blocked_remote_images, 0, "{name}");
    }
}

#[test]
fn fixture_previews_are_clean_text() {
    for &(name, preview, _) in FIXTURES {
        let content = sanitized_content(&raw_message(&fixture(name)), false).unwrap();
        let text = content.text;
        assert!(text.starts_with(preview), "{name}: preview was {text:?}");
        // Preheader padding and entities never leak into previews.
        for needle in [
            "&#", "&zwnj;", "&nbsp;", "&rsquo;", "\u{200C}", "\u{034F}", "\u{FEFF}",
        ] {
            assert!(!text.contains(needle), "{name}: preview kept {needle:?}");
        }
    }
}
