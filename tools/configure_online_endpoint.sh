#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_file="${project_root}/project.godot"
endpoint=""
server_key="${FACE_OFF_NAKAMA_SERVER_KEY:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server-key)
            [[ $# -ge 2 ]] || { echo "--server-key requires a value" >&2; exit 2; }
            server_key="$2"
            shift 2
            ;;
        -h|--help)
            endpoint=""
            break
            ;;
        *)
            if [[ -z "$endpoint" ]]; then
                endpoint="$1"
                shift
            else
                echo "Unexpected argument: $1" >&2
                exit 2
            fi
            ;;
    esac
done

if [[ -z "$endpoint" || "$endpoint" == "-h" || "$endpoint" == "--help" ]]; then
    cat <<'USAGE'
Usage: tools/configure_online_endpoint.sh nakamas://play.example.com [--server-key KEY]

Sets the endpoint prefilled by the in-game online join field. Use nakamas://
for a TLS deployment, or leave the project setting empty for the local relay.
When --server-key is supplied, it also configures the matching Nakama client
key required by the production server.
USAGE
    [[ -z "$endpoint" ]] && exit 2 || exit 0
fi
if [[ "$endpoint" != nakamas://* ]]; then
    echo "The production endpoint must start with nakamas://" >&2
    exit 1
fi
endpoint_body="${endpoint#nakamas://}"
if [[ -z "$endpoint_body" || "$endpoint_body" == *" "* || "$endpoint_body" == */* ]]; then
    echo "Pass a hostname without a path, for example nakamas://play.example.com" >&2
    exit 1
fi
if [[ -n "$server_key" && ( "$server_key" == dev* || "$server_key" == local-* || "$server_key" == replace-* ) ]]; then
    echo "The production client key still contains a development value." >&2
    exit 1
fi

python3 - "$project_file" "$endpoint" "$server_key" <<'PY'
from pathlib import Path
import json
import sys

project_path = Path(sys.argv[1])
endpoint = sys.argv[2]
server_key = sys.argv[3]
text = project_path.read_text()
settings = {"online_endpoint": endpoint}
if server_key:
    settings["online_server_key"] = server_key
lines = text.splitlines()
section_start = None
section_end = None
for index, current in enumerate(lines):
    if current == "[faceoff]":
        section_start = index
        break
if section_start is None:
    lines.extend(["", "[faceoff]", ""])
    lines.extend([f"{key}={json.dumps(value)}" for key, value in settings.items()])
else:
    for index in range(section_start + 1, len(lines)):
        if lines[index].startswith("[") and lines[index].endswith("]"):
            section_end = index
            break
    if section_end is None:
        section_end = len(lines)
    for key, value in settings.items():
        line = f"{key}={json.dumps(value)}"
        replaced = False
        for index in range(section_start + 1, section_end):
            if lines[index].startswith(f"{key}="):
                lines[index] = line
                replaced = True
                break
        if not replaced:
            insert_at = section_end
            while insert_at > section_start + 1 and lines[insert_at - 1] == "":
                insert_at -= 1
            lines.insert(insert_at, line)
            section_end += 1
project_path.write_text("\n".join(lines) + "\n")
PY

echo "Configured project endpoint: $endpoint"
if [[ -n "$server_key" ]]; then
    echo "Configured the matching Nakama server key in project settings."
fi
echo "Restore the empty values in the [faceoff] section to return to the local relay default."
