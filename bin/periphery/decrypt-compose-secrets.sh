#!/usr/bin/env bash
set -euo pipefail

DECRYPT_URL="${DECRYPT_URL:-https://encryptor-028035723b26.viset.vn/decrypt}"

# ponytail: this wrapper supports the common env_file scalar/list forms used here.
# upgrade to a parser-backed approach if compose files start using advanced env_file objects.

declare -a tmp_files=()
declare -A decrypted_cache=()
declare -A rendered_file_cache=()

require_env() {
  local var_name="$1"
  if [[ -z "${!var_name:-}" ]]; then
    echo "Error: Missing required environment variable: $var_name" >&2
    exit 1
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: Required command not found: $cmd" >&2
    exit 1
  }
}

cleanup() {
  local file
  for file in "${tmp_files[@]:-}"; do
    [[ -n "$file" ]] && rm -f -- "$file"
  done
}
trap cleanup EXIT

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

extract_json_text() {
  local json="$1"
  local rest out=""
  local i char escape=0

  [[ "$json" == *'"text"'* ]] || {
    echo "Error: Decrypt response missing text field." >&2
    return 1
  }

  rest="${json#*\"text\"}"
  rest="${rest#*:}"

  while [[ -n "$rest" ]]; do
    case "${rest:0:1}" in
      ' ' | $'\t' | $'\r' | $'\n') rest="${rest:1}" ;;
      *) break ;;
    esac
  done

  [[ "${rest:0:1}" == '"' ]] || {
    echo "Error: Decrypt response text field is not a JSON string." >&2
    return 1
  }

  rest="${rest:1}"

  for ((i = 0; i < ${#rest}; i++)); do
    char="${rest:i:1}"

    if (( escape )); then
      case "$char" in
        '"'|'\\'|'/') out+="$char" ;;
        'b') out+=$'\b' ;;
        'f') out+=$'\f' ;;
        'n') out+=$'\n' ;;
        'r') out+=$'\r' ;;
        't') out+=$'\t' ;;
        'u')
          echo "Error: Unicode escapes are not supported in decrypt response." >&2
          return 1
          ;;
        *)
          echo "Error: Unsupported escape sequence in decrypt response." >&2
          return 1
          ;;
      esac
      escape=0
      continue
    fi

    case "$char" in
      '\\') escape=1 ;;
      '"')
        printf '%s' "$out"
        return 0
        ;;
      *) out+="$char" ;;
    esac
  done

  echo "Error: Unterminated JSON string in decrypt response." >&2
  return 1
}

yaml_single_quote() {
  local value="$1"
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

yaml_double_quote() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

dotenv_double_quote() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//\$/\\$}
  printf '"%s"' "$value"
}

escape_regex() {
  printf '%s' "$1" | sed -e 's/[][(){}.^$?*+|\\/]/\\&/g'
}

absolute_path() {
  local path="$1"
  local dir base
  dir="$(dirname -- "$path")"
  base="$(basename -- "$path")"
  printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$base"
}

resolve_path() {
  local base_dir="$1"
  local path="$2"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$base_dir" "$path"
  fi
}

decrypt_token() {
  local token="$1"
  local cipher response text payload

  if [[ -n "${decrypted_cache[$token]:-}" ]]; then
    printf '%s' "${decrypted_cache[$token]}"
    return 0
  fi

  cipher="${token#secret:}"
  payload='{"cipher":"'"$(json_escape "$cipher")"'"}'

  response="$(
    curl -fsS \
      -X POST \
      "$DECRYPT_URL" \
      -H 'Content-Type: application/json' \
      -H "X-API-Key: $DECRYPT_API_KEY" \
      -d "$payload"
  )"

  text="$(extract_json_text "$response")"

  if [[ "$text" == *$'\n'* || "$text" == *$'\r'* ]]; then
    echo "Error: Multiline decrypted values are not supported." >&2
    return 1
  fi

  decrypted_cache[$token]="$text"
  printf '%s' "$text"
}

collect_tokens() {
  local src="$1"
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    while [[ "$line" =~ (secret:[A-Za-z0-9+/=._-]+) ]]; do
      printf '%s\n' "${BASH_REMATCH[1]}"
      line="${line#*"${BASH_REMATCH[1]}"}"
    done
  done < "$src" | sort -u
}

render_env_file() {
  local src="$1"
  local resolved_src cache_key dir base out line rendered token raw token_re
  local -a tokens=()
  local -a values=()
  local token_count=0
  local i

  resolved_src="$(absolute_path "$src")"
  cache_key="$resolved_src"

  if [[ -n "${rendered_file_cache[$cache_key]:-}" ]]; then
    printf '%s\n' "${rendered_file_cache[$cache_key]}"
    return 0
  fi

  dir="$(dirname -- "$resolved_src")"
  base="$(basename -- "$resolved_src")"
  out="$(mktemp "$dir/.${base}.rendered.XXXXXX")"
  tmp_files+=("$out")
  rendered_file_cache[$cache_key]="$out"

  while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    tokens+=("$token")
    values+=("$(decrypt_token "$token")")
  done < <(collect_tokens "$resolved_src")

  token_count=${#tokens[@]}
  if (( token_count == 0 )); then
    cp -- "$resolved_src" "$out"
    printf '%s\n' "$out"
    return 0
  fi

  : > "$out"

  while IFS= read -r line || [[ -n "$line" ]]; do
    rendered="$line"

    if [[ "$rendered" =~ ^[[:space:]]*$ || "$rendered" =~ ^[[:space:]]*# ]]; then
      printf '%s\n' "$rendered" >> "$out"
      continue
    fi

    for ((i = 0; i < token_count; i++)); do
      token="${tokens[i]}"
      raw="${values[i]}"

      [[ "$rendered" == *"$token"* ]] || continue

      token_re="$(escape_regex "$token")"

      if [[ "$rendered" =~ ^([[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*)"$token_re"([[:space:]]*(#.*)?)$ ]]; then
        rendered="${BASH_REMATCH[1]}$(dotenv_double_quote "$raw")${BASH_REMATCH[3]}"
        continue
      fi

      if [[ "$rendered" =~ ^([[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*)'$token_re'([[:space:]]*(#.*)?)$ ]]; then
        rendered="${BASH_REMATCH[1]}$(dotenv_double_quote "$raw")${BASH_REMATCH[3]}"
        continue
      fi

      if [[ "$rendered" =~ ^([[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*)$token_re([[:space:]]*(#.*)?)$ ]]; then
        rendered="${BASH_REMATCH[1]}$(dotenv_double_quote "$raw")${BASH_REMATCH[3]}"
        continue
      fi

      echo "Error: Unsupported secret placeholder syntax in env file $resolved_src" >&2
      return 1
    done

    printf '%s\n' "$rendered" >> "$out"
  done < "$resolved_src"

  for token in "${tokens[@]}"; do
    if grep -Fq -- "$token" "$out"; then
      echo "Error: Failed to render env secret placeholder in $resolved_src" >&2
      return 1
    fi
  done

  printf '%s\n' "$out"
}

render_env_reference() {
  local compose_dir="$1"
  local ref="$2"
  render_env_file "$(resolve_path "$compose_dir" "$ref")"
}

render_compose_file() {
  local src="$1"
  local resolved_src compose_dir dir base out line rendered token raw token_re ref rendered_ref
  local list_env_file_double_re='^([[:space:]]*-[[:space:]]*)"([^"]+)"([[:space:]]*(#.*)?)$'
  local list_env_file_single_re="^([[:space:]]*-[[:space:]]*)'([^']+)'([[:space:]]*(#.*)?)$"
  local scalar_env_file_double_re='^([[:space:]]*env_file:[[:space:]]*)"([^"]+)"([[:space:]]*(#.*)?)$'
  local scalar_env_file_single_re="^([[:space:]]*env_file:[[:space:]]*)'([^']+)'([[:space:]]*(#.*)?)$"
  local list_env_file_plain_re='^([[:space:]]*-[[:space:]]*)([^[:space:]#][^#]*[^[:space:]#]|[^[:space:]#])([[:space:]]*(#.*)?)$'
  local scalar_env_file_plain_re='^([[:space:]]*env_file:[[:space:]]*)([^[:space:]#][^#]*[^[:space:]#]|[^[:space:]#])([[:space:]]*(#.*)?)$'
  local -a tokens=()
  local -a values=()
  local token_count=0
  local i env_file_indent=0 in_env_file_block=0 line_indent

  resolved_src="$(absolute_path "$src")"
  compose_dir="$(dirname -- "$resolved_src")"
  dir="$compose_dir"
  base="$(basename -- "$resolved_src")"
  out="$(mktemp "$dir/.${base}.rendered.XXXXXX")"
  tmp_files+=("$out")

  while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    tokens+=("$token")
    values+=("$(decrypt_token "$token")")
  done < <(collect_tokens "$resolved_src")

  token_count=${#tokens[@]}

  : > "$out"

  while IFS= read -r line || [[ -n "$line" ]]; do
    rendered="$line"

    if (( in_env_file_block )); then
      if [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]]; then
        printf '%s\n' "$rendered" >> "$out"
        continue
      fi

      line_indent="${line%%[^ ]*}"
      if (( ${#line_indent} <= env_file_indent )); then
        in_env_file_block=0
      else
        if [[ "$rendered" =~ $list_env_file_double_re ]]; then
          ref="${BASH_REMATCH[2]}"
          rendered_ref="$(render_env_reference "$compose_dir" "$ref")"
          rendered="${BASH_REMATCH[1]}$(yaml_double_quote "$rendered_ref")${BASH_REMATCH[3]}"
        elif [[ "$rendered" =~ $list_env_file_single_re ]]; then
          ref="${BASH_REMATCH[2]}"
          rendered_ref="$(render_env_reference "$compose_dir" "$ref")"
          rendered="${BASH_REMATCH[1]}$(yaml_double_quote "$rendered_ref")${BASH_REMATCH[3]}"
        elif [[ "$rendered" =~ $list_env_file_plain_re ]]; then
          ref="${BASH_REMATCH[2]}"
          rendered_ref="$(render_env_reference "$compose_dir" "$ref")"
          rendered="${BASH_REMATCH[1]}$(yaml_double_quote "$rendered_ref")${BASH_REMATCH[3]}"
        fi

        printf '%s\n' "$rendered" >> "$out"
        continue
      fi
    fi

    if [[ "$rendered" =~ ^([[:space:]]*)env_file:[[:space:]]*$ ]]; then
      in_env_file_block=1
      env_file_indent=${#BASH_REMATCH[1]}
      printf '%s\n' "$rendered" >> "$out"
      continue
    fi

    if [[ "$rendered" =~ $scalar_env_file_double_re ]]; then
      ref="${BASH_REMATCH[2]}"
      rendered_ref="$(render_env_reference "$compose_dir" "$ref")"
      rendered="${BASH_REMATCH[1]}$(yaml_double_quote "$rendered_ref")${BASH_REMATCH[3]}"
    elif [[ "$rendered" =~ $scalar_env_file_single_re ]]; then
      ref="${BASH_REMATCH[2]}"
      rendered_ref="$(render_env_reference "$compose_dir" "$ref")"
      rendered="${BASH_REMATCH[1]}$(yaml_double_quote "$rendered_ref")${BASH_REMATCH[3]}"
    elif [[ "$rendered" =~ $scalar_env_file_plain_re ]]; then
      ref="${BASH_REMATCH[2]}"
      rendered_ref="$(render_env_reference "$compose_dir" "$ref")"
      rendered="${BASH_REMATCH[1]}$(yaml_double_quote "$rendered_ref")${BASH_REMATCH[3]}"
    fi

    for ((i = 0; i < token_count; i++)); do
      token="${tokens[i]}"
      raw="${values[i]}"

      [[ "$rendered" == *"$token"* ]] || continue

      token_re="$(escape_regex "$token")"

      if [[ "$rendered" =~ ^([[:space:]]*-[[:space:]]*)([A-Za-z_][A-Za-z0-9_]*)=("$token_re"|'$token_re'|$token_re)([[:space:]]*(#.*)?)$ ]]; then
        rendered="${BASH_REMATCH[1]}$(yaml_double_quote "${BASH_REMATCH[2]}=$raw")${BASH_REMATCH[4]}"
        continue
      fi

      if [[ "$rendered" =~ ^([[:space:]]*[^#][^:]*:[[:space:]]*)("$token_re"|'$token_re'|$token_re)([[:space:]]*(#.*)?)$ ]]; then
        rendered="${BASH_REMATCH[1]}$(yaml_single_quote "$raw")${BASH_REMATCH[3]}"
        continue
      fi

      rendered="${rendered//\'$token\'/$(yaml_single_quote "$raw")}"
      rendered="${rendered//"$token"/$(yaml_double_quote "$raw")}"
    done

    printf '%s\n' "$rendered" >> "$out"
  done < "$resolved_src"

  if (( token_count == 0 )) && ! grep -Fq '.rendered.' "$out"; then
    rm -f -- "$out"
    tmp_files=("${tmp_files[@]/$out}")
    cp -- "$resolved_src" "$out"
  fi

  for token in "${tokens[@]}"; do
    if grep -Fq -- "$token" "$out"; then
      echo "Error: Failed to render compose secret placeholder in $resolved_src" >&2
      return 1
    fi
  done

  printf '%s\n' "$out"
}

main() {
  local arg next_arg
  local -a args=("$@")
  local -a new_args=()
  local i=0

  require_env "DECRYPT_API_KEY"
  require_cmd "curl"
  require_cmd "grep"
  require_cmd "mktemp"
  require_cmd "sed"
  require_cmd "sort"

  while (( i < ${#args[@]} )); do
    arg="${args[i]}"

    case "$arg" in
      -f|--file|--compose-file|-c)
        (( i + 1 < ${#args[@]} )) || {
          echo "Error: Missing path after $arg" >&2
          exit 1
        }
        next_arg="${args[i + 1]}"
        new_args+=("$arg" "$(render_compose_file "$next_arg")")
        ((i += 2))
        ;;
      --file=*|--compose-file=*)
        next_arg="${arg#*=}"
        new_args+=("${arg%%=*}=$(render_compose_file "$next_arg")")
        ((i += 1))
        ;;
      --env-file)
        (( i + 1 < ${#args[@]} )) || {
          echo "Error: Missing path after $arg" >&2
          exit 1
        }
        next_arg="${args[i + 1]}"
        new_args+=("$arg" "$(render_env_file "$next_arg")")
        ((i += 2))
        ;;
      --env-file=*)
        next_arg="${arg#*=}"
        new_args+=("--env-file=$(render_env_file "$next_arg")")
        ((i += 1))
        ;;
      *)
        new_args+=("$arg")
        ((i += 1))
        ;;
    esac
  done

  exec "${new_args[@]}"
}

main "$@"
