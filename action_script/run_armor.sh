
#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   run_armor.sh <BASE_PATH> <HEAD_PATH> <INTERSECTION_HEADERS_PATH> <ARMOR_BINS_PATH>
#
# Env (optional):
#   HEADER_DIR      : If set, pass --header-dir and treat headers as basenames
#   REPORT_FORMAT   : html | json     (default: html; 'json' => html+json)
#   INCLUDE_PATHS   : space-separated include flags, e.g. "-I include -I third_party/include"
#   MACRO_FLAGS     : macro flags, e.g. "-DUSE_FOO -DVALUE=1"
#   LOG_LEVEL       : ERROR|LOG|INFO|DEBUG (default: INFO)
#   DUMP_AST_DIFF   : "true" to add --dump-ast-diff
#   ARMOR_CMD       : armor binary name/path (default: "armor")
#   HEAD_SHA        : used for namespacing output (recommended)
#   BASE_SHA        : optional (for metadata)
#
# Behavior:
#   - Runs armor once per header in the intersection list.
#   - For each header, runs in a temp workdir (armor writes reports to CWD).
#   - Copies results into:
#       $GITHUB_WORKSPACE/armor_output/$HEAD_SHA/
#         <hdr_name>/** (all armor outputs copied as-is)
#   - The workflow will upload this folder as an artifact.

log()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERR]\033[0m %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ------------ Args ------------
BASE_PATH="${1:-}"; [[ -n "$BASE_PATH" ]] || die "Missing BASE_PATH"
HEAD_PATH="${2:-}"; [[ -n "$HEAD_PATH" ]] || die "Missing HEAD_PATH"
INTERSECTION_FILE="${3:-}"; [[ -n "$INTERSECTION_FILE" ]] || die "Missing INTERSECTION_HEADERS_PATH"
ARMOR_BINS_PATH="${4:-}" # optional; if provided, we'll use <ARMOR_BINS_PATH>/armor

[[ -d "$BASE_PATH" ]] || die "BASE_PATH not a directory: $BASE_PATH"
[[ -d "$HEAD_PATH" ]] || die "HEAD_PATH not a directory: $HEAD_PATH"
[[ -f "$INTERSECTION_FILE" ]] || die "Intersection file not found: $INTERSECTION_FILE"

# ------------ Env / defaults ------------
REPORT_FORMAT="${REPORT_FORMAT:-html}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
DUMP_AST_DIFF="${DUMP_AST_DIFF:-false}"
HEADER_DIR="${HEADER_DIR:-}"
INCLUDE_PATHS="${INCLUDE_PATHS:-}"
MACRO_FLAGS="${MACRO_FLAGS:-}"

GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
HEAD_SHA="${HEAD_SHA:-$(git -C "$HEAD_PATH" rev-parse HEAD || echo unknown)}"
BASE_SHA="${BASE_SHA:-}"

# Determine ARMOR_CMD:
# Priority: explicit ARMOR_CMD env > constructed from ARMOR_BINS_PATH arg > "armor" from PATH
if [[ -n "${ARMOR_CMD:-}" ]]; then
  ARMOR_CMD="$ARMOR_CMD"
elif [[ -n "$ARMOR_BINS_PATH" ]]; then
  ARMOR_CMD="${ARMOR_BINS_PATH%/}"
else
  ARMOR_CMD="armor"
fi

# Verify armor command is available/executable
if ! command -v "$ARMOR_CMD" >/dev/null 2>&1; then
  die "armor CLI not found: $ARMOR_CMD (ensure in PATH or provide ARMOR_CMD/ARMOR_BINS_PATH)"
fi

# ------------ Read intersection headers ------------
mapfile -t HEADERS < <(sed -e 's/^\s\+//; s/\s\+$//' -e '/^$/d' -e '/^\s*#/d' "$INTERSECTION_FILE" || true)
if [[ ${#HEADERS[@]} -eq 0 ]]; then
  log "Intersection is empty. Nothing to run."
  exit 0
fi

# ------------ Output layout ------------
OUT_ROOT="${GITHUB_WORKSPACE}/armor_output/${HEAD_SHA}"
mkdir -p "$OUT_ROOT"

generated_any=false

# ------------ Run armor per header ------------
for header in "${HEADERS[@]}"; do
  # Determine armor header argument
  hdr_arg="$header"
  if [[ -n "$HEADER_DIR" ]]; then
    hdr_arg="$(basename "$header")"
  fi

  # Per-header temp workdir (armor writes into CWD)
  # Sanitize header for temp dir suffix
  safe="$(echo "$header" | sed 's/[^A-Za-z0-9_.-]/_/g')"
  WORK_DIR="$(mktemp -d "${GITHUB_WORKSPACE}/.armor_${safe}.XXXXXX")"
  pushd "$WORK_DIR" >/dev/null

  # Build args
  args=()
  [[ -n "$HEADER_DIR" ]]           && args+=( --header-dir "$HEADER_DIR" )
  [[ -n "$REPORT_FORMAT" ]]        && args+=( -r "$REPORT_FORMAT" )
  [[ "$DUMP_AST_DIFF" == "true" ]] && args+=( --dump-ast-diff )
  [[ -n "$LOG_LEVEL" ]]            && args+=( --log-level "$LOG_LEVEL" )

  if [[ -n "$INCLUDE_PATHS" ]]; then
    # shellcheck disable=SC2206
    include_array=( $INCLUDE_PATHS )
    args+=( "${include_array[@]}" )
  fi

  if [[ -n "$MACRO_FLAGS" ]]; then
    # Split macro flags if multiple are provided
    # shellcheck disable=SC2206
    macro_array=( $MACRO_FLAGS )
    args+=( -m "${macro_array[@]}" )
  fi

  log "$ARMOR_CMD ${args[*]} \"$BASE_PATH\" \"$HEAD_PATH\" \"$hdr_arg\""

  set +e
  "$ARMOR_CMD" "${args[@]}" "$BASE_PATH" "$HEAD_PATH" "$hdr_arg"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    warn "armor failed for header: $header (exit $rc). Continuing."
  else
    generated_any=true
  fi

  dest="${OUT_ROOT}/${safe}"
  mkdir -p "$dest"

  # Safer copy even if dir is empty
  # Use tar|tar to preserve layout without wildcards failing
  tar -cf - . 2>/dev/null | tar -xf - -C "$dest" 2>/dev/null || true

  popd >/dev/null
  rm -rf "$WORK_DIR" || true
done

# Write a tiny metadata file (useful when inspecting artifact)
{
  echo "head_sha=${HEAD_SHA}"
  echo "base_sha=${BASE_SHA}"
  echo "headers_count=${#HEADERS[@]}"
  printf "headers="; printf "%s;" "${HEADERS[@]}"; echo
} > "${OUT_ROOT}/metadata.txt"

log "Armor output prepared at: ${OUT_ROOT}"
echo "${OUT_ROOT}" > "${GITHUB_WORKSPACE}/.armor_out_root"
