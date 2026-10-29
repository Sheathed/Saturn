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

desktop_files=$(find "$appdir" -type f -name '*.desktop' -print)
if [ -z "$desktop_files" ]; then
  echo "No desktop entry found in AppImage: $appimage_file" >&2
  exit 1
fi
while IFS= read -r desktop_file; do
  if grep -q '^StartupWMClass=' "$desktop_file"; then
    sed -i "s/^StartupWMClass=.*/StartupWMClass=$STARTUP_WM_CLASS/" "$desktop_file"
  else
    sed -i "/^\[Desktop Entry\]/a StartupWMClass=$STARTUP_WM_CLASS" "$desktop_file"
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
