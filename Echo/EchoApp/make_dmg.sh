#!/bin/zsh
# Builds a shareable Echo-<version>.dmg in ./build (the app plus a shortcut to Applications).
#
# With a "Developer ID Application" certificate in your keychain, the app is signed for distribution and,
# if you've saved notarization credentials once (see below), sent to Apple for notarization, so it opens on
# any Mac without warnings. Without one, it's signed with your Apple Development certificate: fine for you,
# but recipients must approve it in System Settings › Privacy & Security ("Open Anyway").
#
#   ./make_dmg.sh
#
# One-time notarization setup (needs an app-specific password from account.apple.com):
#   xcrun notarytool store-credentials echo-notary --apple-id YOU@EXAMPLE.COM --team-id 29KX8KY65Q
set -e
cd "${0:A:h}"
PROFILE=${ECHO_NOTARY_PROFILE:-echo-notary}

./build.sh
APP=build/Echo.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" $APP/Contents/Info.plist)
DMG=build/Echo-$VERSION.dmg

IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
if [[ -n "$IDENTITY" ]]; then
    echo "Signing for distribution with: $IDENTITY"
else
    IDENTITY=${ECHO_SIGN_IDENTITY:-"Apple Development"}
    echo "No Developer ID certificate found; signing with $IDENTITY (recipients will need \"Open Anyway\")."
fi
# Hardened runtime and a secure timestamp are required for notarization.
codesign --force --options runtime --timestamp --sign "$IDENTITY" $APP
codesign --verify --strict $APP

STAGE=build/dmg
rm -rf $STAGE $DMG
mkdir -p $STAGE
cp -R $APP $STAGE/
ln -s /Applications $STAGE/Applications
hdiutil create -volname "Echo $VERSION" -srcfolder $STAGE -ov -format UDZO -quiet $DMG
rm -rf $STAGE
codesign --force --timestamp --sign "$IDENTITY" $DMG

if [[ "$IDENTITY" == Developer\ ID* ]] && xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "Notarizing (usually a few minutes)…"
    xcrun notarytool submit $DMG --keychain-profile "$PROFILE" --wait
    xcrun stapler staple $DMG
    spctl --assess --type open --context context:primary-signature -v $DMG
elif [[ "$IDENTITY" == Developer\ ID* ]]; then
    echo "Not notarized: no saved credentials named \"$PROFILE\" (see the top of this script)."
fi
echo "Built $(pwd)/$DMG"
