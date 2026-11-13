#!/usr/bin/env bash
# common-security-scan.sh: the one scan behind the pre-commit hook and common-security.yml.
#   common-security-scan.sh staged    scan what is staged for the next commit (hook)
#   common-security-scan.sh tracked   scan every tracked file of the current commit (pipeline)
# Needs git, gitleaks (GITLEAKS=<path> to choose one), jq and sha256sum.
# Exit 0 = clean, 1 = findings or manifest problems, 2 = usage or tool error.
set -euo pipefail

mode="${1:-}"
[[ "$mode" == staged || "$mode" == tracked ]] || { echo "usage: $0 staged|tracked" >&2; exit 2; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="${COMMON_SECURITY_CONFIG:-$here/../config/common-security.toml}"
gitleaks="${GITLEAKS:-gitleaks}"
for tool in git jq sha256sum "$gitleaks"; do
  command -v "$tool" >/dev/null 2>&1 || { echo "common-security: '$tool' not found" >&2; exit 2; }
done
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

# 3. Manifest of anonymized files: every entry must match the exported content.
# In staged mode only the staged files are exported, so the manifest is read from the index
# and only the entries of exported files are checked.
anonymized=()
if git cat-file -e :anonymized.sha256 2>/dev/null; then
  git show :anonymized.sha256 > "$work/manifest"
  # keep only the entries whose file is in the export (all of them in tracked mode)
  while IFS= read -r line; do
    file="$(sed -E 's/^[0-9a-f]{64}[ *]+//' <<< "$line")"
    if [[ -f "$work/tree/$file" ]]; then echo "$line"; elif [[ "$mode" == tracked ]]; then echo "$line"; fi
  done < "$work/manifest" > "$work/manifest.check"
  if [[ -s "$work/manifest.check" ]] && ! (cd "$work/tree" && sha256sum --check --quiet --strict "$work/manifest.check"); then
    echo "common-security: anonymized.sha256 does not match the files (edited after anonymizing?)"
    fail=1
  fi
  mapfile -t anonymized < <(sed -E 's/^[0-9a-f]{64}[ *]+//' "$work/manifest")
fi

# 4. gitleaks with the shared rules on the export. Values are redacted.
set +e
"$gitleaks" dir --no-banner --redact -c "$config" \
  --gitleaks-ignore-path "$root/.gitleaksignore" \
  --report-format json --report-path "$work/report.json" "$work/tree" >/dev/null 2>"$work/gitleaks.err"
rc=$?
set -e
if [[ $rc -ne 0 && $rc -ne 1 ]]; then cat "$work/gitleaks.err" >&2; exit 2; fi

# 5. Party data in a file of the manifest is accepted; everything else stays a finding.
jq -r --arg prefix "$work/tree/" --argjson anon "$(printf '%s\n' "${anonymized[@]}" | jq -R . | jq -s .)" '
  map(.File |= ltrimstr($prefix))
  | map(select((.RuleID | startswith("party-")) and (.File as $f | $anon | index($f)) | not))
  | .[] | "  \(.File):\(.StartLine)  \(.RuleID)"' "$work/report.json" > "$work/findings"
if [[ -s "$work/findings" ]]; then
  echo "common-security: findings (values hidden):"
  cat "$work/findings"
  echo "Fix them, or add a reviewed exception: gitleaks:allow on the line, an entry in anonymized.sha256, or a fingerprint in .gitleaksignore."
  fail=1
fi

[[ $fail -eq 0 ]] && echo "common-security: clean ($mode)"
exit $fail
