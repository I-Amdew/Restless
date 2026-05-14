#!/usr/bin/env bash
set -euo pipefail

USER_NAME="$(id -un)"
RULE="$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
ENCODED_RULE="$(printf "%s\n" "$RULE" | /usr/bin/base64)"
ADMIN_COMMAND="/bin/mkdir -p /etc/sudoers.d && /bin/echo '$ENCODED_RULE' | /usr/bin/base64 -D > /tmp/restless-pmset-sudoers && /usr/sbin/visudo -cf /tmp/restless-pmset-sudoers && /usr/bin/install -m 0440 /tmp/restless-pmset-sudoers /etc/sudoers.d/restless-pmset && /bin/rm -f /tmp/restless-pmset-sudoers"

/usr/bin/osascript -e "do shell script \"$ADMIN_COMMAND\" with administrator privileges"

echo "Installed passwordless Restless pmset toggle for $USER_NAME"
