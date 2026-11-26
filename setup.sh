#!/bin/bash
# Set up Mochi Squad: check the requirements, build the app and install it to ~/Applications.
#   ./setup.sh            checks, builds and installs
#   ./setup.sh --check    only checks the requirements
set -euo pipefail
cd "$(dirname "$0")"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; missing=1; }
missing=0

echo "Mochi Squad – requirements"

major="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "$major" -ge 14 ]]; then ok "macOS $(sw_vers -productVersion)"; else fail "macOS 14 (Sonoma) or newer is required, found: $(sw_vers -productVersion)"; fi

# The terminal library the app builds on needs Swift 6; older command line tools fail only while resolving packages.
if command -v swift >/dev/null 2>&1; then
    swift_version="$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+)\.([0-9]+).*/\1.\2/p' | head -1)"
    if [[ -n "$swift_version" && "${swift_version%%.*}" -ge 6 ]]; then
        ok "Swift $swift_version"
    else
        fail "Swift 6.0 or newer is required, found: ${swift_version:-unknown}. Update the Xcode command line tools: softwareupdate --list, or xcode-select --install"
    fi
else
    fail "Swift is missing. Install the Xcode command line tools with: xcode-select --install"
fi

if [[ -x /usr/bin/python3 ]] && /usr/bin/python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
    ok "Python $(/usr/bin/python3 -c 'import platform; print(platform.python_version())')"
else
    fail "/usr/bin/python3 (3.9 or newer) is missing. It comes with the Xcode command line tools: xcode-select --install"
fi

# At least one agent program is needed; you sign in later in the app with your own subscription.
agents=0
chatgpt_codex="/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
for cli in claude codex; do
    if command -v "$cli" >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/$cli" ]] || [[ "$cli" == codex && -x "$chatgpt_codex" ]]; then
        ok "$cli found"; agents=1
    fi
done
if [[ "$agents" -eq 0 ]]; then
    warn "Neither Claude Code (claude) nor Codex (codex) found. The app starts anyway, but agents need one of them:"
    warn "  Claude Code: https://docs.claude.com/claude-code   ·   Codex: https://developers.openai.com/codex/cli"
fi

if command -v node >/dev/null 2>&1; then ok "Node.js $(node -v) (only needed for WhatsApp)"; else warn "Node.js not found. Only the optional WhatsApp link needs it."; fi

if [[ "$missing" -ne 0 ]]; then
    echo; echo "Please fix the marked points and run ./setup.sh again."; exit 1
fi
[[ "${1:-}" == "--check" ]] && exit 0

# Replacing the app under a running copy would leave that copy with helpers of the new version.
if pgrep -x MochiSquad >/dev/null; then
    echo; echo "Mochi Squad is running. Quit the app (your agents' sessions end with it), then run ./setup.sh again."; exit 1
fi

echo; echo "Building the app (a few minutes the first time) …"
./install.sh
echo
echo "Done. Mochi Squad is in ~/Applications and opens now; on first launch the app guides you through setup."
# Open nothing in automated runs (CI) or without a screen.
[[ -n "${CI:-}" ]] || open "$HOME/Applications/Mochi Squad.app" || true
