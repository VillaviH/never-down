#!/usr/bin/env bash
# Observador de solo lectura para el endpoint /health de Cafe Quetzal.
# Resuelve con un recursor explicito y obliga a curl a usar la IP seleccionada,
# preservando el hostname para Host, SNI y la verificacion TLS.
#
# Uso:
#   ./scripts/watch.sh
#   MAX_ITERATIONS=3 INTERVAL_SECONDS=1 ./scripts/watch.sh
#   FORCE_IP=8.232.135.228 MAX_ITERATIONS=1 ./scripts/watch.sh
#   DNS_RESOLVER=8.8.8.8 ./scripts/watch.sh
#
# Variables opcionales: DNS_RESOLVER, FORCE_IP, MAX_ITERATIONS,
# INTERVAL_SECONDS, CONNECT_TIMEOUT_SECONDS, MAX_TIME_SECONDS y
# DNS_TIMEOUT_SECONDS. Se puede pasar otro hostname como primer argumento.
set -uo pipefail

DOMAIN="${1:-apicafequetzal.hvillavicencio.com}"
URL="https://${DOMAIN}/health"
DNS_RESOLVER="${DNS_RESOLVER:-1.1.1.1}"
FORCE_IP="${FORCE_IP:-}"
MAX_ITERATIONS="${MAX_ITERATIONS:-0}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-2}"
CONNECT_TIMEOUT_SECONDS="${CONNECT_TIMEOUT_SECONDS:-3}"
MAX_TIME_SECONDS="${MAX_TIME_SECONDS:-8}"
DNS_TIMEOUT_SECONDS="${DNS_TIMEOUT_SECONDS:-2}"

if ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "MAX_ITERATIONS debe ser un entero mayor o igual a 0" >&2
  exit 2
fi

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  GREEN='\033[0;32m'
  BLUE='\033[0;34m'
  RED='\033[0;31m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  GREEN=''
  BLUE=''
  RED=''
  BOLD=''
  NC=''
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/never-down-watch.XXXXXX") || exit 1
DNS_OUT="$TMP_DIR/dns.out"
DNS_ERR="$TMP_DIR/dns.err"
BODY_FILE="$TMP_DIR/body"
HEADER_FILE="$TMP_DIR/headers"
CURL_ERR="$TMP_DIR/curl.err"
METRICS_FILE="$TMP_DIR/metrics"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

summarize_file() {
  awk '
    BEGIN { first = 1 }
    {
      gsub(/\r/, "")
      gsub(/[[:space:]]+/, " ")
      if (length($0) > 0) {
        if (!first) printf " "
        printf "%s", $0
        first = 0
      }
    }
    END { print "" }
  ' "$1"
}

echo "🔎 Never Down — watch: $URL"
if [ -n "$FORCE_IP" ]; then
  echo "   source=FORCE_IP selected=$FORCE_IP (DNS omitido intencionalmente)"
else
  echo "   source=DNS resolver=$DNS_RESOLVER"
fi
if [ "$MAX_ITERATIONS" -eq 0 ]; then
  echo "   Ctrl+C para salir"
else
  echo "   iterations=$MAX_ITERATIONS interval=${INTERVAL_SECONDS}s"
fi
echo

ITERATION=0
while [ "$MAX_ITERATIONS" -eq 0 ] || [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
  ITERATION=$((ITERATION + 1))
  TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  SELECTED_IP=''
  ANSWERS=''
  TTLS=''
  DNS_STATUS='NOT_QUERIED'
  DNS_ERROR=''

  if [ -n "$FORCE_IP" ]; then
    SOURCE='FORCE_IP'
    RESOLVER_USED='none'
    SELECTED_IP="$FORCE_IP"
    ANSWERS="$FORCE_IP"
    TTLS='n/a'
    DNS_STATUS='BYPASSED'
  else
    SOURCE='DNS'
    RESOLVER_USED="$DNS_RESOLVER"
    : > "$DNS_OUT"
    : > "$DNS_ERR"
    dig "@$DNS_RESOLVER" "$DOMAIN" A \
      +time="$DNS_TIMEOUT_SECONDS" +tries=1 +noall +comments +answer \
      >"$DNS_OUT" 2>"$DNS_ERR"
    DIG_EXIT=$?

    DNS_STATUS=$(sed -n 's/.*status: \([^,]*\),.*/\1/p' "$DNS_OUT" | awk 'NR == 1 { print; exit }')
    DNS_STATUS="${DNS_STATUS:-UNKNOWN}"
    ANSWERS=$(awk '$4 == "A" { if (count++) printf ","; printf "%s", $5 }' "$DNS_OUT")
    TTLS=$(awk '$4 == "A" { if (count++) printf ","; printf "%s", $2 }' "$DNS_OUT")
    SELECTED_IP=$(awk '$4 == "A" { print $5; exit }' "$DNS_OUT")
    DNS_ERROR=$(summarize_file "$DNS_ERR")
    if [ "$DIG_EXIT" -ne 0 ]; then
      DNS_ERROR="dig exit=$DIG_EXIT${DNS_ERROR:+: $DNS_ERROR}"
    elif [ -z "$SELECTED_IP" ]; then
      DNS_ERROR="sin respuestas A (dns_status=$DNS_STATUS)${DNS_ERROR:+: $DNS_ERROR}"
    fi
  fi

  printf '%s source=%s resolver=%s dns_status=%s answers=[%s] ttl=[%s] selected=%s\n' \
    "$TS" "$SOURCE" "$RESOLVER_USED" "$DNS_STATUS" "${ANSWERS:-}" \
    "${TTLS:-}" "${SELECTED_IP:-none}"

  if [ -z "$SELECTED_IP" ]; then
    printf '  %b curl remote_ip=none http=000 exit=not-run connect=n/a tls=n/a ttfb=n/a total=n/a served_by=unknown error=[%s]%b\n' \
      "${RED}${BOLD}" "$DNS_ERROR" "$NC"
  else
    : > "$BODY_FILE"
    : > "$HEADER_FILE"
    : > "$CURL_ERR"
    : > "$METRICS_FILE"

    curl -sS \
      --connect-timeout "$CONNECT_TIMEOUT_SECONDS" \
      --max-time "$MAX_TIME_SECONDS" \
      --resolve "${DOMAIN}:443:${SELECTED_IP}" \
      -D "$HEADER_FILE" \
      -o "$BODY_FILE" \
      -w '%{remote_ip}|%{http_code}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{time_total}\n' \
      "$URL" >"$METRICS_FILE" 2>"$CURL_ERR"
    CURL_EXIT=$?

    REMOTE_IP=''
    HTTP_STATUS='000'
    TIME_CONNECT='n/a'
    TIME_APPCONNECT='n/a'
    TIME_STARTTRANSFER='n/a'
    TIME_TOTAL='n/a'
    if [ -s "$METRICS_FILE" ]; then
      IFS='|' read -r REMOTE_IP HTTP_STATUS TIME_CONNECT TIME_APPCONNECT TIME_STARTTRANSFER TIME_TOTAL < "$METRICS_FILE"
    fi

    HEADER_SERVED=$(awk '
      tolower($0) ~ /^x-served-by:[[:space:]]*/ {
        value = $0
        sub(/^[^:]*:[[:space:]]*/, "", value)
        sub(/\r$/, "", value)
      }
      END { print value }
    ' "$HEADER_FILE")
    JSON_SERVED=$(sed -nE 's/.*"served_by"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$BODY_FILE" | awk 'NR == 1 { print; exit }')
    SERVED_BY="${HEADER_SERVED:-${JSON_SERVED:-unknown}}"
    CURL_ERROR=$(summarize_file "$CURL_ERR")

    if [[ "$SERVED_BY" == aws* ]]; then
      COLOR="$GREEN"
      CLOUD='AWS'
    elif [[ "$SERVED_BY" == gcp* ]]; then
      COLOR="$BLUE"
      CLOUD='GCP'
    elif [ "$CURL_EXIT" -ne 0 ]; then
      COLOR="$RED"
      CLOUD='ERROR'
    else
      COLOR=''
      CLOUD='UNKNOWN'
    fi

    printf '  %b%s curl remote_ip=%s http=%s exit=%s connect=%s tls=%s ttfb=%s total=%s served_by=%s header_x_served_by=%s json_served_by=%s%b' \
      "$COLOR$BOLD" "$CLOUD" "${REMOTE_IP:-none}" "$HTTP_STATUS" "$CURL_EXIT" \
      "$TIME_CONNECT" "$TIME_APPCONNECT" "$TIME_STARTTRANSFER" "$TIME_TOTAL" \
      "$SERVED_BY" "${HEADER_SERVED:-none}" "${JSON_SERVED:-none}" "$NC"
    if [ "$CURL_EXIT" -ne 0 ] || [ -n "$CURL_ERROR" ]; then
      printf ' error=[%s]' "${CURL_ERROR:-curl fallo sin texto en stderr}"
    fi
    printf '\n'
  fi

  if [ "$MAX_ITERATIONS" -eq 0 ] || [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; then
    sleep "$INTERVAL_SECONDS"
  fi
done
