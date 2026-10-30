#!/bin/sh
set -u

appdir=${1:-${APPDIR:-}}
appimage=${2:-${APPIMAGE:-}}
[ -n "$appdir" ] && [ -n "$appimage" ] || exit 0

# Only the AppDir root entry is used so this works the same in every flavor.
desktop_entry=$(find "$appdir" -maxdepth 1 -name '*.desktop' -print -quit)
[ -n "$desktop_entry" ] || exit 0
icon_name=$(sed -n 's/^Icon=//p' "$desktop_entry" | head -n 1)
wm_class=$(sed -n 's/^StartupWMClass=//p' "$desktop_entry" | head -n 1)
app_name=$(sed -n 's/^Name=//p' "$desktop_entry" | head -n 1)
[ -n "$icon_name" ] || exit 0
[ -n "$wm_class" ] || wm_class=$icon_name
[ -n "$app_name" ] || app_name=Saturn

# Do not create launcher entries for unexpected icon/class values.
case "$icon_name:$wm_class" in
  s.s.saturn:s.s.saturn|s.s.saturn.dev:s.s.saturn.dev|s.s.saturn.canary:s.s.saturn.canary) ;;
  *) exit 0 ;;
esac

user_data_home=${XDG_DATA_HOME:-${HOME:-}/.local/share}
[ -n "$user_data_home" ] || exit 0
applications_dir="$user_data_home/applications"
mkdir -p "$applications_dir" 2>/dev/null || exit 0

for icon_size in 16 24 32 48 64 128 256 512; do
  icon_source="$appdir/usr/share/icons/hicolor/${icon_size}x${icon_size}/apps/$icon_name.png"
  [ -f "$icon_source" ] || icon_source="$appdir/$icon_name.png"
  [ -f "$icon_source" ] || continue
  icon_dir="$user_data_home/icons/hicolor/${icon_size}x${icon_size}/apps"
  mkdir -p "$icon_dir" 2>/dev/null || continue
  icon_destination="$icon_dir/$icon_name.png"
  if ! cmp -s "$icon_source" "$icon_destination"; then
    cp "$icon_source" "$icon_destination" 2>/dev/null || continue
    chmod 644 "$icon_destination" 2>/dev/null || true
  fi
done

# Desktop Entry Exec paths are quoted and must escape backslashes, quotes,
# and literal percent signs. Keep the AppImage path current if it was moved.
exec_path=$(printf '%s' "$appimage" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g')
desktop_destination="$applications_dir/$icon_name.desktop"
temporary_desktop="$desktop_destination.tmp.$$"
{
  printf '[Desktop Entry]\n'
  printf 'Type=Application\n'
  printf 'Name=%s\n' "$app_name"
  printf 'Comment=%s music player\n' "$app_name"
  printf 'Exec="%s" %%U\n' "$exec_path"
  printf 'Icon=%s\n' "$icon_name"
  printf 'Terminal=false\n'
  printf 'StartupWMClass=%s\n' "$wm_class"
  printf 'Categories=AudioVideo;Audio;Player;\n'
  printf 'NoDisplay=true\n'
} > "$temporary_desktop" 2>/dev/null || exit 0
chmod 644 "$temporary_desktop" 2>/dev/null || true
if ! cmp -s "$temporary_desktop" "$desktop_destination"; then
  mv -f "$temporary_desktop" "$desktop_destination" 2>/dev/null || rm -f "$temporary_desktop"
else
  rm -f "$temporary_desktop"
fi
