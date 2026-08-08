#!/bin/sh
# Install Sol Advisor's shipped custom-agent templates without changing Codex config.

set -eu

usage() {
  cat <<'EOF'
Usage: install-agents.sh [--target-dir PATH] [--check]

Install Sol Advisor's two current custom-agent templates into the target directory.
Normal mode also removes only the exact legacy companion files: the superseded
sol-advisor-terra-implementer.toml (v0.2.0 and gpt-5.6-terra-era byte digests) and
the legacy Luna template. It never overwrites or removes a modified, nonregular, or
symlinked destination.

Without --target-dir, the target is "$CODEX_HOME/agents" when CODEX_HOME is already
set, otherwise "$HOME/.codex/agents".

Options:
  --target-dir PATH  Explicit destination directory (absolute or relative).
  --check            Verify that Implementer and Sol match exactly and no legacy
                     Terra or Luna file remains; do not create, replace, or remove
                     anything.
  --help             Show this help text.
EOF
}

fail() {
  printf '%s\n' "ERROR: $*" >&2
  exit 1
}

report_preflight_error() {
  printf '%s\n' "ERROR: $*" >&2
  preflight_failed=1
}

path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

sha256_file() {
  shasum -a 256 "$1" 2>/dev/null | awk 'NF >= 1 && length($1) == 64 { print $1; exit }'
}

classify_current_or_legacy() {
  destination=$1
  template=$2
  legacy_digest=$3

  if ! path_exists "$destination"; then
    printf '%s\n' missing
  elif [ -L "$destination" ] || [ ! -f "$destination" ]; then
    printf '%s\n' unsafe
  elif cmp -s "$template" "$destination"; then
    printf '%s\n' current
  else
    digest=$(sha256_file "$destination")
    if [ -n "$legacy_digest" ] && [ "$digest" = "$legacy_digest" ]; then
      printf '%s\n' legacy
    elif [ -z "$digest" ]; then
      printf '%s\n' unreadable
    else
      printf '%s\n' conflict
    fi
  fi
}

classify_legacy() {
  destination=$1
  shift
  legacy_digests=$*

  if ! path_exists "$destination"; then
    printf '%s\n' missing
  elif [ -L "$destination" ] || [ ! -f "$destination" ]; then
    printf '%s\n' unsafe
  else
    digest=$(sha256_file "$destination")
    if [ -z "$digest" ]; then
      printf '%s\n' unreadable
    else
      matched=0
      for legacy_digest in $legacy_digests; do
        if [ "$digest" = "$legacy_digest" ]; then
          matched=1
          break
        fi
      done
      if [ "$matched" -eq 1 ]; then
        printf '%s\n' legacy
      else
        printf '%s\n' conflict
      fi
    fi
  fi
}

same_state() {
  label=$1
  expected=$2
  actual=$3
  [ "$expected" = "$actual" ] || fail "$label changed after preflight; no further destination files were changed."
}

install_missing() {
  template=$1
  destination=$2
  staged=''

  if path_exists "$destination"; then
    fail "destination changed after preflight and will not be overwritten: $destination"
  fi

  staged=$(mktemp "$target_dir/.sol-advisor-agent.XXXXXX") || fail "could not stage template for installation: $destination"
  if ! cp "$template" "$staged"; then
    rm -f "$staged"
    fail "could not stage template for installation: $destination"
  fi

  if ! ln "$staged" "$destination"; then
    rm -f "$staged"
    fail "destination changed after preflight and will not be overwritten: $destination"
  fi

  rm -f "$staged" || fail "could not remove staged template after installation: $staged"
  printf '%s\n' "INSTALLED: $destination"
}

remove_legacy() {
  label=$1
  destination=$2
  shift 2
  legacy_digests=$*

  [ "$(classify_legacy "$destination" $legacy_digests)" = legacy ] ||
    fail "legacy $label destination changed after preflight and will not be removed: $destination"
  rm "$destination" || fail "could not remove exact legacy $label template: $destination"
  printf '%s\n' "REMOVED LEGACY: $destination"
}

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd) || exit 1
template_dir=$script_dir/../agents

if [ -n "${CODEX_HOME-}" ]; then
  target_dir=$CODEX_HOME/agents
else
  [ -n "${HOME-}" ] || fail "HOME is unset and CODEX_HOME was not supplied; pass --target-dir explicitly."
  target_dir=$HOME/.codex/agents
fi

check_only=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target-dir)
      [ "$#" -ge 2 ] || fail "--target-dir requires a path."
      [ -n "$2" ] || fail "--target-dir requires a non-empty path."
      case "$2" in
        --*) fail "--target-dir path must be explicit; prefix an option-like relative name with ./ or use an absolute path." ;;
      esac
      target_dir=$2
      shift 2
      ;;
    --check)
      check_only=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1 (run with --help for usage)."
      ;;
  esac
done

case "$target_dir" in
  /*) ;;
  *) target_dir=$(pwd -P)/$target_dir ;;
esac

case "$target_dir" in
  /|//) fail "refusing to use the filesystem root as an agent target directory." ;;
esac

implementer_file=sol-advisor-implementer.toml
sol_file=sol-advisor-sol-reviewer.toml
legacy_terra_file=sol-advisor-terra-implementer.toml
luna_file=sol-advisor-luna-implementer.toml
implementer_template=$template_dir/$implementer_file
sol_template=$template_dir/$sol_file
implementer_destination=$target_dir/$implementer_file
sol_destination=$target_dir/$sol_file
legacy_terra_destination=$target_dir/$legacy_terra_file
luna_destination=$target_dir/$luna_file

# Immutable byte digests of superseded templates, calculated from:
# git show HEAD~2:plugins/sol-advisor/agents/sol-advisor-terra-implementer.toml | shasum -a 256
# git show HEAD:plugins/sol-advisor/agents/sol-advisor-terra-implementer.toml | shasum -a 256
# git show HEAD:plugins/sol-advisor/agents/sol-advisor-luna-implementer.toml | shasum -a 256
legacy_terra_v020_sha256=4425a8c1f21ce8c6af93f96adc253bbc33ea301f1389b3fa8ce350be08584eca
legacy_terra_gpt56_sha256=06c318e5e93f37452635906394e6ea69fb6a65ba9e6ad7172d37b444e0dc871d
legacy_luna_sha256=fba1b42849d93737e83b094a2ab0b1611f87ac37db7438c8bbdf581f0813f8eb

for template in "$implementer_template" "$sol_template"; do
  [ -f "$template" ] && [ ! -L "$template" ] ||
    fail "shipped template is missing or not a regular file: $template"
done

preflight_failed=0
if path_exists "$target_dir"; then
  if [ -L "$target_dir" ] || [ ! -d "$target_dir" ]; then
    report_preflight_error "target directory is not a real directory: $target_dir"
  fi
fi

implementer_state=$(classify_current_or_legacy "$implementer_destination" "$implementer_template" '')
sol_state=$(classify_current_or_legacy "$sol_destination" "$sol_template" '')
legacy_terra_state=$(classify_legacy "$legacy_terra_destination" "$legacy_terra_v020_sha256" "$legacy_terra_gpt56_sha256")
luna_state=$(classify_legacy "$luna_destination" "$legacy_luna_sha256")

if [ "$check_only" -eq 1 ]; then
  [ "$implementer_state" = current ] ||
    report_preflight_error "Implementer template is $implementer_state, not the current exact file: $implementer_destination"
  [ "$sol_state" = current ] ||
    report_preflight_error "Sol template is $sol_state, not the current exact file: $sol_destination"
  [ "$legacy_terra_state" = missing ] ||
    report_preflight_error "legacy Terra file remains or is unsafe: $legacy_terra_destination"
  [ "$luna_state" = missing ] ||
    report_preflight_error "legacy Luna file remains or is unsafe: $luna_destination"
else
  case "$implementer_state" in
    current|missing) ;;
    *) report_preflight_error "Implementer destination is $implementer_state and will not be replaced: $implementer_destination" ;;
  esac
  case "$sol_state" in
    current|missing) ;;
    *) report_preflight_error "Sol destination is $sol_state and will not be replaced: $sol_destination" ;;
  esac
  case "$legacy_terra_state" in
    missing|legacy) ;;
    *) report_preflight_error "legacy Terra destination is $legacy_terra_state and will not be removed: $legacy_terra_destination" ;;
  esac
  case "$luna_state" in
    missing|legacy) ;;
    *) report_preflight_error "legacy Luna destination is $luna_state and will not be removed: $luna_destination" ;;
  esac
fi

[ "$preflight_failed" -eq 0 ] || exit 1

if [ "$check_only" -eq 1 ]; then
  printf '%s\n' "CHECK PASSED: Implementer and Sol exactly match $template_dir; no legacy Terra or Luna file remains."
  exit 0
fi

if [ ! -d "$target_dir" ]; then
  mkdir -p "$target_dir" || fail "could not create target directory: $target_dir"
fi
[ -d "$target_dir" ] && [ ! -L "$target_dir" ] ||
  fail "target directory changed after preflight: $target_dir"

same_state Implementer "$implementer_state" "$(classify_current_or_legacy "$implementer_destination" "$implementer_template" '')"
same_state Sol "$sol_state" "$(classify_current_or_legacy "$sol_destination" "$sol_template" '')"
same_state "legacy Terra" "$legacy_terra_state" "$(classify_legacy "$legacy_terra_destination" "$legacy_terra_v020_sha256" "$legacy_terra_gpt56_sha256")"
same_state "legacy Luna" "$luna_state" "$(classify_legacy "$luna_destination" "$legacy_luna_sha256")"

case "$implementer_state" in
  missing) install_missing "$implementer_template" "$implementer_destination" ;;
  current) printf '%s\n' "ALREADY CURRENT: $implementer_destination" ;;
esac

case "$sol_state" in
  missing) install_missing "$sol_template" "$sol_destination" ;;
  current) printf '%s\n' "ALREADY CURRENT: $sol_destination" ;;
esac

if [ "$legacy_terra_state" = legacy ]; then
  remove_legacy Terra "$legacy_terra_destination" "$legacy_terra_v020_sha256" "$legacy_terra_gpt56_sha256"
fi

if [ "$luna_state" = legacy ]; then
  remove_legacy Luna "$luna_destination" "$legacy_luna_sha256"
fi

[ "$(classify_current_or_legacy "$implementer_destination" "$implementer_template" '')" = current ] ||
  fail "post-install exactness check failed: $implementer_destination"
[ "$(classify_current_or_legacy "$sol_destination" "$sol_template" '')" = current ] ||
  fail "post-install exactness check failed: $sol_destination"
[ "$(classify_legacy "$legacy_terra_destination" "$legacy_terra_v020_sha256" "$legacy_terra_gpt56_sha256")" = missing ] ||
  fail "post-install legacy removal check failed: $legacy_terra_destination"
[ "$(classify_legacy "$luna_destination" "$legacy_luna_sha256")" = missing ] ||
  fail "post-install legacy removal check failed: $luna_destination"

printf '%s\n' "INSTALL PASSED: Implementer and Sol exactly match $template_dir; no legacy Terra or Luna file remains."
