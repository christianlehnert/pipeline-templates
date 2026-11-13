#!/usr/bin/env bash
# Tests scripts/common-security-scan.sh in a throw-away Git repository.
# Every case states the expected exit code; the script fails on the first wrong one.
# The sample values below are fake and marked with gitleaks:allow.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scan="$here/../../scripts/common-security-scan.sh"
repo="$(mktemp -d)"
trap 'rm -rf "$repo"' EXIT
cd "$repo"
git init -q && git config user.email t@example.com && git config user.name test
passed=0

expect() { # expect <exit code> <mode> <name>
  set +e; out="$("$scan" "$2" 2>&1)"; rc=$?; set -e
  if [[ $rc -ne $1 ]]; then echo "FAIL $3: expected $1, got $rc"; echo "$out"; exit 1; fi
  echo "ok   $3 (exit $rc)"; passed=$((passed + 1))
}
undo() { git reset -q --hard; git clean -qfdx; }

echo hello > readme.md; git add readme.md; expect 0 staged "clean change passes"; git commit -qm init
echo 'iban=CH93 0076 2011 6238 5295 7' > pay.txt # gitleaks:allow
git add pay.txt; expect 1 staged "real Swiss IBAN is blocked"; undo
echo 'iban=CH93 0076 2011 6238 5295 TEST' > pay.txt; git add pay.txt; expect 0 staged "test IBAN passes"; undo
echo 'X=1' > .env; git add -f .env; expect 1 staged ".env file is blocked"; undo
echo 'db.password=Sommer2026' > app.properties # gitleaks:allow
git add app.properties; expect 1 staged "plain password is blocked"; undo
echo 'password=${DB_PASSWORD}' > app.properties; git add app.properties; expect 0 staged "password reference passes"; undo
printf '<Document><Nm>Hans Muster</Nm></Document>\n' > msg.xml # gitleaks:allow
git add msg.xml; expect 1 staged "party data in a message is blocked"; undo
printf '<Document><Nm>Qwbz Lkmrt</Nm></Document>\n' > msg.xml; sha256sum msg.xml > anonymized.sha256
git add msg.xml anonymized.sha256; expect 0 staged "anonymized message in the manifest passes"; git commit -qm anon
printf '<Document><Nm>Hans Muster</Nm></Document>\n' > msg.xml # gitleaks:allow
git add msg.xml; expect 1 staged "message edited after anonymizing is blocked"; undo
echo 'contact: hans.muster@bank.ch' > mail.txt # gitleaks:allow
git add mail.txt; expect 1 staged "personal e-mail address is blocked"; undo
echo 'USERNAME=hmuster' > env.txt # gitleaks:allow
git add env.txt; expect 1 staged "environment dump is blocked"; undo
printf ':59:/CH9300762011623852957\n' > mt.txt # gitleaks:allow
git add mt.txt; expect 1 staged "MT field 59 is blocked"; undo
echo 'password=Fake4Test # gitleaks:allow input for a fake system' > t.properties
git add t.properties; expect 0 staged "line with gitleaks:allow passes"; git commit -qm allow
echo '0000000000000000000000000000000000000000000000000000000000000000  gone.xml' >> anonymized.sha256
git add anonymized.sha256; git commit -qm broken; expect 1 tracked "manifest entry without a file is blocked"; git reset -q --hard HEAD~1
expect 0 tracked "whole repository is clean"
echo "all $passed cases passed"
