#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
variant="${1:-}"
if [[ "$variant" != "debug" && "$variant" != "release" ]]; then
    echo "Usage: tools/patch_android_invite_manifest.sh debug|release" >&2
    exit 2
fi

manifest="$project_root/android/build/src/$variant/AndroidManifest.xml"
if [[ ! -f "$manifest" ]]; then
    echo "Generated Android $variant manifest not found: $manifest" >&2
    exit 1
fi

if grep -Fq 'android:scheme="faceoff" android:host="invite"' "$manifest"; then
    exit 0
fi

temporary="$(mktemp "${TMPDIR:-/tmp}/faceoff-android-manifest.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
awk '
    /<\/activity>/ && !inserted {
        print "            <intent-filter>"
        print "                <action android:name=\"android.intent.action.VIEW\" />"
        print "                <category android:name=\"android.intent.category.DEFAULT\" />"
        print "                <category android:name=\"android.intent.category.BROWSABLE\" />"
        print "                <data android:scheme=\"faceoff\" android:host=\"invite\" />"
        print "            </intent-filter>"
        inserted = 1
    }
    { print }
    END {
        if (!inserted) exit 1
    }
' "$manifest" > "$temporary"
mv "$temporary" "$manifest"
trap - EXIT
