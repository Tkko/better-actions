#!/usr/bin/env bash
#
# find-min-flutter.sh - find the lowest stable Flutter version a project works with.
#
# Switches the project between Flutter versions using FVM, runs a check
# command at each one, and reports the lowest version that passes. By default
# it binary-searches (assumes "if X works, everything newer works"); use
# --linear to test every version instead.
#
# The project's .fvmrc and pubspec.lock are restored on exit.
#
# Requires: fvm.

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: find-min-flutter.sh [options]

  -C, --dir DIR       Project directory (default: current directory)
      --from VERSION  Lowest Flutter version to consider (default: from pubspec
                      environment.flutter if present, else 3.0.0)
      --to VERSION    Highest Flutter version to consider (default: latest stable)
      --cmd COMMAND   Check run at each version via `fvm flutter`-aware shell
                      (default: "fvm flutter pub get && fvm flutter analyze && fvm flutter test")
      --linear        Test every version in range instead of binary search
  -h, --help          Show this help

Examples:
  find-min-flutter.sh -C ~/code/my_package
  find-min-flutter.sh --from 3.10.0 --cmd "fvm flutter pub get && fvm flutter analyze"
EOF
}

dir="."
from=""
to=""
cmd=""
linear=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -C|--dir)  dir="$2"; shift 2 ;;
    --from)    from="$2"; shift 2 ;;
    --to)      to="$2"; shift 2 ;;
    --cmd)     cmd="$2"; shift 2 ;;
    --linear)  linear=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in fvm; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 2; }
done

cd "$dir" || { echo "Cannot cd to $dir" >&2; exit 2; }
[[ -f pubspec.yaml ]] || { echo "No pubspec.yaml in $(pwd)" >&2; exit 2; }

# Checks run as stages ("name|command"), stopping at the first failure so the
# failing stage's output can be shown. --cmd replaces them with one stage.
if [[ -n "$cmd" ]]; then
  stages="check|$cmd"
else
  stages="pub get|fvm flutter pub get
analyze|fvm flutter analyze --no-fatal-infos"
  [[ -d test ]] && stages="$stages
test|fvm flutter test"
fi

# --- Lower bound ------------------------------------------------------------
if [[ -z "$from" ]]; then
  # environment: flutter: ">=3.10.0" -> 3.10.0
  from=$(sed -n '/^environment:/,/^[^ ]/p' pubspec.yaml \
    | sed -nE 's/^[[:space:]]+flutter:[[:space:]]*["'\'']?[>=^ ]*([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' \
    | head -1)
  from="${from:-3.0.0}"
fi

# --- Candidate versions -----------------------------------------------------
# Stable releases only, de-duplicated, ascending, within [from, to].
# `fvm releases` prints a colored table: strip ANSI codes, then take the first
# column of rows whose channel column is "stable".
release_rows=$(fvm releases --channel stable 2>/dev/null \
  | sed $'s/\x1b\\[[0-9;]*m//g' \
  | awk -F'│' '$4 ~ /stable/ {
      gsub(/[ \t]/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3); print $2 "|" $3 }' \
  | sed 's/^v//' | sort -uV)   # rows of "version|release date"
[[ -n "$release_rows" ]] || { echo "Failed to read releases from 'fvm releases'" >&2; exit 1; }

ver_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]; }  # $1 >= $2
release_date() { printf '%s\n' "$release_rows" | grep "^$1|" | head -1 | cut -d'|' -f2; }

versions=()
while IFS='|' read -r v _; do
  ver_ge "$v" "$from" || continue
  [[ -n "$to" ]] && ! ver_ge "$to" "$v" && continue
  versions+=("$v")
done <<<"$release_rows"

if [[ ${#versions[@]} -eq 0 ]]; then
  echo "No stable versions in range (from=$from to=${to:-latest})" >&2
  exit 1
fi

# --- Backup / restore -------------------------------------------------------
backup=$(mktemp -d "${TMPDIR:-/tmp}/find-min-flutter.XXXXXX") || { echo "Cannot create temp dir" >&2; exit 2; }
had_fvmrc=0
had_lock=0
if [[ -f .fvmrc ]];       then cp .fvmrc "$backup/fvmrc"; had_fvmrc=1; fi
if [[ -f pubspec.lock ]]; then cp pubspec.lock "$backup/pubspec.lock"; had_lock=1; fi

# Spinner with a label for the step in progress, shown at the end of the
# current line (only on an interactive terminal), e.g. "| analyze". Each frame
# is written in one go and ends with backspaces, so the cursor stays put and
# the next text overwrites it. spinner_stop wipes it.
spin_pid=""
spin_len=0
spinner_start() {
  [[ -t 1 ]] || return 0
  local label="$1" bs="" i
  spin_len=$(( ${#label} + 2 ))
  for (( i = 0; i < spin_len; i++ )); do bs="$bs"$'\b'; done
  (
    while :; do
      for frame in '|' '/' '-' '\'; do
        printf '%s %s%s' "$frame" "$label" "$bs"
        sleep 0.15
      done
    done
  ) &
  spin_pid=$!
  disown "$spin_pid" 2>/dev/null || true
}
spinner_stop() {
  [[ -n "$spin_pid" ]] || return 0
  kill "$spin_pid" 2>/dev/null || true
  spin_pid=""
  local bs="" i
  for (( i = 0; i < spin_len; i++ )); do bs="$bs"$'\b'; done
  printf '%*s%s' "$spin_len" '' "$bs"   # erase the label
}

restore() {
  spinner_stop
  if (( had_fvmrc )); then cp "$backup/fvmrc" .fvmrc; else rm -f .fvmrc; fi
  if (( had_lock ));  then cp "$backup/pubspec.lock" pubspec.lock; else rm -f pubspec.lock; fi
  rm -rf "$backup"
  # Re-link .fvm to the original version if there was one.
  if (( had_fvmrc )); then fvm use --force --skip-pub-get >/dev/null 2>&1 || true; fi
}
trap restore EXIT

# --- Probe ------------------------------------------------------------------
# Results are cached as files (bash 3.2 on macOS has no associative arrays).
mkdir -p "$backup/results"
set_result() { echo "$2" >"$backup/results/$1"; }
get_result() { cat "$backup/results/$1" 2>/dev/null || true; }

mkdir -p "$backup/logs" "$backup/stages"

# Print the lines of a version's log that most likely explain the failure
# (falls back to the last lines when nothing looks like an error).
reason() {
  local log="$backup/logs/$1.log" n="${2:-3}" lines
  lines=$(grep -iE 'error|failed|because|requires|incompatible|solving|not supported|not found|doesn.t match' "$log" | head -n "$n")
  [[ -n "$lines" ]] || lines=$(tail -n "$n" "$log")
  printf '%s\n' "$lines" | sed 's/^/      | /'
}

# Show why a version failed: for `analyze`, the analyzer's own issue lines
# ("error • message • file:line"); otherwise the likely error lines.
explain() {
  local v="$1" n="${2:-3}" log="$backup/logs/$1.log" stage lines
  stage=$(cat "$backup/stages/$v" 2>/dev/null || true)
  if [[ "$stage" == analyze ]]; then
    # Errors and warnings first; infos only when there is nothing else.
    lines=$(grep -E '^[[:space:]]*(error|warning) •' "$log" | head -n "$n")
    [[ -n "$lines" ]] || lines=$(grep '•' "$log" | head -n "$n")
    if [[ -n "$lines" ]]; then printf '%s\n' "$lines" | sed 's/^/      | /'; return; fi
  fi
  reason "$v" "$n"
}

check() {
  local v="$1" cached log="$backup/logs/$1.log" name command dart_version infos
  cached=$(get_result "$v")
  [[ -n "$cached" ]] && { [[ "$cached" == pass ]]; return; }
  printf '  %-9s %-13s ' "$v" "$(release_date "$v")"
  spinner_start "switching"
  if ! fvm use "$v" --force --skip-pub-get >"$log" 2>&1; then
    # Not installed yet: let fvm install it.
    spinner_stop; spinner_start "installing"
    if ! fvm install "$v" >"$log" 2>&1 || ! fvm use "$v" --force --skip-pub-get >>"$log" 2>&1; then
      spinner_stop; echo "SKIP (could not install)"; reason "$v"
      set_result "$v" skip; return 1
    fi
  fi
  # The Dart SDK bundled with this Flutter version, e.g. "Dart 3.2.0".
  spinner_stop; spinner_start "reading Dart version"
  dart_version=$(fvm flutter --version 2>/dev/null \
    | sed -nE 's/.*Dart ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -1)
  spinner_stop
  printf '%-11s ' "Dart ${dart_version:-?}"
  rm -f pubspec.lock
  infos=""
  while IFS='|' read -r name command; do
    [[ -n "$name" ]] || continue
    spinner_start "$name"
    if ! bash -c "$command" >"$log" 2>&1 </dev/null; then
      echo "$name" >"$backup/stages/$v"
      spinner_stop; echo "fail ($name)"; explain "$v" 8; set_result "$v" fail; return 1
    fi
    spinner_stop
    # Analyzer infos do not fail the check; keep them to show under the result.
    if [[ "$name" == analyze ]]; then
      infos=$(grep -E '^[[:space:]]*info •' "$log" || true)
    fi
  done <<<"$stages"
  echo "pass"; set_result "$v" pass
  if [[ -n "$infos" ]]; then
    printf '%s\n' "$infos" | head -n 5 | sed 's/^[[:space:]]*/      | /'
    (( $(printf '%s\n' "$infos" | wc -l) > 5 )) && echo "      | ... and more infos (not failing)"
  fi
  return 0
}

echo "Project : $(pwd)"
echo "Range   : $from .. ${to:-latest} (${#versions[@]} stable versions)"
echo "Checks  : $(printf '%s\n' "$stages" | cut -d'|' -f1 | paste -sd, - | sed 's/,/, /g')"
echo "Mode    : $([[ $linear == 1 ]] && echo linear || echo binary search)"
echo

newest_idx=$(( ${#versions[@]} - 1 ))
newest="${versions[$newest_idx]}"
if ! check "$newest"; then
  echo
  echo "The check already fails on the newest version ($newest); nothing to search."
  echo "Last output:"; tail -20 "$backup/logs/$newest.log"
  exit 1
fi

min="$newest"
if (( linear )); then
  for v in "${versions[@]}"; do
    if check "$v"; then min="$v"; break; fi
  done
else
  # Check the lower bound too: if it already passes there is nothing to search.
  lo=0; hi=$newest_idx   # invariant: versions[hi] passes
  if check "${versions[0]}"; then
    hi=0
    at_floor=1
  else
    lo=1                 # versions[0] is known to fail; search above it
  fi
  while (( lo < hi )); do
    mid=$(( (lo + hi) / 2 ))
    if check "${versions[$mid]}"; then hi=$mid; else lo=$(( mid + 1 )); fi
  done
  min="${versions[$hi]}"
fi

echo
echo "Lowest working Flutter version: $min"
if (( ${at_floor:-0} )); then
  echo "The lowest version in range passes, so the real minimum may be lower."
  echo "Re-run with a smaller --from to look further down."
fi

# Explain why the next version down does not work.
prev=""
for i in "${!versions[@]}"; do
  [[ "${versions[$i]}" == "$min" && $i -gt 0 ]] && prev="${versions[$((i - 1))]}"
done
if [[ -n "$prev" && -f "$backup/logs/$prev.log" ]]; then
  echo
  echo "Why $prev does not work ($(get_result "$prev")):"
  explain "$prev" 15
  keep=$(mktemp "${TMPDIR:-/tmp}/find-min-flutter-$prev.XXXXXX")
  cp "$backup/logs/$prev.log" "$keep"
  echo "  Full log: $keep"
fi

# Install failures are treated as failures, which can make the result too high.
skipped=$(grep -l '^skip$' "$backup"/results/* 2>/dev/null | wc -l | tr -d ' ')
if (( skipped > 0 )); then
  echo
  echo "Warning: $skipped version(s) could not be installed and were counted as failures,"
  echo "so the real minimum may be lower than reported."
fi

if (( ! linear )); then
  echo "(binary search assumes monotonic results; re-run with --linear to verify)"
fi
