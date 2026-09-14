#!/usr/bin/env bash
set -euo pipefail

artifact_path="${1:-}"

usage() {
  cat <<'USAGE'
Usage: tools/verify_android_16kb.sh ARTIFACT

Checks that every native library in an APK or AAB has 16 KB ELF LOAD
alignment. APKs are also checked for 16 KB ZIP alignment.
USAGE
}

if [[ -z "$artifact_path" || "$artifact_path" == "-h" || "$artifact_path" == "--help" ]]; then
  usage
  exit 2
fi
[[ -f "$artifact_path" ]] || { echo "Android artifact not found: $artifact_path" >&2; exit 1; }

sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" && -d "$HOME/Library/Android/sdk" ]]; then
  sdk_root="$HOME/Library/Android/sdk"
fi
[[ -d "$sdk_root" ]] || { echo "Android SDK is required for the 16 KB verification." >&2; exit 1; }

readelf_bin=""
for ndk_dir in "$sdk_root"/ndk/*; do
  for toolchain_dir in "$ndk_dir"/toolchains/llvm/prebuilt/*; do
    candidate="$toolchain_dir/bin/llvm-readelf"
    if [[ -x "$candidate" ]]; then
      readelf_bin="$candidate"
    fi
  done
done
[[ -n "$readelf_bin" ]] || { echo "llvm-readelf was not found in the Android NDK." >&2; exit 1; }

case "$artifact_path" in
  *.apk)
    native_pattern='lib/*/*.so'
    ;;
  *.aab)
    native_pattern='base/lib/*/*.so'
    ;;
  *)
    echo "Expected an .apk or .aab artifact: $artifact_path" >&2
    exit 2
    ;;
esac

check_dir="$(mktemp -d "${TMPDIR:-/tmp}/faceoff-android-16kb-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
unzip -q "$artifact_path" "$native_pattern" -d "$check_dir"

native_count=0
while IFS= read -r library; do
  native_count=$((native_count + 1))
  alignment_list="$("$readelf_bin" -Wl "$library" | awk '$1 == "LOAD" { print $NF }')"
  [[ -n "$alignment_list" ]] || { echo "No ELF LOAD segments found in $library" >&2; exit 1; }
  while IFS= read -r alignment; do
    [[ -n "$alignment" ]] || continue
    alignment_value=$((16#${alignment#0x}))
    if (( alignment_value < 16384 )); then
      echo "ELF alignment failed for $library: $alignment" >&2
      exit 1
    fi
  done <<< "$alignment_list"
done < <(find "$check_dir" -type f -name '*.so' -print)

(( native_count > 0 )) || { echo "No native libraries found in $artifact_path" >&2; exit 1; }

if [[ "$artifact_path" == *.apk ]]; then
  zipalign_bin=""
  for build_tools_dir in "$sdk_root"/build-tools/*; do
    candidate="$build_tools_dir/zipalign"
    if [[ -x "$candidate" ]]; then
      zipalign_bin="$candidate"
    fi
  done
  [[ -n "$zipalign_bin" ]] || { echo "zipalign was not found in the Android SDK." >&2; exit 1; }
  "$zipalign_bin" -c -P 16 4 "$artifact_path" >/dev/null
fi

echo "Android 16 KB compatibility verified: $artifact_path"
