#!/usr/bin/env bash
# Sets the version everywhere it is written down, in one go.
#
# Five files have to agree: VERSION is what CI keys off, the spec and the
# Debian changelog are what the packages carry, _service names the git tag OBS
# downloads, and the PKGBUILD is what the AUR builds. A release where they
# disagree produces a package claiming one version and containing another, so
# .github/workflows/release.yml refuses to publish unless they match.
#
#   scripts/bump-version.sh 1.5.0
set -euo pipefail

VERSION="${1:-}"
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *)
    echo "usage: ${0##*/} X.Y.Z" >&2
    exit 2
    ;;
esac

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$REPO_DIR"

printf '%s\n' "$VERSION" >VERSION

sed -i -E "s/^(Version:[[:space:]]+).*/\1$VERSION/" packaging/obs/tpm-keyring-unlock.spec
sed -i -E "s|(archive/refs/tags/v)[0-9]+\.[0-9]+\.[0-9]+(\.tar\.gz)|\1$VERSION\2|" packaging/obs/_service
sed -i -E "s|(filename\">tpm-keyring-unlock-)[0-9]+\.[0-9]+\.[0-9]+(\.tar\.gz)|\1$VERSION\2|" packaging/obs/_service
sed -i -E "s/^(Version:[[:space:]]+)[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)/\1$VERSION\2/" packaging/obs/tpm-keyring-unlock.dsc
sed -i -E "s/(tpm-keyring-unlock-)[0-9]+\.[0-9]+\.[0-9]+(\.tar\.gz)/\1$VERSION\2/" packaging/obs/tpm-keyring-unlock.dsc
sed -i -E "s/^pkgver=.*/pkgver=$VERSION/" packaging/aur/PKGBUILD

# The AUR checksum can only be computed once the tag exists on GitHub, which
# is after this runs - so it goes back to a placeholder of 64 zeros, which
# fails a build loudly instead of letting an unverified download through.
# .github/workflows/release.yml replaces it with the real one and commits that
# back, within a minute of the tag being created. Nobody fills this in by
# hand: README points Arch users straight at this file while the AUR is closed,
# so a placeholder left sitting here would break that instruction for them.
sed -i -E "s/^sha256sums=\('[0-9a-f]{64}'\)/sha256sums=('$(printf '0%.0s' {1..64})')/" packaging/aur/PKGBUILD

# Debian wants newest-first, and dpkg-parsechangelog reads only the top entry.
TMP_CHANGELOG="$(mktemp)"
{
  printf 'tpm-keyring-unlock (%s-1) unstable; urgency=medium\n\n' "$VERSION"
  printf '  * Release %s. See JOURNAL.md for the full history.\n\n' "$VERSION"
  printf ' -- %s <%s>  %s\n\n' \
    "$(git config user.name)" "$(git config user.email)" "$(date -R)"
  cat packaging/obs/debian.changelog
} >"$TMP_CHANGELOG"
mv "$TMP_CHANGELOG" packaging/obs/debian.changelog

echo "Set $VERSION in:"
echo "  VERSION"
echo "  packaging/obs/tpm-keyring-unlock.spec"
echo "  packaging/obs/tpm-keyring-unlock.dsc"
echo "  packaging/obs/_service"
echo "  packaging/obs/debian.changelog"
echo "  packaging/aur/PKGBUILD  (checksum reset to the placeholder)"
echo
echo "Commit these, merge to main, and the release workflow tags and publishes."
