#!/bin/sh
# Runs the tests with swift-testing. With only the Command Line Tools installed (no
# Xcode), the Testing framework isn't on the default search paths, so add them; and its
# Foundation overlay ships without a Swift module, so cross-import overlays are off.
set -e
cd "$(dirname "$0")/.."
FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
LIBS="$(xcode-select -p)/Library/Developer/usr/lib"
if [ -d "$FRAMEWORKS/Testing.framework" ]; then
  exec swift test \
    -Xswiftc -F"$FRAMEWORKS" -Xlinker -F"$FRAMEWORKS" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$LIBS" "$@"
fi
exec swift test "$@"
