#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
if pgrep -x BleachApp >/dev/null; then
    print -u2 'Quit Bleach before installing an update.'
    exit 1
fi
"$PROJECT_DIR/scripts/build.sh"
BLEACH_STAGED_APP="/Applications/.Bleach-install-$$.app"
trap 'if [[ -d "$BLEACH_STAGED_APP" ]]; then rm -rf -- "$BLEACH_STAGED_APP"; fi' EXIT
ditto "$PROJECT_DIR/build/Bleach.app" "$BLEACH_STAGED_APP"
codesign --verify --strict "$BLEACH_STAGED_APP"
if [[ -e /Applications/Bleach.app ]]; then
    BLEACH_APP_STATE="$HOME/Library/Application Support/Bleach"
    if [[ ! -e "$BLEACH_APP_STATE" && ! -L "$BLEACH_APP_STATE" ]]; then
        mkdir -m 700 "$BLEACH_APP_STATE"
    fi
    if [[ -L "$BLEACH_APP_STATE" || ! -d "$BLEACH_APP_STATE" || ! -O "$BLEACH_APP_STATE" || $(stat -f '%Lp' "$BLEACH_APP_STATE") != 700 ]]; then
        print -u2 'Bleach backups require a private, user-owned state folder (mode 700).'
        exit 1
    fi
    BLEACH_BACKUP_DIR="$BLEACH_APP_STATE/Backups/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$BLEACH_BACKUP_DIR"
    mv /Applications/Bleach.app "$BLEACH_BACKUP_DIR/Bleach.app"
    print "Previous app saved to $BLEACH_BACKUP_DIR"
fi
mv "$BLEACH_STAGED_APP" /Applications/Bleach.app
mkdir -p "$HOME/.local/bin"
if [[ ( -e "$HOME/.local/bin/bleach" || -L "$HOME/.local/bin/bleach" ) && $(readlink "$HOME/.local/bin/bleach" 2>/dev/null || true) != /Applications/Bleach.app/Contents/MacOS/bleach ]]; then
    BLEACH_CLI_BACKUP="$HOME/.local/bin/bleach.backup-$(date +%Y%m%d-%H%M%S)-$$"
    mv "$HOME/.local/bin/bleach" "$BLEACH_CLI_BACKUP"
    print "Previous CLI saved to $BLEACH_CLI_BACKUP"
fi
ln -sfn /Applications/Bleach.app/Contents/MacOS/bleach "$HOME/.local/bin/bleach"
codesign --verify --strict /Applications/Bleach.app
print 'Installed /Applications/Bleach.app and ~/.local/bin/bleach'
print 'Add ~/.local/bin to PATH if it is not already there.'
