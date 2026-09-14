#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot_bin="${GODOT_BIN:-godot}"
output_dir="${FACE_OFF_IOS_EXPORT_DIR:-${project_root}/exports/ios}"
build_simulator=0
clean_output=0

usage() {
	cat <<'USAGE'
Usage: tools/export_ios.sh [--clean] [--build-simulator] [--output-dir PATH]

Exports a Godot iOS Xcode project. The iOS Project preset uses the Apple Team
ID configured in export_presets.cfg and deliberately exports project files so
Xcode can apply the local signing profile. Pass --build-simulator to ask
xcodebuild for an unsigned simulator build. Pass --clean to replace a previous
generated export in the selected output directory.
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--build-simulator)
			build_simulator=1
			shift
			;;
		--clean)
			clean_output=1
			shift
			;;
		--output-dir)
			[[ $# -ge 2 ]] || { echo "--output-dir requires a value" >&2; exit 2; }
			output_dir="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown argument: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

if [[ "$output_dir" != /* ]]; then
	output_dir="${project_root}/${output_dir}"
fi
project_path="${output_dir}/Faceoff.xcodeproj"
if [[ -e "$project_path" ]]; then
	if [[ "$clean_output" -eq 1 ]]; then
		rm -rf "$output_dir"
	else
		echo "Export destination already contains ${project_path}. Pass --clean, choose another --output-dir, or move the old export aside." >&2
		exit 1
	fi
fi

team_id="$(sed -n 's/^application\/app_store_team_id="\([^"]*\)"/\1/p' "${project_root}/export_presets.cfg" | head -n 1)"
if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
	echo "The iOS preset needs a 10-character Apple Team ID in export_presets.cfg." >&2
	exit 1
fi

mkdir -p "$output_dir"
cd "$project_root"
"$godot_bin" --headless --path . --export-debug "iOS Project" "${output_dir}/Faceoff"

if [[ "$build_simulator" -eq 1 ]]; then
	if ! command -v xcodebuild >/dev/null 2>&1; then
		echo "xcodebuild is required for --build-simulator." >&2
		exit 1
	fi
	xcodebuild \
		-project "$project_path" \
		-scheme Faceoff \
		-sdk iphonesimulator \
		-configuration Debug \
		-derivedDataPath "${output_dir}/DerivedData" \
		-destination 'generic/platform=iOS Simulator' \
		CODE_SIGNING_ALLOWED=NO \
		build
fi

echo "iOS Xcode project: ${project_path}"
