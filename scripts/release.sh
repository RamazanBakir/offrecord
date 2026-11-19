#!/bin/zsh
# Publishes a new Offrecord release:
#   1. moves the "## [Unreleased]" notes in CHANGELOG.md under the new version,
#   2. bumps the version and build number in Resources/Info.plist,
#   3. builds the app and zips it into dist/,
#   4. commits, tags vX.Y.Z, pushes and creates the GitHub release with the zip.
#
# Usage: ./scripts/release.sh 0.2.0 [--dry-run]
# Requires: a clean main branch, the GitHub CLI (gh) logged in.
# Signing: ad-hoc by default. Set OFFRECORD_RELEASE_IDENTITY to a code-signing identity
# (for example a Developer ID) to sign the downloadable app with it.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="RamazanBakir/offrecord"
die() { print -u2 "release: $1"; exit 1; }

VERSION="${1:-}"
DRY_RUN=false
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "usage: ./scripts/release.sh X.Y.Z [--dry-run]"

command -v gh >/dev/null || die "GitHub CLI (gh) is not installed"
[[ "$(git branch --show-current)" == "main" ]] || die "switch to the main branch first"
git diff --quiet && git diff --cached --quiet || die "commit or stash your changes first"
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && die "tag v$VERSION already exists"

CURRENT=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
[[ "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)" == "$VERSION" && "$CURRENT" != "$VERSION" ]] \
  || die "$VERSION is not newer than the current version $CURRENT"

# Release notes: everything between "## [Unreleased]" and the next "## [".
NOTES=$(awk '/^## \[Unreleased\]/{found=1; next} /^## \[/{if (found) exit} found' CHANGELOG.md | sed -e '/./,$!d')
[[ -n "${NOTES//[[:space:]]/}" ]] || die "add your changes under '## [Unreleased]' in CHANGELOG.md"

BUILD=$(( $(plutil -extract CFBundleVersion raw Resources/Info.plist) + 1 ))
DATE=$(date +%Y-%m-%d)
ZIP="dist/Offrecord-$VERSION.zip"

print "Releasing Offrecord $CURRENT → $VERSION (build $BUILD)"
$DRY_RUN && { print "\n--- release notes ---\n$NOTES"; print "\n(dry run: nothing changed)"; exit 0; }

# 1. Changelog and version.
perl -0pi -e "s/^## \\[Unreleased\\]\\n/## [Unreleased]\\n\\n## [$VERSION] - $DATE\\n/m" CHANGELOG.md
perl -0pi -e "s/^(\\[[0-9]+\\.[0-9]+\\.[0-9]+\\]: )/[$VERSION]: https:\\/\\/github.com\\/$REPO\\/releases\\/tag\\/v$VERSION\\n\$1/m" CHANGELOG.md
plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
plutil -replace CFBundleVersion -string "$BUILD" Resources/Info.plist

# 2. Build and package.
OFFRECORD_SIGN_IDENTITY="${OFFRECORD_RELEASE_IDENTITY:--}" ./scripts/build-app.sh
[[ "$(build/Offrecord.app/Contents/MacOS/Offrecord --version)" == "Offrecord $VERSION ($BUILD)" ]] || die "built app reports the wrong version"
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Offrecord.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)

# 3. Commit, tag, push.
git add CHANGELOG.md Resources/Info.plist
git commit -q -m "chore(release): v$VERSION"
git tag -a "v$VERSION" -m "Offrecord $VERSION"
git push -q origin main "v$VERSION"

# 4. GitHub release.
BODY=$(mktemp)
cat > "$BODY" <<EOF
$NOTES

## Install or update

**Download (quickest)**

1. Download **Offrecord-$VERSION.zip** below, unzip it and move **Offrecord** to your Applications folder (replace the old copy when updating).
2. Open it. Offrecord isn't notarized by Apple yet, so macOS blocks the first launch. Open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**.
3. After an update, macOS may ask for Microphone and Screen & System Audio Recording permission again.

**Build from source (keeps permissions across updates)**

\`\`\`sh
git pull && ./scripts/install.sh
\`\`\`

Requires macOS 26 or later on Apple silicon.

SHA-256 of \`Offrecord-$VERSION.zip\`: \`$SHA\`

Full changelog: [CHANGELOG.md](https://github.com/$REPO/blob/v$VERSION/CHANGELOG.md)
EOF
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "Offrecord $VERSION" --notes-file "$BODY" --latest
rm -f "$BODY"
print "Released https://github.com/$REPO/releases/tag/v$VERSION"
