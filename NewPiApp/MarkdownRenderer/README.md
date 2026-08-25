# MarkdownRenderer Assets

Vendored for local-only WKWebView rendering in NewPi. Do not load rendering code or CSS from a runtime CDN.

- `markdown-it.min.js`: markdown-it 14.1.1, MIT License
- `highlight.min.js`: highlight.js 11.11.1 browser bundle, BSD-3-Clause License
- `highlight-github.min.css`: highlight.js GitHub theme, BSD-3-Clause License
- `github-markdown-light.css`: github-markdown-css 5.9.0, MIT License
- `markdown-renderer.js` and `markdown-renderer.css`: NewPi glue and layout overrides

The Swift WebView bridge loads this directory from the app bundle with CSP and navigation checks to keep untrusted model output local.
