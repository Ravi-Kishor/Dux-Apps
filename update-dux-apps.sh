
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Dux Apps Updater
# Arch Linux | x86-64-v3
# ============================================================

REPO="Ravi-Kishor/Dux-Apps"

STATE_DIR="/var/lib/dux-apps"
STATE_FILE="$STATE_DIR/installed-tag"

PACKAGES=(
  "dux-calendar-git"
  "dux-files-git"
  "dux-gop-git"
  "greetd-dms-greeter-git"
)

# ============================================================
# Helpers
# ============================================================

die() {
  echo "❌ $*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 ||
    die "Required command '$1' not found."
}

for CMD in \
  curl jq tar zstd sha256sum pacman install \
  mktemp grep awk sed tee
do
  require "$CMD"
done

# ============================================================
# Privilege escalation
# ============================================================

if command -v sudo >/dev/null 2>&1; then
  SUDO=(sudo)
elif command -v sudo-rs >/dev/null 2>&1; then
  SUDO=(sudo-rs)
else
  die "Neither sudo nor sudo-rs was found."
fi

# ============================================================
# Architecture validation
# ============================================================

[[ "$(uname -m)" == "x86_64" ]] ||
  die "Unsupported architecture: $(uname -m). Required: x86_64."

CPU_FLAGS="$(
  awk -F ': ' '/^flags[[:space:]]*:/ { print $2; exit }' /proc/cpuinfo
)"

for FLAG in avx avx2 bmi1 bmi2 f16c fma abm movbe; do
  grep -qw "$FLAG" <<<"$CPU_FLAGS" ||
    die "CPU/OS is missing required x86-64-v3 feature: $FLAG"
done

echo "✅ CPU supports x86-64-v3"

# ============================================================
# Installed release information
# ============================================================

INSTALLED_TAG="Not Installed"

if [[ -r "$STATE_FILE" ]]; then
  INSTALLED_TAG="$(<"$STATE_FILE")"
fi

echo
echo "Installed Dux Apps release: $INSTALLED_TAG"
echo "📡 Fetching latest release metadata..."

RELEASE_JSON="$(
  curl -fsSL \
    --retry 3 \
    --retry-delay 2 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$REPO/releases/latest"
)" || die "Could not retrieve GitHub release metadata."

TAG_NAME="$(
  jq -er '.tag_name | select(type == "string" and length > 0)' \
    <<<"$RELEASE_JSON"
)" || die "Latest release has no valid tag."

echo "Latest release: $TAG_NAME"

# ============================================================
# Locate package assets
# ============================================================

ASSET_NAMES=()

for PACKAGE in "${PACKAGES[@]}"; do
  mapfile -t MATCHES < <(
    jq -r --arg prefix "$PACKAGE-" '
      .assets[].name
      | select(
          startswith($prefix)
          and endswith("-x86_64_v3.pkg.tar.zst")
        )
    ' <<<"$RELEASE_JSON"
  )

  [[ "${#MATCHES[@]}" -eq 1 ]] ||
    die "Expected exactly one release asset for $PACKAGE."

  ASSET_NAMES+=("${MATCHES[0]}")
done

MANIFEST_COUNT="$(
  jq '[.assets[].name | select(. == "SHA256SUMS")] | length' \
    <<<"$RELEASE_JSON"
)"

[[ "$MANIFEST_COUNT" -eq 1 ]] ||
  die "Release must contain exactly one SHA256SUMS file."

# ============================================================
# Update selection
# ============================================================

echo
echo "Choose an action:"
echo "1) Update (skip if already installed)"
echo "2) Force install this release"

read -rp "Enter choice (1/2): " CHOICE

case "$CHOICE" in
  1)
    if [[ "$INSTALLED_TAG" == "$TAG_NAME" ]]; then
      echo "✅ Dux Apps are already up to date."
      exit 0
    fi

    PACMAN_FLAGS=(--needed)
    echo "⬆️ Updating: $INSTALLED_TAG → $TAG_NAME"
    ;;

  2)
    PACMAN_FLAGS=()
    echo "🛠️ Force installing release $TAG_NAME"
    ;;

  *)
    die "Invalid choice."
    ;;
esac

# ============================================================
# Temporary workspace
# ============================================================

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

DOWNLOAD_DIR="$TMP_DIR/downloads"
mkdir -p "$DOWNLOAD_DIR"

# ============================================================
# Download helper
# ============================================================

download_asset() {
  local asset="$1"
  local url

  url="$(
    jq -er --arg name "$asset" '
      .assets[]
      | select(.name == $name)
      | .browser_download_url
    ' <<<"$RELEASE_JSON"
  )" || die "Could not find download URL for $asset."

  echo "📥 Downloading $asset..."

  curl -fL \
    --retry 3 \
    --retry-delay 2 \
    "$url" \
    -o "$DOWNLOAD_DIR/$asset" ||
    die "Download failed: $asset"
}

# ============================================================
# Download assets
# ============================================================

download_asset "SHA256SUMS"

for ASSET in "${ASSET_NAMES[@]}"; do
  download_asset "$ASSET"
done

# ============================================================
# SHA256 verification
# ============================================================

echo
echo "🔐 Verifying SHA256 checksums..."

for ASSET in "${ASSET_NAMES[@]}"; do
  awk -v file="$ASSET" '
    {
      name = $2
      sub(/^\*/, "", name)
      if (name == file) found = 1
    }
    END { exit !found }
  ' "$DOWNLOAD_DIR/SHA256SUMS" ||
    die "SHA256SUMS is missing an entry for $ASSET."
done

(
  cd "$DOWNLOAD_DIR"
  sha256sum --check --strict SHA256SUMS
) || die "Checksum verification failed."

echo "✅ All checksums verified."

# ============================================================
# Package validation
# ============================================================

echo
echo "🔍 Validating Arch package archives..."

PACKAGE_PATHS=()

for INDEX in "${!PACKAGES[@]}"; do
  PACKAGE="${PACKAGES[$INDEX]}"
  ASSET="${ASSET_NAMES[$INDEX]}"
  FILE="$DOWNLOAD_DIR/$ASSET"

  echo
  echo "Checking: $PACKAGE"

  # Validate Zstandard compression.
  zstd -t "$FILE" >/dev/null ||
    die "Invalid Zstandard archive: $ASSET"

  # Validate tar archive.
  tar --zstd -tf "$FILE" >/dev/null ||
    die "Invalid tar archive: $ASSET"

  # Extract .PKGINFO directly.
  # Avoid tar-listing pipelines with grep under pipefail.
  PKGINFO="$(
    tar --zstd -xOf "$FILE" .PKGINFO 2>/dev/null ||
    tar --zstd -xOf "$FILE" ./.PKGINFO 2>/dev/null ||
    true
  )"

  [[ -n "$PKGINFO" ]] ||
    die "Could not extract .PKGINFO from $ASSET."

  # Validate internal package name.
  INTERNAL_NAME="$(
    awk -F ' = ' '$1 == "pkgname" { print $2; exit }' \
      <<<"$PKGINFO"
  )"

  [[ "$INTERNAL_NAME" == "$PACKAGE" ]] ||
    die "Package name mismatch in $ASSET (found: ${INTERNAL_NAME:-unknown})."

  # Validate architecture.
  INTERNAL_ARCH="$(
    awk -F ' = ' '$1 == "arch" { print $2; exit }' \
      <<<"$PKGINFO"
  )"

  [[ "$INTERNAL_ARCH" == "x86_64" ]] ||
    die "Invalid architecture in $ASSET: ${INTERNAL_ARCH:-unknown}."

  # Validate version.
  INTERNAL_VERSION="$(
    awk -F ' = ' '$1 == "pkgver" { print $2; exit }' \
      <<<"$PKGINFO"
  )"

  [[ -n "$INTERNAL_VERSION" ]] ||
    die "Missing package version in $ASSET."

  echo "✅ Package: $INTERNAL_NAME"
  echo "   Version: $INTERNAL_VERSION"
  echo "   Arch:    $INTERNAL_ARCH"

  PACKAGE_PATHS+=("$FILE")
done

# ============================================================
# Install packages
# ============================================================

echo
echo "📦 Installing all Dux Apps packages..."
echo

"${SUDO[@]}" pacman -U \
  "${PACMAN_FLAGS[@]}" \
  --noconfirm \
  "${PACKAGE_PATHS[@]}" ||
  die "Pacman installation failed. Installed release tag was not changed."

# ============================================================
# Save release state only after successful installation
# ============================================================

"${SUDO[@]}" install -d "$STATE_DIR"

printf '%s\n' "$TAG_NAME" |
  "${SUDO[@]}" tee "$STATE_FILE" >/dev/null

# ============================================================
# Final verification
# ============================================================

echo
echo "🔎 Verifying installed packages..."

"${SUDO[@]}" pacman -Q "${PACKAGES[@]}" ||
  die "Could not verify all installed packages."

echo
echo "============================================================"
echo "✅ Dux Apps installation completed successfully!"
echo "============================================================"
echo
echo "Release: $TAG_NAME"
echo
echo "Installed packages:"
printf '  - %s\n' "${PACKAGES[@]}"

echo
echo "Remove all four packages with:"
echo "  sudo pacman -Rns ${PACKAGES[*]}"
echo
