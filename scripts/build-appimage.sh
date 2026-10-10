#!/usr/bin/env bash
set -euo pipefail
# Wraps the self-contained build from build-linux.sh in a single-file AppImage.
rhi_repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$rhi_repo/scripts/linux-dependencies.env"
rhi_build="${1:-$rhi_repo/artifacts/linux-x64}"
rhi_output="$rhi_repo/artifacts/RHI-x86_64.AppImage"
if [[ ! -x "$rhi_build/RHI.Linux" ]]; then
    echo "No build at $rhi_build; run ./scripts/build-linux.sh first." >&2
    exit 1
fi
rhi_cache="$rhi_repo/artifacts/dependencies"
mkdir -p "$rhi_cache"
rhi_work="$(mktemp -d "$rhi_repo/artifacts/appimage.XXXXXX")"
trap 'rm -rf -- "$rhi_work"' EXIT
# Download into the cache once; refuse anything that does not match the pinned SHA-256.
rhi_fetch() {
    local url="$1" sha="$2" target="$3"
    if [[ -f "$target" ]] && printf '%s  %s\n' "$sha" "$target" | sha256sum --check --status; then return; fi
    curl --fail --location --silent --show-error --retry 3 "$url" -o "$rhi_work/download"
    if ! printf '%s  %s\n' "$sha" "$rhi_work/download" | sha256sum --check --status; then
        echo "$url does not match the pinned SHA-256; refusing to use it." >&2
        exit 1
    fi
    mv -- "$rhi_work/download" "$target"
}
rhi_tool="$rhi_cache/appimagetool-x86_64.AppImage"
rhi_runtime="$rhi_cache/appimage-runtime-x86_64"
rhi_fetch "$RHI_APPIMAGETOOL_URL" "$RHI_APPIMAGETOOL_SHA256" "$rhi_tool"
rhi_fetch "$RHI_APPIMAGE_RUNTIME_URL" "$RHI_APPIMAGE_RUNTIME_SHA256" "$rhi_runtime"
chmod +x "$rhi_tool"

rhi_appdir="$rhi_work/RHI.AppDir"
mkdir -p "$rhi_appdir/usr/lib/rhi"
cp -a "$rhi_build/." "$rhi_appdir/usr/lib/rhi/"
# The menu installer and launcher refer to the extracted folder; AppImage integration replaces them.
rm -f "$rhi_appdir/usr/lib/rhi/install.sh" "$rhi_appdir/usr/lib/rhi/run-linux.sh"
cat > "$rhi_appdir/AppRun" <<'EOF'
#!/bin/sh
here="${APPDIR:-$(dirname "$(readlink -f "$0")")}"
exec "$here/usr/lib/rhi/RHI.Linux" "$@"
EOF
chmod 755 "$rhi_appdir/AppRun"
printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=RHI (Linux / Proton)' \
    'Comment=Manage ReShade and RenoDX for Proton games' \
    'Exec=RHI.Linux' 'Icon=rhi-linux' 'Terminal=false' 'Categories=Game;' 'StartupWMClass=RHI.Linux' \
    > "$rhi_appdir/rhi-linux.desktop"
cp "$rhi_repo/RHI.Linux/Assets/rhi.png" "$rhi_appdir/rhi-linux.png"
ln -s rhi-linux.png "$rhi_appdir/.DirIcon"

rhi_version="$(git -C "$rhi_repo" describe --tags --always --dirty 2>/dev/null || echo unknown)"
# Extract-and-run avoids needing FUSE on build machines and in containers.
# Embedded update info lets AppImageUpdate and Gear Lever fetch only changed blocks via the .zsync file.
# CI defaults it to this repository's latest GitHub release; set RHI_APPIMAGE_UPDATE_INFO to override.
rhi_update_info="${RHI_APPIMAGE_UPDATE_INFO:-}"
if [[ -z "$rhi_update_info" && -n "${GITHUB_REPOSITORY:-}" ]]; then
    rhi_update_info="gh-releases-zsync|${GITHUB_REPOSITORY%%/*}|${GITHUB_REPOSITORY#*/}|latest|RHI-x86_64.AppImage.zsync"
fi
rhi_update_args=()
if [[ -n "$rhi_update_info" ]]; then rhi_update_args=(--updateinformation "$rhi_update_info"); fi
(cd "$rhi_work" && ARCH=x86_64 VERSION="$rhi_version" APPIMAGE_EXTRACT_AND_RUN=1 \
    "$rhi_tool" --no-appstream --runtime-file "$rhi_runtime" "${rhi_update_args[@]}" "$rhi_appdir" RHI-x86_64.AppImage)
mv -f -- "$rhi_work/RHI-x86_64.AppImage" "$rhi_output"
if [[ -f "$rhi_work/RHI-x86_64.AppImage.zsync" ]]; then
    mv -f -- "$rhi_work/RHI-x86_64.AppImage.zsync" "$rhi_output.zsync"
elif [[ -n "$rhi_update_info" ]]; then
    echo 'appimagetool did not create the .zsync file.' >&2
    exit 1
fi
(cd "$rhi_repo/artifacts" && sha256sum "$(basename -- "$rhi_output")" > "$(basename -- "$rhi_output").sha256")
echo "AppImage: $rhi_output"
