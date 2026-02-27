#!/usr/bin/env bash
###############################################################################
#  NKP helpers — source this file, then use kapply
#
#  source helpers.sh
#  kapply day2/00-license.yaml NKP_LICENSE="eyJhb..."
###############################################################################

kapply() {
  local dry_run=false
  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=true
    shift
  fi

  local file="$1"; shift

  if [[ ! -f "$file" ]]; then
    echo "Error: $file not found"
    return 1
  fi

  # Build substitution list from passed VAR=value args
  local vars=""
  for arg in "$@"; do
    vars+=" \${${arg%%=*}}"
  done

  if [[ "$dry_run" == "true" ]]; then
    echo "--- dry-run: $file ---"
    env "$@" envsubst "$vars" < "$file"
  else
    env "$@" envsubst "$vars" < "$file" | kubectl apply -f -
  fi
}
