#!/usr/bin/env bash
# config/app-assignments.sh's drift decision without a Keycloak (ekip-yetkileri ticket 17): its own
# in_roots, panel_changed and missing_class, taken out of the script, against a decision table. A
# seeded Privileged role changed in its seed set (/<NAME>, /UYELER/<NAME>, a sub-group) is BILGI
# (S2-tohum); outside its seed set, or a write role of config/dk-read-only.sh on DK even when DK is in
# its seed set, it is drift; a prefix sibling (/UYELER/YKX) is no seed root; DK's temporary Forms roles
# missing are BILGI (S2-geçici). Needs bash 4 or later, no Keycloak.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$SCRIPT_DIR/../config/app-assignments.sh"
DK_SCRIPT="$SCRIPT_DIR/../config/dk-read-only.sh"

# function NAME INDENT: the function's text as the script holds it (INDENT: its leading spaces).
function_text() {
  local text
  text=$(sed -n "/^$2$1() {\$/,/^$2}\$/p" "$SCRIPT")
  [[ -n $text ]] || { printf 'app-assignments drift check failed: %s() not found in %s\n' "$1" "$SCRIPT" >&2; exit 1; }
  printf '%s\n' "$text"
}
eval "$(function_text in_roots '')"
eval "$(function_text panel_changed '  ')"
eval "$(function_text missing_class '  ')"

declare -A seeded=() seed_names=() dk_write=()
seed() { # seed CLIENT ROLE NAMES
  seeded[$1|$2]=1
  seed_names[$1|$2]=" $3"
}
seed skymail skymail:mails:approve 'YK'
seed skymail skymail:mails:write 'ADMIN YK'
seed admin content:read 'ADMIN YK DK'
# Not the code's set (content:write is ADMIN and YK): DK in the seed set of a write role, so that the
# write role rule on DK is measured on its own.
seed admin content:write 'ADMIN YK DK'
seed forms 'skyforms:*' 'YK'
dk_write_roles=$(bash "$DK_SCRIPT" --print-write-roles)
while IFS= read -r entry; do
  if [[ -n $entry ]]; then dk_write[$entry]=1; fi
done <<<"$dk_write_roles"
[[ -n ${dk_write["*|content:write"]:-} && -n ${dk_write["skymail|skymail:mails:approve"]:-} ]] \
  || { printf 'app-assignments drift check failed: dk-read-only.sh --print-write-roles lacks its write roles\n' >&2; exit 1; }

status=0
# fazla WANT PATH CLIENT ROLE: a mapping the realm has and the code does not expect.
fazla() {
  local want=$1 got=drift
  shift
  if panel_changed "$1" "$2" "$3" fazla; then got=BILGI; fi
  if [[ $got != "$want" ]]; then
    printf 'app-assignments drift check failed: %s|%s on %s (more) is %s, not %s\n' "$2" "$3" "$1" "$got" "$want" >&2
    status=1
  fi
}
# eksik WANT PATH CLIENT ROLE VALUE: a mapping the code expects (VALUE) and the realm lacks.
eksik() {
  local want=$1 got
  shift
  got=$(missing_class "$@")
  if [[ $got != "$want" ]]; then
    printf 'app-assignments drift check failed: %s|%s on %s (missing, %s) is %s, not %s\n' "$2" "$3" "$1" "$4" "$got" "$want" >&2
    status=1
  fi
}

# In the seed set: the root in both shapes and its sub-groups.
fazla BILGI /UYELER/YK skymail skymail:mails:approve
fazla BILGI /YK skymail skymail:mails:approve
fazla BILGI /UYELER/YK/ALT skymail skymail:mails:approve
fazla BILGI /UYELER/YK/ALT/X skymail skymail:mails:approve
fazla BILGI /ADMIN admin content:write
# Outside the seed set: a root, its sub-group, the other shape, a prefix sibling.
fazla drift /ADMIN skymail skymail:mails:approve
fazla drift /ADMIN/ALT skymail skymail:mails:approve
fazla drift /UYELER/ADMIN skymail skymail:mails:approve
fazla drift /UYELER/YKX skymail skymail:mails:approve
fazla drift /DKX admin content:read
# No seed: drift wherever.
fazla drift /ADMIN skymail skymail:templates:write
# DK: a read role of its seed set is the panel's; a write role never, DK in its seed set or not.
fazla BILGI /UYELER/DK/ALT admin content:read
fazla BILGI /DK admin content:read
fazla drift /UYELER/DK admin content:write
fazla drift /DK/ALT admin content:write
fazla drift /UYELER/DK skymail skymail:mails:write
# Missing: in the seed set BILGI (S2-tohum), DK's write role taken away included; DK's temporary
# Forms roles taken away S2-geçici; outside the seed set or never seeded S2-eksik.
eksik S2-tohum /ADMIN skymail skymail:mails:write evet
eksik S2-tohum /DK admin content:read evet
eksik S2-tohum /UYELER/DK admin content:write evet
eksik S2-geçici /UYELER/DK forms 'skyforms:*' geçici
eksik S2-geçici /DK forms 'skyforms:feedback:*' geçici
eksik S2-eksik /UYELER/YK forms skyforms:access evet
eksik S2-eksik /ADMIN skymail skymail:mails:approve evet

if [[ $status == 0 ]]; then
  printf 'app-assignments drift decision: 23 cases as expected\n'
fi
exit "$status"
