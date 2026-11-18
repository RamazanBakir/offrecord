#!/bin/zsh
# Lists interface strings passed to L("…") that have no Turkish translation,
# translations nobody uses any more, and duplicate keys (which crash at launch).
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/../Sources/Offrecord"
TABLE=Localization/Turkish.swift

used=$(grep -rhoE 'L\("([^"\\]|\\.)*"' --include='*.swift' . | grep -v "^$TABLE" | sed -E 's/^L\("//; s/"$//' | sort -u)
keys=$(grep -oE '^        "([^"\\]|\\.)*":' "$TABLE" | sed -E 's/^        "//; s/":$//' | sort)
result=0

missing=$(comm -23 <(print -r -- "$used") <(print -r -- "$keys" | sort -u))
[[ -n "$missing" ]] && { print "Missing Turkish translation:"; print -r -- "$missing" | sed 's/^/  /'; result=1 }

unused=$(comm -13 <(print -r -- "$used") <(print -r -- "$keys" | sort -u))
[[ -n "$unused" ]] && { print "Unused translations:"; print -r -- "$unused" | sed 's/^/  /' }

dupes=$(print -r -- "$keys" | uniq -d)
[[ -n "$dupes" ]] && { print "Duplicate keys:"; print -r -- "$dupes" | sed 's/^/  /'; result=1 }

(( result == 0 )) && print "Translations OK ($(print -r -- "$keys" | wc -l | tr -d ' ') strings)."
exit $result
