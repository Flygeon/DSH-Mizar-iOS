#!/usr/bin/env bash
#
# The CI's hands. Everything .github/workflows/ios.yml does with Xcode lives
# here, so the same commands can be run on a laptop when a green run has to be
# explained.
#
# Usage:
#   scripts/ci.sh xcode [version]   select an Xcode (no argument: the image default)
#   scripts/ci.sh protocol          MizarKit's tests, on the Mac, no simulator
#   scripts/ci.sh app               compile the app for the simulator
#   scripts/ci.sh sign              import APPLE_CERTIFICATE_P12 into a throwaway keychain
#   scripts/ci.sh ipa               archive, then a signed .ipa or an unsigned one
#
# Signing is optional and is decided by the environment, not by a flag. All six
# of these turn it on:
#
#   APPLE_CERTIFICATE_P12       base64 of a .p12 holding the distribution identity
#   APPLE_CERTIFICATE_PASSWORD  its password
#   APPLE_TEAM_ID               the team the profile belongs to
#   APPSTORE_API_KEY_ID         App Store Connect API key id
#   APPSTORE_API_ISSUER_ID      its issuer id
#   APPSTORE_API_PRIVATE_KEY    the .p8 contents
#
# Without them the .ipa is still the real Release build, but unsigned: iOS
# refuses to install it until it is signed with a certificate that belongs to
# whoever installs it. That is not a degraded build, it is an unsigned one, and
# the summary says which it is.
#
# Output: release/ci/DSH-Mizar-<version>.ipa (+ .dSYMs.zip, summary.md)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/DSH-Mizar.xcodeproj"
SCHEME="DSH-Mizar"
CACHE="$ROOT/.devcache/ci"
OUT="$ROOT/release/ci"
ARCHIVE="$CACHE/DSH-Mizar.xcarchive"
EXPORT_DIR="$CACHE/export"
SUMMARY="$OUT/summary.md"

export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

die() { printf 'ci: %s\n' "$1" >&2; exit 1; }

signed() {
  [ -n "${APPLE_CERTIFICATE_P12:-}" ] &&
  [ -n "${APPLE_CERTIFICATE_PASSWORD:-}" ] &&
  [ -n "${APPLE_TEAM_ID:-}" ] &&
  [ -n "${APPSTORE_API_KEY_ID:-}" ] &&
  [ -n "${APPSTORE_API_ISSUER_ID:-}" ] &&
  [ -n "${APPSTORE_API_PRIVATE_KEY:-}" ]
}

# xcodebuild's arguments for automatic signing, plus the API key it needs to
# fetch a profile.
AUTH_ARGS=()
prepare_auth() {
  signed || return 0
  local dir="$HOME/.appstoreconnect/private_keys"
  local key="$dir/AuthKey_${APPSTORE_API_KEY_ID}.p8"
  mkdir -p "$dir"
  printf '%s\n' "$APPSTORE_API_PRIVATE_KEY" > "$key"
  chmod 600 "$key"
  AUTH_ARGS=(
    -allowProvisioningUpdates
    -allowProvisioningDeviceRegistration
    -authenticationKeyPath "$key"
    -authenticationKeyID "$APPSTORE_API_KEY_ID"
    -authenticationKeyIssuerID "$APPSTORE_API_ISSUER_ID"
  )
}

# Per-run settings for the archive: the team on a signed run, and "do not sign
# at all" on an unsigned one. Written as the bash-3.2-safe form of "expand an
# array that may be empty": the Mac's bash treats a bare "${ARRAY[@]}" of an
# empty array as an unbound variable under set -u, and this repository's
# scripts run on that bash.
EXTRA_ARGS=()

run_xcodebuild() {
  xcodebuild "$@" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}
}

# --- select -----------------------------------------------------------------

select_xcode() {
  local wanted="${1:-}"
  if [ -z "$wanted" ]; then
    xcodebuild -version
    return
  fi
  # "26.6" and "26.6.0" both have to find /Applications/Xcode_26.6.app, and a
  # bare "26" has to find it too -- the runner names the app by the version
  # xcodebuild prints, which is not always the string a workflow was written
  # with.
  local candidate
  for candidate in \
    "/Applications/Xcode_${wanted}.app" \
    "/Applications/Xcode_${wanted%.*}.app" \
    "/Applications/Xcode_${wanted}.0.app" \
    "/Applications/Xcode_${wanted}_beta.app"; do
    if [ -d "$candidate" ]; then
      sudo xcode-select -s "$candidate/Contents/Developer"
      xcodebuild -version
      return
    fi
  done
  echo "no Xcode named '$wanted' on this runner; installed:" >&2
  ls -d /Applications/Xcode*.app >&2
  exit 1
}

# --- tests and compile-only builds ------------------------------------------

protocol_tests() {
  cd "$ROOT/MizarKit"
  # No simulator and no app: the protocol layer is a plain Swift package, which
  # is what makes it the fast check. The fixtures are read from
  # protocol/fixtures through #filePath, so the checkout has to be the one
  # being tested -- a copy elsewhere would test a different tree.
  swift test
}

simulator_build() {
  # Compiling is the check here, not running: the UI suite has its own job, and
  # a Debug build is what would break first if the app stopped compiling.
  #
  # The optional first argument is a deployment target, and it is the whole
  # point of the second use of this function: overriding IPHONEOS_DEPLOYMENT_TARGET
  # to 18.0 turns every iOS 26-only API into a compile error, which is how the
  # app stopped being installable on iOS 18 without anybody noticing.
  local target="${1:-}"
  local override=()
  if [ -n "$target" ]; then
    override=(IPHONEOS_DEPLOYMENT_TARGET="$target")
  fi
  echo "ci: building for the simulator${target:+ at iOS $target}"
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$CACHE/DerivedData" \
    ${override[@]+"${override[@]}"} \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO
}

# --- signing -----------------------------------------------------------------

import_identity() {
  signed || die 'sign needs all six signing variables'
  local keychain="${KEYCHAIN_PATH:-$RUNNER_TEMP/app-signing.keychain-db}"
  local password
  password="$(uuidgen)"
  local cert="$RUNNER_TEMP/certificate.p12"

  printf '%s' "$APPLE_CERTIFICATE_P12" > "$RUNNER_TEMP/certificate.p12.base64"
  openssl base64 -d -in "$RUNNER_TEMP/certificate.p12.base64" -out "$cert"
  rm -f "$RUNNER_TEMP/certificate.p12.base64"

  # A keychain of its own, put in front of the login keychain rather than
  # replacing it: codesign searches the list, and the runner's own state is
  # none of this job's business.
  security create-keychain -p "$password" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security unlock-keychain -p "$password" "$keychain"
  security import "$cert" -k "$keychain" -P "$APPLE_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$password" "$keychain" > /dev/null
  security list-keychain -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
  rm -f "$cert"

  report_profiles
  security find-identity -v -p codesigning
}

# Says whether a profile for this bundle id is already installed. xcodebuild can
# fetch one with the API key, but when it cannot, "no profile for team" arrives
# on its own and it is worth knowing that before the archive starts.
report_profiles() {
  local profile
  local id="${BUNDLE_ID:-me.shirazu.dshmizar}"
  for profile in "$HOME/Library/MobileDevice/Provisioning Profiles/"*.mobileprovision; do
    [ -e "$profile" ] || continue
    if security cms -D -i "$profile" 2>/dev/null | grep -q "$id"; then
      echo "ci: a profile for $id is installed"
      return 0
    fi
  done
  echo "ci: no profile installed for $id — xcodebuild will ask the API key for one"
}

# --- the package -------------------------------------------------------------

marketing_version() {
  grep -m1 'MARKETING_VERSION' "$PROJECT/project.pbxproj" | sed 's/.*= //; s/;.*//'
}

# A fork cannot be signed against me.shirazu.dshmizar: that App ID belongs to a
# team it does not have. Rewriting the checkout, and only the checkout, is what
# lets the same workflow sign a fork's build without editing the project in the
# repository. The suffix keeps the Live Activity extension's id in the app's
# prefix, which is what an embedded extension requires.
apply_bundle_id() {
  local id="${BUNDLE_ID:-}"
  [ -n "$id" ] || return 0
  # A bundle id is letters, digits, dots and hyphens. Anything else is either a
  # typo or an attempt to write into the sed expression below, and both are
  # refused here rather than discovered by a half-rewritten project file.
  case "$id" in
    *[!A-Za-z0-9.-]*|.*|*.)
      die "BUNDLE_ID is not a bundle id: $id" ;;
  esac
  echo "ci: bundle id overridden to $id"
  local rewritten="$PROJECT/project.pbxproj.ci"
  sed -E "s/(PRODUCT_BUNDLE_IDENTIFIER = )(me[.]shirazu[.]dshmizar)([.][A-Za-z]+)?;/\\1$id\\3;/g" \
    "$PROJECT/project.pbxproj" > "$rewritten"
  mv "$rewritten" "$PROJECT/project.pbxproj"
  grep -m2 "PRODUCT_BUNDLE_IDENTIFIER" "$PROJECT/project.pbxproj"
}

archive_app() {
  mkdir -p "$CACHE" "$OUT"
  rm -rf "$ARCHIVE" "$EXPORT_DIR"
  apply_bundle_id
  prepare_auth

  # An unsigned archive is still built: it carries the app and the dSYMs, and it
  # is what the unsigned packaging below starts from. Signing is switched off
  # for the whole archive rather than per target, because a half-signed bundle
  # is a worse thing to ship than an unsigned one.
  EXTRA_ARGS=()
  if signed; then
    # The team is settable because the checked-in project names one; a fork
    # signing as somebody else overrides it instead of editing the project.
    EXTRA_ARGS=(DEVELOPMENT_TEAM="$APPLE_TEAM_ID")
  else
    EXTRA_ARGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
  fi

  local build_number="${BUILD_NUMBER:-$(date -u +%Y%m%d.%H%M)}"
  echo "ci: archiving $SCHEME, build $build_number"
  run_xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$CACHE/DerivedData" \
    CURRENT_PROJECT_VERSION="$build_number"
  [ -d "$ARCHIVE" ] || die 'the archive was not produced'
}

write_export_options() {
  local destination="$1" method="$2"
  local plist="$CACHE/ExportOptions.plist"
  mkdir -p "$CACHE"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key>
	<string>${destination}</string>
	<key>method</key>
	<string>${method}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>${APPLE_TEAM_ID}</string>
	<key>stripSwiftSymbols</key>
	<true/>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST
  printf '%s' "$plist"
}

# An unsigned archive still holds a .app, and a Payload zip of that .app is
# exactly what an .ipa is. It is not installable until it is signed -- with
# Xcode, with Sideloadly, or by re-running this workflow with the secrets set --
# but it is the build this repository produces, and calling it anything else
# would be a lie.
unsigned_ipa() {
  local version="$1" app="$ARCHIVE/Products/Applications/$SCHEME.app"
  [ -d "$app" ] || die "the archive has no app at $app"
  local staging="$CACHE/unsigned"
  rm -rf "$staging"
  mkdir -p "$staging/Payload"
  cp -R "$app" "$staging/Payload/"
  local out="$OUT/DSH-Mizar-$version.ipa"
  rm -f "$out"
  ( cd "$staging" && zip -qry "$out" Payload )
  printf '%s' "$out"
}

package() {
  local version build_number
  version="$(marketing_version)"
  build_number="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$ARCHIVE/Info.plist" 2>/dev/null || echo unknown)"
  mkdir -p "$OUT"

  local method="${EXPORT_METHOD:-app-store-connect}"
  local destination="export"
  if [ "${UPLOAD:-0}" = "1" ]; then destination="upload"; fi
  # Only app-store-connect can upload. Asking for anything else with the upload
  # switch on is a typo, not a request, and failing after the archive has been
  # built would have wasted the whole job.
  if [ "$destination" = "upload" ] && [ "$method" != "app-store-connect" ]; then
    echo "ci: upload implies app-store-connect; ignoring '$method'"
    method="app-store-connect"
  fi

  local status detail ipa=""
  if signed; then
    prepare_auth
    local plist
    plist="$(write_export_options "$destination" "$method")"
    rm -rf "$EXPORT_DIR"
    # Not run_xcodebuild: -exportArchive takes no build settings, so the team
    # and the unsigned switch belong to the archive only. The API key does
    # still belong here, because the export may need to fetch a profile.
    xcodebuild -exportArchive \
      -archivePath "$ARCHIVE" \
      -exportPath "$EXPORT_DIR" \
      -exportOptionsPlist "$plist" \
      ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}
    status="signed"
    if [ "$destination" = "upload" ]; then
      detail="uploaded to App Store Connect — the build appears in TestFlight once Apple has processed it"
    else
      detail="signed with the team's distribution identity, method '$method'"
      [ -f "$EXPORT_DIR/$SCHEME.ipa" ] || die 'export produced no .ipa'
      ipa="$OUT/DSH-Mizar-$version.ipa"
      cp "$EXPORT_DIR/$SCHEME.ipa" "$ipa"
    fi
  else
    ipa="$(unsigned_ipa "$version")"
    status="unsigned"
    detail="not signed — install it only after signing it with a certificate and profile that belong to you"
  fi

  # What the phone will read, not what the project file said. Printing it is the
  # cheap check that the archive really is installable on the oldest supported
  # iOS: the deployment target has been wrong once, and a build that installs and
  # then exits is the most expensive way to find that out.
  local app="$ARCHIVE/Products/Applications/$SCHEME.app"
  local minimum_os="unknown"
  if [ -f "$app/Info.plist" ]; then
    minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$app/Info.plist" 2>/dev/null || echo unknown)"
  fi
  echo "ci: MinimumOSVersion $minimum_os"

  # A .dSYM is a directory; an artifact is a file.
  local dsyms="$OUT/DSH-Mizar-$version.dSYMs.zip"
  rm -f "$dsyms"
  if [ -d "$ARCHIVE/dSYMs" ]; then
    ( cd "$ARCHIVE" && zip -qry "$dsyms" dSYMs )
  fi

  {
    echo "## DSH-Mizar $version ($build_number)"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Version | '$version' |"
    echo "| Build | '$build_number' |"
    echo "| Signing | **$status** |"
    echo "| Export | '$method' |"
    echo "| Minimum iOS | '$minimum_os' |"
    if [ -n "$ipa" ] && [ -f "$ipa" ]; then
      echo "| Package | '$(basename "$ipa")' ($(du -h "$ipa" | cut -f1)) |"
      echo "| SHA-256 | '$(shasum -a 256 "$ipa" | cut -d' ' -f1)' |"
    fi
    echo
    echo "$detail."
  } > "$SUMMARY"

  cat "$SUMMARY"
}

# --- entry -------------------------------------------------------------------

case "${1:-}" in
  xcode)    select_xcode "${2:-}" ;;
  protocol) protocol_tests ;;
  app)      simulator_build "${2:-}" ;;
  sign)     import_identity ;;
  ipa)
    archive_app
    package
    ;;
  *)
    die 'usage: scripts/ci.sh xcode [version]|protocol|app|sign|ipa'
    ;;
esac
