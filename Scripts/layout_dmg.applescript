on run arguments
  if (count of arguments) is not 8 then
    error "layout_dmg.applescript 需要 8 个参数"
  end if

  set mountPath to item 1 of arguments
  set windowWidth to item 2 of arguments as integer
  set windowHeight to item 3 of arguments as integer
  set appX to item 4 of arguments as integer
  set appY to item 5 of arguments as integer
  set applicationsX to item 6 of arguments as integer
  set applicationsY to item 7 of arguments as integer
  set finderIconSize to item 8 of arguments as integer
  set mountAlias to POSIX file mountPath as alias

  tell application "Finder"
    set targetDisk to disk of mountAlias

    tell targetDisk
      open

      set diskWindow to container window
      set current view of diskWindow to icon view
      set toolbar visible of diskWindow to false
      set statusbar visible of diskWindow to false
      set pathbar visible of diskWindow to false
      set bounds of diskWindow to {200, 160, 200 + windowWidth, 160 + windowHeight}

      set iconOptions to icon view options of diskWindow
      set arrangement of iconOptions to not arranged
      set icon size of iconOptions to finderIconSize
      set text size of iconOptions to 12
      set label position of iconOptions to bottom
      set shows item info of iconOptions to false
      set shows icon preview of iconOptions to true
      set background picture of iconOptions to file ".background:background.png"

      set position of item "NeoShuttle.app" of diskWindow to {appX, appY}
      set position of item "Applications" of diskWindow to {applicationsX, applicationsY}
      set extension hidden of item "NeoShuttle.app" to true

      close diskWindow
      open
      update without registering applications
      delay 5
      close container window
      delay 1
    end tell
  end tell
end run
