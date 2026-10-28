# ReDZ — Read Easy

An offline EPUB and PDF reader for Mac. Read and listen together with natural voices and sentence highlighting.

[Download for Mac](https://muhammadsqlan.com/redz/) · [Releases](https://github.com/muhammadsqlan/redz/releases)

## Requirements

Apple Silicon, macOS 14 or later. The download includes the speech model, Python runtime, PDF libraries, and voices. No account or API key is required.

## Features

- EPUB and selectable-text PDF reading with local speech.
- Sentence highlighting, pause/resume, sentence navigation, and automatic page/chapter continuation.
- Heart, Bella, Michael, and Fenrir voices; 0.75×–2× playback.
- System, Light, and Dark appearance; saved position and preferences.
- Original PDF view, figure enlargement, and PDF-to-EPUB export.

PDFs must be unlocked and contain selectable text, with a maximum of 300 pages and 150 MB. OCR is not included. Scanned pages, figures, tables, and displayed equations remain images; their image contents are not narrated. Complex layouts may need comparison with the Original view.

## Source

`app/` contains the native app and build instructions. `site/` contains the dedicated Cloudflare Worker and static download website. Versioned release assets include dependency source archives and SHA-256 checksums.

The app is licensed under AGPL-3.0-or-later. Third-party components retain their respective licenses; see [app/ThirdPartyNotices.md](app/ThirdPartyNotices.md). The corresponding-source archive is distributed alongside each binary release.

## Website

The Worker is named `redz` and serves `muhammadsqlan.com/redz`. Download links point to immutable versioned GitHub release assets. Requests for other paths on the domain pass through to the existing site.

```sh
cd site
npm install
npm test
npm run dev
npm run deploy
```

The original app name was ReadAlong. Internal library and preference identifiers are retained for reading-position compatibility; the public app is ReDZ.
