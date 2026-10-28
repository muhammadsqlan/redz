# ReDZ 0.3.2 — Read Easy

Native Mac EPUB and PDF reader for reading and listening together. Open your own book with the folder button or File → Open. ReDZ restores your last book on subsequent launches. Existing ReadAlong books and settings remain compatible.

- **Play** starts with the first word on the current screen page.
- **Pause** holds narration. **Resume** restarts the highlighted sentence from its beginning. **Space** also toggles playback.
- **↑ / ↓** or the matching arrow buttons move to the previous or next sentence and start reading it. Repeated presses count individually, including across pages and sections.
- Recent audio is kept in memory, and two sentences in each direction are prepared in the background. Replaying a prepared sentence starts without generating it again. Skipping cancels unused generation. New, unprepared sentences can still take longer to start.
- **← / →** turn pages. A manual page turn stops narration; the next Play starts at the top of that page.
- The circular arrow reads the current page again from the top.
- Narration highlights the whole current sentence and turns pages and chapters automatically. The highlight remains visible while paused.
- Click an image or chart to enlarge it and pause narration. Close it with **×** or **Escape**, then press Resume.
- Use Contents to jump to a chapter or section, and the voice, speed, and text-size controls to adjust reading.
- Choose **Heart** or **Bella** (female), or **Michael** or **Fenrir** (male). Heart is the default. Novelty and older system voices are excluded.
- Above 1×, each sentence's first word plays one step (0.25×) slower before a smooth transition to the selected speed: 2× starts at 1.75×, 1.75× at 1.5×, 1.5× at 1.25×, and 1.25× at 1×. Resume and sentence skips repeat this lead-in. A one-word sentence uses the lead-in speed throughout. Speeds of 1× and below stay constant.
- Double-click a word to start narration there.
- **System / Light / Dark** changes appearance. System is the default and follows macOS, including changes while the app is open. Dark mode uses native macOS background, text, and selection colors. Your choice is saved for the next launch.
- Your book position, voice, speed, and text size are saved locally.
- Open a research **PDF** with the folder button or **File → Open**. Its columns become one readable text flow with the same narration and sentence highlighting.
- **Original** opens the source PDF at the highlighted passage’s page and pauses narration. **Reading** returns to the same passage; moving to a different original page returns to that part of the text.
- Figures, tables, and displayed equations keep their original appearance as zoomable images. Captions remain readable text. Footnotes are collected at the end.
- **File → Export EPUB** saves the reflowed paper for other EPUB readers. Choose a new filename; existing files are preserved.

Pages reflow to the window and text size; their numbers are screen-page numbers within the current section, rather than the PDF's printed page numbers. Unencrypted EPUBs and text-based PDFs of up to 300 pages / 150 MB are supported. The PDF number in the footer identifies the original source page; the other number identifies the reflowed screen page. No audio is played automatically when opening a book.

PDFs are parsed locally with PyMuPDF Layout and PyMuPDF4LLM, cached by source SHA256 and converter version, and exported as XHTML and EPUB. An unchanged original is retained alongside the conversion. No PDF is uploaded to Firecrawl or any other service. Scanned pages within a mixed document remain images; fully scanned PDFs report that OCR is required. Conversion is best-effort: unusual layouts, inline math, symbols, and reading order can require comparison with **Original**. Equations and table cells in image crops are not narrated.

The EPUB is extracted into a new folder under `~/Library/Application Support/ReadAlong/Books`. The original EPUB is not edited. Books and settings stay on the Mac. The app bundles Kokoro-82M, ONNX Runtime, and Python for offline speech. Audio is generated in memory at normal speed. Up to 64 prepared recordings or 48 MiB of audio are retained; voices and speeds use separate cache entries, and duplicate pending requests share a single render. The speech worker also retains up to 32 natural recordings or 48 MiB, so changing speed can reuse the same speech without repeating neural generation. Two neighbouring sentences in each direction are prepared, and the next playback sentence is prefetched. Unused inference stops when you skip. The complete audio onset is retained; only excess trailing silence is trimmed. A gentle 30 Hz high-pass filter removes changing DC offsets and subsonic rumble, with short fades inside the clip's silent edges and peak headroom. It preserves audio duration and word timings. Tempo is prepared entirely before playback with the [Rubber Band](https://breakfastquay.com/rubberband/) R3/Finer offline engine. It preserves pitch and prepares the first-word lead-in and smooth transition in the recording. Word positions are mapped to the prepared audio clock. The Mac player runs at 1× with its live speed processor disabled at every setting. Natural 1× audio and one-word units at a selected 1.25× bypass tempo processing. This replaces the previous native speed path; whether it resolves the reported speaker thump still requires a listening test. No account, server, or speech API is required. A short delay may occur when starting or changing a voice.

## Build

Xcode with Swift and macOS 14 or later are required. This build targets Apple Silicon.

Run `zsh build.sh /absolute/path/to/a/new/build-directory /path/to/speech-assets /path/to/site-packages /path/to/standalone-python /path/to/pdf-packages` from this folder. Each build creates a fresh `ReDZ.app`; existing builds are preserved. Set `REDZ_SIGN_IDENTITY` to a Developer ID Application identity for a timestamped, hardened-runtime signature; otherwise the build is signed ad hoc. The script checks native dependencies and bundle symlinks for portability and signs each bundled native component before signing the app.

The speech-assets directory contains the full-precision `kokoro-v1.0.onnx` and `voices-v1.0.bin` from the [model-files-v1.1 release](https://github.com/thewh1teagle/kokoro-onnx/releases/tag/model-files-v1.1), which includes phoneme durations. Use Python 3.13 with `kokoro-onnx==0.6.1`. The PDF packages directory contains PyMuPDF 1.28.2, PyMuPDF4LLM 1.28.2, PyMuPDF Layout 1.28.2, PyYAML 6.0.3, NetworkX 3.7, tabulate 0.10.0, and the non-free-threaded arm64 ABI3 wheel of psutil 7.2.2. Exact package versions and model hashes are recorded in `ThirdPartyNotices.md`.

## Checks

The app includes a silent test run using the real book and the bundled speech engine:

`ReDZ.app/Contents/MacOS/ReDZ --self-test '/path/to/book.epub' '/path/to/a/new/test-directory'`

Passing a BERT or ResNet PDF to the same `--self-test` entry point runs PDF import, two-column reading-order landmarks, figures/tables/equation crops, source-page viewing, paused-state preservation, narration, sentence navigation, cached reopening, compact layouts, and EPUB export/reimport checks.

The EPUB checks cover system appearance at startup and while running, saved Light/Dark overrides, text and highlight contrast, image zoom in dark mode, theme changes during playback without interrupting audio, reading order, page-start narration, pause and sentence-start resume, repeated keyboard/button sentence navigation across pages and sections, sentence highlighting, all four voices and their audio timings, prepared audio timings at every fast speed, a normal PCM playback clock with native speed processing bypassed, cache reuse and book-position remapping, neighbouring-sentence preparation, measured skip-to-speech latency, page and chapter continuation, image display, image zoom, saved progress, and window/text resizing. Separate audio checks verify filter response, low-frequency noise reduction, preserved speech energy, clipping headroom, and the complete first word and timing after filtering for every voice. Tempo checks inspect rendered tones and separate speech-like bursts for unchanged pitch, one-step-slower first-word duration, and later timing, then check all four real voices at every speed for onset retention, mapped word positions, clipping, edge transients, and cache reuse. They also cover one-word audio and cancellation. The test run writes a JSON report, screenshots, and voice samples and uses a separate settings suite. Historical 0.3.1 validation covered these checks. Release-specific checks are recorded separately; a test report must identify which checks were actually rerun.

Technical pronunciations and your preferred voice still need your listening feedback. OCR, DRM, cloud parsing, and cloud voices are outside this version's scope. The sentence highlight is exact; word positions used for automatic page turns are aligned from phonemes and can be slightly approximate around numbers or unusual technical terms.
