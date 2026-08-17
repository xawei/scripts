#!/usr/bin/env bash
set -euo pipefail

# Check certificates stored in Kubernetes secrets and print their details
# in a readable table, so certs can be compared and reviewed easily.
#
# Detects any secret key ending in .crt / .pem (covers kubernetes.io/tls
# secrets with tls.crt, plus CA bundles like ca.crt, root-cert.pem, ...).
#
# Usage:
#   check-certs-in-secret.sh                   # current namespace
#   check-certs-in-secret.sh <namespace>       # specific namespace
#   check-certs-in-secret.sh -A                # all namespaces
#   check-certs-in-secret.sh -d                # also print full cert details
#   check-certs-in-secret.sh -e [days]         # only expired / expiring soon (default 30d)

for cmd in kubectl jq openssl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "❌ $cmd is required" >&2; exit 1; }
done

usage() {
  sed -n '4,15p' "$0" | sed 's/^# \{0,1\}//'
}

NS=""
ALL_NS=false
DETAIL=false
EXPIRING=false
EXPIRING_DAYS=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    -A|--all-namespaces) ALL_NS=true; shift ;;
    -d|--detail) DETAIL=true; shift ;;
    -e|--expiring)
      EXPIRING=true
      if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then EXPIRING_DAYS="$2"; shift; fi
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "❌ Unknown option: $1" >&2
      echo ""
      usage
      exit 1
      ;;
    *) NS="$1"; shift ;;
  esac
done

# Colors (only when attached to a TTY)
if [[ -t 1 ]]; then
  RED=$'\033[31m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; YELLOW=""; GREEN=""; BOLD=""; RESET=""
fi

# ---------- helpers ----------
to_epoch() {
  local d="$1" e
  e=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$d" +%s 2>/dev/null)
  if [[ -z "$e" ]]; then
    e=$(date -d "$d" +%s 2>/dev/null || echo "")
  fi
  echo "$e"
}

fmt_iso() {
  local d="$1" e out
  e=$(to_epoch "$d")
  if [[ -n "$e" ]]; then
    out=$(date -j -f "%s" "$e" "+%Y-%m-%d" 2>/dev/null)
    [[ -z "$out" ]] && out=$(date -d "@$e" "+%Y-%m-%d" 2>/dev/null)
    echo "${out:-$d}"
  else
    echo "$d"
  fi
}

# Extract CN (or fall back to the whole subject)
cn_of() {
  local s="$1"
  if [[ "$s" == *"CN="* ]]; then
    sed 's/.*CN *= *\([^,/]*\).*/\1/' <<< "$s"
  else
    echo "$s"
  fi
}

# Pull fields out of a single PEM cert
cert_fields() {
  local pem="$1"
  SUBJECT=$(printf '%s\n' "$pem" | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject=//')
  ISSUER=$(printf '%s\n' "$pem" | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')
  NOT_BEFORE=$(printf '%s\n' "$pem" | openssl x509 -noout -startdate 2>/dev/null | sed 's/^notBefore=//')
  NOT_AFTER=$(printf '%s\n' "$pem" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
  SAN=$(printf '%s\n' "$pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null \
        | tail -n +2 | tr '\n' ' ' | sed 's/^ *//; s/ *$//')
  SUBJECT_CN=$(cn_of "$SUBJECT")
  ISSUER_CN=$(cn_of "$ISSUER")

  local na
  na=$(to_epoch "$NOT_AFTER")
  DAYS_LEFT=""
  if [[ -n "$na" ]]; then
    DAYS_LEFT=$(( (na - $(date +%s)) / 86400 ))
  fi
}

# ---------- gather secrets ----------
if [[ "$ALL_NS" == true ]]; then
  SECRETS_JSON=$(kubectl get secrets -A -o json)
  SCOPE="all namespaces"
else
  [[ -z "$NS" ]] && NS=$(kubectl config view --minify -o jsonpath='{.contexts[0].context.namespace}')
  NS=${NS:-default}
  SECRETS_JSON=$(kubectl get secrets -n "$NS" -o json)
  SCOPE="namespace: $NS"
fi

TOTAL_SECRETS=$(echo "$SECRETS_JSON" | jq '.items | length')
if [[ "$TOTAL_SECRETS" -eq 0 ]]; then
  echo "ℹ️  No secrets found in $SCOPE"
  exit 0
fi

# ---------- collect cert rows ----------
declare -a ROWS=()     # ns|secret|key|subject|issuer|notbefore|notafter|days|san
declare -a DETAILS=()  # secret + key + cert text (for -d)
CERT_COUNT=0
SECRETS_WITH_CERTS=0

while IFS= read -r item; do
  ns=$(echo "$item" | jq -r '.metadata.namespace')
  secret=$(echo "$item" | jq -r '.metadata.name')

  cert_keys=$(echo "$item" | jq -r '.data | keys[] | select(test(".*\\.(crt|pem)$"))' 2>/dev/null || true)
  [[ -z "$cert_keys" ]] && continue

  SECRETS_WITH_CERTS=$((SECRETS_WITH_CERTS + 1))

  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    b64=$(echo "$item" | jq -r --arg k "$key" '.data[$k] // empty')
    [[ -z "$b64" ]] && continue

    pem=$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)
    [[ -z "$pem" ]] && continue

    # split PEM bundle into individual certs (handles leaf + chain)
    idx=0
    while IFS= read -r -d '' chunk; do
      [[ -z "$chunk" ]] && continue
      idx=$((idx + 1))
      cert_fields "$chunk"
      [[ -z "$NOT_AFTER" ]] && continue

      CERT_COUNT=$((CERT_COUNT + 1))

      # expire warning state
      if [[ -n "$DAYS_LEFT" ]]; then
        if [[ "$DAYS_LEFT" -lt 0 ]]; then
          STATE="expired"
        elif [[ "$DAYS_LEFT" -le 30 ]]; then
          STATE="critical"
        elif [[ "$DAYS_LEFT" -le 90 ]]; then
          STATE="warn"
        else
          STATE="ok"
        fi
      else
        STATE="unknown"
      fi

      # filter: only show expiring / expired when -e is given
      if [[ "$EXPIRING" == true ]]; then
        if [[ "$STATE" == "expired" || "$STATE" == "critical" ]]; then
          :
        elif [[ "$STATE" == "warn" && "$DAYS_LEFT" -le "$EXPIRING_DAYS" ]]; then
          :
        else
          continue
        fi
      fi

      display_key="$key"
      [[ "$idx" -gt 1 ]] && display_key="$key[$idx]"

      ROWS+=("$ns|$secret|$display_key|$SUBJECT_CN|$ISSUER_CN|$(fmt_iso "$NOT_BEFORE")|$(fmt_iso "$NOT_AFTER")|$DAYS_LEFT|$STATE|$SAN")

      if [[ "$DETAIL" == true ]]; then
        # base64-encode the cert so it survives the | -joined array
        chunk_b64=$(printf '%s' "$chunk" | base64 | tr -d '\n')
        DETAILS+=("$ns|$secret|$display_key|$chunk_b64")
      fi
    done < <(printf '%s\n' "$pem" | awk '
      /-----BEGIN CERTIFICATE-----/ { buf=$0 "\n"; n=1; next }
      n { buf=buf $0 "\n" }
      /-----END CERTIFICATE-----/ && n { printf "%s%c", buf, 0; buf=""; n=0 }
    ')
  done <<< "$cert_keys"
done < <(echo "$SECRETS_JSON" | jq -c '.items[]')

# ---------- output ----------
if [[ "$CERT_COUNT" -eq 0 ]]; then
  echo "ℹ️  No certificates found in $SCOPE"
  exit 0
fi

# sort rows by days left (most urgent first)
SORTED_ROWS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && SORTED_ROWS+=("$line")
done < <(printf '%s\n' "${ROWS[@]+"${ROWS[@]}"}" | sort -t'|' -k8 -n)

if [[ ${#SORTED_ROWS[@]} -eq 0 ]]; then
  if [[ "$EXPIRING" == true ]]; then
    echo "✅ No certificates expiring within ${EXPIRING_DAYS} day(s) in $SCOPE"
  else
    echo "ℹ️  No certificates found in $SCOPE"
  fi
  exit 0
fi

ROWS=("${SORTED_ROWS[@]}")

echo ""
echo "🔐 Certificates in $SCOPE"
echo "============================"
echo "Secrets with certs: $SECRETS_WITH_CERTS / $TOTAL_SECRETS    Certs found: $CERT_COUNT"
echo ""

# compute column widths
declare -a W=(8 6 3 7 6 10 10 9 3)  # ns secret key subject issuer notbefore notafter days san
for row in "${ROWS[@]}"; do
  IFS='|' read -r ns secret key subject issuer nb na days state san <<< "$row"
  [[ ${#ns} -gt ${W[0]} ]] && W[0]=${#ns}
  [[ ${#secret} -gt ${W[1]} ]] && W[1]=${#secret}
  [[ ${#key} -gt ${W[2]} ]] && W[2]=${#key}
  [[ ${#subject} -gt ${W[3]} ]] && W[3]=${#subject}
  [[ ${#issuer} -gt ${W[4]} ]] && W[4]=${#issuer}
  [[ ${#nb} -gt ${W[5]} ]] && W[5]=${#nb}
  [[ ${#na} -gt ${W[6]} ]] && W[6]=${#na}
  [[ ${#san} -gt ${W[8]} ]] && W[8]=${#san}
done

# pad helper: manual padding so ANSI color codes don't break column alignment
pad() { printf "%-*s" "$1" "$2"; }

print_row() {
  printf "%s  %s  %s  %s  %s  %s  %s  %s  %s\n" \
    "$(pad "${W[0]}" "$1")" "$(pad "${W[1]}" "$2")" "$(pad "${W[2]}" "$3")" \
    "$(pad "${W[3]}" "$4")" "$(pad "${W[4]}" "$5")" "$(pad "${W[5]}" "$6")" \
    "$(pad "${W[6]}" "$7")" "$(pad "${W[7]}" "$8")" "$(pad "${W[8]}" "$9")"
}

print_row "NAMESPACE" "SECRET" "KEY" "SUBJECT" "ISSUER" "NOT BEFORE" "NOT AFTER" "DAYS LEFT" "SANS"
print_row "---------" "------" "---" "-------" "------" "----------" "---------" "---------" "----"

for row in "${ROWS[@]}"; do
  IFS='|' read -r ns secret key subject issuer nb na days state san <<< "$row"

  # color the days-left cell (color around a pre-padded value keeps alignment)
  case "$state" in
    expired)  days_cell="${RED}$(pad "${W[7]}" "EXPIRED")${RESET}";;
    critical) days_cell="${RED}$(pad "${W[7]}" "${days}d")${RESET}";;
    warn)     days_cell="${YELLOW}$(pad "${W[7]}" "${days}d")${RESET}";;
    ok)       days_cell="${GREEN}$(pad "${W[7]}" "${days}d")${RESET}";;
    unknown)  days_cell="$(pad "${W[7]}" "?")";;
  esac

  # truncate long fields to keep the table readable
  [[ ${#subject} -gt ${W[3]} ]] && subject="${subject:0:${W[3]}}"
  [[ ${#san} -gt ${W[8]} ]] && san="${san:0:${W[8]}}"

  print_row "$ns" "$secret" "$key" "$subject" "$issuer" "$nb" "$na" "$days_cell" "$san"
done

# ---------- attention section ----------
expired_rows=()
for row in "${ROWS[@]}"; do
  IFS='|' read -r ns secret key subject issuer nb na days state san <<< "$row"
  if [[ "$state" == "expired" || "$state" == "critical" ]]; then
    expired_rows+=("$row")
  fi
done

if [[ "${#expired_rows[@]}" -gt 0 ]]; then
  echo ""
  echo "⚠️  Attention ($(printf '%s\n' "${expired_rows[@]}" | wc -l | tr -d ' ') cert(s) expiring soon / already expired):"
  for row in "${expired_rows[@]}"; do
    IFS='|' read -r ns secret key subject issuer nb na days state san <<< "$row"
    state_up=$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')
    if [[ "$state" == "expired" ]]; then
      phrase="expired $((-days)) day(s) ago"
    else
      phrase="${days} day(s) left"
    fi
    echo "  • ${RED}${state_up}${RESET}  ${ns}/${secret} (${key})  ${BOLD}${subject}${RESET}  ->  ${nb} .. ${na}  (${phrase})"
  done
  echo ""
  echo "💡 Renew these before expiry or they will stop being trusted by clients."
fi

# ---------- detail section ----------
if [[ "$DETAIL" == true && "${#DETAILS[@]}" -gt 0 ]]; then
  echo ""
  echo "📄 Full certificate details"
  echo "============================"
  for d in "${DETAILS[@]}"; do
    IFS='|' read -r ns secret key chunk_b64 <<< "$d"
    chunk=$(printf '%s' "$chunk_b64" | base64 -d)
    echo ""
    echo "${BOLD}▶ ${ns}/${secret}  (${key})${RESET}"
    printf '%s\n' "$chunk" | openssl x509 -noout -text | sed 's/^/    /'
  done
fi

echo ""
echo "✅ Done: $CERT_COUNT certificate(s) checked in $SCOPE"
