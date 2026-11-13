#!/usr/bin/env bash
# common-security-scan.sh: the one scan behind the pre-commit hook and common-security.yml.
#   common-security-scan.sh staged    scan what is staged for the next commit (hook)
#   common-security-scan.sh tracked   scan every tracked file of the current commit (pipeline)
# Needs git, jq, sha256sum and gitleaks in exactly the version below (GITLEAKS=<path>).
# Exit 0 = clean, 1 = findings or manifest problems, 2 = usage or tool error.
#
# Customer data rules (ids starting with iban- or party-) follow the value manifest:
#   anonymized.sha256  one line per accepted value: SHA-256 of the normalized value,
#                      two blanks, a label for the reader; lines starting with # are comments.
#   normalization      IBAN: no white space, upper case. Other values: trimmed, runs of
#                      white space as one blank.
#   IBAN               a match with wrong check digits (modulo 97) is no IBAN and no finding.
#   accepted           a value in the manifest is accepted wherever it occurs.
#   stale              a manifest line whose value occurs nowhere fails the scan (tracked mode).
set -euo pipefail

REQUIRED_GITLEAKS_VERSION="8.30.1"

mode="${1:-}"
[[ "$mode" == staged || "$mode" == tracked ]] || { echo "usage: $0 staged|tracked" >&2; exit 2; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="${COMMON_SECURITY_CONFIG:-$here/../config/common-security.toml}"
gitleaks="${GITLEAKS:-gitleaks}"
for tool in git jq sha256sum "$gitleaks"; do
  command -v "$tool" >/dev/null 2>&1 || { echo "common-security: '$tool' not found" >&2; exit 2; }
done
version="$("$gitleaks" version 2>/dev/null | tr -d 'v[:space:]')"
if [[ "$version" != "$REQUIRED_GITLEAKS_VERSION" ]]; then
  echo "common-security: gitleaks $REQUIRED_GITLEAKS_VERSION is required (found '${version:-none}'), so that laptop and pipeline give the same result." >&2
  exit 2
fi
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

# 1. Export exactly what will be committed (staged) or what is committed (tracked).
if [[ "$mode" == staged ]]; then
  git diff --cached --name-only --diff-filter=ACMR -z > "$work/files"
  if [[ ! -s "$work/files" ]]; then exit 0; fi
  xargs -0 git checkout-index --prefix="$work/tree/" -- < "$work/files"
else
  git ls-files -z > "$work/files"
  git checkout-index --all --prefix="$work/tree/"
fi

# 2. File types that must never be in a repository (same list as the push ruleset).
forbidden='(^|/)(\.env(\..*)?|id_rsa|id_ed25519|.*\.(pem|key|p12|pfx|jks|keystore|kdbx|ppk))$'
if tr '\0' '\n' < "$work/files" | grep -E "$forbidden" | grep -vE '(^|/)\.env\.example$' > "$work/forbidden"; then
  echo "common-security: files that must not be committed:"
  sed 's/^/  /' "$work/forbidden"
  fail=1
fi

# 3. gitleaks with the shared rules on the export. The raw report holds the values; it
#    stays in the temporary directory, is never printed and is deleted at the end.
set +e
"$gitleaks" dir --no-banner -c "$config" \
  --gitleaks-ignore-path "$root/.gitleaksignore" \
  --report-format json --report-path "$work/report.json" "$work/tree" >/dev/null 2>"$work/gitleaks.err"
rc=$?
set -e
if [[ $rc -ne 0 && $rc -ne 1 ]]; then cat "$work/gitleaks.err" >&2; exit 2; fi

# 4. Manifest of accepted values (read from the index, so it also applies in staged mode).
: > "$work/accepted"
if git cat-file -e :anonymized.sha256 2>/dev/null; then
  git show :anonymized.sha256 | grep -vE '^\s*(#|$)' | awk '{print $1}' > "$work/accepted"
fi

iban_valid() { # modulo 97 check of an IBAN without white space, upper case
  local iban="$1" moved digits rest i c
  [[ "$iban" =~ ^[A-Z]{2}[0-9]{2}[0-9A-Z]{8,30}$ ]] || return 1
  moved="${iban:4}${iban:0:4}"
  digits=""
  for ((i = 0; i < ${#moved}; i++)); do
    c="${moved:i:1}"
    if [[ "$c" =~ [A-Z] ]]; then digits+=$(( $(printf '%d' "'$c") - 55 )); else digits+="$c"; fi
  done
  rest=0
  for ((i = 0; i < ${#digits}; i += 7)); do
    rest=$(( 10#${rest}${digits:i:7} % 97 ))
  done
  [[ $rest -eq 1 ]]
}

# 5. Decide per finding. Customer data: normalize, check IBAN digits, look up the manifest.
: > "$work/findings"; : > "$work/missing"; : > "$work/seen"
jq -r --arg prefix "$work/tree/" '.[] | [(.File | ltrimstr($prefix)), (.StartLine | tostring), .RuleID, (.Secret | @base64)] | @tsv' \
  "$work/report.json" > "$work/rows"
while IFS=$'\t' read -r file line rule secret64; do
  if [[ "$rule" == iban-* || "$rule" == party-* ]]; then
    value="$(printf '%s' "$secret64" | base64 -d)"
    if [[ "$rule" == iban-* ]]; then
      value="$(printf '%s' "$value" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
      iban_valid "$value" || continue
    else
      value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')"
    fi
    sum="$(printf '%s' "$value" | sha256sum | awk '{print $1}')"
    echo "$sum" >> "$work/seen"
    if grep -qx "$sum" "$work/accepted"; then continue; fi
    echo "  $file:$line  $rule" >> "$work/findings"
    echo "$sum  $file:$line $rule" >> "$work/missing"
  else
    echo "  $file:$line  $rule" >> "$work/findings"
  fi
done < "$work/rows"

if [[ -s "$work/findings" ]]; then
  echo "common-security: findings (values hidden):"
  sort -u "$work/findings"
  if [[ -s "$work/missing" ]]; then
    echo "Checksums of the customer data values above. Only after a person has judged a value as"
    echo "not critical, its line goes into anonymized.sha256 (checksum, two blanks, label):"
    sort -u "$work/missing" | sed 's/^/  /'
  fi
  echo "Fix them, or add a reviewed exception: a value in anonymized.sha256, gitleaks:allow on the line, or a fingerprint in .gitleaksignore."
  fail=1
fi

# 6. Stale manifest lines: a value that occurs nowhere any more (only decidable on the whole tree).
if [[ "$mode" == tracked && -s "$work/accepted" ]]; then
  if grep -vxFf "$work/seen" "$work/accepted" > "$work/stale"; then
    echo "common-security: anonymized.sha256 lists values that occur in no tracked file; remove these lines:"
    sed 's/^/  /' "$work/stale"
    fail=1
  fi
fi

[[ $fail -eq 0 ]] && echo "common-security: clean ($mode)"
exit $fail
