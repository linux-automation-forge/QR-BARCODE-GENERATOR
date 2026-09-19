#!/usr/bin/env bash
#
# codesmith.sh — batch QR code & barcode generator with roundtrip verification,
#                multiple content types, and print-ready HTML label sheets.
#
# Corporate use cases: inventory labels, asset tags, WiFi posters, contact sharing.
#
#   ./codesmith.sh qr --url "https://example.com"
#   ./codesmith.sh qr --wifi "OfficeGuest" "welcome123" WPA
#   ./codesmith.sh barcode --ean 890123456789 --label "Neem Oil 250ml"
#   ./codesmith.sh batch products.csv
#   ./codesmith.sh --log | --selftest | --help
#
# Exit codes: 0 ok | 1 verification failed | 2 missing dependency | 3 bad input
#
set -euo pipefail

VERSION="1.0.1"
# pure-bash basename — no external command needed before deps are probed
SCRIPT_NAME="${0##*/}"

# ---------------------------------------------------------------- exit codes
EX_OK=0
EX_VERIFY=1
EX_DEP=2
EX_INPUT=3

# The script relies on bash arrays, [[ ]], ${var//} and friends — refuse
# non-bash interpreters early (e.g. `sh codesmith.sh` / `zsh codesmith.sh`)
# instead of dying with confusing syntax errors halfway through.
if [ -z "${BASH_VERSION:-}" ]; then
  printf '[✗] codesmith.sh must be run with bash (try: bash %s --help)\n' "$0" >&2
  exit "$EX_DEP"
fi

# ------------------------------------------------------------------ config
GENERATED_DIR="generated"
LOG_FILE="codesmith_log.csv"
LOG_HEADER="timestamp,mode,content_type,payload,output_file,verified,status"

# ----------------------------------------------------------- runtime state
EC="M"
SIZE=4
FG=""; BG=""
SVG=0
LOGO=""
TERMINAL=0
LABEL=""
VERIFY=1

QR_CT="";   QR_VALUE=""
BC_TYPE=""; BC_VALUE=""
WIFI_SSID=""; WIFI_PASS=""; WIFI_AUTH="WPA"
VC_NAME=""; VC_TEL=""; VC_EMAIL=""
GEO_LAT=""; GEO_LON=""

PAYLOAD=""
OUT_FILE=""
V_RESULT="SKIPPED"
V_DECODED=""

SELF_TMP=""

# tallies (used by qr/barcode/batch)
N_GEN=0; N_VER=0; N_MISMATCH=0; N_FAILED=0; N_SKIPPED=0

# ------------------------------------------------------------- dependency state
HAVE_QRENCODE=0
HAVE_ZINT=0
HAVE_ZBAR=0
HAVE_IM=0
IM=""
IM_ID=()
QR_HAS_COLOR=0
ZINT_VWHITE=0

# ------------------------------------------------------------------ colors
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'
  C_B=$'\033[1m';  C_0=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_C=""; C_B=""; C_0=""
fi
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  T_R=$'\033[31m'; T_G=$'\033[32m'; T_Y=$'\033[33m'; T_C=$'\033[36m'
  T_B=$'\033[1m';  T_D=$'\033[2m';  T_0=$'\033[0m'
else
  T_R=""; T_G=""; T_Y=""; T_C=""; T_B=""; T_D=""; T_0=""
fi

# ============================================================ tiny utilities

have() { command -v "$1" >/dev/null 2>&1; }

err()  { printf '%s\n' "${C_R}[✗]${C_0} ${C_B}$*${C_0}" >&2; }
warn() { printf '%s\n' "${C_Y}[!]${C_0} $*" >&2; }
ok()   { printf '%s\n' "${C_G}[✔]${C_0} $*" >&2; }
info() { printf '%s\n' "${C_C}[•]${C_0} $*" >&2; }

die_input() { err "$*"; printf '\n' >&2; usage_short >&2; exit "$EX_INPUT"; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

trunc() {
  local s="$1" n="$2"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  if [ "${#s}" -le "$n" ]; then
    printf '%s' "$s"
  else
    printf '%s…' "${s:0:$((n - 1))}"
  fi
}

slugify() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  s="$(printf '%s' "$s" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  if [ -z "$s" ]; then s="item"; fi
  printf '%s' "$s"
}

html_escape() {
  local s="$1"
  s="${s//&/\&amp;}"
  s="${s//</\&lt;}"
  s="${s//>/\&gt;}"
  s="${s//\"/\&quot;}"
  printf '%s' "$s"
}

csv_escape() {
  local s="$1"
  s="${s//\"/\"\"}"
  case "$s" in
    *,*|*\"*) printf '"%s"' "$s" ;;
    *)        printf '%s' "$s" ;;
  esac
}

strip_hash() { local s="$1"; s="${s#\#}"; printf '%s' "$s"; }

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
is_num()  { [[ "${1:-}" =~ ^[-+]?[0-9]+(\.[0-9]+)?$ ]]; }

ensure_tmp() {
  if [ -z "$SELF_TMP" ]; then
    if ! SELF_TMP="$(mktemp -d "${TMPDIR:-/tmp}/codesmith.XXXXXX")"; then
      err "could not create a temp directory"; exit "$EX_INPUT"
    fi
  fi
}

cleanup() {
  if [ -n "${SELF_TMP:-}" ] && [ -d "$SELF_TMP" ]; then
    rm -rf "$SELF_TMP"
  fi
  :
}
trap cleanup EXIT

# ============================================================ CSV (pure bash)
# Splits one CSV record into the global array CSV_FIELDS.
# Handles double-quoted fields and "" escapes. Newlines must be pre-stripped.

csv_split() {
  CSV_FIELDS=()
  local line="$1" field="" inq=0 i=0 ch nxt
  while [ "$i" -lt "${#line}" ]; do
    ch="${line:i:1}"
    if [ "$inq" = 1 ]; then
      if [ "$ch" = '"' ]; then
        nxt="${line:i+1:1}"
        if [ "$nxt" = '"' ]; then
          field+='"'
          i=$((i + 1))
        else
          inq=0
        fi
      else
        field+="$ch"
      fi
    else
      case "$ch" in
        '"') inq=1 ;;
        ',') CSV_FIELDS+=("$field"); field="" ;;
        *)   field+="$ch" ;;
      esac
    fi
    i=$((i + 1))
  done
  CSV_FIELDS+=("$field")
}

# ========================================================== payload builders

wifi_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//;/\\;}"
  s="${s//,/\\,}"
  s="${s//:/\\:}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

mecard_escape() { wifi_escape "$1"; }

build_wifi_payload() {
  local auth pass ssid
  if [ -z "${WIFI_SSID:-}" ]; then
    err "wifi: SSID must not be empty"
    return 1
  fi
  auth="$(printf '%s' "${WIFI_AUTH:-WPA}" | tr '[:lower:]' '[:upper:]')"
  ssid="$(wifi_escape "$WIFI_SSID")"
  case "$auth" in
    WPA|WPA2|WPA3|RSN)
      if [ -z "${WIFI_PASS:-}" ]; then
        err "wifi: WPA requires a password"
        return 1
      fi
      pass="$(wifi_escape "$WIFI_PASS")"
      printf 'WIFI:T:WPA;S:%s;P:%s;;' "$ssid" "$pass"
      ;;
    WEP)
      if [ -z "${WIFI_PASS:-}" ]; then
        err "wifi: WEP requires a password"
        return 1
      fi
      pass="$(wifi_escape "$WIFI_PASS")"
      printf 'WIFI:T:WEP;S:%s;P:%s;;' "$ssid" "$pass"
      ;;
    NONE|NOPASS|OPEN|"")
      printf 'WIFI:T:nopass;S:%s;;' "$ssid"
      ;;
    *)
      err "wifi: auth must be WPA, WEP or none (got: ${WIFI_AUTH:-<empty>})"
      return 1
      ;;
  esac
}

build_vcard_payload() {
  if [ -z "${VC_NAME:-}" ]; then
    err "vcard: name must not be empty"
    return 1
  fi
  printf 'MECARD:N:%s;TEL:%s;EMAIL:%s;;' \
    "$(mecard_escape "$VC_NAME")" \
    "$(mecard_escape "$VC_TEL")" \
    "$(mecard_escape "$VC_EMAIL")"
}

build_geo_payload() {
  if ! is_num "$GEO_LAT" || ! is_num "$GEO_LON"; then
    err "geo: latitude/longitude must be numeric (got: '$GEO_LAT', '$GEO_LON')"
    return 1
  fi
  if ! awk -v a="$GEO_LAT"  'BEGIN { exit !(a >= -90  && a <= 90)  }'; then
    err "geo: latitude must be within -90..90"
    return 1
  fi
  if ! awk -v a="$GEO_LON"  'BEGIN { exit !(a >= -180 && a <= 180) }'; then
    err "geo: longitude must be within -180..180"
    return 1
  fi
  printf 'GEO:%s,%s' "$GEO_LAT" "$GEO_LON"
}

# ---------------------------------------------------------------- check digits

ean13_check() {  # $1 = 12 digits -> prints 13th check digit (1x/3x weights)
  local digits="$1" sum=0 i d
  for ((i = 0; i < 12; i++)); do
    d="${digits:i:1}"
    if (( i % 2 == 0 )); then sum=$((sum + d)); else sum=$((sum + d * 3)); fi
  done
  printf '%s' "$(( (10 - sum % 10) % 10 ))"
}

upc_check() {    # $1 = 11 digits -> prints 12th check digit (3x/1x weights)
  local digits="$1" sum=0 i d
  for ((i = 0; i < 11; i++)); do
    d="${digits:i:1}"
    if (( i % 2 == 0 )); then sum=$((sum + d * 3)); else sum=$((sum + d)); fi
  done
  printf '%s' "$(( (10 - sum % 10) % 10 ))"
}

build_ean13_payload() {
  local v="${1//[[:space:]]/}"
  if ! [[ "$v" =~ ^[0-9]{12}$ ]]; then
    if [[ "$v" =~ ^[0-9]{13}$ ]]; then
      err "ean: pass the 12 data digits only — I compute the check digit (for ${v:0:12} it is $(ean13_check "${v:0:12}"))"
    else
      err "ean: EAN-13 needs exactly 12 digits (got: $(trunc "$v" 30))"
    fi
    return 1
  fi
  printf '%s%s' "$v" "$(ean13_check "$v")"
}

build_upca_payload() {
  local v="${1//[[:space:]]/}"
  if ! [[ "$v" =~ ^[0-9]{11}$ ]]; then
    if [[ "$v" =~ ^[0-9]{12}$ ]]; then
      err "upc: pass the 11 data digits only — I compute the check digit (for ${v:0:11} it is $(upc_check "${v:0:11}"))"
    else
      err "upc: UPC-A needs exactly 11 digits (got: $(trunc "$v" 30))"
    fi
    return 1
  fi
  printf '%s%s' "$v" "$(upc_check "$v")"
}

build_code39_payload() {
  local v="$1" re='[^A-Za-z0-9 .$/%+-]'
  if [ -z "$v" ]; then
    err "code39: value must not be empty"
    return 1
  fi
  if [[ "$v" =~ $re ]]; then
    err "code39: allowed characters are A-Z 0-9 - . \$ / + % and space (got: $(trunc "$v" 30))"
    return 1
  fi
  printf '%s' "$(printf '%s' "$v" | tr '[:lower:]' '[:upper:]')"
}

isbn10_check_ok() {  # $1 = full ISBN-10 (9 digits + check char X|digit)
  local s="$1" sum=0 i d c
  for ((i = 0; i < 9; i++)); do
    d="${s:i:1}"
    sum=$(( sum + d * (10 - i) ))
  done
  c="${s:9:1}"
  case "$c" in [Xx]) c=10 ;; esac
  sum=$(( sum + c ))
  [ $(( sum % 11 )) -eq 0 ]
}

build_isbn_payload() {
  local v base c
  v="$(printf '%s' "$1" | tr -d ' -')"
  if   [[ "$v" =~ ^[0-9]{9}$ ]]; then
    base="978${v}"
  elif [[ "$v" =~ ^[0-9]{9}[Xx]$ || "$v" =~ ^[0-9]{10}$ ]]; then
    if ! isbn10_check_ok "$v"; then
      err "isbn: invalid ISBN-10 '$v' — check digit does not match"
      return 1
    fi
    base="978${v:0:9}"
  elif [[ "$v" =~ ^[0-9]{12}$ ]]; then
    if [ "${v:0:3}" != "978" ] && [ "${v:0:3}" != "979" ]; then
      err "isbn: ISBN-13 must start with 978 or 979"
      return 1
    fi
    base="$v"
  elif [[ "$v" =~ ^[0-9]{13}$ ]]; then
    if [ "${v:0:3}" != "978" ] && [ "${v:0:3}" != "979" ]; then
      err "isbn: ISBN-13 must start with 978 or 979"
      return 1
    fi
    c="$(ean13_check "${v:0:12}")"
    if [ "$c" != "${v:12:1}" ]; then
      err "isbn: check digit mismatch — given '${v:12:1}', computed '$c'"
      return 1
    fi
    base="${v:0:12}"
  else
    err "isbn: use 9/10-digit ISBN-10 or 12/13-digit ISBN-13 starting with 978/979"
    return 1
  fi
  printf '%s%s' "$base" "$(ean13_check "$base")"
}

# $1 = barcode type; $2 = raw value. Prints encoded payload.
build_bc_payload() {
  local t="$1" v="$2"
  case "$t" in
    ean)     build_ean13_payload "$v" ;;
    upc)     build_upca_payload "$v" ;;
    code128)
      if [ -z "$v" ]; then err "code128: value must not be empty"; return 1; fi
      printf '%s' "$v"
      ;;
    code39)  build_code39_payload "$v" ;;
    isbn)    build_isbn_payload "$v" ;;
    *) err "unknown barcode type: $t"; return 1 ;;
  esac
}

# ================================================================== deps

print_install_hints() {
  cat >&2 <<'HINTS'

Missing dependencies — install with one of:
  Debian/Ubuntu : sudo apt install qrencode zint zbar-tools imagemagick
  Fedora        : sudo dnf install qrencode zint zbar imagemagick
  macOS (brew)  : brew install qrencode zint zbar imagemagick
HINTS
}

probe_deps() {
  if have qrencode; then HAVE_QRENCODE=1; fi
  if have zint;     then HAVE_ZINT=1; fi
  if have zbarimg;  then HAVE_ZBAR=1; fi

  if have magick; then
    IM="magick"; IM_ID=(magick identify); HAVE_IM=1
  elif have convert && have identify; then
    IM="convert"; IM_ID=(identify); HAVE_IM=1
  fi

  if [ "$HAVE_QRENCODE" = 1 ]; then
    if qrencode --help 2>&1 | grep -q -- '--foreground'; then QR_HAS_COLOR=1; fi
  fi
  if [ "$HAVE_ZINT" = 1 ]; then
    if zint --help 2>&1 | grep -q -- '--vwhitesp'; then ZINT_VWHITE=1; fi
  fi
}

need_bins() {
  local t missing=0
  for t in "$@"; do
    if ! have "$t"; then
      err "missing dependency: $t"
      missing=1
    fi
  done
  if [ "$missing" = 1 ]; then
    print_install_hints
    exit "$EX_DEP"
  fi
}

need_im() {
  if [ "$HAVE_IM" != 1 ]; then
    err "ImageMagick is required for this operation (--logo/--label)"
    print_install_hints
    exit "$EX_DEP"
  fi
}

notice_verification_state() {
  if [ "$VERIFY" = 1 ]; then
    if [ "$HAVE_ZBAR" != 1 ]; then
      info "zbarimg not found — roundtrip verification DISABLED (install zbar-tools to enable)"
    fi
  else
    warn "roundtrip verification disabled by --no-verify"
  fi
}

# ============================================================ image helpers

get_dims() {  # $1 file, $2 width-var, $3 height-var
  # NOTE: internal vars are prefixed to avoid dynamic-scope collisions with
  # the caller's variables (printf -v resolves through the caller's scope).
  local _gd_d _gd_w _gd_h
  if ! _gd_d="$("${IM_ID[@]}" -format '%w %h' "$1" 2>/dev/null)"; then
    err "cannot read image dimensions: $1"
    return 1
  fi
  read -r _gd_w _gd_h <<< "$_gd_d"
  if ! is_uint "${_gd_w:-}" || ! is_uint "${_gd_h:-}" \
     || [ "${_gd_w:-0}" -lt 1 ] || [ "${_gd_h:-0}" -lt 1 ]; then
    err "bad image dimensions for $1"
    return 1
  fi
  printf -v "$2" '%s' "$_gd_w"
  printf -v "$3" '%s' "$_gd_h"
}

# $1 payload, $2 output file (extension decides PNG vs SVG). Uses EC/SIZE/FG/BG/SVG.
gen_qr_image() {
  local payload="$1" out="$2"
  # -m 4 = the 4-module quiet zone the QR specification recommends for print
  local -a qa=(-l "$EC" -s "$SIZE" -m 4 -o "$out")
  if [ "$SVG" = 1 ]; then qa+=(-t SVG); else qa+=(-t PNG); fi
  if [ -n "$FG" ] || [ -n "$BG" ]; then
    if [ "$QR_HAS_COLOR" = 1 ]; then
      if [ -n "$FG" ]; then qa+=("--foreground=$FG"); fi
      if [ -n "$BG" ]; then qa+=("--background=$BG"); fi
    else
      warn "qrencode >= 4.0 needed for --fg/--bg colors — ignoring colors"
    fi
  fi
  if ! qrencode "${qa[@]}" -- "$payload"; then
    err "qrencode failed — payload too long for a QR symbol?"
    return 1
  fi
}

# $1 = QR png to overlay onto. Uses LOGO. CS_LOGO_PCT controls logo width
# as a percent of QR width (default 25). Rejects if covered area > 25%.
apply_logo() {
  local qr="$1"
  local scaled="$qr.logo.png" final="$qr.out.png"
  local pct="${CS_LOGO_PCT:-25}"
  if ! is_uint "$pct" || [ "$pct" -lt 1 ] || [ "$pct" -gt 100 ]; then
    err "CS_LOGO_PCT must be an integer percent between 1 and 100 (got: $pct)"
    return 1
  fi

  local qr_w qr_h target
  get_dims "$qr" qr_w qr_h || return 1
  target=$(( qr_w * pct / 100 ))
  if [ "$target" -lt 8 ]; then target=8; fi

  local logo_w logo_h
  get_dims "$LOGO" logo_w logo_h || return 1
  if [ "$logo_w" -lt "$target" ] || [ "$logo_h" -lt "$target" ]; then
    warn "logo source (${logo_w}x${logo_h}) is smaller than ${target}px — keeping it at native size (no upscaling)"
  fi

  if ! "$IM" "$LOGO" -resize "${target}x${target}>" -bordercolor white -border 2 "$scaled"; then
    err "could not scale logo: $LOGO"
    return 1
  fi

  local lw lh area
  get_dims "$scaled" lw lh || return 1
  area=$(( lw * lh * 100 / (qr_w * qr_h) ))
  if [ "$area" -gt 25 ]; then
    err "logo would cover ${area}% of the QR symbol (> 25%) — scanning would likely fail"
    info "shrink it: CS_LOGO_PCT=20 $SCRIPT_NAME qr ... --logo \"$LOGO\""
    return 1
  fi

  if ! "$IM" "$qr" \( "$scaled" \) -gravity center -geometry +0+0 -composite "$final"; then
    err "logo composite failed"
    return 1
  fi
  mv -f "$final" "$qr"
  rm -f "$scaled"
}

# $1 = image, $2 = caption text. Appends readable text below the code.
apply_label() {
  local img="$1" text="$2" tmp="$1.lbl.png" w _h ps
  get_dims "$img" w _h || return 1
  ps=$(( w / 10 ))
  if [ "$ps" -lt 12 ]; then ps=12; fi
  if [ "$ps" -gt 30 ]; then ps=30; fi
  if ! "$IM" "$img" \
       \( -background white -fill black -pointsize "$ps" label:"$text" \) \
       -background white -gravity center -append "$tmp"; then
    return 1
  fi
  mv -f "$tmp" "$img"
}

# $1 payload, $2 output file, $3 barcode type. Data passed with check digits included.
gen_barcode_image() {
  local payload="$1" out="$2" bctype="$3"
  local -a za=(-o "$out" -w 10)
  case "$bctype" in
    ean)     za+=(-b EANX) ;;
    upc)     za+=(-b UPCA) ;;
    code128) za+=(-b CODE128) ;;
    code39)  za+=(-b CODE39) ;;
    isbn)    za+=(-b ISBNX) ;;
  esac
  if [ "$ZINT_VWHITE" = 1 ]; then za+=(--vwhitesp=4); fi
  if ! zint "${za[@]}" -d "$payload"; then
    err "zint failed while encoding $(trunc "$payload" 40)"
    return 1
  fi
}

# ============================================================ verification
# Decodes $1 back with zbarimg and compares to expected payload $2.
# Sets V_RESULT: VERIFIED | MISMATCH | SKIPPED   (V_DECODED on mismatch)

verify_roundtrip() {
  local file="$1" expected="$2" decoded=""
  V_RESULT="SKIPPED"
  V_DECODED=""
  if [ "$VERIFY" != 1 ] || [ "$HAVE_ZBAR" != 1 ]; then
    return 0
  fi
  if ! decoded="$(zbarimg -q --raw "$file" 2>/dev/null)"; then
    decoded=""
  fi
  if [ -z "$decoded" ]; then
    case "$file" in
      *.svg)
        warn "SVG could not be raster-decoded — verification skipped for this item"
        V_RESULT="SKIPPED"
        ;;
      *)
        err "roundtrip decode failed: no readable symbol in $file"
        V_RESULT="MISMATCH"
        ;;
    esac
    return 0
  fi
  if [ "$decoded" = "$expected" ] || [ "$decoded" = "0$expected" ] || [ "0$decoded" = "$expected" ]; then
    V_RESULT="VERIFIED"
  else
    V_RESULT="MISMATCH"
    V_DECODED="$decoded"
  fi
  return 0
}

# ================================================================== logging

init_log() {
  if [ ! -f "$LOG_FILE" ]; then
    printf '%s\n' "$LOG_HEADER" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

log_row() {  # mode, content_type, payload, output_file, verified, status
  local mode="$1" ctype="$2" payload="$3" file="$4" verified="$5" status="$6" ts
  init_log
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "$ts" \
    "$(csv_escape "$mode")" \
    "$(csv_escape "$ctype")" \
    "$(csv_escape "$(trunc "$payload" 200)")" \
    "$(csv_escape "$file")" \
    "$(csv_escape "$verified")" \
    "$(csv_escape "$status")" \
    >> "$LOG_FILE" 2>/dev/null || warn "could not append to $LOG_FILE"
}

do_log() {
  if [ ! -f "$LOG_FILE" ]; then
    info "no log file yet — generate something first (expects: $LOG_FILE)"
    exit "$EX_OK"
  fi
  local -a lines=()
  local line
  # plain while-read (not mapfile) — keeps the stock macOS bash 3.2 supported
  while IFS= read -r line || [ -n "$line" ]; do
    lines+=("$line")
  done < <(tail -n +2 "$LOG_FILE" | tail -n 10)
  local total
  total=$(( $(wc -l < "$LOG_FILE") - 1 ))
  if [ "$total" -lt 0 ]; then total=0; fi

  if [ "${#lines[@]}" = 0 ]; then
    info "log is empty ($LOG_FILE)"
    exit "$EX_OK"
  fi

  printf '%s\n' "${T_B}codesmith log — last ${#lines[@]} of $total entries${T_0}"
  printf '%s\n' "${T_C}TIMESTAMP            MODE    TYPE     PAYLOAD                        OUTPUT                     VERIFIED   STATUS${T_0}"
  local ts mode ctype payload file verified status vcol
  for line in "${lines[@]}"; do
    csv_split "$line"
    ts="${CSV_FIELDS[0]:-}"; mode="${CSV_FIELDS[1]:-}"; ctype="${CSV_FIELDS[2]:-}"
    payload="${CSV_FIELDS[3]:-}"; file="${CSV_FIELDS[4]:-}"
    verified="${CSV_FIELDS[5]:-}"; status="${CSV_FIELDS[6]:-}"
    case "$verified" in
      VERIFIED) vcol="$T_G" ;;
      MISMATCH) vcol="$T_R" ;;
      SKIPPED)  vcol="$T_Y" ;;
      *)        vcol="$T_D" ;;
    esac
    case "$status" in
      FAILED) status="${T_R}${status}${T_0}" ;;
      GENERATED) status="${T_G}${status}${T_0}" ;;
    esac
    printf '%-20s %-7s %-8s %-30s %-26s %s%-9s%s %s\n' \
      "$(trunc "$ts" 20)" "$(trunc "$mode" 7)" "$(trunc "$ctype" 8)" \
      "$(trunc "$payload" 30)" "$(trunc "$file" 26)" \
      "$vcol" "$(trunc "$verified" 9)" "$T_0" "$status"
  done
  exit "$EX_OK"
}

# ================================================================ qr mode

parse_qr_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --url|--text|--raw)
        if [ -n "$QR_CT" ]; then die_input "only one content type per run"; fi
        if [ $# -lt 2 ] || [[ "${2:-}" == --* ]]; then die_input "missing value for $1"; fi
        QR_CT="${1#--}"
        QR_VALUE="$2"
        if [ -z "$QR_VALUE" ]; then die_input "$1 needs a non-empty value"; fi
        shift 2
        ;;
      --wifi)
        if [ -n "$QR_CT" ]; then die_input "only one content type per run"; fi
        shift
        local -a w=()
        while [ $# -gt 0 ] && [[ "$1" != --* ]]; do w+=("$1"); shift; done
        if [ "${#w[@]}" -lt 1 ] || [ "${#w[@]}" -gt 3 ]; then
          die_input "--wifi expects: SSID [password] [WPA|WEP|none]"
        fi
        WIFI_SSID="${w[0]}"
        WIFI_PASS="${w[1]:-}"
        WIFI_AUTH="${w[2]:-WPA}"
        QR_CT="wifi"
        ;;
      --vcard)
        if [ -n "$QR_CT" ]; then die_input "only one content type per run"; fi
        shift
        local -a v=()
        while [ $# -gt 0 ] && [[ "$1" != --* ]]; do v+=("$1"); shift; done
        if [ "${#v[@]}" -ne 3 ]; then
          die_input "--vcard expects: NAME PHONE EMAIL"
        fi
        VC_NAME="${v[0]}"; VC_TEL="${v[1]}"; VC_EMAIL="${v[2]}"
        QR_CT="vcard"
        ;;
      --geo)
        if [ -n "$QR_CT" ]; then die_input "only one content type per run"; fi
        shift
        local -a g=()
        while [ $# -gt 0 ] && [[ "$1" != --* ]]; do g+=("$1"); shift; done
        if [ "${#g[@]}" = 1 ] && [[ "${g[0]}" == *,* ]]; then
          IFS=',' read -r GEO_LAT GEO_LON <<< "${g[0]}"
          GEO_LAT="$(trim "$GEO_LAT")"; GEO_LON="$(trim "$GEO_LON")"
        elif [ "${#g[@]}" -eq 2 ]; then
          GEO_LAT="${g[0]}"; GEO_LON="${g[1]}"
        else
          die_input "--geo expects: LATITUDE LONGITUDE (or one \"LAT,LONG\" value)"
        fi
        QR_CT="geo"
        ;;
      --size)
        if [ $# -lt 2 ]; then die_input "--size needs a number (pixels per module)"; fi
        if ! is_uint "$2" || [ "$2" -lt 1 ] || [ "$2" -gt 80 ]; then
          die_input "--size must be an integer 1..80 (got: $2)"
        fi
        SIZE="$2"; shift 2
        ;;
      --ec)
        if [ $# -lt 2 ]; then die_input "--ec needs L, M, Q or H"; fi
        EC="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
        if ! [[ "$EC" =~ ^[LMQH]$ ]]; then die_input "--ec must be L, M, Q or H (got: $2)"; fi
        shift 2
        ;;
      --svg) SVG=1; shift ;;
      --fg)
        if [ $# -lt 2 ]; then die_input "--fg needs a hex color, e.g. --fg 1a1a2e"; fi
        FG="$(strip_hash "$2")"
        if ! [[ "$FG" =~ ^[0-9a-fA-F]{6}$ ]]; then die_input "--fg must be 6 hex digits (got: $2)"; fi
        FG="$(printf '%s' "$FG" | tr '[:upper:]' '[:lower:]')"
        shift 2
        ;;
      --bg)
        if [ $# -lt 2 ]; then die_input "--bg needs a hex color, e.g. --bg ffffff"; fi
        BG="$(strip_hash "$2")"
        if ! [[ "$BG" =~ ^[0-9a-fA-F]{6}$ ]]; then die_input "--bg must be 6 hex digits (got: $2)"; fi
        BG="$(printf '%s' "$BG" | tr '[:upper:]' '[:lower:]')"
        shift 2
        ;;
      --logo)
        if [ $# -lt 2 ]; then die_input "--logo needs an image file"; fi
        if [ ! -f "$2" ]; then die_input "logo file not found: $2"; fi
        LOGO="$2"; shift 2
        ;;
      --label)
        if [ $# -lt 2 ]; then die_input "--label needs a text value"; fi
        LABEL="$2"; shift 2
        ;;
      --terminal) TERMINAL=1; shift ;;
      --no-verify) VERIFY=0; shift ;;
      -h|--help) usage; exit "$EX_OK" ;;
      *) die_input "unknown option for qr: $1" ;;
    esac
  done
  if [ -z "$QR_CT" ]; then
    die_input "qr needs a content type: --url --text --wifi --vcard --geo --raw"
  fi
  if [ -n "$LABEL" ] && [ "$SVG" = 1 ]; then
    warn "--label is skipped for SVG output (raster only)"
    LABEL=""
  fi
}

do_qr() {
  probe_deps
  need_bins qrencode
  parse_qr_args "$@"
  notice_verification_state

  case "$QR_CT" in
    url|text|raw) PAYLOAD="$QR_VALUE" ;;
    wifi)
      if ! PAYLOAD="$(build_wifi_payload)"; then exit "$EX_INPUT"; fi ;;
    vcard)
      if ! PAYLOAD="$(build_vcard_payload)"; then exit "$EX_INPUT"; fi ;;
    geo)
      if ! PAYLOAD="$(build_geo_payload)"; then exit "$EX_INPUT"; fi ;;
  esac

  if [ "$QR_CT" = "url" ]; then
    if ! [[ "$PAYLOAD" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]]; then
      warn "'$PAYLOAD' has no scheme (https://…)? — encoding it as-is"
    fi
  fi

  info "QR [$QR_CT] payload: $(trunc "$PAYLOAD" 64)"

  # --terminal: scannable QR straight to stdout, no file
  if [ "$TERMINAL" = 1 ]; then
    if [ -n "$LOGO" ]; then die_input "--logo cannot be combined with --terminal"; fi
    if [ "$SVG" = 1 ]; then die_input "--svg cannot be combined with --terminal"; fi
    if [ -n "$LABEL" ] || [ -n "$FG" ] || [ -n "$BG" ]; then
      warn "--label/--fg/--bg have no effect with --terminal — ignoring"
    fi
    if ! qrencode -t ANSIUTF8 -l "$EC" -m 2 -- "$PAYLOAD"; then
      err "qrencode failed"; exit "$EX_INPUT"
    fi
    log_row "qr" "$QR_CT" "$PAYLOAD" "-" "SKIPPED" "GENERATED"
    N_GEN=$((N_GEN + 1)); N_SKIPPED=$((N_SKIPPED + 1))
    ok "rendered in terminal (no file written)"
    exit "$EX_OK"
  fi

  # --logo pre-flight: needs ImageMagick, needs PNG, forces EC H
  if [ -n "$LOGO" ]; then
    if [ "$SVG" = 1 ]; then
      die_input "--logo requires PNG output — drop --svg"
    fi
    need_im
    if [ "$EC" != "H" ]; then
      warn "logo mode requires error correction H (auto-upgrading from $EC)"
      EC="H"
    fi
  fi

  if ! mkdir -p "$GENERATED_DIR" 2>/dev/null; then
    err "cannot create output directory: $GENERATED_DIR"
    exit "$EX_INPUT"
  fi

  local ext="png"
  if [ "$SVG" = 1 ]; then ext="svg"; fi
  OUT_FILE="$GENERATED_DIR/qr-${QR_CT}-$(date +%Y%m%d-%H%M%S)-$RANDOM.$ext"

  if ! gen_qr_image "$PAYLOAD" "$OUT_FILE"; then exit "$EX_INPUT"; fi
  if [ -n "$LOGO" ]; then
    if ! apply_logo "$OUT_FILE"; then exit "$EX_INPUT"; fi
    info "logo composited (EC=$EC, area <= 25% checked)"
  fi
  if [ -n "$LABEL" ]; then
    if [ "$HAVE_IM" != 1 ]; then
      warn "ImageMagick not found — --label skipped (install imagemagick)"
    elif ! apply_label "$OUT_FILE" "$LABEL"; then
      warn "label rendering failed — continuing without label"
    fi
  fi

  verify_roundtrip "$OUT_FILE" "$PAYLOAD"
  log_row "qr" "$QR_CT" "$PAYLOAD" "$OUT_FILE" "$V_RESULT" "GENERATED"
  N_GEN=$((N_GEN + 1))

  case "$V_RESULT" in
    VERIFIED)
      N_VER=$((N_VER + 1))
      ok "VERIFIED  $OUT_FILE"
      exit "$EX_OK"
      ;;
    MISMATCH)
      N_MISMATCH=$((N_MISMATCH + 1)); N_FAILED=$((N_FAILED + 1))
      err "MISMATCH  $OUT_FILE"
      err "  expected: $(trunc "$PAYLOAD" 70)"
      err "  decoded : $(trunc "$V_DECODED" 70)"
      exit "$EX_VERIFY"
      ;;
    *)
      N_SKIPPED=$((N_SKIPPED + 1))
      warn "generated (verification skipped)  $OUT_FILE"
      exit "$EX_OK"
      ;;
  esac
}

# ========================================================== barcode mode

parse_barcode_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --ean|--upc|--code128|--code39|--isbn)
        if [ -n "$BC_TYPE" ]; then die_input "only one barcode type per run"; fi
        if [ $# -lt 2 ] || [[ "${2:-}" == --* ]]; then die_input "missing value for $1"; fi
        BC_TYPE="${1#--}"
        BC_VALUE="$2"
        if [ -z "$BC_VALUE" ]; then die_input "$1 needs a non-empty value"; fi
        shift 2
        ;;
      --label)
        if [ $# -lt 2 ]; then die_input "--label needs a text value"; fi
        LABEL="$2"; shift 2
        ;;
      --svg) SVG=1; shift ;;
      --no-verify) VERIFY=0; shift ;;
      -h|--help) usage; exit "$EX_OK" ;;
      *) die_input "unknown option for barcode: $1" ;;
    esac
  done
  if [ -z "$BC_TYPE" ]; then
    die_input "barcode needs a type: --ean --upc --code128 --code39 --isbn"
  fi
  if [ -n "$LABEL" ] && [ "$SVG" = 1 ]; then
    warn "--label is skipped for SVG output (raster only)"
    LABEL=""
  fi
}

do_barcode() {
  probe_deps
  need_bins zint
  parse_barcode_args "$@"
  notice_verification_state

  if ! PAYLOAD="$(build_bc_payload "$BC_TYPE" "$BC_VALUE")"; then
    exit "$EX_INPUT"
  fi

  info "BARCODE [$BC_TYPE] payload: $(trunc "$PAYLOAD" 64)"

  if ! mkdir -p "$GENERATED_DIR" 2>/dev/null; then
    err "cannot create output directory: $GENERATED_DIR"
    exit "$EX_INPUT"
  fi

  local ext="png"
  if [ "$SVG" = 1 ]; then ext="svg"; fi
  OUT_FILE="$GENERATED_DIR/bc-${BC_TYPE}-$(date +%Y%m%d-%H%M%S)-$RANDOM.$ext"

  if ! gen_barcode_image "$PAYLOAD" "$OUT_FILE" "$BC_TYPE"; then
    exit "$EX_INPUT"
  fi

  if [ -n "$LABEL" ]; then
    if [ "$HAVE_IM" != 1 ]; then
      warn "ImageMagick not found — caption skipped, code value still printed by zint (install imagemagick)"
    elif ! apply_label "$OUT_FILE" "$LABEL — $PAYLOAD"; then
      warn "label rendering failed — continuing without label"
    fi
  fi

  verify_roundtrip "$OUT_FILE" "$PAYLOAD"
  log_row "barcode" "$BC_TYPE" "$PAYLOAD" "$OUT_FILE" "$V_RESULT" "GENERATED"
  N_GEN=$((N_GEN + 1))

  case "$V_RESULT" in
    VERIFIED)
      N_VER=$((N_VER + 1))
      ok "VERIFIED  $OUT_FILE"
      exit "$EX_OK"
      ;;
    MISMATCH)
      N_MISMATCH=$((N_MISMATCH + 1)); N_FAILED=$((N_FAILED + 1))
      err "MISMATCH  $OUT_FILE"
      err "  expected: $(trunc "$PAYLOAD" 70)"
      err "  decoded : $(trunc "$V_DECODED" 70)"
      exit "$EX_VERIFY"
      ;;
    *)
      N_SKIPPED=$((N_SKIPPED + 1))
      warn "generated (verification skipped)  $OUT_FILE"
      exit "$EX_OK"
      ;;
  esac
}

# ============================================================ batch mode

append_card() {  # $1 body-file, $2 img, $3 name, $4 sku, $5 price, $6 verified, $7 wide
  local badge
  if [ "$6" = "VERIFIED" ]; then
    badge='<span class="badge ok">✓ VERIFIED</span>'
  else
    badge='<span class="badge warn">⚠ UNVERIFIED</span>'
  fi
  {
    if [ "$7" = "1" ]; then
      printf '<div class="card wide">\n'
    else
      printf '<div class="card">\n'
    fi
    printf '  <div class="name">%s</div>\n' "$(html_escape "$3")"
    if [ -n "$4" ]; then
      printf '  <div class="sku">SKU · %s</div>\n' "$(html_escape "$4")"
    fi
    if [ -n "$5" ]; then
      printf '  <div class="price">%s</div>\n' "$(html_escape "$5")"
    fi
    printf '  <div class="code"><img src="%s" alt="%s code"></div>\n' \
      "$(html_escape "${2##*/}")" "$(html_escape "$3")"
    printf '  %s\n' "$badge"
    printf '</div>\n'
  } >> "$1"
}

batch_row_fail() {  # $1 idx, $2 typ, $3 name, $4 msg
  N_FAILED=$((N_FAILED + 1))
  err "row $1 [$2]: $4"
  log_row "batch" "${2:--}" "-" "-" "n/a" "FAILED"
  FAILED_NAMES+="${3:+$3, }"
  return 1
}

process_batch_row() {  # $1 row-index; CSV_FIELDS hold name,sku,type,code_value,price
  local idx="$1"
  local name="" sku="" typ="" val="" price=""
  if [ "${#CSV_FIELDS[@]}" -gt 0 ]; then name="$(trim "${CSV_FIELDS[0]}")"; fi
  if [ "${#CSV_FIELDS[@]}" -gt 1 ]; then sku="$(trim "${CSV_FIELDS[1]}")"; fi
  if [ "${#CSV_FIELDS[@]}" -gt 2 ]; then typ="$(printf '%s' "$(trim "${CSV_FIELDS[2]}")" | tr '[:upper:]' '[:lower:]')"; fi
  if [ "${#CSV_FIELDS[@]}" -gt 3 ]; then val="$(trim "${CSV_FIELDS[3]}")"; fi
  if [ "${#CSV_FIELDS[@]}" -gt 4 ]; then price="$(trim "${CSV_FIELDS[4]}")"; fi

  if [ -z "$name" ] && [ -z "$typ" ] && [ -z "$val" ]; then
    return 0   # entirely blank row — ignore silently
  fi

  if [ -z "$name" ]; then batch_row_fail "$idx" "$typ" "$name" "missing product name"; return 1; fi
  if [ -z "$typ" ];   then batch_row_fail "$idx" "$typ" "$name" "missing type column";    return 1; fi

  local payload="" wide=0
  case "$typ" in
    url|text|raw)
      if [ -z "$val" ]; then batch_row_fail "$idx" "$typ" "$name" "empty code_value for $typ"; return 1; fi
      QR_VALUE="$val"; payload="$val"
      ;;
    wifi)
      local s p a
      IFS='|' read -r s p a <<< "$val"
      WIFI_SSID="$(trim "$s")"; WIFI_PASS="$(trim "${p:-}")"; WIFI_AUTH="$(trim "${a:-WPA}")"
      if [ -z "$WIFI_SSID" ]; then batch_row_fail "$idx" "$typ" "$name" "wifi needs code_value 'SSID|password|auth'"; return 1; fi
      if ! payload="$(build_wifi_payload)"; then batch_row_fail "$idx" "$typ" "$name" "invalid wifi settings"; return 1; fi
      ;;
    vcard)
      local n t e
      IFS='|' read -r n t e <<< "$val"
      VC_NAME="$(trim "${n:-}")"; VC_TEL="$(trim "${t:-}")"; VC_EMAIL="$(trim "${e:-}")"
      if ! payload="$(build_vcard_payload)"; then batch_row_fail "$idx" "$typ" "$name" "invalid vcard"; return 1; fi
      ;;
    geo)
      if [[ "$val" != *,* ]]; then
        batch_row_fail "$idx" "$typ" "$name" "geo needs code_value 'LAT,LON' (got: '$val')"; return 1
      fi
      GEO_LAT="$(trim "${val%%,*}")"
      GEO_LON="$(trim "${val#*,}")"
      if ! payload="$(build_geo_payload)"; then batch_row_fail "$idx" "$typ" "$name" "invalid geo value '$val'"; return 1; fi
      ;;
    ean)
      if ! payload="$(build_ean13_payload "$val")"; then batch_row_fail "$idx" "$typ" "$name" "invalid EAN value '$val'"; return 1; fi
      wide=1
      ;;
    upc)
      if ! payload="$(build_upca_payload "$val")"; then batch_row_fail "$idx" "$typ" "$name" "invalid UPC value '$val'"; return 1; fi
      wide=1
      ;;
    code128)
      if [ -z "$val" ]; then batch_row_fail "$idx" "$typ" "$name" "empty code_value"; return 1; fi
      payload="$val"; wide=1
      ;;
    code39)
      if ! payload="$(build_code39_payload "$val")"; then batch_row_fail "$idx" "$typ" "$name" "invalid code39 value '$val'"; return 1; fi
      wide=1
      ;;
    isbn)
      if ! payload="$(build_isbn_payload "$val")"; then batch_row_fail "$idx" "$typ" "$name" "invalid isbn value '$val'"; return 1; fi
      wide=1
      ;;
    *)
      batch_row_fail "$idx" "$typ" "$name" "unknown type '$typ' (use: url text wifi vcard geo raw ean upc code128 code39 isbn)"
      return 1
      ;;
  esac

  # unique output path: generated/<slug>.png
  local base f i=2
  base="$(slugify "$name")"
  f="$GENERATED_DIR/$base.png"
  while [ -e "$f" ]; do
    f="$GENERATED_DIR/$base-$i.png"
    i=$((i + 1))
  done

  # generate
  case "$typ" in
    url|text|wifi|vcard|geo|raw)
      if ! gen_qr_image "$payload" "$f"; then
        batch_row_fail "$idx" "$typ" "$name" "qrencode failed"; return 1
      fi
      ;;
    ean|upc|code128|code39|isbn)
      if ! gen_barcode_image "$payload" "$f" "$typ"; then
        batch_row_fail "$idx" "$typ" "$name" "zint failed"; return 1
      fi
      ;;
  esac

  # label: product name (+ value for barcodes) under the code
  if [ "$HAVE_IM" = 1 ]; then
    local lbl="$name"
    case "$typ" in
      ean|upc|code128|code39|isbn) lbl="$name — $payload" ;;
    esac
    if ! apply_label "$f" "$lbl"; then
      warn "row $idx: label rendering failed — continuing without"
    fi
  elif [ "$LABEL_WARNED" != 1 ]; then
    warn "ImageMagick not found — labels skipped (install imagemagick)"
    LABEL_WARNED=1
  fi

  verify_roundtrip "$f" "$payload"
  log_row "batch" "$typ" "$payload" "$f" "$V_RESULT" "GENERATED"
  N_GEN=$((N_GEN + 1))

  case "$V_RESULT" in
    VERIFIED)
      N_VER=$((N_VER + 1))
      printf '  %s✔%s %-30s %s\n' "$C_G" "$C_0" "$(trunc "$name" 30)" "${f##*/}" >&2
      ;;
    MISMATCH)
      N_MISMATCH=$((N_MISMATCH + 1)); N_FAILED=$((N_FAILED + 1))
      FAILED_NAMES+="${name:+$name, }"
      printf '  %s✗%s %-30s %s — expected %s, decoded %s\n' \
        "$C_R" "$C_0" "$(trunc "$name" 30)" "${f##*/}" \
        "$(trunc "$payload" 24)" "$(trunc "$V_DECODED" 24)" >&2
      ;;
    *)
      N_SKIPPED=$((N_SKIPPED + 1))
      printf '  %s•%s %-30s %s (verification skipped)\n' "$C_Y" "$C_0" "$(trunc "$name" 30)" "${f##*/}" >&2
      ;;
  esac

  append_card "$BODY_FILE" "$f" "$name" "$sku" "$price" "$V_RESULT" "$wide"
  return 0
}

write_contact_sheet() {  # $1 body-file, $2 out-html, $3 count, $4 failed-names, $5 generated-time, $6 failed-count
  {
    cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>codesmith — Shelf Label Sheet ($3 labels)</title>
<style>
  :root { --ink:#16181d; --muted:#6b7280; --line:#e5e7eb; --accent:#0f766e; }
  * { box-sizing:border-box; margin:0; padding:0; }
  body { font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif;
         color:var(--ink); background:#f6f7f9; padding:28px; }
  .sheet-head { display:flex; align-items:flex-end; justify-content:space-between;
                gap:16px; flex-wrap:wrap; margin-bottom:18px; }
  h1 { font-size:20px; letter-spacing:-0.01em; }
  .meta { color:var(--muted); font-size:12.5px; margin-top:4px; }
  .btn { border:1px solid var(--ink); background:var(--ink); color:#fff; padding:9px 18px;
         border-radius:8px; font-size:13px; cursor:pointer; }
  .btn:hover { opacity:.85; }
  .failnote { background:#fdeceb; color:#b3261e; border:1px solid #f5c6c2; border-radius:8px;
              padding:10px 14px; font-size:13px; margin-bottom:16px; }
  .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(230px,1fr)); gap:14px; }
  .card { background:#fff; border:1px solid var(--line); border-radius:12px;
          padding:16px 14px; text-align:center; break-inside:avoid; page-break-inside:avoid;
          display:flex; flex-direction:column; align-items:center; gap:5px; }
  .name  { font-weight:700; font-size:14.5px; }
  .sku   { color:var(--muted); font-size:11px; text-transform:uppercase; letter-spacing:.06em; }
  .price { font-size:17px; font-weight:700; color:var(--accent); }
  .code  { margin-top:6px; }
  .code img { width:168px; max-width:100%; display:block; image-rendering:pixelated; }
  .card.wide .code img { width:100%; image-rendering:auto; }
  .badge { font-size:10px; font-weight:600; padding:2px 9px; border-radius:99px; letter-spacing:.03em; }
  .ok   { background:#e5f5ec; color:#15803d; }
  .warn { background:#fdf3d8; color:#9a6b00; }
  footer { margin-top:22px; color:var(--muted); font-size:11.5px; text-align:center; }
  @page { size:A4; margin:12mm; }
  @media print {
    body { background:#fff; padding:0; }
    .btn { display:none; }
    .grid { grid-template-columns:repeat(3,1fr); gap:10px; }
    .card { border-radius:0; border-color:#d1d5db; }
  }
</style>
</head>
<body>
  <div class="sheet-head">
    <div>
      <h1>Shelf Label Sheet</h1>
      <div class="meta">$3 labels · generated $5 · by codesmith.sh</div>
    </div>
    <button class="btn" onclick="window.print()">🖨 Print</button>
  </div>
EOF
    if [ "${6:-0}" -gt 0 ]; then
      printf '  <div class="failnote">⚠ %s label(s) failed or did not verify and need attention' "$6"
      if [ -n "$4" ]; then printf ': %s' "$(html_escape "$4")"; fi
      printf '</div>\n'
    fi
    printf '  <div class="grid">\n'
    cat "$1"
    printf '  </div>\n'
    cat <<'FOOT'
  <footer>Generated by codesmith.sh — sized for ~35 mm labels. Scan one test print before mass printing.</footer>
</body>
</html>
FOOT
  } > "$2"
}

do_batch() {
  probe_deps

  local file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-verify) VERIFY=0; shift ;;
      -h|--help)   usage; exit "$EX_OK" ;;
      -*) die_input "unknown option for batch: $1 (supported: --no-verify)" ;;
      *)
        if [ -n "$file" ]; then die_input "batch takes a single CSV file (unexpected: $1)"; fi
        file="$1"; shift ;;
    esac
  done
  if [ -z "$file" ]; then
    die_input "batch needs a CSV file — see: $SCRIPT_NAME --help"
  fi
  if [ ! -f "$file" ]; then
    die_input "CSV file not found: $file"
  fi

  local -a rows=()
  local line r0=1
  # plain while-read (not mapfile) — keeps the stock macOS bash 3.2 supported
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [ "$r0" = 1 ]; then
      line="${line#$'\xEF\xBB\xBF'}"   # strip UTF-8 BOM
      r0=0
    fi
    if [ -z "$(trim "$line")" ]; then continue; fi   # blank line
    if [[ "$line" == \#* ]]; then continue; fi       # comment line
    rows+=("$line")
  done < "$file"
  if [ "${#rows[@]}" = 0 ]; then
    die_input "no data rows in $file"
  fi
  notice_verification_state

  # pre-flight: which engines do we need?
  local need_qr=0 need_bc=0 i
  for ((i = 0; i < ${#rows[@]}; i++)); do
    csv_split "${rows[i]}"
    local t=""
    if [ "${#CSV_FIELDS[@]}" -gt 2 ]; then t="$(printf '%s' "$(trim "${CSV_FIELDS[2]}")" | tr '[:upper:]' '[:lower:]')"; fi
    case "$t" in
      url|text|wifi|vcard|geo|raw) need_qr=1 ;;
      ean|upc|code128|code39|isbn) need_bc=1 ;;
    esac
  done
  if [ "$need_qr" = 1 ]; then need_bins qrencode; fi
  if [ "$need_bc" = 1 ]; then need_bins zint; fi

  if ! mkdir -p "$GENERATED_DIR" 2>/dev/null; then
    err "cannot create output directory: $GENERATED_DIR"
    exit "$EX_INPUT"
  fi
  ensure_tmp

  BODY_FILE="$SELF_TMP/body.html"
  : > "$BODY_FILE"
  FAILED_NAMES=""
  LABEL_WARNED=0

  info "batch: ${#rows[@]} row(s) from $file"
  local idx=0 first=1
  for line in "${rows[@]}"; do
    idx=$((idx + 1))
    csv_split "$line"
    # optional header row
    if [ "$first" = 1 ]; then
      first=0
      local h0=""
      if [ "${#CSV_FIELDS[@]}" -gt 0 ]; then h0="$(printf '%s' "$(trim "${CSV_FIELDS[0]}")" | tr '[:upper:]' '[:lower:]')"; fi
      if [ "$h0" = "name" ]; then
        info "header row detected — skipped"
        continue
      fi
    fi
    process_batch_row "$idx" || true
  done

  # build the print-ready sheet
  local sheet="$GENERATED_DIR/contact_sheet.html"
  local gen_time
  gen_time="$(date '+%Y-%m-%d %H:%M')"
  write_contact_sheet "$BODY_FILE" "$sheet" "$N_GEN" "${FAILED_NAMES%, }" "$gen_time" "$N_FAILED"

  printf '%s\n' "────────────────────────────────────────" >&2
  printf '%sBATCH SUMMARY:%s %s%d generated%s, %s%d verified%s, %s%d failed%s (%d mismatch, %d skipped)' \
    "$C_B" "$C_0"  "$C_G" "$N_GEN" "$C_0"  "$C_G" "$N_VER" "$C_0" \
    "$C_R" "$N_FAILED" "$C_0"  "$N_MISMATCH" "$N_SKIPPED" >&2
  if [ "$N_FAILED" = 0 ]; then
    printf '%s\n' " — sheet: $sheet" >&2
  else
    printf '%s\n' " — sheet (unverified items flagged): $sheet" >&2
  fi

  if [ "$N_FAILED" -gt 0 ]; then
    exit "$EX_VERIFY"
  fi
  exit "$EX_OK"
}

# ============================================================ self-test

do_selftest() {
  probe_deps
  ensure_tmp
  local pass=0 fail=0 skip=0
  local line
  local -a rows=()

  t() {  # desc expected actual
    if [ "$2" = "$3" ]; then
      pass=$((pass + 1))
      printf '  %s[PASS]%s %s\n' "$C_G" "$C_0" "$1"
    else
      fail=$((fail + 1))
      printf '  %s[FAIL]%s %s — expected %q, got %q\n' "$C_R" "$C_0" "$1" "$2" "$3"
    fi
  }
  s() {  # desc reason
    skip=$((skip + 1))
    printf '  %s[SKIP]%s %s (%s)\n' "$C_Y" "$C_0" "$1" "$2"
  }

  printf '%s\n' "${C_B}codesmith self-test${C_0}"
  printf '%s\n' ""

  # --- 1) QR roundtrip with known text --------------------------------
  if [ "$HAVE_QRENCODE" = 1 ] && [ "$HAVE_ZBAR" = 1 ]; then
    local p f
    p="codesmith-selftest-$(date +%s)"
    f="$SELF_TMP/st.png"
    if qrencode -l M -s 4 -m 2 -t PNG -o "$f" -- "$p"; then
      verify_roundtrip "$f" "$p"
      t "QR roundtrip decodes to the original text" "VERIFIED" "$V_RESULT"
    else
      s "QR roundtrip" "qrencode could not write test image"
    fi
  else
    s "QR roundtrip" "needs qrencode + zbarimg"
  fi

  # --- 2) check-digit math against known-good examples -----------------
  t "EAN-13 check digit: 400638133393 -> 1" "1" "$(ean13_check 400638133393)"
  t "EAN-13 check digit: 590123412345 -> 7" "7" "$(ean13_check 590123412345)"
  t "EAN-13 check digit: 890123456789 -> 0" "0" "$(ean13_check 890123456789)"
  t "UPC-A check digit: 03600029145 -> 2"   "2" "$(upc_check 03600029145)"
  t "UPC-A check digit: 01234567890 -> 5"   "5" "$(upc_check 01234567890)"

  t "ISBN-10 0306406152 -> EAN 9780306406157" "9780306406157" "$(build_isbn_payload 0306406152)"
  t "ISBN-10 with X check char 080442957X accepted" "9780804429573" "$(build_isbn_payload 080442957X)"
  t "invalid ISBN-10 check digit rejected (rc 1)" "1" \
    "$( set +e; build_isbn_payload 0306406153 >/dev/null 2>&1; echo $? )"
  t "EAN with 11 digits rejected (rc 1)" "1" \
    "$( set +e; build_ean13_payload 40063813339 >/dev/null 2>&1; echo $? )"
  t "EAN with 13 digits (check given) rejected (rc 1)" "1" \
    "$( set +e; build_ean13_payload 4006381333931 >/dev/null 2>&1; echo $? )"
  t "wifi with empty SSID rejected (rc 1)" "1" \
    "$( set +e; WIFI_SSID=''; WIFI_PASS='x'; WIFI_AUTH='WPA'; build_wifi_payload >/dev/null 2>&1; echo $? )"
  t "vcard with empty name rejected (rc 1)" "1" \
    "$( set +e; VC_NAME=''; build_vcard_payload >/dev/null 2>&1; echo $? )"

  WIFI_SSID="OfficeGuest"; WIFI_PASS="welcome123"; WIFI_AUTH="WPA"
  t "wifi payload (WPA)" "WIFI:T:WPA;S:OfficeGuest;P:welcome123;;" "$(build_wifi_payload)"
  WIFI_SSID="Cafe Guest"; WIFI_PASS=""; WIFI_AUTH="none"
  t "wifi payload (nopass)" "WIFI:T:nopass;S:Cafe Guest;;" "$(build_wifi_payload)"
  VC_NAME="Ravi Kumar"; VC_TEL="+919876543210"; VC_EMAIL="ravi@corp.com"
  t "vcard payload (MECARD)" \
    "MECARD:N:Ravi Kumar;TEL:+919876543210;EMAIL:ravi@corp.com;;" "$(build_vcard_payload)"

  # --- 3) CSV parser with a 3-row sample in a temp dir ------------------
  local cf="$SELF_TMP/sample.csv"
  {
    printf 'name,sku,type,code_value,price\n'
    printf 'Widget A,W-1,ean,400638133393,10.50\n'
    printf '"Widget, B",W-2,code128,"AB-123, X",5\n'
    printf 'Widget C,W-3,url,https://example.com,3\n'
  } > "$cf"
  # plain while-read (not mapfile) — keeps the stock macOS bash 3.2 supported
  while IFS= read -r line || [ -n "$line" ]; do rows+=("$line"); done < "$cf"
  t "csv sample has 3 data rows" "3" "$(( ${#rows[@]} - 1 ))"
  csv_split "${rows[1]}"
  t "csv plain fields parsed" "Widget A" "${CSV_FIELDS[0]}"
  t "csv numeric field parsed" "400638133393" "${CSV_FIELDS[3]}"
  csv_split "${rows[2]}"
  t "csv quoted field with comma" "Widget, B" "${CSV_FIELDS[0]}"
  t "csv inner quoted value kept" "AB-123, X" "${CSV_FIELDS[3]}"

  printf '%s\n' ""
  printf '%s%d passed%s, %s%d failed%s, %d skipped\n' \
    "$C_G" "$pass" "$C_0" "$C_R" "$fail" "$C_0" "$skip"
  if [ "$fail" -gt 0 ]; then
    exit 1
  fi
  exit "$EX_OK"
}

# ================================================================== help

usage_short() {
  cat >&2 <<'USAGE'
usage: codesmith.sh qr --url|--text|--wifi|--vcard|--geo|--raw [flags]
       codesmith.sh barcode --ean|--upc|--code128|--code39|--isbn [flags]
       codesmith.sh batch products.csv
       codesmith.sh --log | --selftest | --help
USAGE
}

usage() {
  cat <<'HELP'
codesmith.sh — batch QR & barcode generator with roundtrip verification
Corporate label printing: inventory labels, asset tags, WiFi posters, contact sharing.

USAGE
  codesmith.sh qr --url|--text|--wifi|--vcard|--geo|--raw … [flags]
  codesmith.sh barcode --ean|--upc|--code128|--code39|--isbn VALUE [flags]
  codesmith.sh batch products.csv
  codesmith.sh --log | --selftest | --version | --help

QUICK START — five copy-paste examples
  1) ./codesmith.sh qr --url "https://example.com"
  2) ./codesmith.sh qr --wifi "OfficeGuest" "welcome123" WPA
  3) ./codesmith.sh qr --url "https://x.com" --logo brand.png
  4) ./codesmith.sh barcode --ean 890123456789 --label "Neem Oil 250ml"
  5) ./codesmith.sh batch products.csv        # → generated/contact_sheet.html

QR CONTENT TYPES
  --url URL                plain URL                        --url "https://example.com"
  --text TEXT              arbitrary text                   --text "water the ficus every 3 days"
  --wifi SSID [PASS] [AUTH]  → WIFI:T:WPA;S:<ssid>;P:<pass>;; (WEP / none supported)
  --vcard NAME PHONE EMAIL   → MECARD:N:<name>;TEL:<phone>;EMAIL:<mail);;
  --geo LAT LONG             → GEO:<lat>,<long>
  --raw PAYLOAD            custom payload, passed through untouched

QR FLAGS
  --size N        module size in pixels (default 4)
  --ec L|M|Q|H    error correction level (default M)
  --svg           vector output for print quality
  --fg HEX --bg HEX   colors, e.g. --fg 1a1a2e --bg ffffff
  --logo FILE     centered logo overlay (ImageMagick). Requires EC H — auto-upgraded.
                  Rejects if the logo would cover > 25% of the symbol.
                  Tune size with CS_LOGO_PCT (percent of QR width, default 25).
  --terminal      render a SCANNABLE QR right in the terminal — no file written
  --label TEXT    caption rendered under the code (raster output)

BARCODE TYPES (zint)
  --ean 12digits    EAN-13 — the 13th check digit is COMPUTED for you (1x/3x mod 10)
  --upc 11digits    UPC-A  — check digit computed automatically
  --code128 TEXT    arbitrary text — best for SKUs like SKU-4821-BLUE
  --code39 TEXT     legacy logistics (A-Z 0-9 - . $ / + % space)
  --isbn VALUE      ISBN-10 or ISBN-13 (978/979), check digit computed/verified
BARCODE FLAGS
  --label "NAME"    product name + code value as caption under the bars
  --svg             vector output
  --no-verify       skip roundtrip verification (warning printed)

BATCH MODE
  CSV columns: name,sku,type,code_value,price   (header optional; quote fields
    that contain commas; a field cannot span multiple lines)
    Neem Oil 250ml,SKU-4821,ean,890123456789,₹249
    HDMI Cable 2m,HD-2001,code128,HD-2001-CABLE,₹399
    Office WiFi,NET-01,wifi,OfficeGuest|welcome123|WPA,
    Support,SUP-01,vcard,Ravi Kumar|+919876543210|ravi@corp.com,
    Store,LOC-01,geo,"12.9716,77.5946",
  Each row → labeled code in generated/<slug>.png → verified → tallied.
  Builds generated/contact_sheet.html: a print-ready grid (name, price, code) —
  open in any browser, hit Print, stick on shelves.

ROUNDTRIP VERIFICATION
  Every generated code is decoded back with zbarimg and compared to the input.
  VERIFIED / MISMATCH is reported per item; mismatches are counted, logged and
  reflected in the exit code. --no-verify skips with a warning; if zbarimg is
  missing, verification degrades gracefully with a notice.

LOGGING
  codesmith_log.csv (append-only): timestamp,mode,content_type,payload,output_file,verified,status
  --log renders the last 10 rows as an aligned color table.

SELF-TEST
  --selftest runs: QR roundtrip, EAN-13/UPC check-digit math, CSV parser. Exit 1 on failure.

FILES
  generated/            output codes + contact_sheet.html
  codesmith_log.csv     append-only activity log

DEPENDENCIES
  required : qrencode (qr mode), zint (barcode mode)
  optional : zbarimg (verification), ImageMagick (--logo, --label)
  missing?   sudo apt install qrencode zint zbar-tools imagemagick

EXIT CODES
  0 ok · 1 verification failed · 2 missing dependency · 3 bad input
HELP
}

# ================================================================== main

main() {
  local cmd="${1:-}"
  if [ -z "$cmd" ]; then
    usage
    exit "$EX_OK"
  fi
  case "$cmd" in
    qr)              shift; do_qr "$@" ;;
    barcode|bar)     shift; do_barcode "$@" ;;
    batch)           shift; do_batch "$@" ;;
    --log|log)       do_log ;;
    --selftest|selftest) do_selftest ;;
    --help|-h|help)  usage; exit "$EX_OK" ;;
    --version|-v)    printf 'codesmith %s\n' "$VERSION" ;;
    *)
      err "unknown command: $cmd"
      printf '\n' >&2
      usage_short
      exit "$EX_INPUT"
      ;;
  esac
  exit "$EX_OK"
}

main "$@"
