on run argv
    set volumeName to item 1 of argv
    set appName to item 2 of argv
    set leftSlotCenter to {170, 160}
    set rightSlotCenter to {490, 160}

    tell application "Finder"
        tell disk volumeName
            open
            delay 1

            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set pathbar visible of container window to false
            -- Keep window height aligned with background rendering to avoid a blank strip at bottom.
            set bounds of container window to {120, 120, 780, 600}

            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 128
            set text size of viewOptions to 14
            set background picture of viewOptions to file ".background:background.png"

            set position of item appName of container window to leftSlotCenter
            set position of item "Applications" of container window to rightSlotCenter

            update without registering applications
            delay 2
            close
            open
            delay 1
        end tell
    end tell
end run
