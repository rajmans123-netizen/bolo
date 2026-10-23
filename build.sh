#!/bin/zsh
# Build Bolo.app (universal: Apple silicon + Intel), ad-hoc signed, into build/
set -e
cd "${0:A:h}"
APP=build/Bolo.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos26.0 Sources/main.swift -o build/Bolo-$arch
done
lipo -create build/Bolo-arm64 build/Bolo-x86_64 -output $APP/Contents/MacOS/Bolo && rm build/Bolo-arm64 build/Bolo-x86_64
[ -f assets/Bolo.icns ] && cp assets/Bolo.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Bolo</string>
  <key>CFBundleDisplayName</key><string>Bolo</string>
  <key>CFBundleIdentifier</key><string>com.rajtries.bolo</string>
  <key>CFBundleExecutable</key><string>Bolo</string>
  <key>CFBundleIconFile</key><string>Bolo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSMicrophoneUsageDescription</key><string>Bolo listens only while you hold the key, and turns your speech into text on this Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Bolo uses Apple's on-device speech recognition to type what you say.</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Raj Tries · built with Claude</string>
</dict></plist>
PL
codesign --force --deep -s - $APP
echo "built $APP"
