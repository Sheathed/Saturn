#!/bin/sh
set -eu

: "${OUTPUT_DIRECTORY:?Fastforge did not provide OUTPUT_DIRECTORY}"
: "${STARTUP_WM_CLASS:?The AppImage job must specify STARTUP_WM_CLASS}"

project_root=$(pwd)
appimage_file=$(find "$OUTPUT_DIRECTORY" -maxdepth 3 -type f -name '*.AppImage' -printf '%T@ %p\n' \
  | sort -nr | sed -n '1s/^[^ ]* //p')
if [ -z "$appimage_file" ]; then
  echo "No AppImage found under $OUTPUT_DIRECTORY" >&2
  exit 1
fi
appimage_file=$(realpath "$appimage_file")
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT HUP INT TERM

(
  cd "$temp_dir"
  APPIMAGE_EXTRACT_AND_RUN=1 "$appimage_file" --appimage-extract >/dev/null
)
appdir="$temp_dir/squashfs-root"
if [ ! -d "$appdir" ]; then
  echo "AppImage extraction failed: $appimage_file" >&2
  exit 1
fi

case "$STARTUP_WM_CLASS" in
  s.s.saturn)
    display_name="Saturn"
    icon_source="$project_root/assets/icon.png"
    ;;
  s.s.saturn.canary)
    display_name="Saturn Canary"
    icon_source="$project_root/assets/icon-canary.png"
    ;;
  s.s.saturn.dev)
    display_name="Saturn Dev"
    icon_source="$project_root/assets/icon-dev.png"
    ;;
  *) echo "Unknown Saturn app ID: $STARTUP_WM_CLASS" >&2; exit 1 ;;
esac
if [ ! -f "$icon_source" ]; then
  echo "Flavor icon not found: $icon_source" >&2
  exit 1
fi

# AppImage preview/launcher icons are read from the AppDir root. Keep the
# dimensions at a standard hicolor size so desktop icon themes can resolve it.
if ! command -v convert >/dev/null 2>&1; then
  echo "ImageMagick is required to normalize the AppImage icon" >&2
  exit 1
fi
convert "$icon_source" -resize 512x512 "$appdir/$STARTUP_WM_CLASS.png"
find "$appdir" -maxdepth 1 -type f -name '*.png' ! -name "$STARTUP_WM_CLASS.png" -delete
rm -f "$appdir/.DirIcon"
ln -s "$STARTUP_WM_CLASS.png" "$appdir/.DirIcon"

desktop_files=$(find "$appdir" -type f -name '*.desktop' -print)
if [ -z "$desktop_files" ]; then
  echo "No desktop entry found in AppImage: $appimage_file" >&2
  exit 1
fi
while IFS= read -r desktop_file; do
  # Match the name, desktop-entry ID, icon name, and WM class to this flavor.
  if grep -q '^Name=' "$desktop_file"; then
    sed -i "s|^Name=.*|Name=$display_name|" "$desktop_file"
  else
    sed -i "/^\[Desktop Entry\]/a Name=$display_name" "$desktop_file"
  fi
  if grep -q '^Comment=' "$desktop_file"; then
    sed -i "s|^Comment=.*|Comment=$display_name music player|" "$desktop_file"
  fi
  sed -i 's|^Exec=.*|Exec=AppRun %u|' "$desktop_file"
  if grep -q '^Icon=' "$desktop_file"; then
    sed -i "s|^Icon=.*|Icon=$STARTUP_WM_CLASS|" "$desktop_file"
  else
    sed -i "/^\[Desktop Entry\]/a Icon=$STARTUP_WM_CLASS" "$desktop_file"
  fi
  if grep -q '^StartupWMClass=' "$desktop_file"; then
    sed -i "s/^StartupWMClass=.*/StartupWMClass=$STARTUP_WM_CLASS/" "$desktop_file"
  else
    sed -i "/^\[Desktop Entry\]/a StartupWMClass=$STARTUP_WM_CLASS" "$desktop_file"
  fi
  desktop_dir=$(dirname "$desktop_file")
  app_id_desktop="$desktop_dir/$STARTUP_WM_CLASS.desktop"
  if [ "$desktop_file" != "$app_id_desktop" ]; then
    mv "$desktop_file" "$app_id_desktop"
  fi
done <<EOF
$desktop_files
EOF

if [ ! -f "$project_root/linux/packaging/appimage/AppRun" ]; then
  echo "Custom AppRun not found in $project_root" >&2
  exit 1
fi
cp "$project_root/linux/packaging/appimage/AppRun" "$appdir/AppRun"
chmod +x "$appdir/AppRun"
appimagetool -n "$appdir" "$appimage_file"
echo "Patched $appimage_file with StartupWMClass=$STARTUP_WM_CLASS and the custom AppRun"
