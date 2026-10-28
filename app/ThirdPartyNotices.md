# ReDZ third-party notices

ReDZ application source is provided under AGPL-3.0-or-later; see `LICENSE`. Third-party components retain their own licenses below. The matching application source and upstream corresponding-source archive are provided beside each binary release at https://github.com/muhammadsqlan/redz/releases. The source archive contains the exact upstream source versions, build instructions, license texts, provenance, and SHA256 checksums. Native Apple frameworks are supplied by macOS.

## Bundled speech

ReDZ uses [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) under Apache-2.0. The model license is included in `Kokoro-LICENSE.txt` and in the app's resources. The full-precision ONNX model and voice pack are unmodified assets from the [kokoro-onnx model-files-v1.1 release](https://github.com/thewh1teagle/kokoro-onnx/releases/tag/model-files-v1.1).

- `kokoro-v1.0.onnx` SHA256: `beb0d1848dee9a49da392cc3df26958d46cfa35d321edf434f52949153f0df3a`
- `voices-v1.0.bin` SHA256: `bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d`

The local worker uses [kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx) 0.6.1 (MIT), ONNX Runtime 1.30.0 (MIT), espeakng-loader 0.2.4 (MIT), phonemizer 3.4.0 (GPL-3.0-or-later), NumPy 2.5.3, attrs 26.1.0, cloudpickle 3.1.2, dlinfo 2.0.0, flatbuffers 25.12.19, joblib 1.6.0, packaging 26.3, protobuf 7.36.2, and typing-extensions 4.16.0. Package notices and licenses are preserved with each distribution in `Contents/Resources/SpeechPackages` and the release source archive. The loader bundles eSpeak NG 1.52.0 (GPL-3.0-or-later), including pronunciation data. Matching source is included in the release source archive for [phonemizer](https://github.com/bootphon/phonemizer), [eSpeak NG](https://github.com/espeak-ng/espeak-ng), and [espeakng-loader](https://github.com/thewh1teagle/espeakng-loader), including the loader build workflow.

Standalone CPython 3.13.15 is bundled in `Contents/Resources/Python`, with its licenses and dependency notices retained. It was installed with uv's python-build-standalone distribution. The reader exchanges sentence text and generated audio through local pipes and makes no runtime network requests.

Tempo is prepared in memory with [Rubber Band Library 4.0.0](https://github.com/breakfastquay/rubberband/tree/v4.0.0), copyright 2007–2024 Particular Programs Ltd, under GPL-2.0-or-later. Its unmodified source is included in `ThirdParty/rubberband-4.0.0`, and its license is included in `RubberBand-LICENSE.txt` and the app's resources. Source tag `v4.0.0` resolves to commit `1d95888bec3ae0a17c0c4af791810d5a63f6bc35`; the original tag archive SHA256 is `24300f48a8014b7c863b573a9647e61b1b19b37875e2cdd92005e64c6424d266`. The equivalent commit-based archive and its hash are recorded in the release's `dependency-sources.json`. `build.sh` compiles its single-file build into `libReDZTempo.dylib`, using the macOS Accelerate FFT and built-in resampler. Audio uses the R3/Finer offline engine with unchanged pitch. No system package manager or additional runtime service is required.


## Local PDF reflow

PDF conversion uses PyMuPDF, PyMuPDF4LLM, and PyMuPDF Layout 1.28.2, under AGPL-3.0 (with commercial licensing available separately from Artifex). Sources: https://github.com/pymupdf/PyMuPDF, https://github.com/pymupdf/pymupdf4llm, and https://github.com/ArtifexSoftware/pymupdf_layout. Upstream macOS arm64 wheels and unmodified layout models are used. Native library install IDs, load paths, and signatures are adjusted for portable app packaging as documented in `sign_bundle.py`; upstream Python source is unchanged. Distribution licenses and notices are retained in `Contents/Resources/PDFPackages/*.dist-info`; full license texts and matching source, including MuPDF and its bundled third-party dependencies, accompany the release. ONNX Runtime and NumPy are shared with the speech worker. Auxiliary packages: PyYAML 6.0.3, NetworkX 3.7, tabulate 0.10.0, psutil 7.2.2. These run locally without a cloud API or model download.

Native original-page viewing uses Apple's PDFKit. PDF text and figures are not sent to Firecrawl or another service. Original documents are preserved; rendered figure, table, and equation crops are included in each locally generated EPUB. Public BERT (arXiv:1810.04805) and ResNet (arXiv:1512.03385) PDFs are development test inputs and are not bundled with the app.
