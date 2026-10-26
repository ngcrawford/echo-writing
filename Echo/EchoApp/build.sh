#!/bin/zsh
# Builds Echo.app into ./build and signs it with your Apple Development certificate, so the Accessibility
# permission survives rebuilds.
#
#   ./build.sh          build
#   ./build.sh --open      build, then quit any running Echo and launch the new one
#   ./build.sh --install   build, copy to /Applications, and launch it from there (Accessibility access is
#                          granted to /Applications/Echo.app and survives reinstalling)
set -e
cd "${0:A:h}"
IDENTITY=${ECHO_SIGN_IDENTITY:-"Apple Development"}

swift build -c release
APP=build/Echo.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/Echo $APP/Contents/MacOS/Echo
cp Support/Info.plist $APP/Contents/Info.plist
cp ../EchoEngine/Sources/EchoEngine/Resources/zipf-en.tsv $APP/Contents/Resources/
codesign --force --sign "$IDENTITY" $APP
echo "Built $(pwd)/$APP"

if [[ "$1" == "--open" || "$1" == "--install" ]]; then
    pkill -x Echo || true
    sleep 0.5
fi
if [[ "$1" == "--install" ]]; then
    rm -rf /Applications/Echo.app
    cp -R $APP /Applications/Echo.app
    echo "Installed /Applications/Echo.app"
    open /Applications/Echo.app
elif [[ "$1" == "--open" ]]; then
    open $APP
fi
