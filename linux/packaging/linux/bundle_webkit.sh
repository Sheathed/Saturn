#!/bin/bash
set -euo pipefail

: "${BUILD_OUTPUT_DIRECTORY:?Fastforge did not provide BUILD_OUTPUT_DIRECTORY}"

bundle_dir=$(realpath "$BUILD_OUTPUT_DIRECTORY")
binary_name=Saturn
binary_path="$bundle_dir/$binary_name"
real_binary_path="$bundle_dir/$binary_name.bin"
if [ -x "$real_binary_path" ]; then
  binary_path="$real_binary_path"
elif [ ! -x "$binary_path" ]; then
  echo "Flutter Linux executable not found: $binary_path" >&2
  exit 1
fi

multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)
webkit_helper_dirs=(
  "/usr/lib/$multiarch/webkit2gtk-4.1"
  /usr/lib64/webkit2gtk-4.1
  /usr/lib/webkit2gtk-4.1
  /usr/libexec/webkit2gtk-4.1
)
webkit_helper_dir=""
for candidate in "${webkit_helper_dirs[@]}"; do
  if [ -x "$candidate/WebKitWebProcess" ] && [ -x "$candidate/WebKitNetworkProcess" ]; then
    webkit_helper_dir="$candidate"
    break
  fi
done
if [ -z "$webkit_helper_dir" ]; then
  echo "Could not locate WebKitGTK 4.1 helper processes" >&2
  exit 1
fi
if [ ! -f "$webkit_helper_dir/injected-bundle/libwebkit2gtkinjectedbundle.so" ]; then
  echo "Could not locate WebKitGTK injected bundle" >&2
  exit 1
fi

command -v linuxdeploy >/dev/null 2>&1 || {
  echo "linuxdeploy is required to bundle WebKitGTK dependencies" >&2
  exit 1
}
command -v linuxdeploy-plugin-gtk.sh >/dev/null 2>&1 || {
  echo "linuxdeploy-plugin-gtk.sh is required to bundle GTK runtime resources" >&2
  exit 1
}

temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT HUP INT TERM
appdir="$temp_dir/AppDir"
mkdir -p "$appdir/usr/bin" "$appdir${webkit_helper_dir%/*}/webkit2gtk-4.1/injected-bundle"
cp "$binary_path" "$appdir/usr/bin/$binary_name"
webkit_appdir_path="$appdir${webkit_helper_dir}"
mkdir -p "$webkit_appdir_path/injected-bundle"
cp -a "$webkit_helper_dir/WebKitWebProcess" "$webkit_helper_dir/WebKitNetworkProcess" "$webkit_appdir_path/"
if [ -f "$webkit_helper_dir/WebKitGPUProcess" ]; then
  cp -a "$webkit_helper_dir/WebKitGPUProcess" "$webkit_appdir_path/"
fi
cp -a "$webkit_helper_dir/injected-bundle/libwebkit2gtkinjectedbundle.so" \
  "$webkit_appdir_path/injected-bundle/"

deploy_args=(
  --appimage-extract-and-run
  --appdir "$appdir"
  --executable "$appdir/usr/bin/$binary_name"
  --executable "$webkit_appdir_path/WebKitWebProcess"
  --executable "$webkit_appdir_path/WebKitNetworkProcess"
  --library "$webkit_appdir_path/injected-bundle/libwebkit2gtkinjectedbundle.so"
  --plugin gtk
)
if [ -x "$webkit_appdir_path/WebKitGPUProcess" ]; then
  deploy_args+=(--executable "$webkit_appdir_path/WebKitGPUProcess")
fi
for plugin_library in "$bundle_dir"/lib/*.so; do
  [ -f "$plugin_library" ] || continue
  deploy_args+=(--library "$plugin_library")
done
LD_LIBRARY_PATH="$bundle_dir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  PATH="$(dirname "$(command -v linuxdeploy)"):$PATH" \
  DEPLOY_GTK_VERSION=3 APPIMAGE_EXTRACT_AND_RUN=1 linuxdeploy "${deploy_args[@]}"

mkdir -p "$bundle_dir/usr/lib" "$bundle_dir/usr/share" "$bundle_dir/apprun-hooks"
if [ -d "$appdir/usr/lib" ]; then
  cp -a "$appdir/usr/lib/." "$bundle_dir/usr/lib/"
fi
if [ -d "$appdir/usr/share" ]; then
  cp -a "$appdir/usr/share/." "$bundle_dir/usr/share/"
fi
if [ -d "$appdir/apprun-hooks" ]; then
  cp -a "$appdir/apprun-hooks/." "$bundle_dir/apprun-hooks/"
fi

# linuxdeploy-plugin-gtk forces GDK_BACKEND=x11 in its hook. Leave backend
# selection to GTK so Wayland sessions can use the native Wayland backend and
# do not require XWayland solely for this package.
gtk_hook="$bundle_dir/apprun-hooks/linuxdeploy-plugin-gtk.sh"
if [ -f "$gtk_hook" ]; then
  sed -i '/^[[:space:]]*export GDK_BACKEND=x11[[:space:]]*$/d' "$gtk_hook"
fi

# The ELF launcher stays next to Flutter's data directory. This wrapper sets
# the runtime library/resource paths and the working directory WebKitGTK uses
# to locate its subprocesses on AppImage, DEB, and RPM installs.
if [ "$binary_path" != "$real_binary_path" ]; then
  mv "$binary_path" "$real_binary_path"
fi
cat > "$binary_path" <<'EOF'
#!/bin/bash
set -euo pipefail
APPDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -d "$APPDIR/apprun-hooks" ]; then
  for hook in "$APPDIR"/apprun-hooks/*.sh; do
    [ -f "$hook" ] && . "$hook"
  done
fi
injected_bundle=$(find "$APPDIR/usr/lib" "$APPDIR/usr/lib64" "$APPDIR/usr/libexec" \
  -path '*/webkit2gtk-4.1/injected-bundle/libwebkit2gtkinjectedbundle.so' \
  -print -quit 2>/dev/null || true)
if [ -n "$injected_bundle" ]; then
  export WEBKIT_INJECTED_BUNDLE_PATH="$(dirname "$injected_bundle")"
fi
export LD_LIBRARY_PATH="$APPDIR/usr/lib:$APPDIR/usr/lib64:$APPDIR/lib:$APPDIR/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cd "$APPDIR/usr"
exec "$APPDIR/Saturn.bin" "$@"
EOF
chmod +x "$binary_path"
echo "Bundled WebKitGTK 4.1 runtime into $bundle_dir"
