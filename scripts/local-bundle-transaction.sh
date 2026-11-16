# The caller supplies verify_staged_bundle, prepare_for_swap, activate_bundle,
# undo_new_activation, and restore_registration for its install domain.
replace_local_bundle() (
  set -euo pipefail
  local source_bundle=$1 destination=$2
  local destination_dir=${destination:h}
  if [[ -L "$destination_dir" || -L "$destination" ]]; then
    echo "Refusing a symbolic-link installation path" >&2
    return 65
  fi
  mkdir -p "$destination_dir" || return $?
  local lock="$destination_dir/.sentencealong-install.lock"
  if [[ -L "$lock" ]]; then
    echo "Refusing a symbolic-link installation lock" >&2
    return 65
  fi
  : >> "$lock" || return $?
  zmodload zsh/system || return $?
  local lock_fd
  if ! zsystem flock -t 15 -f lock_fd "$lock"; then
    echo "Another SentenceAlong installation is in progress" >&2
    return 75
  fi

  local stage
  stage=$(mktemp -d "$destination_dir/.sentencealong-install.XXXXXX") || return $?
  local staged="$stage/SentenceAlong.app"
  local previous="$stage/Previous.app"
  local rejected="$stage/Rejected.app"
  local started_swap=0 had_previous=0 activated=0 committed=0

  finish_install() {
    local result=$1
    trap - EXIT HUP INT TERM
    if (( ! committed && started_swap )); then
      if [[ ! -e "$staged" && -e "$destination" ]]; then
        if (( activated )); then
          undo_new_activation "$destination" || echo "Could not undo input-source activation" >&2
        fi
        if ! mv "$destination" "$rejected"; then
          echo "Could not move the failed bundle aside. Recovery directory: $stage" >&2
          exit "$result"
        fi
      fi
      if [[ -e "$previous" ]] && ! mv "$previous" "$destination"; then
        echo "Could not restore the previous bundle. Recovery directory: $stage" >&2
        exit "$result"
      fi
      if ! restore_registration; then
        echo "Could not restore input-source registration. Recovery directory: $stage" >&2
        exit "$result"
      fi
    fi
    /bin/rm -rf "$stage"
    exit "$result"
  }

  trap 'finish_install $?' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  ditto "$source_bundle" "$staged" || return $?
  verify_staged_bundle "$staged" || return $?
  prepare_for_swap "$destination" || return $?
  if [[ -e "$destination" ]]; then had_previous=1; fi

  started_swap=1
  if (( had_previous )); then mv "$destination" "$previous" || return $?; fi
  mv "$staged" "$destination" || return $?
  activated=1
  activate_bundle "$destination" || return $?
  committed=1
)
