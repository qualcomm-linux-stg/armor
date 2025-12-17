
#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
set -euo pipefail

# ------------------------------------------------------------------------------
# Usage (4 args):
#   parse_headers.sh <CONFIG_YAML> <BRANCH> <HEAD_PATH> [<WORKSPACE>]
#
# Behavior:
#   • HEAD-only expansion (base is NOT consulted).
#   • NO normalization: outputs contain absolute paths rooted at HEAD_PATH.
#   • Robust to missing YAML keys, missing dirs, globs with zero matches.
#
# Outputs (written into WORKSPACE or current dir if not provided):
#   - blocking_headers.txt        (absolute paths under HEAD_PATH; may be empty)
#   - nonblocking_headers.txt     (absolute paths under HEAD_PATH; may be empty)
# ------------------------------------------------------------------------------

CONFIG_YAML="${1:?CONFIG_YAML is required}"
BRANCH="${2:?BRANCH is required}"
HEAD_PATH="${3:?HEAD_PATH is required}"
WORKSPACE="${4:-${GITHUB_WORKSPACE:-$(pwd)}}"

# --- sanity ---
if [[ ! -f "$CONFIG_YAML" ]]; then
  echo "[ERR] config not found: $CONFIG_YAML" >&2; exit 1
fi
if [[ ! -d "$HEAD_PATH" ]]; then
  echo "[ERR] HEAD_PATH not a directory: $HEAD_PATH" >&2; exit 1
fi
if ! command -v yq >/dev/null 2>&1; then
  echo "[ERR] yq is required but not installed" >&2; exit 1
fi

echo "[parse_headers] config=$CONFIG_YAML branch=$BRANCH head=$HEAD_PATH ws=$WORKSPACE (no normalization)"

# Ensure outputs exist from the start (even if we find nothing)
BLOCKING_OUT="$WORKSPACE/blocking_headers.txt"
NONBLOCKING_OUT="$WORKSPACE/nonblocking_headers.txt"
: > "$BLOCKING_OUT"
: > "$NONBLOCKING_OUT"

# --- helper: expand one pattern against HEAD_PATH (never fails) ---
expand_patt_head() {
  local root="$1" patt="$2" out="$3"

  # normalize "./"
  if [[ "$patt" == ./* ]]; then
    patt="${patt#./}"
  fi

  # trailing slash => directory recurse
  if [[ "$patt" == */ ]]; then
    local dir="${patt%/}"
    if [[ -d "$root/$dir" ]]; then
      find "$root/$dir" -type f \( -name '*.h' -o -name '*.hpp' \) -print >>"$out"
    fi
    return 0
  fi

  # explicit directory => recurse
  if [[ -d "$root/$patt" ]]; then
    find "$root/$patt" -type f \( -name '*.h' -o -name '*.hpp' \) -print >>"$out"
    return 0
  fi

  # glob patterns (supports **/*.h, *.h, *.hpp, ? and [])
  if [[ "$patt" == *"*"* || "$patt" == *"?"* || "$patt" == *"["*"]"* ]]; then
    local dir_part base_part search_dir
    dir_part="$(dirname -- "$patt")"
    base_part="$(basename -- "$patt")"
    search_dir="$root"
    if [[ "$dir_part" != "." ]]; then
      search_dir="$root/$dir_part"
    fi

    if [[ -d "$search_dir" ]]; then
      case "$base_part" in
        "**.h"|"**/*.h")
          find "$search_dir" -type f -name '*.h'   -print >>"$out"
          ;;
        "**.hpp"|"**/*.hpp")
          find "$search_dir" -type f -name '*.hpp' -print >>"$out"
          ;;
        *)
          find "$search_dir" -type f -name "$base_part" -print >>"$out"
          ;;
      esac
    fi
    return 0
  fi

  # explicit file path relative to HEAD (only accept .h/.hpp)
  if [[ -f "$root/$patt" ]]; then
    case "$patt" in
      *.h|*.hpp) echo "$root/$patt" >>"$out" ;;
    esac
  fi
  return 0
}

# --- helper: process one mode (HEAD-only, absolute paths) ---
process_mode() {
  local mode="$1" final="$2"
  local patt_file="$WORKSPACE/${mode}_patterns.txt"
  local expanded_head="$WORKSPACE/${mode}_expanded_head.txt"

  : > "$patt_file"
  : > "$expanded_head"
  : > "$final"       # ensure file is created

  # Extract patterns; tolerate missing keys (yq non-zero -> ignore)
  yq ".branches.${BRANCH}.modes.${mode}.headers[]" "$CONFIG_YAML" >>"$patt_file" || true

  # Dedup patterns even if file is empty
  sort -u -o "$patt_file" "$patt_file" || true

  # Expand against HEAD only (tolerate missing dirs/globs -> no matches)
  while IFS= read -r patt; do
    # skip blank/whitespace-only
    if [[ -z "${patt//[[:space:]]/}" ]]; then
      continue
    fi
    expand_patt_head "$HEAD_PATH" "$patt" "$expanded_head"
  done < "$patt_file"

  # Dedup absolute paths (no normalization)
  if [[ -s "$expanded_head" ]]; then
    sort -u "$expanded_head" >"$final" || true
  fi

  echo "[parse_headers] ${mode} → ${final}"
  if [[ -s "$final" ]]; then
       cat "$final"
  else
    echo "(empty)"
  fi
}

# --- run modes (HEAD-only) ---
process_mode "blocking"      "$BLOCKING_OUT"
process_mode "non-blocking"  "$NONBLOCKING_OUT"


