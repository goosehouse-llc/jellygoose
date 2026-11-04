#!/bin/zsh
# Puts JellyGoose on Sam's own iPhone with its own car screen: CarPlay video
# beside CarPlay audio, so a car that can't show CarPlay video (the Audi)
# opens the app's own screens and player, picture while parked. App Review
# refused that pair for iOS 1.7.1 (Guideline 2.5.1), so the App Store build
# has CarPlay audio alone; this one is never archived or uploaded (the build
# stops if it's archived). It needs the CarPlay Video capability left on for
# the App ID at developer.apple.com.
#
# The same as choosing the "JellyGoose Car Screen" scheme in Xcode, then the
# iPhone, then Run (its CarScreen configuration is what switches it on).
#
#   zsh Tools/car-screen.sh <device>   builds and installs on that iPhone (id from: xcrun devicectl list devices)
#
# Close JellyGoose on the phone first: installing quits it. If the car's icon
# is greyed after installing with the phone plugged into the car, unplug it
# and plug it back in.
set -e
cd "${0:A:h}/.."
device=${1:?usage: zsh Tools/car-screen.sh <device id>}
app=build/ios-release/Build/Products/CarScreen-iphoneos/JellyGoose.app
log=build/ios-release/car-screen.log

xcodegen generate --quiet
mkdir -p build/ios-release
echo "Building (a few minutes)…"
if ! xcodebuild build -project GooseTV.xcodeproj -scheme "JellyGoose Car Screen" \
  -configuration CarScreen -destination "id=$device" \
  -derivedDataPath build/ios-release -allowProvisioningUpdates > $log 2>&1; then
  grep -E "error:|BUILD FAILED" $log | tail -20 >&2
  echo "The build failed; the whole log is $log." >&2
  exit 1
fi

if ! codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q carplay-video; then
  echo "The build has no CarPlay video entitlement; not installing." >&2
  exit 1
fi
if ! plutil -p "$app/Info.plist" | grep -q UIWindowSceneSessionRoleCarPlay; then
  echo "The build has no car screen scene; not installing." >&2
  exit 1
fi

xcrun devicectl device install app --device "$device" "$app" > /dev/null
echo "Installed JellyGoose $(plutil -extract CFBundleShortVersionString raw "$app/Info.plist") ($(plutil -extract CFBundleVersion raw "$app/Info.plist")) with the car screen."
