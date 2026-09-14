#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
android_template_version="${GODOT_ANDROID_TEMPLATE_VERSION:-4.5.2}"
build_version_path="$project_root/android/.build_version"
installed_build_version=""
if [[ -f "$build_version_path" ]]; then
  installed_build_version="$(<"$build_version_path")"
fi

if [[ ! -f "$project_root/android/build/build.gradle" || "$installed_build_version" != "${android_template_version}.stable" ]]; then
  template="${GODOT_ANDROID_SOURCE:-$HOME/Library/Application Support/Godot/export_templates/${android_template_version}.stable/android_source.zip}"
  if [[ ! -f "$template" ]]; then
    template="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/${android_template_version}.stable/android_source.zip"
  fi
  [[ -f "$template" ]] || {
    echo "Install Godot ${android_template_version} Android export templates or set GODOT_ANDROID_SOURCE to android_source.zip" >&2
    exit 1
  }
  mkdir -p "$project_root/android/build"
  unzip -q -o "$template" -d "$project_root/android/build"
  printf '%s\n' "${android_template_version}.stable" > "$build_version_path"
fi

# Use the official Godot Android runtime that matches the exporter and is
# linked with 16 KB ELF alignment for Android packaging.
godot_android_version="${GODOT_ANDROID_RUNTIME_VERSION:-4.5.2}"
godot_android_url="${GODOT_ANDROID_RUNTIME_URL:-https://github.com/godotengine/godot/releases/download/${godot_android_version}-stable/godot-lib.${godot_android_version}.stable.template_release.aar}"
godot_android_aar="${GODOT_ANDROID_RUNTIME_AAR:-}"
godot_android_checksum="${GODOT_ANDROID_RUNTIME_SHA256:-}"
runtime_cache_dir="$project_root/android/build/.cache"
mkdir -p "$runtime_cache_dir"
runtime_source_is_cached=0

sha256_for() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "A SHA-256 tool (shasum or sha256sum) is required to verify the Godot Android runtime." >&2
    exit 1
  fi
}

if [[ -n "$godot_android_aar" ]]; then
  if [[ "$godot_android_aar" != /* ]]; then
    godot_android_aar="$project_root/$godot_android_aar"
  fi
  [[ -f "$godot_android_aar" ]] || {
    echo "GODOT_ANDROID_RUNTIME_AAR was not found: $godot_android_aar" >&2
    exit 1
  }
else
  if [[ "$godot_android_version" == "4.5.2" ]]; then
    godot_android_checksum="${godot_android_checksum:-e920f3b514907931621f3639b30069fd124ca008d68b366d43a36f41388be8c7}"
  fi
  godot_android_aar="$runtime_cache_dir/godot-lib.${godot_android_version}.stable.template_release.aar"
  runtime_source_is_cached=1

  if [[ -f "$godot_android_aar" ]]; then
    cached_checksum="$(sha256_for "$godot_android_aar")"
    if [[ "$cached_checksum" != "$godot_android_checksum" ]]; then
      echo "Cached Godot Android runtime checksum mismatch. Redownloading it." >&2
      rm -f "$godot_android_aar"
    fi
  fi

  if [[ ! -f "$godot_android_aar" ]]; then
    command -v curl >/dev/null 2>&1 || {
      echo "curl is required to download the Godot Android runtime." >&2
      exit 1
    }
    temporary_aar="$(mktemp "${TMPDIR:-/tmp}/faceoff-godot-runtime.XXXXXX")"
    trap 'rm -f "$temporary_aar"' EXIT
    echo "Downloading Godot ${godot_android_version} Android runtime..." >&2
    curl --fail --location --retry 3 --silent --show-error "$godot_android_url" -o "$temporary_aar"
    downloaded_checksum="$(sha256_for "$temporary_aar")"
    [[ "$downloaded_checksum" == "$godot_android_checksum" ]] || {
      echo "Godot Android runtime checksum mismatch." >&2
      echo "Expected: $godot_android_checksum" >&2
      echo "Actual:   $downloaded_checksum" >&2
      exit 1
    }
    mv "$temporary_aar" "$godot_android_aar"
    trap - EXIT
  fi
fi

if [[ -n "${GODOT_ANDROID_RUNTIME_SHA256:-}" ]]; then
  actual_checksum="$(sha256_for "$godot_android_aar")"
  [[ "$actual_checksum" == "$GODOT_ANDROID_RUNTIME_SHA256" ]] || {
    echo "Configured Godot Android runtime checksum mismatch." >&2
    exit 1
  }
fi

# Android exports in this project are arm64-only. Reuse a derived AAR with
# the other ABI folders removed when one has already been generated. This
# avoids expanding three unused native libraries during Gradle packaging while
# leaving the verified official AAR untouched as the source of truth.
if [[ "$runtime_source_is_cached" -eq 1 && "${FACEOFF_ANDROID_ABIS:-}" == "arm64-v8a" ]]; then
  arm64_runtime_cache="$runtime_cache_dir/godot-lib.${godot_android_version}.stable.template_release.arm64-v8a.aar"
  if [[ ! -f "$arm64_runtime_cache" || "$godot_android_aar" -nt "$arm64_runtime_cache" ]]; then
    if command -v zip >/dev/null 2>&1 && unzip -l "$godot_android_aar" 2>/dev/null | grep -E 'jni/(armeabi-v7a|x86|x86_64)/' >/dev/null; then
      arm64_runtime_temporary="$(mktemp "$runtime_cache_dir/.faceoff-arm64-runtime.XXXXXX")"
      trap 'find "$arm64_runtime_temporary" -depth -delete' EXIT
      cp "$godot_android_aar" "$arm64_runtime_temporary"
      zip -q -d "$arm64_runtime_temporary" 'jni/armeabi-v7a/*' 'jni/x86/*' 'jni/x86_64/*' >/dev/null 2>&1 || true
      mv "$arm64_runtime_temporary" "$arm64_runtime_cache"
      trap - EXIT
    fi
  fi
  if [[ -f "$arm64_runtime_cache" && "$arm64_runtime_cache" -nt "$godot_android_aar" ]]; then
    godot_android_aar="$arm64_runtime_cache"
  fi
fi

config_path="$project_root/android/build/config.gradle"
[[ -f "$config_path" ]] || { echo "Godot Android Gradle config not found: $config_path" >&2; exit 1; }

configured_compile_sdk="$(sed -n 's/^[[:space:]]*compileSdk[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$config_path" | sed -n '1p')"
configured_build_tools="$(sed -n "s/^[[:space:]]*buildTools[[:space:]]*:[[:space:]]*'\([^']*\)'.*/\1/p" "$config_path" | sed -n '1p')"
configured_ndk_version="$(sed -n "s/^[[:space:]]*ndkVersion[[:space:]]*:[[:space:]]*'\([^']*\)'.*/\1/p" "$config_path" | sed -n '1p')"
configured_compile_sdk="${configured_compile_sdk:-35}"
configured_build_tools="${configured_build_tools:-35.0.1}"
configured_ndk_version="${configured_ndk_version:-28.1.13356709}"

highest_platform_sdk() {
  local highest=""
  local platform_path
  local platform_name
  local platform_version
  for platform_path in "$sdk_root"/platforms/android-*; do
    platform_name="${platform_path##*/}"
    platform_version="${platform_name#android-}"
    if [[ "$platform_version" =~ ^[0-9]+$ ]] && { [[ -z "$highest" ]] || (( platform_version > highest )); }; then
      highest="$platform_version"
    fi
  done
  printf '%s' "$highest"
}

highest_build_tools() {
  local highest=""
  local build_tools_path
  for build_tools_path in "$sdk_root"/build-tools/*; do
    if [[ -x "$build_tools_path/aapt2" ]]; then
      highest="${build_tools_path##*/}"
    fi
  done
  printf '%s' "$highest"
}

highest_ndk_version() {
  local highest=""
  local ndk_path
  local readelf_path
  for ndk_path in "$sdk_root"/ndk/*; do
    for readelf_path in "$ndk_path"/toolchains/llvm/prebuilt/*/bin/llvm-readelf; do
      if [[ -x "$readelf_path" ]]; then
        highest="${ndk_path##*/}"
        break
      fi
    done
  done
  printf '%s' "$highest"
}

sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" && -d "$HOME/Library/Android/sdk" ]]; then
  sdk_root="$HOME/Library/Android/sdk"
fi

android_compile_sdk="${FACEOFF_ANDROID_COMPILE_SDK:-$configured_compile_sdk}"
android_target_sdk="${FACEOFF_ANDROID_TARGET_SDK:-$android_compile_sdk}"
android_build_tools="${FACEOFF_ANDROID_BUILD_TOOLS:-$configured_build_tools}"
android_ndk_version="${FACEOFF_ANDROID_NDK_VERSION:-$configured_ndk_version}"

if [[ -d "$sdk_root" ]]; then
  if [[ -z "${FACEOFF_ANDROID_COMPILE_SDK:-}" && ! -d "$sdk_root/platforms/android-$android_compile_sdk" ]]; then
    available_platform_sdk="$(highest_platform_sdk)"
    android_compile_sdk="${available_platform_sdk:-$android_compile_sdk}"
  fi
  if [[ -z "${FACEOFF_ANDROID_TARGET_SDK:-}" && ! -d "$sdk_root/platforms/android-$android_target_sdk" ]]; then
    android_target_sdk="$android_compile_sdk"
  fi
  if [[ -z "${FACEOFF_ANDROID_BUILD_TOOLS:-}" && ! -d "$sdk_root/build-tools/$android_build_tools" ]]; then
    available_build_tools="$(highest_build_tools)"
    android_build_tools="${available_build_tools:-$android_build_tools}"
  fi
  if [[ -z "${FACEOFF_ANDROID_NDK_VERSION:-}" && ! -d "$sdk_root/ndk/$android_ndk_version" ]]; then
    available_ndk_version="$(highest_ndk_version)"
    android_ndk_version="${available_ndk_version:-$android_ndk_version}"
  fi
fi

perl -0pi -e "s/(compileSdk\s*:\s*)[0-9]+/\${1}${android_compile_sdk}/; s/(targetSdk\s*:\s*)[0-9]+/\${1}${android_target_sdk}/; s/(buildTools\s*:\s*)'[^']+'/\${1}'${android_build_tools}'/; s/(ndkVersion\s*:\s*)'[^']+'/\${1}'${android_ndk_version}'/" "$config_path"

mkdir -p "$project_root/android/build/libs/debug" "$project_root/android/build/libs/release"

# The debug and release variants use the same verified runtime bytes. Keep
# one filesystem copy when possible so a low-disk developer machine does not
# fail while Gradle expands the native libraries. A custom runtime path may
# live on another volume, so fall back to a regular copy in that case.
link_or_copy_runtime() {
  local source="$1"
  local destination="$2"
  if [[ -e "$destination" || -L "$destination" ]]; then
    find "$destination" -depth -delete
  fi
  if ! ln "$source" "$destination" 2>/dev/null; then
    cp "$source" "$destination"
  fi
}

link_or_copy_runtime "$godot_android_aar" "$project_root/android/build/libs/debug/godot-lib.template_debug.aar"
link_or_copy_runtime "$godot_android_aar" "$project_root/android/build/libs/release/godot-lib.template_release.aar"

# The project manifest is also used as the Gradle main manifest. Resolve this
# placeholder here because the stock Gradle template does not define it for
# custom project manifests.
sed "s/\${godotEditorVersion}/${android_template_version}.stable/g" \
  "$project_root/platform/android/AndroidManifest.xml" > "$project_root/android/build/AndroidManifest.xml"
mkdir -p "$project_root/android/build/src/com/faceoff/android"
cp "$project_root/platform/android/src/com/faceoff/android/"*.java "$project_root/android/build/src/com/faceoff/android/"
mkdir -p "$project_root/android/build/src/com/godot/game"
cp "$project_root/platform/android/src/com/godot/game/GodotApp.java" "$project_root/android/build/src/com/godot/game/GodotApp.java"

mkdir -p "$project_root/android/build/res/xml"
cp "$project_root/platform/android/faceoff_invite_paths.xml" "$project_root/android/build/res/xml/"

for variant in debug release; do
  manifest="$project_root/android/build/src/$variant/AndroidManifest.xml"
  if [[ -f "$manifest" ]]; then
    "$project_root/tools/patch_android_invite_manifest.sh" "$variant"
  fi
done
