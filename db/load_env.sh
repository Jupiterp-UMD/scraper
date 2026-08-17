#!/usr/bin/env bash
#
# Read `db/.env` into the environment. Source it, do not execute it:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/load_env.sh"
#   load_env_file
#
# This is the shell counterpart to `load_env_file()` in clone_via_api.py, and
# deliberately matches its semantics so that the same `db/.env` drives the
# Python and the shell halves of this directory. Both parse the file by hand
# rather than depending on python-dotenv or a `set -a` sourcing trick: the file
# holds connection strings whose passwords contain `#`, `$`, and `&`, and
# sourcing it as shell would expand or truncate exactly those.
#
# Values already present in the environment win, so a one-off override still
# works with the file in place:
#
#   DATABASE_DIRECT_URL=postgresql://... ./db/migrate.sh
#
# Handles the `export KEY=value` form, because that is what you get from
# copying the lines out of the README.

# Directory of this file, captured at source time.
_LOAD_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

load_env_file() {
  local path="${1:-$_LOAD_ENV_DIR/.env}"

  # A missing file is not an error. Every variable it would have set can be
  # exported directly, and the callers already fail with a useful message when
  # one is genuinely absent.
  [[ -f "$path" ]] || return 0

  local line key value

  # `|| [[ -n "$line" ]]` so a final line with no trailing newline is still read.
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "$line" || "$line" == '#'* ]] && continue

    [[ "$line" == "export "* ]] && line="${line#export }"
    [[ "$line" == *=* ]] || continue

    key="${line%%=*}"
    value="${line#*=}"

    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"

    # Not a shell identifier: skip rather than let `export` fail the script
    # under `set -e`.
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    # Inline comments, matching python-dotenv so the Python and shell halves of
    # this directory read one `.env` the same way. Only when the value is
    # unquoted, and only on ` #` with leading whitespace -- a bare `#` is a
    # perfectly ordinary password character.
    #
    # Getting this wrong is not loud. `KEY=abc # note` silently becomes the
    # value "abc # note", which fails wherever it is used with an error about
    # the credential rather than about the file it came from.
    if [[ "${value:0:1}" != '"' && "${value:0:1}" != "'" && "$value" == *" #"* ]]; then
      value="${value%%" #"*}"
      value="${value%"${value##*[![:space:]]}"}"
    fi

    # One layer of matching quotes, which is what wrapping a connection string
    # in single quotes to protect it from the shell leaves behind. Quoted
    # values keep any `#` they contain.
    if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
      value="${value:1:${#value}-2}"
    elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
      value="${value:1:${#value}-2}"
    fi

    # The environment wins.
    [[ -n "${!key:-}" ]] && continue

    export "$key=$value"
  done < "$path"
}
