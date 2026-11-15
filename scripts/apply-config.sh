#!/usr/bin/env bash
# Write one app's rendered bundle into its folder on the VM.
#
# Usage: apply-config.sh BUNDLE --apps-root DIR --app NAME --owner ID [--adopt] [--dry-run]
#        (BUNDLE may be '-' to read stdin)
#
# Needs only bash, base64 (coreutils) and mktemp. The bundle is data: nothing in it is executed here.
# Guard rails (everything is checked BEFORE anything is written; a bad bundle changes nothing):
#   * paths: relative, segments of [A-Za-z0-9._-], no '.'/'..', at most 8 levels / 200 characters;
#     the names .owner, .files, .disabled and .apply.* are reserved; no duplicates; no path that is
#     both a file and a folder
#   * modes: only 600, 640 or 644; at most 200 files, 256 KiB per file, 2 MiB in total
#   * destination: APPS_ROOT/NAME. APPS_ROOT must already exist (it is the mounted data disk; it is
#     never created here, so a missing mount cannot silently fill the boot disk). Neither APPS_ROOT,
#     the app folder nor any folder below it may be a symbolic link.
#   * ownership: the app folder holds a .owner file naming the repo that deployed it; another owner is
#     refused. A non-empty folder without .owner is refused unless --adopt is given (first migration).
#   * stale files: files written by the previous run (listed in .files) that are no longer part of the
#     bundle are removed; nothing else is ever deleted.
# Directories are created with mode 755 (containers run as other users and must be able to traverse them).
#
# Bundle format: "config-bundle v2", "app <name>", then one line per file: "<mode> <path> <base64>".
set -euo pipefail
umask 077
export LC_ALL=C

MAX_FILES=200
MAX_FILE_BYTES=262144
MAX_TOTAL_BYTES=2097152

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//'; }

# ---- arguments ----
bundle="" apps_root="" app="" owner="" adopt=0 dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apps-root) [ $# -ge 2 ] || die "--apps-root needs a directory"; apps_root="$2"; shift 2 ;;
    --app) [ $# -ge 2 ] || die "--app needs a name"; app="$2"; shift 2 ;;
    --owner) [ $# -ge 2 ] || die "--owner needs an id"; owner="$2"; shift 2 ;;
    --adopt) adopt=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -) [ -z "$bundle" ] || die "only one bundle allowed"; bundle="-"; shift ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$bundle" ] || die "only one bundle allowed"; bundle="$1"; shift ;;
  esac
done
[ -n "$bundle" ] && [ -n "$apps_root" ] && [ -n "$app" ] && [ -n "$owner" ] || { usage >&2; exit 2; }
[[ "$app" =~ ^[a-z][a-z0-9-]{0,40}$ ]] || die "invalid --app"
[[ "$owner" =~ ^[A-Za-z0-9._/-]{1,100}$ ]] || die "invalid --owner"
[[ "$apps_root" =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+){0,11}$ ]] || die "--apps-root must be an absolute path of up to 12 simple segments"
case "/$apps_root/" in */../*|*/./*) die "--apps-root must not contain . or .." ;; esac
command -v base64 >/dev/null || die "base64 is required"

work="$(mktemp -d)"
staged_tmp=()
cleanup() {
  local t
  for t in ${staged_tmp[@]+"${staged_tmp[@]}"}; do rm -f -- "$t"; done
  rm -rf -- "$work"
}
trap cleanup EXIT

if [ "$bundle" = "-" ]; then cat >"$work/bundle"; else
  [ -r "$bundle" ] || die "cannot read bundle: $bundle"
  cat -- "$bundle" >"$work/bundle"
fi

# ---- path rules (shared by new and previously written paths) ----
path_ok() {
  local p="$1" seg rest
  [ "${#p}" -le 200 ] || return 1
  [[ "$p" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || return 1
  rest="$p"; local depth=1
  while [[ "$rest" == */* ]]; do rest="${rest#*/}"; depth=$((depth + 1)); done
  [ "$depth" -le 8 ] || return 1
  rest="$p"
  while :; do
    seg="${rest%%/*}"
    case "$seg" in .|..) return 1 ;; esac
    [[ "$rest" == */* ]] || break
    rest="${rest#*/}"
  done
  case "$p" in .owner|.files|.disabled) return 1 ;; esac
  case "${p##*/}" in .apply.*) return 1 ;; esac
  return 0
}

# ---- parse and validate the whole bundle ----
modes=() paths=() b64s=()
seen=" "
n=0 total=0
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  n=$((n + 1))
  if [ "$n" = 1 ]; then [ "$line" = "config-bundle v2" ] || die "unsupported bundle format"; continue; fi
  if [ "$n" = 2 ]; then [ "$line" = "app $app" ] || die "the bundle is for a different app than --app $app"; continue; fi
  [ -n "$line" ] || continue
  [[ "$line" =~ ^(600|640|644)\ ([^\ ]+)\ ([A-Za-z0-9+/]*={0,2})$ ]] || die "malformed bundle line $n"
  mode="${BASH_REMATCH[1]}" path="${BASH_REMATCH[2]}" data="${BASH_REMATCH[3]}"
  path_ok "$path" || die "path not allowed: $(printf '%q' "$path")"
  case "$seen" in *" $path "*) die "duplicate entry: $path" ;; esac
  printf '%s' "$data" | base64 -d >"$work/probe" 2>/dev/null || die "invalid encoding for $path"
  size="$(wc -c <"$work/probe")"
  [ "$size" -le "$MAX_FILE_BYTES" ] || die "$path is larger than $MAX_FILE_BYTES bytes"
  total=$((total + size))
  seen+="$path "
  modes+=("$mode"); paths+=("$path"); b64s+=("$data")
done <"$work/bundle"
[ "$n" -ge 2 ] || die "unsupported bundle format (empty)"
[ "${#paths[@]}" -le "$MAX_FILES" ] || die "more than $MAX_FILES files"
[ "$total" -le "$MAX_TOTAL_BYTES" ] || die "bundle is larger than $MAX_TOTAL_BYTES bytes"
for p in ${paths[@]+"${paths[@]}"}; do
  for q in ${paths[@]+"${paths[@]}"}; do
    [[ "$q" == "$p"/* ]] && die "$p is both a file and a folder"
  done
done

# ---- destination checks ----
dest="$apps_root/$app"
[ -d "$apps_root" ] || die "$apps_root does not exist (is the data disk mounted?); it is not created automatically"
[ ! -L "$apps_root" ] || die "$apps_root is a symbolic link"
[ ! -L "$dest" ] || die "$dest is a symbolic link"
old_files=()
if [ -e "$dest" ]; then
  [ -d "$dest" ] || die "$dest exists and is not a directory"
  if [ -f "$dest/.owner" ]; then
    [ "$(cat -- "$dest/.owner")" = "owner=$owner" ] || die "$dest is owned by another repository"
  elif [ -n "$(ls -A -- "$dest")" ] && [ "$adopt" = 0 ]; then
    die "$dest is not empty and has no .owner file (not created by this tool); check it, then use --adopt"
  fi
  if [ -f "$dest/.files" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if path_ok "$line"; then old_files+=("$line"); fi    # silently ignore anything that is not a valid path
    done <"$dest/.files"
  fi
fi

# ---- dry run ----
if [ "$dry_run" = 1 ]; then
  for i in "${!paths[@]}"; do printf 'would write %s/%s (%s)\n' "$dest" "${paths[$i]}" "${modes[$i]}"; done
  printf 'would write %s/.owner and %s/.files\n' "$dest" "$dest"
  stale=0
  for o in ${old_files[@]+"${old_files[@]}"}; do case "$seen" in *" $o "*) ;; *) stale=$((stale + 1)) ;; esac; done
  echo "would remove $stale stale file(s)"
  exit 0
fi

# ---- helpers for writing ----
# ensure_dir REL: create DEST/REL step by step with mode 755, refusing symbolic links on the way
ensure_dir() {
  local rel="$1" cur="$dest" seg
  if [ ! -d "$cur" ]; then mkdir -m 755 -- "$cur" || die "cannot create $cur"; fi
  [ -n "$rel" ] || return 0
  local rest="$rel"
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
    cur="$cur/$seg"
    [ ! -L "$cur" ] || die "$cur is a symbolic link"
    if [ ! -d "$cur" ]; then mkdir -m 755 -- "$cur" || die "cannot create $cur"; fi
  done
}

stage() {  # stage MODE REL CONTENT-FROM-STDIN  -> registers a temp file to be moved into place
  local mode="$1" rel="$2" dir tmp
  dir="$dest/$(dirname -- "$rel")"
  ensure_dir "$(dirname -- "$rel" | sed 's#^\.$##')"
  [ ! -L "$dest/$rel" ] || die "$dest/$rel is a symbolic link"
  [ ! -d "$dest/$rel" ] || die "$dest/$rel is a directory"
  tmp="$(mktemp "$dir/.apply.XXXXXX")" || die "cannot create a temporary file in $dir"
  staged_tmp+=("$tmp")
  staged_target+=("$dest/$rel")
  cat >"$tmp"
  chmod "$mode" "$tmp"
}

# ---- stage everything, then move it all into place ----
staged_target=()
ensure_dir ""
# (stage runs in this shell, not in a pipeline, so that it can register its temp files)
for i in "${!paths[@]}"; do
  printf '%s' "${b64s[$i]}" | base64 -d >"$work/data"
  stage "${modes[$i]}" "${paths[$i]}" <"$work/data"
done
printf 'owner=%s\n' "$owner" >"$work/data"
stage 644 ".owner" <"$work/data"
printf '%s\n' ${paths[@]+"${paths[@]}"} >"$work/data"
stage 644 ".files" <"$work/data"
for i in "${!staged_tmp[@]}"; do
  mv -f -- "${staged_tmp[$i]}" "${staged_target[$i]}"
done
staged_tmp=()

# ---- remove files the previous run wrote that are no longer part of the bundle ----
removed=0
for o in ${old_files[@]+"${old_files[@]}"}; do
  case "$seen" in *" $o "*) continue ;; esac
  f="$dest/$o"
  # skip anything reached through a symbolic link
  cur="$dest"; rest="$o"; safe=1
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"; if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
    cur="$cur/$seg"; if [ -L "$cur" ]; then safe=0; break; fi
  done
  [ "$safe" = 1 ] && [ -f "$f" ] || continue
  rm -f -- "$f" && removed=$((removed + 1))
  d="$(dirname -- "$o")"
  while [ "$d" != "." ] && rmdir -- "$dest/$d" 2>/dev/null; do d="$(dirname -- "$d")"; done
done

echo "Applied ${#paths[@]} files to $dest ($removed stale file(s) removed)."
