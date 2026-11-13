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
sum() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }

echo hello > readme.md; git add readme.md; expect 0 staged "clean change passes"; git commit -qm init

echo 'iban=CH93 0076 2011 6238 5295 7' > pay.txt # gitleaks:allow
git add pay.txt; expect 1 staged "valid IBAN not in the manifest is blocked"; undo
echo 'iban=ch9300762011623852957' > pay.txt # gitleaks:allow
git add pay.txt; expect 1 staged "lower-case compact IBAN is blocked"; undo
echo 'id=CH12 3456 7890 1234 5678 9' > pay.txt; git add pay.txt; expect 0 staged "wrong check digits are no IBAN"; undo
echo 'iban=CH90 0076 2011 6238 5TES T' > pay.txt # gitleaks:allow test IBAN
git add pay.txt; expect 1 staged "test IBAN not yet in the manifest is blocked"; undo

echo "$(sum CH900076201162385TEST)  test IBAN of the bank mock" > anonymized.sha256
echo 'iban=CH90 0076 2011 6238 5TES T' > pay.txt # gitleaks:allow test IBAN
echo 'String iban = "CH900076201162385TEST";' > PayTest.java # gitleaks:allow test IBAN
git add anonymized.sha256 pay.txt PayTest.java; expect 0 staged "accepted value passes wherever it occurs"; git commit -qm manifest

printf '<Document><Nm>Hans Muster</Nm></Document>\n' > msg.xml # gitleaks:allow
git add msg.xml; expect 1 staged "name in a message is blocked"; undo
echo "$(sum 'Qwbz Lkmrt')  anonymized creditor name" >> anonymized.sha256
printf '<Document><Nm>  Qwbz   Lkmrt </Nm></Document>\n' > msg.xml # gitleaks:allow anonymized
git add anonymized.sha256 msg.xml; expect 0 staged "anonymized value passes (normalized)"; git commit -qm anon
printf '<Document><Nm>Qwbz Lkmrt</Nm><StrtNm>Bahnhofstrasse 1</StrtNm></Document>\n' > msg.xml # gitleaks:allow
git add msg.xml; expect 1 staged "other value in the same file is still blocked"; undo

echo 'X=1' > .env; git add -f .env; expect 1 staged ".env file is blocked"; undo
echo 'db.password=Sommer2026' > app.properties # gitleaks:allow
git add app.properties; expect 1 staged "plain password is blocked"; undo
# shellcheck disable=SC2016 # the reference must stay literal
echo 'password=${DB_PASSWORD}' > app.properties; git add app.properties; expect 0 staged "password reference passes"; undo
echo 'contact: hans.muster@bank.ch' > mail.txt # gitleaks:allow
git add mail.txt; expect 1 staged "personal e-mail address is blocked"; undo
echo 'USERNAME=hmuster' > env.txt # gitleaks:allow
git add env.txt; expect 1 staged "environment dump is blocked"; undo
printf ':59:HANS MUSTER\n' > mt.txt # gitleaks:allow
git add mt.txt; expect 1 staged "MT field 59 is blocked"; undo
echo 'password=Fake4Test # gitleaks:allow input for a fake system' > t.properties
git add t.properties; expect 0 staged "line with gitleaks:allow passes"; git commit -qm allow

expect 0 tracked "whole repository is clean"
git rm -q PayTest.java pay.txt; git commit -qm "drop the test IBAN"
expect 1 tracked "manifest value that occurs nowhere is blocked"
echo "all $passed cases passed"
