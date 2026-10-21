#!/bin/zsh
set -euo pipefail
TUCK_ROOT="${0:A:h:h}"
"$TUCK_ROOT/scripts/build.sh"
if pgrep -x Tuck >/dev/null; then
    print -u2 'Quit Tuck before installing an update. This restores your icons.'
    exit 1
fi
if [[ -d /Applications/Tuck.app ]]; then
    TUCK_BACKUP="$HOME/Library/Application Support/Tuck/Backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$TUCK_BACKUP"
    ditto /Applications/Tuck.app "$TUCK_BACKUP/Tuck.app"
fi
ditto "$TUCK_ROOT/build/Tuck.app" /Applications/Tuck.app
print 'Installed /Applications/Tuck.app'
