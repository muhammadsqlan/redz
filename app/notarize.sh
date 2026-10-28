#!/bin/zsh
set -euo pipefail
release_app="${1:?Pass the signed ReDZ.app path}"
notary_profile="${2:?Pass the notarytool Keychain profile name}"
release_dir="${release_app:A:h}"
release_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$release_app/Contents/Info.plist")
release_identity="${REDZ_SIGN_IDENTITY:?Set REDZ_SIGN_IDENTITY to a Developer ID Application identity}"
release_stem="ReDZ-${release_version}-arm64"
release_dmg="$release_dir/$release_stem.dmg"
release_zip="$release_dir/$release_stem.zip"
release_layout="$release_dir/DMG Layout"
release_receipt="$release_dir/notarization.json"
release_notary_log="$release_dir/notarization-log.json"
release_hashes="$release_dir/SHA256SUMS.txt"

for release_output in "$release_dmg" "$release_zip" "$release_layout" "$release_receipt" "$release_notary_log" "$release_hashes"; do
  if [[ -e "$release_output" || -L "$release_output" ]]; then
    print -u2 "Preserving existing output: $release_output"
    exit 1
  fi
done

[[ "$release_app:t" == ReDZ.app ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$release_app/Contents/Info.plist")" == com.muhammadsqlan.redz ]]
/usr/bin/codesign --verify --deep --strict "$release_app"
mkdir "$release_layout"
/usr/bin/ditto "$release_app" "$release_layout/ReDZ.app"
ln -s /Applications "$release_layout/Applications"
/usr/bin/hdiutil create -fs HFS+ -format UDZO -imagekey zlib-level=9 -srcfolder "$release_layout" -volname ReDZ "$release_dmg"
/usr/bin/codesign --force --identifier com.muhammadsqlan.redz.dmg --timestamp --sign "$release_identity" "$release_dmg"
/usr/bin/codesign --verify --strict "$release_dmg"

xcrun notarytool submit "$release_dmg" --keychain-profile "$notary_profile" --wait --output-format json > "$release_receipt"
release_submission=$(/usr/bin/plutil -extract id raw -o - "$release_receipt")
release_status=$(/usr/bin/plutil -extract status raw -o - "$release_receipt")
xcrun notarytool log "$release_submission" --keychain-profile "$notary_profile" "$release_notary_log"
if [[ "$release_status" != Accepted ]]; then
  print -u2 "Notarization status: $release_status; see $release_notary_log"
  exit 1
fi

xcrun stapler staple "$release_dmg"
xcrun stapler validate "$release_dmg"
xcrun stapler staple "$release_app"
xcrun stapler validate "$release_app"
/usr/bin/codesign --verify --deep --strict "$release_app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$release_app"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$release_dmg"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$release_app" "$release_zip"
(
  cd "$release_dir"
  /usr/bin/shasum -a 256 "$release_stem.dmg" "$release_stem.zip" > "$release_hashes"
)
print "Ready: $release_dmg"
print "Ready: $release_zip"
