# Public ReDZ release

- Website: https://muhammadsqlan.com/redz
- Download: https://muhammadsqlan.com/redz/download
- Source and release: https://github.com/muhammadsqlan/redz/releases/tag/v0.3.2
- Dedicated Cloudflare Worker: `redz`
- Worker URL: https://redz.sqlan.workers.dev/redz/
- Route: `muhammadsqlan.com/redz*`; non-ReDZ paths pass through to the existing origin.
- Deployment version: `d7d7bbef-d3a5-4bcc-96e7-235e2baddd0d`

## Mac app

ReDZ 0.3.2, build 13. Apple Silicon, macOS 14+. Developer ID signed, Apple notarization Accepted, stapled, and Gatekeeper accepted. The final disk image's enclosed app was mounted read-only and verified for identity, version, signature, executable hash, and Gatekeeper acceptance.

`ReDZ-0.3.2-arm64.dmg` is 466,175,612 bytes. SHA-256:

```text
7b2601d5d31424828120f7df3950ea926388d3994fdb943a4103a8abc2e1b1de
```

The public download was fetched anonymously through `/redz/download` and its full SHA-256 matched the notarized local installer. GitHub also reported matching asset hashes for the installer and dependency source archive. The dependency sources, application source, license notices, and checksums are public alongside the download.

## Validation

- 30 native PDF checks passed, including real voice generation, sentence highlighting/navigation, Original PDF mapping, caching, images, appearance, and EPUB export/reimport.
- Four Worker routing tests and deployment dry run passed.
- Fifteen live HTTP checks passed, covering pages, static assets, release metadata, fixed download/source redirects, unknown paths, and unsupported methods.
- Existing homepage content and all pre-existing Cloudflare routes were unchanged.
- Background browser checks passed at desktop and mobile sizes. Copy, layout, typography, palette, controls, and responsive behavior were compared with the design concept. All live page and style bytes matched those browser-tested files. A separate live browser screenshot was unavailable because the passive browser surface became unavailable.

Original ReadAlong source and the installed ReadAlong app were preserved. ReDZ keeps compatible internal preferences and library paths; it does not bundle personal books or use a personal first-launch book fallback.

Local evidence is preserved under `releases/0.3.2/native-checks`, `docs/deployment`, and `docs/design`; these directories are excluded from the public repository.
