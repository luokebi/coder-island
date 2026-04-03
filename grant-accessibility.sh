#!/bin/bash
# Grant accessibility permission to CoderIsland after rebuild
BUNDLE_ID="com.luokobe.CoderIsland"
APP_PATH="$1"

if [ -z "$APP_PATH" ]; then
    APP_PATH="$(find ~/Library/Developer/Xcode/DerivedData/CoderIsland-*/Build/Products/Debug/CoderIsland.app -maxdepth 0 2>/dev/null | head -1)"
fi

if [ -z "$APP_PATH" ]; then
    echo "CoderIsland.app not found"
    exit 1
fi

echo "Granting accessibility to: $APP_PATH"

# Use tccutil to reset, then use osascript to prompt
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null

# Open System Preferences to the right pane
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

echo "Please toggle CoderIsland in the Accessibility list."
echo "Tip: The app should appear automatically after first launch."
