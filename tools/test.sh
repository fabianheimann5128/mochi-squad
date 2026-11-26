#!/bin/bash
# Führt alle Tests aus: Swift (Swift Testing) und die Python-Helfer.
# Ohne Xcode liegt das Test-Framework bei den Befehlszeilenwerkzeugen; die nötigen Pfade werden dann ergänzt.
set -euo pipefail
cd "$(dirname "$0")/.."
flags=()
clt=/Library/Developer/CommandLineTools
if [[ "$(xcode-select -p)" == "$clt" ]]; then
    f="$clt/Library/Developer/Frameworks"
    flags=(-Xswiftc -F -Xswiftc "$f" -Xlinker -F -Xlinker "$f" -Xlinker -rpath -Xlinker "$f"
           -Xlinker -rpath -Xlinker "$clt/Library/Developer/usr/lib"
           -Xswiftc -plugin-path -Xswiftc "$clt/usr/lib/swift/host/plugins/testing")
fi
swift test "${flags[@]}"
/usr/bin/python3 -B -W error::ResourceWarning -m unittest discover -s Tests/python
