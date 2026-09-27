#!/usr/bin/env bash
# The next version from the commit prefixes since the last v* tag.
#   major: …  |  <type>!: …  |  "BREAKING CHANGE" in the body  -> major
#   feat: …                                                   -> minor
#   fix: …                                                    -> patch
#   anything else (chore:, docs:, no prefix)                  -> no release
# Prints "X.Y.Z" (the next version) or nothing (no release). With --explain it
# also prints the last tag and the deciding commits to stderr.
# The first release (no tag yet) is 1.0.0 whatever the prefix.
set -euo pipefail

explain=false
[[ "${1:-}" == "--explain" ]] && explain=true

last_tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)
if [[ -z "$last_tag" ]]; then
  range="HEAD"
  base="0.0.0"
else
  range="${last_tag}..HEAD"
  base="${last_tag#v}"
fi

bump=0   # 0 none, 1 patch, 2 minor, 3 major
reasons=()
# One record per commit: subject, then body, separated by a unit separator.
while IFS= read -r -d $'\x1e' record; do
  subject="${record%%$'\x1f'*}"
  body="${record#*$'\x1f'}"
  subject="${subject#"${subject%%[![:space:]]*}"}"
  level=0
  if [[ "$subject" =~ ^major(\([^\)]*\))?!?: ]] || [[ "$subject" =~ ^[a-zA-Z]+(\([^\)]*\))?!: ]] || [[ "$body" == *"BREAKING CHANGE"* ]]; then
    level=3
  elif [[ "$subject" =~ ^feat(\([^\)]*\))?: ]]; then
    level=2
  elif [[ "$subject" =~ ^fix(\([^\)]*\))?: ]]; then
    level=1
  fi
  if (( level > 0 )); then reasons+=("$subject"); fi
  if (( level > bump )); then bump=$level; fi
done < <(git log --format='%s%x1f%b%x1e' "$range" 2>/dev/null || true)

if $explain; then
  echo "last tag: ${last_tag:-none}" >&2
  for r in "${reasons[@]:-}"; do [[ -n "$r" ]] && echo "  $r" >&2; done
fi

(( bump == 0 )) && exit 0

if [[ -z "$last_tag" ]]; then
  echo "1.0.0"
  exit 0
fi

IFS=. read -r major minor patch <<<"$base"
case $bump in
  3) major=$((major + 1)); minor=0; patch=0 ;;
  2) minor=$((minor + 1)); patch=0 ;;
  1) patch=$((patch + 1)) ;;
esac
echo "${major}.${minor}.${patch}"
