#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PBXPROJ="$SCRIPT_DIR/PocketMai.xcodeproj/project.pbxproj"

if [ ! -f "$PBXPROJ" ]; then
  printf '%s\n' "version.sh: missing project file: $PBXPROJ" >&2
  exit 1
fi

current_version=$(awk -F'= ' '
  /MARKETING_VERSION = / {
    gsub(/;[[:space:]]*$/, "", $2)
    print $2
    exit
  }
' "$PBXPROJ")

if [ "$#" -eq 0 ]; then
  printf '%s\n' "$current_version"
  exit 0
fi

new_version=$1

if ! printf '%s\n' "$new_version" | grep -Eq '^[0-9]+(\.[0-9]+){2}$'; then
  printf '%s\n' "version.sh: expected version in the form X.Y.Z, got: $new_version" >&2
  exit 1
fi

perl -0pi -e "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $new_version;/g" "$PBXPROJ"

current_build=$(awk -F'= ' '
  /CURRENT_PROJECT_VERSION = / {
    gsub(/;[[:space:]]*$/, "", $2)
    print $2
    exit
  }
' "$PBXPROJ")
new_build=$((current_build + 1))

perl -0pi -e "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $new_build;/g" "$PBXPROJ"

printf 'version: %s -> %s\n' "$current_version" "$new_version"
printf 'build:   %s -> %s\n' "$current_build" "$new_build"
