#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"
BLEACH_DEVELOPER_DIR=$(xcode-select -p)
# SwiftPM in the installed CLT release does not add its own Testing framework
# or interop runtime paths. Use those existing files without changing Xcode.
if [[ "$BLEACH_DEVELOPER_DIR" == /Library/Developer/CommandLineTools && -d "$BLEACH_DEVELOPER_DIR/Library/Developer/Frameworks/Testing.framework" ]]; then
    swift test --disable-xctest --enable-swift-testing \
        -Xswiftc -F -Xswiftc "$BLEACH_DEVELOPER_DIR/Library/Developer/Frameworks" \
        -Xswiftc -load-plugin-library -Xswiftc "$BLEACH_DEVELOPER_DIR/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib" \
        -Xlinker -rpath -Xlinker "$BLEACH_DEVELOPER_DIR/Library/Developer/Frameworks" \
        -Xlinker -rpath -Xlinker "$BLEACH_DEVELOPER_DIR/Library/Developer/usr/lib" "$@"
else
    swift test --disable-xctest --enable-swift-testing "$@"
fi
