#!/bin/zsh
set -eu
reader_source_dir="${0:A:h}/Source"
reader_build_dir="${1:?Pass a new build directory}"
reader_speech_dir="${2:?Pass the prepared speech-assets directory}"
reader_packages_dir="${3:?Pass the prepared Python site-packages directory}"
reader_python_dir="${4:?Pass the standalone Python directory}"
reader_pdf_packages_dir="${5:?Pass the prepared PDF packages directory}"
reader_app="$reader_build_dir/ReDZ.app"
if [[ -e "$reader_app" ]]; then
  print -u2 "Use a fresh build directory."
  exit 1
fi
mkdir -p "$reader_app/Contents/MacOS" "$reader_app/Contents/Resources"
cp "$reader_source_dir/Reader.js" "$reader_app/Contents/Resources/Reader.js"
cp "$reader_source_dir/SpeechWorker.py" "$reader_app/Contents/Resources/SpeechWorker.py"
cp "$reader_source_dir/AudioDSP.py" "$reader_app/Contents/Resources/AudioDSP.py"
cp "$reader_source_dir/AudioTempo.py" "$reader_app/Contents/Resources/AudioTempo.py"
cp "$reader_source_dir/PDFImport.py" "$reader_app/Contents/Resources/PDFImport.py"
cp -R "$reader_pdf_packages_dir" "$reader_app/Contents/Resources/PDFPackages"
xcrun clang++ -std=c++11 -O3 -DNDEBUG -target arm64-apple-macos14.0 -dynamiclib -framework Accelerate "$reader_source_dir/../ThirdParty/rubberband-4.0.0/single/RubberBandSingle.cpp" -o "$reader_app/Contents/Resources/libReDZTempo.dylib" -Wl,-install_name,@rpath/libReDZTempo.dylib
cp "$reader_source_dir/../RubberBand-LICENSE.txt" "$reader_app/Contents/Resources/RubberBand-LICENSE.txt"
cp "$reader_source_dir/../Kokoro-LICENSE.txt" "$reader_app/Contents/Resources/Kokoro-LICENSE.txt"
cp "$reader_source_dir/../ThirdPartyNotices.md" "$reader_app/Contents/Resources/ThirdPartyNotices.md"
cp "$reader_source_dir/../LICENSE" "$reader_app/Contents/Resources/LICENSE"
cp -R "$reader_source_dir/../ThirdPartyLicenses" "$reader_app/Contents/Resources/ThirdPartyLicenses"
cp "$reader_speech_dir/kokoro-v1.0.onnx" "$reader_speech_dir/voices-v1.0.bin" "$reader_app/Contents/Resources/"
cp -R "$reader_packages_dir" "$reader_app/Contents/Resources/SpeechPackages"
cp -R "$reader_python_dir" "$reader_app/Contents/Resources/Python"
xcrun swift "$reader_source_dir/Icon.swift" "$reader_app/Contents/Resources/ReDZ.icns"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -framework AppKit -framework WebKit -framework AVFoundation -framework UniformTypeIdentifiers -framework PDFKit "$reader_source_dir/EPUBBook.swift" "$reader_source_dir/PDFImporter.swift" "$reader_source_dir/NeuralSpeech.swift" "$reader_source_dir/ReaderController.swift" "$reader_source_dir/SelfTests.swift" "$reader_source_dir/PDFTests.swift" "$reader_source_dir/main.swift" -o "$reader_app/Contents/MacOS/ReDZ"
cat > "$reader_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>ReDZ</string>
<key>CFBundleDisplayName</key><string>ReDZ</string>
<key>CFBundleIdentifier</key><string>com.muhammadsqlan.redz</string>
<key>CFBundleExecutable</key><string>ReDZ</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>ReDZ</string>
<key>CFBundleShortVersionString</key><string>0.3.2</string>
<key>CFBundleVersion</key><string>13</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>EPUB Book</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>org.idpf.epub-container</string></array>
</dict><dict>
<key>CFBundleTypeName</key><string>PDF Document</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
</dict></array>
</dict></plist>
PLIST
/usr/bin/python3 "${reader_source_dir:h}/sign_bundle.py" "$reader_app" "${REDZ_SIGN_IDENTITY:--}"
/usr/bin/codesign --verify --deep --strict "$reader_app"
print "$reader_app"
