#!/usr/bin/env bash

# ============================================================
#
#    ██████╗  █████╗ ██████╗ ██╗  ██╗    ███╗   ███╗ █████╗ ████████╗████████╗███████╗██████╗
#    ██╔══██╗██╔══██╗██╔══██╗██║ ██╔╝    ████╗ ████║██╔══██╗╚══██╔══╝╚══██╔══╝██╔════╝██╔══██╗
#    ██║  ██║███████║██████╔╝█████╔╝     ██╔████╔██║███████║   ██║      ██║   █████╗  ██████╔╝
#    ██║  ██║██╔══██║██╔══██╗██╔═██╗     ██║╚██╔╝██║██╔══██║   ██║      ██║   ██╔══╝  ██╔══██╗
#    ██████╔╝██║  ██║██║  ██║██║  ██╗    ██║ ╚═╝ ██║██║  ██║   ██║      ██║   ███████╗██║  ██║
#    ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝     ╚═╝╚═╝  ╚═╝   ╚═╝      ╚═╝   ╚══════╝╚═╝  ╚═╝
#
#    ██████╗ ███████╗ ██████╗ ██████╗ ███╗   ██╗
#    ██╔══██╗██╔════╝██╔════╝██╔═══██╗████╗  ██║
#    ██████╔╝█████╗  ██║     ██║   ██║██╔██╗ ██║
#    ██╔══██╗██╔══╝  ██║     ██║   ██║██║╚██╗██║
#    ██║  ██║███████╗╚██████╗╚██████╔╝██║ ╚████║
#    ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═════╝╚═╝  ╚═══╝
#
#    GlobalDarkRecon — Dark Matter Recon v2.0
#    Red Team OSINT Challenge Framework
#    For use on domains you own only.
#
# ============================================================

# ── BASH VERSION CHECK ───────────────────────────────────────
if (( BASH_VERSINFO[0] < 4 )); then
    echo "Error: Bash 4.0+ required (running $BASH_VERSION)"
    echo "Tip (macOS): brew install bash && sudo bash $0 $*"
    exit 1
fi

# ── GLOBAL CONFIG ────────────────────────────────────────────
SCRIPT_VERSION="2.0"
TARGET=""
TARGET_FILE=""
SHODAN_API_KEY="${SHODAN_API_KEY:-}"
SINGLE_PHASE=""
STEALTH_MODE=false
QUIET=false
LIGHT_MODE=false
ENABLE_AMASS=false

# Initialized per target by init_target_env()
RESULTS_DIR=""
REPORT=""
REAL_IP_FILE=""
GRAVATAR_FILE=""
CURRENT_PHASE=0
SCAN_START_SECONDS=$SECONDS

# ── SEVERITY COUNTERS ────────────────────────────────────────
COUNT_CRITICAL=0
COUNT_HIGH=0
COUNT_MEDIUM=0
COUNT_INFO=0

# ── PHASE TIMING ─────────────────────────────────────────────
declare -A PHASE_TIME

# ── TEMP FILE TRACKING ───────────────────────────────────────
# TEMP_FILES: all temp files (cleaned on exit/signal)
# PHASE_TEMP_FILES: current phase's temp files (cleaned after each phase)
declare -a TEMP_FILES=()
declare -a PHASE_TEMP_FILES=()

# ── GLOBAL USER AGENT LIST ───────────────────────────────────
# Declared globally so all phases (including phase4) can use it.
UA_LIST=(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    "Mozilla/5.0 (X11; Linux x86_64; rv:125.0) Gecko/20100101 Firefox/125.0"
    "Googlebot/2.1 (+http://www.google.com/bot.html)"
    "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)"
)

# ── CLOUDFLARE STATIC IP RANGES ──────────────────────────────
# Hardcoded fallback used when live fetch from cloudflare.com fails.
# Pure-bash CIDR check replaces the original fragile python3 inline.
CF_RANGES_STATIC=(
    "173.245.48.0/20" "103.21.244.0/22" "103.22.200.0/22"
    "103.31.4.0/22"   "141.101.64.0/18" "108.162.192.0/18"
    "190.93.240.0/20" "188.114.96.0/20" "197.234.240.0/22"
    "198.41.128.0/17" "162.158.0.0/15"  "104.16.0.0/13"
    "104.24.0.0/14"   "172.64.0.0/13"   "131.0.72.0/22"
)
CF_RANGES_LIVE=""   # populated during phase0 from live fetch

# ── COLORS ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ════════════════════════════════════════════════════════════
# LOGGING & SEVERITY
# ════════════════════════════════════════════════════════════

log()      { local m="[$(date +%H:%M:%S)] $1"; echo "$m" >> "$REPORT"; [[ "$QUIET" != "true" ]] && echo -e "$m"; }
phase()    { echo ""; echo -e "${MAGENTA}${BOLD}  ╔══════════════════════════════════════════════════════╗"; printf "  ║  %-52s║\n" "$1"; echo -e "  ╚══════════════════════════════════════════════════════╝${NC}"; echo "[PHASE] $1" >> "$REPORT"; }
found()    { COUNT_INFO=$(( COUNT_INFO + 1 )); echo "[INFO]  $1" >> "$REPORT"; [[ "$QUIET" != "true" ]] && echo -e "${GREEN}  [+] $1${NC}"; }
warn()     { echo "[WARN]  $1" >> "$REPORT"; [[ "$QUIET" != "true" ]] && echo -e "${YELLOW}  [!] $1${NC}"; }
miss()     { echo "[MISS]  $1" >> "$REPORT"; [[ "$QUIET" != "true" ]] && echo -e "${RED}  [-] $1${NC}"; }
info()     { COUNT_INFO=$(( COUNT_INFO + 1 )); echo "[INFO]  $1" >> "$REPORT"; [[ "$QUIET" != "true" ]] && echo -e "${CYAN}  [~] $1${NC}"; }
stealth()  { [[ "$QUIET" != "true" ]] && echo -e "${DIM}${CYAN}  [stealth] $1${NC}"; }
sep()      { echo "---" >> "$REPORT"; [[ "$QUIET" != "true" ]] && echo -e "${RED}  ────────────────────────────────────────────────────${NC}"; }

# Severity-coded findings — CRITICAL and HIGH always shown (bypass --quiet)
critical() { COUNT_CRITICAL=$(( COUNT_CRITICAL + 1 )); echo -e "${BOLD}${RED}  [CRITICAL] $1${NC}"; echo "[CRITICAL] $1" >> "$REPORT"; }
high()     { COUNT_HIGH=$(( COUNT_HIGH + 1 ));     echo -e "${RED}  [HIGH]     $1${NC}"; echo "[HIGH] $1" >> "$REPORT"; }
medium()   { COUNT_MEDIUM=$(( COUNT_MEDIUM + 1 )); echo "[MEDIUM] $1" >> "$REPORT"; [[ "$QUIET" != "true" ]] && echo -e "${YELLOW}  [MEDIUM]   $1${NC}"; }

save_ip_candidate() { echo "$1  # $2" >> "$REAL_IP_FILE"; }

# ════════════════════════════════════════════════════════════
# CIDR / IP UTILITIES  (pure bash — no python3 required)
# Uses 64-bit signed bash arithmetic; requires 64-bit OS (standard on modern Linux)
# ════════════════════════════════════════════════════════════

ip_to_int() {
    local a b c d
    IFS='.' read -r a b c d <<< "$1"
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

# Returns 0 (true) if $1 is inside CIDR $2, else 1
ip_in_cidr() {
    local ip="$1" cidr="$2"
    local network="${cidr%/*}" prefix="${cidr#*/}"
    local ip_int net_int mask
    ip_int=$(ip_to_int "$ip")
    net_int=$(ip_to_int "$network")
    (( prefix == 0 )) && return 0
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    (( (ip_int & mask) == (net_int & mask) ))
}

is_cloudflare_ip() {
    local ip="$1"
    local range
    # Prefer live ranges fetched at start of phase0; fall back to static list
    if [[ -n "$CF_RANGES_LIVE" ]]; then
        while IFS= read -r range; do
            [[ -z "$range" ]] && continue
            ip_in_cidr "$ip" "$range" && return 0
        done <<< "$CF_RANGES_LIVE"
    else
        for range in "${CF_RANGES_STATIC[@]}"; do
            ip_in_cidr "$ip" "$range" && return 0
        done
    fi
    return 1
}

# ════════════════════════════════════════════════════════════
# JITTER  (awk with pure-bash fallback if awk is absent)
# ════════════════════════════════════════════════════════════

jitter() {
    local min="${1:-2}" max="${2:-8}"
    local delay
    if command -v awk &>/dev/null; then
        delay=$(awk "BEGIN{srand(); printf \"%.1f\", $min+rand()*($max-$min)}")
    else
        # Pure bash fallback — integer seconds in [min, max]
        local range=$(( max - min ))
        delay=$(( min + RANDOM % (range + 1) ))
    fi
    stealth "Jitter sleep ${delay}s..."
    sleep "$delay"
}

# ════════════════════════════════════════════════════════════
# PROGRESS BAR
# ════════════════════════════════════════════════════════════

show_progress() {
    local completed="$1" total=6
    local pct=$(( completed * 100 / total ))
    local filled=$(( pct / 5 ))
    local bar="" i
    for (( i=0; i<20; i++ )); do
        (( i < filled )) && bar+="█" || bar+="░"
    done
    echo -e "\n${CYAN}  ▶ Progress: [${bar}] ${pct}%  (${completed}/${total} phases complete)${NC}\n"
}

# ════════════════════════════════════════════════════════════
# TEMP FILE MANAGEMENT
# ════════════════════════════════════════════════════════════

# Create a mktemp file tracked for cleanup
make_temp() {
    local f
    f=$(mktemp)
    TEMP_FILES+=("$f")
    PHASE_TEMP_FILES+=("$f")
    echo "$f"
}

# Clean up files created during the current phase
phase_cleanup() {
    local f
    for f in "${PHASE_TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
    PHASE_TEMP_FILES=()
}

# Drop Linux page cache to free RAM between heavy phases
drop_caches() {
    if sudo -n true 2>/dev/null; then
        sync 2>/dev/null
        sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
        stealth "Page cache dropped to free RAM"
    fi
}

# ════════════════════════════════════════════════════════════
# PHASE TIMING WRAPPER
# ════════════════════════════════════════════════════════════

run_phase() {
    local phase_num="$1" phase_func="$2"
    local phase_start=$SECONDS
    CURRENT_PHASE="$phase_num"

    "$phase_func"

    PHASE_TIME["$phase_num"]=$(( SECONDS - phase_start ))
    local t=${PHASE_TIME[$phase_num]}
    info "Phase ${phase_num} completed in $((t/60))m $((t%60))s"

    phase_cleanup
    drop_caches
    show_progress $(( phase_num + 1 ))
}

# ════════════════════════════════════════════════════════════
# CLEANUP & SIGNAL HANDLING
# ════════════════════════════════════════════════════════════

cleanup() {
    local sig="${1:-INT}"
    echo ""
    echo -e "${YELLOW}  [!] Signal ${sig} — cleaning up...${NC}"
    local f
    for f in "${TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
    if [[ -d "${RESULTS_DIR:-}" ]]; then
        echo -e "${CYAN}  [~] Partial results saved to: $RESULTS_DIR${NC}"
        generate_json_report 2>/dev/null || true
    fi
    echo -e "${YELLOW}  [!] Scan aborted.${NC}"
    exit 130
}

trap 'cleanup INT'  INT
trap 'cleanup TERM' TERM

# ════════════════════════════════════════════════════════════
# SYSTEM CHECKS
# ════════════════════════════════════════════════════════════

check_ram() {
    local free_mb
    free_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
    if [[ -n "$free_mb" ]] && (( free_mb < 1500 )); then
        echo -e "${YELLOW}  [!] WARNING: Low RAM — ${free_mb}MB free (recommended: 1500MB+)${NC}"
        echo -e "${YELLOW}      Consider: --light  (reduces nmap parallelism, caps subfinder, skips Wayback)${NC}"
    fi

    local tmp_pct
    tmp_pct=$(df /tmp 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
    if [[ -n "$tmp_pct" ]] && (( tmp_pct > 60 )); then
        echo -e "${YELLOW}  [!] WARNING: /tmp is ${tmp_pct}% full (tmpfs on live USB — keep temp files small)${NC}"
    fi
}

# ════════════════════════════════════════════════════════════
# DOMAIN VALIDATION
# ════════════════════════════════════════════════════════════

validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]]; then
        echo -e "${RED}  [!] '$domain' does not look like a valid domain${NC}"
        return 1
    fi
    local ip
    ip=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    if [[ -z "$ip" ]]; then
        echo -e "${YELLOW}  [!] '$domain' has no A record (may be CDN-only, CNAME, or non-existent)${NC}"
        if [[ -t 0 ]]; then
            read -rp "  Continue anyway? [y/N] " confirm
            [[ "${confirm,,}" == "y" ]] || { echo "Aborted."; return 1; }
        fi
    else
        echo -e "${GREEN}  [+] Domain validated: $domain → $ip${NC}"
    fi
    return 0
}

# ════════════════════════════════════════════════════════════
# PER-TARGET ENVIRONMENT INIT
# ════════════════════════════════════════════════════════════

init_target_env() {
    TARGET="$1"
    RESULTS_DIR="$HOME/dark_matter_results/$(date +%Y%m%d_%H%M%S)_${TARGET//[^a-zA-Z0-9]/_}"
    REPORT="$RESULTS_DIR/DARK_MATTER_REPORT.txt"
    REAL_IP_FILE="$RESULTS_DIR/origin_ip_candidates.txt"
    GRAVATAR_FILE="$RESULTS_DIR/gravatar_hashes.txt"
    COUNT_CRITICAL=0; COUNT_HIGH=0; COUNT_MEDIUM=0; COUNT_INFO=0
    PHASE_TIME=()
    TEMP_FILES=()
    PHASE_TEMP_FILES=()
    CF_RANGES_LIVE=""
    SCAN_START_SECONDS=$SECONDS

    mkdir -p "$RESULTS_DIR"
    touch "$REPORT" "$REAL_IP_FILE"
    {
        echo "DARK MATTER RECON v${SCRIPT_VERSION} — $TARGET — $(date)"
        echo "============================================================"
    } >> "$REPORT"
}

# ════════════════════════════════════════════════════════════
# JSON REPORT GENERATION
# ════════════════════════════════════════════════════════════

generate_json_report() {
    local json_file="$RESULTS_DIR/dark_matter_summary.json"
    local duration=$(( SECONDS - SCAN_START_SECONDS ))
    local end_time; end_time=$(date '+%Y-%m-%dT%H:%M:%S%z')

    # Origin IPs array — read from file, never from a large bash variable
    local origins="[]"
    if [[ -s "$REAL_IP_FILE" ]]; then
        local ips_json="" first=true ip
        while IFS= read -r line; do
            ip="${line%% *}"
            [[ -z "$ip" ]] && continue
            $first || ips_json+=","
            ips_json+="\"${ip}\""
            first=false
        done < <(sort -u "$REAL_IP_FILE")
        origins="[${ips_json}]"
    fi

    # Findings — stream from REPORT line by line
    local findings_json="" first=true severity message
    while IFS= read -r line; do
        severity=""
        [[ "$line" =~ ^\[CRITICAL\]\ (.*) ]] && { severity="CRITICAL"; message="${BASH_REMATCH[1]}"; }
        [[ -z "$severity" ]] && [[ "$line" =~ ^\[HIGH\]\ (.*) ]]     && { severity="HIGH";     message="${BASH_REMATCH[1]}"; }
        [[ -z "$severity" ]] && [[ "$line" =~ ^\[MEDIUM\]\ (.*) ]]   && { severity="MEDIUM";   message="${BASH_REMATCH[1]}"; }
        [[ -z "$severity" ]] && [[ "$line" =~ ^\[INFO\]\ \ (.*) ]]   && { severity="INFO";     message="${BASH_REMATCH[1]}"; }
        [[ -z "$severity" ]] && continue
        # JSON-escape backslashes and double quotes
        message="${message//\\/\\\\}"
        message="${message//\"/\\\"}"
        $first || findings_json+=","$'\n    '
        findings_json+="{\"severity\":\"${severity}\",\"message\":\"${message}\"}"
        first=false
    done < "$REPORT"

    # Phase timings
    local phase_names=("passive" "fingerprint" "subdomains" "portscan" "wordpress" "osint")
    local timings_json="" i
    for i in 0 1 2 3 4 5; do
        [[ $i -gt 0 ]] && timings_json+=","$'\n    '
        timings_json+="\"phase${i}_${phase_names[$i]}\": ${PHASE_TIME[$i]:-0}"
    done

    cat > "$json_file" << EOF
{
  "meta": {
    "tool": "Dark Matter Recon",
    "version": "${SCRIPT_VERSION}",
    "target": "${TARGET}",
    "scan_date": "${end_time}",
    "duration_seconds": ${duration},
    "results_dir": "${RESULTS_DIR}",
    "light_mode": ${LIGHT_MODE},
    "amass_enabled": ${ENABLE_AMASS}
  },
  "severity_summary": {
    "CRITICAL": ${COUNT_CRITICAL},
    "HIGH":     ${COUNT_HIGH},
    "MEDIUM":   ${COUNT_MEDIUM},
    "INFO":     ${COUNT_INFO}
  },
  "phase_timings_seconds": {
    ${timings_json}
  },
  "origin_ip_candidates": ${origins},
  "findings": [
    ${findings_json}
  ]
}
EOF
    found "JSON report written: $json_file"
}

# ════════════════════════════════════════════════════════════
# BANNER
# ════════════════════════════════════════════════════════════

print_banner() {
    clear
    echo -e "${RED}"
    echo '    ██████╗  █████╗ ██████╗ ██╗  ██╗    ███╗   ███╗ █████╗ ████████╗████████╗███████╗██████╗ '
    echo '    ██╔══██╗██╔══██╗██╔══██╗██║ ██╔╝    ████╗ ████║██╔══██╗╚══██╔══╝╚══██╔══╝██╔════╝██╔══██╗'
    echo '    ██║  ██║███████║██████╔╝█████╔╝     ██╔████╔██║███████║   ██║      ██║   █████╗  ██████╔╝'
    echo '    ██║  ██║██╔══██║██╔══██╗██╔═██╗     ██║╚██╔╝██║██╔══██║   ██║      ██║   ██╔══╝  ██╔══██╗'
    echo '    ██████╔╝██║  ██║██║  ██║██║  ██╗    ██║ ╚═╝ ██║██║  ██║   ██║      ██║   ███████╗██║  ██║'
    echo '    ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝     ╚═╝╚═╝  ╚═╝   ╚═╝      ╚═╝   ╚══════╝╚═╝  ╚═╝'
    echo -e "${CYAN}"
    echo '    ██████╗ ███████╗ ██████╗ ██████╗ ███╗   ██╗'
    echo '    ██╔══██╗██╔════╝██╔════╝██╔═══██╗████╗  ██║'
    echo '    ██████╔╝█████╗  ██║     ██║   ██║██╔██╗ ██║'
    echo '    ██╔══██╗██╔══╝  ██║     ██║   ██║██║╚██╗██║'
    echo '    ██║  ██║███████╗╚██████╗╚██████╔╝██║ ╚████║'
    echo '    ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═════╝╚═╝  ╚═══╝'
    echo -e "${NC}"
    echo -e "${RED}  ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄${NC}"
    echo -e "${YELLOW}        ⚡ GlobalDarkRecon — Red Team OSINT Challenge  v${SCRIPT_VERSION} ⚡${NC}"
    echo -e "${RED}  ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀${NC}"
    echo ""
}

# ════════════════════════════════════════════════════════════
# DEPENDENCY CHECK
# ════════════════════════════════════════════════════════════

check_deps() {
    phase "DEPENDENCY CHECK"
    local required=(nmap curl dig whois openssl host)
    local optional=(subfinder wpscan wafw00f whatweb gobuster theHarvester shodan amass awk)
    local missing_opt=()

    for cmd in "${required[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            found "$cmd — OK"
        else
            miss "$cmd — MISSING (required)"
            warn "Install: sudo apt install $cmd -y"
        fi
    done

    sep
    info "Optional tools (enhance scan depth):"
    for cmd in "${optional[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            found "$cmd — available"
        else
            missing_opt+=("$cmd")
            warn "$cmd — not installed (some checks will use fallback)"
        fi
    done

    [[ "$ENABLE_AMASS" == "false" ]] && info "amass disabled by default (use --enable-amass to enable)"
    [[ "$LIGHT_MODE"   == "true"  ]] && info "--light mode: nmap parallelism reduced, subfinder capped at 50, Wayback skipped"

    if [[ ${#missing_opt[@]} -gt 0 ]]; then
        echo ""
        info "Install optional tools for max coverage:"
        echo -e "  ${DIM}sudo apt install wpscan wafw00f whatweb gobuster theharvester -y${NC}"
        echo -e "  ${DIM}go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest${NC}"
    fi
}

# ════════════════════════════════════════════════════════════
# USAGE
# ════════════════════════════════════════════════════════════

usage() {
    echo -e "${CYAN}Usage:${NC}"
    echo "  ./dark_matter_recon.sh <target_domain> [options]"
    echo "  ./dark_matter_recon.sh --target targets.txt  [options]"
    echo ""
    echo -e "${CYAN}Options:${NC}"
    echo "  --target <file>       File with one domain per line (multi-target mode)"
    echo "  --shodan-key <key>    Shodan API key (or: export SHODAN_API_KEY=xxx)"
    echo "  --phase <0-5>         Run a single phase only"
    echo "  --stealth             Maximum stealth mode (slower jitter)"
    echo "  --quiet               Suppress verbose output; only CRITICAL/HIGH shown on screen"
    echo "  --light               Low-RAM mode: reduced nmap, cap subfinder@50, skip Wayback"
    echo "  --enable-amass        Enable amass passive enum (disabled by default — high RAM)"
    echo "  --report-only         Print last saved report and exit"
    echo "  --help, -h            Show this help"
    echo ""
    echo -e "${CYAN}Examples:${NC}"
    echo "  ./dark_matter_recon.sh radiofurqaan.com"
    echo "  ./dark_matter_recon.sh radiofurqaan.com --quiet --light"
    echo "  ./dark_matter_recon.sh --target domains.txt --shodan-key abc123"
    echo "  SHODAN_API_KEY=abc123 ./dark_matter_recon.sh radiofurqaan.com --phase 0"
    echo ""
    echo -e "${CYAN}Results:${NC}"
    echo "  ~/dark_matter_results/<timestamp>_<domain>/"
    echo "  ├── DARK_MATTER_REPORT.txt     (full text report)"
    echo "  ├── dark_matter_summary.json   (machine-readable summary)"
    echo "  ├── origin_ip_candidates.txt   (potential origin IPs)"
    echo "  ├── gravatar_hashes.txt        (extracted MD5 hashes)"
    echo "  ├── nmap_common.txt            (port scan)"
    echo "  └── nmap_scripts.txt           (service fingerprint)"
    exit 0
}

# ════════════════════════════════════════════════════════════
# PHASE 0 — PURE PASSIVE RECON
# No traffic touches the target servers.
# Goal: find real origin IP before firing a single packet.
# ════════════════════════════════════════════════════════════

phase0_passive() {
    phase "PHASE 0 ▶ PURE PASSIVE RECON (zero server contact)"
    info "No traffic will reach $TARGET servers in this phase"
    echo ""

    # Fetch live Cloudflare IP ranges — used throughout this phase
    info "Fetching live Cloudflare IP ranges..."
    CF_RANGES_LIVE=$(curl -s --max-time 10 "https://www.cloudflare.com/ips-v4" 2>/dev/null)
    if [[ -z "$CF_RANGES_LIVE" ]]; then
        warn "Could not fetch live CF ranges — using hardcoded static list"
    else
        found "Cloudflare IP ranges fetched ($(echo "$CF_RANGES_LIVE" | wc -l) ranges)"
    fi

    # ── DNS Resolution ────────────────────────────────────────
    sep
    info "DNS Resolution & Records"
    local CURRENT_IP
    CURRENT_IP=$(dig +short "$TARGET" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    if [[ -n "$CURRENT_IP" ]]; then
        found "Current A record: $TARGET → $CURRENT_IP"
        save_ip_candidate "$CURRENT_IP" "current A record"
    else
        warn "Could not resolve $TARGET via A record"
    fi

    # MX records — often reveal real IP or hosting provider
    info "MX Records (email servers often bypass CDN):"
    while IFS= read -r mx; do
        [[ -z "$mx" ]] && continue
        found "MX: $mx"
        local mx_host="${mx##* }"
        local mx_ip
        mx_ip=$(dig +short "$mx_host" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
        [[ -n "$mx_ip" ]] && save_ip_candidate "$mx_ip" "MX record for $mx"
    done < <(dig MX "$TARGET" +short 2>/dev/null)

    # TXT records — SPF, DKIM, verification tokens
    info "TXT Records (SPF/DKIM/verification):"
    while IFS= read -r txt; do
        [[ -z "$txt" ]] && continue
        found "TXT: $txt"
        # Extract IPs from SPF records — direct ip4:/ip6: entries
        while IFS= read -r spf_entry; do
            local ip="${spf_entry#ip*:}"
            save_ip_candidate "$ip" "SPF record"
            high "Origin IP candidate via SPF: $ip"
        done < <(echo "$txt" | grep -oE 'ip[46]:[0-9a-f.:]+')
    done < <(dig TXT "$TARGET" +short 2>/dev/null | head -10)

    # NS records
    info "Nameservers:"
    while IFS= read -r ns; do
        [[ -n "$ns" ]] && found "NS: $ns"
    done < <(dig NS "$TARGET" +short 2>/dev/null)

    jitter 2 5

    # ── WHOIS ─────────────────────────────────────────────────
    sep
    info "WHOIS — Registrant & Infrastructure"
    local whois_temp
    whois_temp=$(make_temp)
    if whois "$TARGET" > "$whois_temp" 2>/dev/null; then
        grep -iE '(registrar|registrant|name server|creation|expir|status|email)' "$whois_temp" \
            | head -20 | while IFS= read -r line; do info "$line"; done

        if grep -qi "privacy\|redacted\|protected" "$whois_temp"; then
            found "WHOIS privacy protection enabled — registrant hidden"
        else
            medium "WHOIS registrant data may be exposed — check manually"
        fi
    else
        warn "whois lookup failed for $TARGET"
    fi

    jitter 2 4

    # ── Certificate Transparency ──────────────────────────────
    sep
    info "Certificate Transparency Logs (crt.sh) — Subdomain Mining"
    local crt_temp
    crt_temp=$(make_temp)

    # Stream crt.sh JSON directly to temp file — never load full JSON into a variable
    if curl -s --max-time 20 "https://crt.sh/?q=%25.$TARGET&output=json" 2>/dev/null \
        | grep -o '"name_value":"[^"]*"' \
        | sed 's/"name_value":"//;s/"//' \
        | tr ',' '\n' \
        | grep -v '^\*' \
        | grep "\.$TARGET$\|^$TARGET$" \
        | sort -u > "$crt_temp" && [[ -s "$crt_temp" ]]; then

        local crt_count
        crt_count=$(wc -l < "$crt_temp")
        found "Found $crt_count unique subdomains via cert transparency"

        while IFS= read -r sub; do
            found "SUBDOMAIN: $sub"
            local sub_ip
            sub_ip=$(dig +short "$sub" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
            if [[ -n "$sub_ip" ]]; then
                info "  $sub → $sub_ip"
                save_ip_candidate "$sub_ip" "subdomain: $sub"
            fi
        done < "$crt_temp"

        # Flag high-value bypass subdomains
        for bypass in direct mail ftp smtp pop imap cpanel webmail whm dev staging admin api origin; do
            if grep -q "^${bypass}\.${TARGET}$" "$crt_temp"; then
                high "WAF BYPASS CANDIDATE: ${bypass}.$TARGET — likely not behind CDN"
            fi
        done
    else
        warn "crt.sh returned no data (timeout or no certificates found)"
    fi

    jitter 3 6

    # ── Google Dorks ──────────────────────────────────────────
    sep
    info "Google Dork Intelligence (URLs generated for manual review)"
    local DORKS=(
        "site:$TARGET"
        "site:$TARGET filetype:pdf OR filetype:doc OR filetype:xls"
        "site:$TARGET inurl:wp-admin OR inurl:wp-login"
        "site:$TARGET inurl:config OR inurl:backup OR inurl:db"
        "site:$TARGET ext:env OR ext:log OR ext:sql OR ext:bak"
        "\"$TARGET\" password OR credentials OR leaked"
        "site:pastebin.com \"$TARGET\""
        "site:github.com \"$TARGET\""
    )
    for dork in "${DORKS[@]}"; do
        # URL-encode using sed (no python3 required)
        local encoded
        encoded=$(printf '%s' "$dork" | sed 's/ /%20/g; s/:/%3A/g; s/"/%22/g')
        info "https://www.google.com/search?q=$encoded"
    done
    warn "Review these dorks manually in browser — do not automate Google queries"

    jitter 2 4

    # ── Shodan Passive Lookup ─────────────────────────────────
    sep
    info "Shodan Intelligence"
    if [[ -n "$SHODAN_API_KEY" ]]; then
        info "Querying Shodan API for $TARGET..."
        local shodan_result shodan_ip
        shodan_result=$(curl -s --max-time 15 \
            "https://api.shodan.io/dns/resolve?hostnames=$TARGET&key=$SHODAN_API_KEY" 2>/dev/null)
        if [[ $? -ne 0 ]] || [[ -z "$shodan_result" ]]; then
            warn "Shodan DNS resolve failed (network error or invalid key)"
        else
            shodan_ip=$(echo "$shodan_result" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
            if [[ -n "$shodan_ip" ]]; then
                found "Shodan resolved: $TARGET → $shodan_ip"
                save_ip_candidate "$shodan_ip" "Shodan DNS resolve"

                local host_info open_ports vulns
                host_info=$(curl -s --max-time 15 \
                    "https://api.shodan.io/shodan/host/$shodan_ip?key=$SHODAN_API_KEY" 2>/dev/null)
                if [[ -n "$host_info" ]]; then
                    open_ports=$(echo "$host_info" | grep -o '"port":[0-9]*' | sed 's/"port"://' \
                        | tr '\n' ',' | sed 's/,$//')
                    vulns=$(echo "$host_info" | grep -o '"CVE-[^"]*"' | head -10)
                    [[ -n "$open_ports" ]] && high "Shodan open ports: $open_ports"
                    [[ -n "$vulns"      ]] && critical "Shodan CVEs on $shodan_ip: $vulns"
                fi
            fi
        fi

        info "Historical Shodan search for $TARGET..."
        local hist
        hist=$(curl -s --max-time 15 \
            "https://api.shodan.io/shodan/host/search?query=hostname:$TARGET&key=$SHODAN_API_KEY" 2>/dev/null)
        if [[ -n "$hist" ]]; then
            echo "$hist" | grep -oE '"ip_str":"[^"]*"' | sed 's/"ip_str":"//;s/"//' | sort -u \
            | while IFS= read -r hip; do
                save_ip_candidate "$hip" "Shodan historical"
                high "HISTORICAL IP via Shodan: $hip"
            done
        fi
    else
        warn "No Shodan API key — skipping (set SHODAN_API_KEY env var)"
        info "Manual: https://www.shodan.io/search?query=hostname:$TARGET"
    fi

    jitter 2 5

    # ── DNS History ───────────────────────────────────────────
    sep
    info "DNS History — checking for pre-Cloudflare IPs (HackerTarget)"
    # Stream directly into REAL_IP_FILE — no large variable needed
    local hackertarget_out
    hackertarget_out=$(curl -s --max-time 15 \
        "https://api.hackertarget.com/hostsearch/?q=$TARGET" 2>/dev/null)
    if [[ $? -ne 0 ]] || echo "$hackertarget_out" | grep -q "error\|rate limit"; then
        warn "HackerTarget rate limited or failed — try https://securitytrails.com manually"
    else
        echo "$hackertarget_out" | while IFS=',' read -r host ip; do
            if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                found "Historical: $host → $ip"
                save_ip_candidate "$ip" "DNS history: $host"
            fi
        done
    fi

    # ── Origin IP Summary ─────────────────────────────────────
    sep
    echo -e "${BOLD}${RED}  ◆ ORIGIN IP CANDIDATE SUMMARY ◆${NC}"
    if [[ -s "$REAL_IP_FILE" ]]; then
        warn "Possible real origin IPs (may bypass WAF/CDN):"
        sort -u "$REAL_IP_FILE" | while IFS= read -r line; do
            echo -e "${YELLOW}    $line${NC}"
        done

        info "Classifying IPs against Cloudflare ranges..."
        sort -u "$REAL_IP_FILE" | awk '{print $1}' | while IFS= read -r candidate; do
            if is_cloudflare_ip "$candidate"; then
                info "$candidate — Cloudflare edge node (not origin)"
            else
                critical "POTENTIAL ORIGIN IP: $candidate (not a Cloudflare address)"
                echo "[ORIGIN_CANDIDATE] $candidate" >> "$REPORT"
            fi
        done
    else
        found "No origin IP candidates found in passive phase"
    fi
}

# ════════════════════════════════════════════════════════════
# PHASE 1 — SLOW STEALTH FINGERPRINT
# Mimics legitimate browser traffic. Jitter + T1 timing.
# ════════════════════════════════════════════════════════════

phase1_stealth_fingerprint() {
    phase "PHASE 1 ▶ STEALTH FINGERPRINT (mimicking legit traffic)"

    # UA_LIST is declared globally — no local redeclaration needed
    local UA="${UA_LIST[$RANDOM % ${#UA_LIST[@]}]}"
    stealth "Using User-Agent: $UA"

    # ── HTTP Headers Collection ───────────────────────────────
    sep
    info "Collecting HTTP response headers (HTTPS first, then HTTP)..."
    jitter 3 8

    local HEADERS
    HEADERS=$(curl -sI --max-time 15 \
        -H "User-Agent: $UA" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
        -H "Accept-Language: en-US,en;q=0.5" \
        -H "Accept-Encoding: gzip, deflate, br" \
        "https://$TARGET" 2>/dev/null)

    if [[ -z "$HEADERS" ]]; then
        warn "HTTPS failed — trying HTTP"
        HEADERS=$(curl -sI --max-time 15 -H "User-Agent: $UA" "http://$TARGET" 2>/dev/null)
    fi

    if [[ -z "$HEADERS" ]]; then
        miss "Could not retrieve headers from $TARGET (both HTTPS and HTTP failed)"
        return
    fi

    found "Headers obtained"

    # Server disclosure
    local SERVER X_POWERED CF_RAY CF_CACHE VIA X_CF_IP
    SERVER=$(echo "$HEADERS"   | grep -i "^server:"           | head -1 | tr -d '\r')
    X_POWERED=$(echo "$HEADERS"| grep -i "^x-powered-by:"    | head -1 | tr -d '\r')
    CF_RAY=$(echo "$HEADERS"   | grep -i "^cf-ray:"          | head -1 | tr -d '\r')
    CF_CACHE=$(echo "$HEADERS" | grep -i "^cf-cache-status:" | head -1 | tr -d '\r')
    VIA=$(echo "$HEADERS"      | grep -i "^via:"             | head -1 | tr -d '\r')
    X_CF_IP=$(echo "$HEADERS"  | grep -i "^x-forwarded-for:\|cf-connecting-ip:" | head -1 | tr -d '\r')

    [[ -n "$SERVER"    ]] && medium "Server header disclosure: $SERVER"
    [[ -n "$X_POWERED" ]] && medium "X-Powered-By disclosure: $X_POWERED"
    [[ -n "$CF_RAY"    ]] && info   "Cloudflare detected: $CF_RAY"
    [[ -n "$CF_CACHE"  ]] && info   "CF Cache Status: $CF_CACHE"
    [[ -n "$VIA"       ]] && info   "Via header: $VIA"
    [[ -n "$X_CF_IP"   ]] && high   "IP leaked in header: $X_CF_IP"

    # Security headers audit
    sep
    info "Security Headers Audit:"
    # declare -A inside function is fine in bash 4+ — this is local to the function
    declare -A SECURITY_HEADERS=(
        ["Strict-Transport-Security"]="HSTS"
        ["Content-Security-Policy"]="CSP"
        ["X-Frame-Options"]="Clickjacking protection"
        ["X-Content-Type-Options"]="MIME sniffing protection"
        ["Referrer-Policy"]="Referrer policy"
        ["Permissions-Policy"]="Permissions policy"
        ["X-XSS-Protection"]="XSS protection header"
        ["Cross-Origin-Opener-Policy"]="COOP"
        ["Cross-Origin-Resource-Policy"]="CORP"
    )
    for header in "${!SECURITY_HEADERS[@]}"; do
        local label="${SECURITY_HEADERS[$header]}"
        if echo "$HEADERS" | grep -qi "^${header}:"; then
            local VALUE
            VALUE=$(echo "$HEADERS" | grep -i "^${header}:" | head -1 | tr -d '\r')
            found "$label present → $VALUE"
        else
            medium "$label MISSING — $header not set"
        fi
    done

    # HTTP → HTTPS redirect check
    local HTTP_CODE
    HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" --max-time 10 \
        -H "User-Agent: $UA" "http://$TARGET" 2>/dev/null)
    if [[ -z "$HTTP_CODE" ]]; then
        warn "HTTP redirect check failed (curl timeout)"
    elif [[ "$HTTP_CODE" =~ ^30[12] ]]; then
        found "HTTP redirects to HTTPS ($HTTP_CODE)"
    else
        medium "HTTP does not redirect to HTTPS (code: $HTTP_CODE)"
    fi

    jitter 5 12

    # ── WAF Detection ─────────────────────────────────────────
    sep
    info "WAF Detection"
    if command -v wafw00f &>/dev/null; then
        stealth "Running wafw00f..."
        jitter 3 7
        wafw00f "https://$TARGET" 2>/dev/null \
            | grep -iE '(detected|behind|firewall|waf)' \
            | while IFS= read -r line; do warn "WAF: $line"; done
    else
        info "wafw00f not installed — manual WAF fingerprint from headers"
        if   echo "$HEADERS" | grep -qi "cf-ray";      then warn "Cloudflare WAF detected (cf-ray)"
        elif echo "$HEADERS" | grep -qi "x-sucuri";    then warn "Sucuri WAF detected"
        elif echo "$HEADERS" | grep -qi "x-fw-";       then warn "Wordfence detected"
        elif echo "$HEADERS" | grep -qi "aws-waf\|x-amzn"; then warn "AWS WAF detected"
        else info "No obvious WAF signature in headers"
        fi
    fi

    jitter 4 10

    # ── Technology Stack Detection ────────────────────────────
    sep
    info "Technology Stack Detection"
    if command -v whatweb &>/dev/null; then
        stealth "Running whatweb (aggression 1)..."
        jitter 3 6
        whatweb --aggression=1 --user-agent="$UA" "https://$TARGET" 2>/dev/null \
            | tr ',' '\n' | grep -v "^\[" | sed 's/^/  /' \
            | while IFS= read -r line; do info "$line"; done
    else
        info "whatweb not installed — manual tech detection from headers+HTML"
        local body_temp
        body_temp=$(make_temp)
        curl -sL --max-time 15 -H "User-Agent: $UA" "https://$TARGET" 2>/dev/null \
            | head -200 > "$body_temp"
        {
            echo "$HEADERS"
            cat "$body_temp"
        } | grep -ioE 'wordpress|drupal|joomla|shopify|wix|squarespace|laravel|django|ruby on rails|nginx|apache|php|node\.?js|react|vue|angular' \
            | sort -u | while IFS= read -r tech; do
                found "Technology detected: $tech"
            done
    fi

    # ── cPanel Detection ──────────────────────────────────────
    sep
    info "cPanel / Hosting Panel Detection (ports not proxied by Cloudflare)"
    for port in 2082 2083 2086 2087 2095 2096; do
        jitter 1 3
        local CODE
        CODE=$(curl -so /dev/null -w "%{http_code}" --max-time 8 \
            -H "User-Agent: $UA" "https://$TARGET:$port" 2>/dev/null)
        if [[ "$CODE" =~ ^[23] ]]; then
            high "cPanel port OPEN: $port (HTTP $CODE) — often NOT behind CDN"
        else
            miss "cPanel port $port: closed or filtered ($CODE)"
        fi
    done
}

# ════════════════════════════════════════════════════════════
# PHASE 2 — SUBDOMAIN ENUMERATION
# File-based deduplication instead of assoc array in RAM.
# ════════════════════════════════════════════════════════════

phase2_subdomains() {
    phase "PHASE 2 ▶ SUBDOMAIN ENUMERATION"

    # Use a temp file for dedup — avoids loading thousands of subdomains
    # into a bash associative array (RAM-friendly for live USB operation)
    local subs_temp
    subs_temp=$(make_temp)

    # ── subfinder ─────────────────────────────────────────────
    if command -v subfinder &>/dev/null; then
        info "Running subfinder (passive)..."
        jitter 2 5
        if [[ "$LIGHT_MODE" == "true" ]]; then
            stealth "Light mode: capping subfinder at 50 results"
            subfinder -d "$TARGET" -silent 2>/dev/null | head -50 >> "$subs_temp"
        else
            subfinder -d "$TARGET" -silent 2>/dev/null >> "$subs_temp"
        fi
        found "subfinder complete ($(sort -u "$subs_temp" | wc -l) unique so far)"
    fi

    # ── amass passive (disabled by default — high RAM usage) ──
    if [[ "$ENABLE_AMASS" == "true" ]]; then
        if command -v amass &>/dev/null; then
            info "Running amass passive enum..."
            jitter 3 7
            amass enum -passive -d "$TARGET" 2>/dev/null >> "$subs_temp"
            found "amass complete ($(sort -u "$subs_temp" | wc -l) unique so far)"
        else
            warn "amass not installed — skipping"
        fi
    else
        stealth "amass skipped (use --enable-amass to enable)"
    fi

    # ── crt.sh — stream directly to subs_temp ─────────────────
    info "Re-adding crt.sh results..."
    curl -s --max-time 20 "https://crt.sh/?q=%25.$TARGET&output=json" 2>/dev/null \
        | grep -o '"name_value":"[^"]*"' \
        | sed 's/"name_value":"//;s/"//' \
        | tr ',' '\n' \
        | grep -v '^\*' \
        | grep "\.$TARGET$\|^$TARGET$" \
        >> "$subs_temp" || warn "crt.sh fetch failed in phase2"

    jitter 2 5

    # ── DNS Brute Force ────────────────────────────────────────
    sep
    info "DNS Brute Force (common subdomains)..."
    local COMMON_SUBS=(www mail ftp smtp pop imap cpanel whm webmail dev staging api admin
                       portal shop blog cdn static assets media img images upload uploads
                       test demo beta old new secure vpn remote access mx mx1 mx2 ns1 ns2
                       autodiscover autoconfig direct origin backend internal)

    for sub in "${COMMON_SUBS[@]}"; do
        jitter 0.2 0.8
        local full="${sub}.${TARGET}"
        local ip
        ip=$(dig +short "$full" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
        if [[ -n "$ip" ]]; then
            echo "$full" >> "$subs_temp"
            found "DNS BRUTEFORCE HIT: $full → $ip"
            save_ip_candidate "$ip" "subdomain bruteforce: $full"
        fi
    done

    # ── Resolve all discovered subdomains ─────────────────────
    sep
    local total_subs
    total_subs=$(sort -u "$subs_temp" | wc -l)
    info "Resolving all $total_subs unique subdomains (streaming, no large array)..."
    {
        echo ""
        echo "[SUBDOMAINS]"
    } >> "$REPORT"

    # Process line-by-line — never load all subdomains into a bash array
    while IFS= read -r sub; do
        local ip
        ip=$(dig +short "$sub" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
        if [[ -n "$ip" ]]; then
            echo "[SUBDOMAIN] $sub → $ip" >> "$REPORT"
            save_ip_candidate "$ip" "subdomain: $sub"
        fi
    done < <(sort -u "$subs_temp")

    found "Total unique subdomains discovered: $total_subs"
}

# ════════════════════════════════════════════════════════════
# PHASE 3 — PORT SCAN & SERVICE FINGERPRINT
# Evasive nmap: fragmentation, slow timing.
# ════════════════════════════════════════════════════════════

phase3_port_scan() {
    phase "PHASE 3 ▶ PORT SCAN & SERVICE FINGERPRINT (evasive nmap)"
    warn "This phase generates real traffic to $TARGET"
    warn "Your IDS/Suricata will likely see this — that is intentional"
    echo ""

    if ! command -v nmap &>/dev/null; then
        miss "nmap not found — skipping phase 3 (install: sudo apt install nmap)"
        return
    fi

    # Select scan target: prefer confirmed non-Cloudflare origin IP
    local SCAN_TARGET="$TARGET"
    if [[ -s "$REAL_IP_FILE" ]]; then
        local candidate
        while IFS= read -r line; do
            candidate="${line%% *}"
            [[ -z "$candidate" ]] && continue
            if ! is_cloudflare_ip "$candidate"; then
                info "Scanning confirmed non-CF origin IP directly: $candidate"
                SCAN_TARGET="$candidate"
                break
            fi
        done < <(sort -u "$REAL_IP_FILE")
    fi

    jitter 5 12

    # ── Standard ports scan ───────────────────────────────────
    info "Phase 3a: Common ports on $SCAN_TARGET"
    stealth "Flags: -sV -sC -T2 -f --data-length 24"

    local nmap_parallelism="--min-parallelism 5"
    [[ "$LIGHT_MODE" == "true" ]] && nmap_parallelism="--min-parallelism 1"

    if ! sudo nmap \
        -sV -sC \
        -T2 \
        -f \
        --data-length 24 \
        --randomize-hosts \
        $nmap_parallelism \
        -p 21,22,23,25,53,80,110,143,443,465,587,993,995,2082,2083,2086,2087,2095,2096,3000,3306,5432,6379,8080,8443,8888,27017 \
        --open \
        -oN "$RESULTS_DIR/nmap_common.txt" \
        "$SCAN_TARGET" 2>/dev/null; then
        warn "nmap phase 3a returned non-zero exit (check sudo / nmap install)"
    fi

    if [[ -f "$RESULTS_DIR/nmap_common.txt" ]]; then
        while IFS= read -r line; do
            warn "PORT: $line"
            # Flag exposed database ports as HIGH severity
            if echo "$line" | grep -qE '\b(3306|5432|6379|27017|1433|5984|9200)\b'; then
                high "DATABASE PORT EXPOSED: $line"
            fi
        done < <(grep -E '(open|filtered)' "$RESULTS_DIR/nmap_common.txt" 2>/dev/null)
    fi

    jitter 8 20

    # ── Targeted service scripts ──────────────────────────────
    info "Phase 3b: Service-specific scripts (SSH, HTTP, SSL)"
    if ! sudo nmap \
        -sV \
        -T2 \
        -f \
        $nmap_parallelism \
        --script=http-title,http-server-header,http-methods,ssl-cert,ssh-hostkey,banner \
        -p 22,80,443,8080,8443 \
        -oN "$RESULTS_DIR/nmap_scripts.txt" \
        "$SCAN_TARGET" 2>/dev/null; then
        warn "nmap phase 3b returned non-zero exit"
    fi

    if [[ -f "$RESULTS_DIR/nmap_scripts.txt" ]]; then
        grep -vE '^(#|Nmap|Not shown|SF-)' "$RESULTS_DIR/nmap_scripts.txt" \
            | grep -v '^$' \
            | while IFS= read -r line; do info "$line"; done
    fi

    jitter 5 10

    # ── SSL Certificate from direct IP ────────────────────────
    sep
    info "Phase 3c: SSL cert from direct connection to $SCAN_TARGET"
    local ssl_out
    ssl_out=$(echo | timeout 10 openssl s_client \
        -connect "${SCAN_TARGET}:443" \
        -servername "$TARGET" 2>/dev/null)

    if [[ -n "$ssl_out" ]]; then
        local CERT_CN CERT_SAN CERT_ISSUER CERT_EXPIRY
        CERT_CN=$(echo "$ssl_out"     | openssl x509 -noout -subject    2>/dev/null | grep -oE 'CN\s*=\s*[^,]*' | head -1)
        CERT_SAN=$(echo "$ssl_out"    | openssl x509 -noout -ext subjectAltName 2>/dev/null)
        CERT_ISSUER=$(echo "$ssl_out" | openssl x509 -noout -issuer     2>/dev/null)
        CERT_EXPIRY=$(echo "$ssl_out" | openssl x509 -noout -enddate    2>/dev/null)

        found "SSL CN: $CERT_CN"
        info  "Issuer: $CERT_ISSUER"
        info  "Expiry: $CERT_EXPIRY"
        info  "SANs: $CERT_SAN"

        # SANs can reveal other domains on same server
        echo "$CERT_SAN" | grep -oE '[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}' | while IFS= read -r san_domain; do
            medium "SAN domain: $san_domain (co-hosted or related domain)"
        done
    else
        warn "SSL handshake failed to $SCAN_TARGET:443 (port may be closed or filtered)"
    fi
}

# ════════════════════════════════════════════════════════════
# PHASE 4 — WORDPRESS DEEP RECON
# WPScan aggressive enum + manual fallback + Gravatar intel.
# ════════════════════════════════════════════════════════════

phase4_wordpress() {
    phase "PHASE 4 ▶ WORDPRESS DEEP RECON"

    # UA_LIST is now global — no UA_LIST-before-declaration bug
    local UA="${UA_LIST[$RANDOM % ${#UA_LIST[@]}]}"

    # Verify WP is present before investing time
    local WP_CHECK
    WP_CHECK=$(curl -sL --max-time 15 -H "User-Agent: $UA" "https://$TARGET" 2>/dev/null \
        | grep -ic "wp-content\|wp-includes\|wordpress") || WP_CHECK=0

    if [[ "$WP_CHECK" -eq 0 ]]; then
        warn "WordPress not detected on $TARGET — skipping phase 4"
        return
    fi
    found "WordPress confirmed on $TARGET"

    jitter 3 7

    if command -v wpscan &>/dev/null; then
        info "Running WPScan — aggressive enumeration"
        stealth "Enumerating: plugins, themes, users, timthumbs, config backups"
        jitter 5 10
        wpscan \
            --url "https://$TARGET" \
            --enumerate vp,vt,u,tt,cb,dbe \
            --detection-mode aggressive \
            --random-user-agent \
            --throttle 1500 \
            --no-update \
            --output "$RESULTS_DIR/wpscan.txt" \
            --format cli 2>/dev/null || warn "wpscan exited with error (check output file)"

        if [[ -f "$RESULTS_DIR/wpscan.txt" ]]; then
            while IFS= read -r line; do
                if echo "$line" | grep -q '\[!\]'; then
                    high "WPScan: $line"
                else
                    found "WPScan: $line"
                fi
            done < <(grep -E '\[!\]|\[\+\]' "$RESULTS_DIR/wpscan.txt" 2>/dev/null)
        fi
    else
        warn "wpscan not installed — running manual WordPress checks"
        # UA already set above from global UA_LIST

        # Version detection
        info "WordPress version detection..."
        local WP_VER WP_VER2
        WP_VER=$(curl -sL --max-time 10 -H "User-Agent: $UA" "https://$TARGET/feed/" 2>/dev/null \
            | grep -oP 'generator[^>]+WordPress [0-9.]+' | head -1)
        [[ -n "$WP_VER" ]] && medium "WP Version via feed: $WP_VER"

        WP_VER2=$(curl -sL --max-time 10 -H "User-Agent: $UA" "https://$TARGET/wp-login.php" 2>/dev/null \
            | grep -oP 'ver=[0-9.]+' | head -1)
        [[ -n "$WP_VER2" ]] && medium "WP Version via login page asset: $WP_VER2"

        jitter 3 7

        # User enumeration via author archives
        info "WordPress user enumeration via author archives..."
        for i in 1 2 3; do
            jitter 2 5
            local AUTHOR
            AUTHOR=$(curl -sL --max-time 10 -H "User-Agent: $UA" \
                "https://$TARGET/?author=$i" 2>/dev/null \
                | grep -oP 'author/[^/"]+' | head -1 | sed 's|author/||')
            [[ -n "$AUTHOR" ]] && high "WP User enumerated (author archive): #$i → $AUTHOR"
        done

        # REST API user enum
        jitter 2 4
        local REST_USERS
        REST_USERS=$(curl -sL --max-time 10 -H "User-Agent: $UA" \
            "https://$TARGET/wp-json/wp/v2/users" 2>/dev/null \
            | grep -o '"slug":"[^"]*"' | sed 's/"slug":"//;s/"//g')
        if [[ -n "$REST_USERS" ]]; then
            high "WP REST API user enumeration enabled — users exposed:"
            echo "$REST_USERS" | while IFS= read -r u; do high "  WP User: $u"; done
        fi

        jitter 3 6

        # Common sensitive paths
        info "Checking sensitive WordPress paths..."
        local WP_PATHS=(
            "wp-login.php"
            "wp-admin/"
            "wp-config.php"
            "wp-config.php.bak"
            "wp-config.old"
            "wp-content/debug.log"
            "wp-content/uploads/"
            ".env"
            "xmlrpc.php"
            "wp-json/wp/v2/users"
            "readme.html"
            "license.txt"
            "wp-cron.php"
        )

        for path in "${WP_PATHS[@]}"; do
            jitter 1 3
            local CODE
            CODE=$(curl -so /dev/null -w "%{http_code}" --max-time 8 \
                -H "User-Agent: $UA" "https://$TARGET/$path" 2>/dev/null)
            if [[ -z "$CODE" ]]; then
                warn "curl timeout checking /$path"
                continue
            fi
            case "$CODE" in
                200)     high "ACCESSIBLE: /$path (200 OK)" ;;
                301|302) info "REDIRECT: /$path ($CODE)" ;;
                403)     medium "FORBIDDEN: /$path (403 — exists but blocked)" ;;
                404)     miss "NOT FOUND: /$path" ;;
                *)       miss "/$path: HTTP $CODE" ;;
            esac
        done

        # xmlrpc brute-force surface check
        jitter 2 4
        local XMLRPC
        XMLRPC=$(curl -s --max-time 10 -H "User-Agent: $UA" \
            -d '<?xml version="1.0"?><methodCall><methodName>system.listMethods</methodName></methodCall>' \
            "https://$TARGET/xmlrpc.php" 2>/dev/null)
        if echo "$XMLRPC" | grep -q "methodResponse"; then
            high "xmlrpc.php ENABLED and responding — brute-force/DDoS amplification surface"
        fi
    fi

    # ── Gravatar Intelligence Module ──────────────────────────
    jitter 2 4
    phase4_gravatar_intel "$UA"
}

# ════════════════════════════════════════════════════════════
# PHASE 4 — GRAVATAR INTELLIGENCE MODULE
# Extract email MD5 hashes from Gravatar URLs on the target.
# Hashes are crackable offline with hashcat -m 0 against email
# wordlists — useful for username/email enumeration.
# ════════════════════════════════════════════════════════════

phase4_gravatar_intel() {
    local UA="$1"
    sep
    info "Gravatar Intelligence — email MD5 hash extraction"

    local html_temp
    html_temp=$(make_temp)

    # Method 1: Scrape rendered HTML for gravatar.com/avatar/<hash> URLs
    info "Scraping $TARGET HTML for embedded gravatar URLs..."
    curl -sL --max-time 15 -H "User-Agent: $UA" "https://$TARGET" 2>/dev/null > "$html_temp" \
        || curl -sL --max-time 15 -H "User-Agent: $UA" "http://$TARGET" 2>/dev/null > "$html_temp" \
        || { warn "Could not fetch $TARGET HTML for Gravatar scan"; return; }

    # Extract all 32-char hex strings from gravatar.com/avatar/ paths
    local html_hashes_temp
    html_hashes_temp=$(make_temp)
    grep -oE 'gravatar\.com/avatar/([a-f0-9]{32})' "$html_temp" 2>/dev/null \
        | grep -oE '[a-f0-9]{32}' \
        | sort -u > "$html_hashes_temp"

    local html_count
    html_count=$(wc -l < "$html_hashes_temp")
    if [[ $html_count -gt 0 ]]; then
        found "Found $html_count gravatar hash(es) in page HTML"
        cat "$html_hashes_temp" >> "$GRAVATAR_FILE"
    fi

    # Method 2: WP REST API — avatar_urls field contains gravatar hash
    info "Extracting gravatar hashes from WP REST API (/wp-json/wp/v2/users)..."
    local rest_temp
    rest_temp=$(make_temp)
    curl -sL --max-time 12 -H "User-Agent: $UA" \
        "https://$TARGET/wp-json/wp/v2/users?per_page=20" 2>/dev/null > "$rest_temp"

    if [[ -s "$rest_temp" ]]; then
        grep -oE 'gravatar\.com/avatar/([a-f0-9]{32})' "$rest_temp" 2>/dev/null \
            | grep -oE '[a-f0-9]{32}' \
            | sort -u >> "$GRAVATAR_FILE"
        local rest_count
        rest_count=$(grep -oE 'gravatar\.com/avatar/([a-f0-9]{32})' "$rest_temp" 2>/dev/null \
            | grep -oE '[a-f0-9]{32}' | sort -u | wc -l)
        [[ $rest_count -gt 0 ]] && found "Found $rest_count gravatar hash(es) in REST API response"
    fi

    # Deduplicate final gravatar hash file
    local total_hashes=0
    if [[ -s "$GRAVATAR_FILE" ]]; then
        local dedup_temp
        dedup_temp=$(make_temp)
        sort -u "$GRAVATAR_FILE" > "$dedup_temp"
        mv "$dedup_temp" "$GRAVATAR_FILE"
        total_hashes=$(wc -l < "$GRAVATAR_FILE")
    fi

    if [[ $total_hashes -eq 0 ]]; then
        found "No gravatar hashes found on $TARGET"
        return
    fi

    high "Found $total_hashes unique gravatar hash(es) — email MD5s crackable offline"
    info "Hashcat: hashcat -a 0 -m 0 $GRAVATAR_FILE /usr/share/wordlists/emails.txt"
    info "All hashes saved: $GRAVATAR_FILE"

    # Method 3: Verify each hash and pull public profile data
    sep
    info "Verifying gravatar profiles and extracting public data..."
    local details_file="${GRAVATAR_FILE%.txt}_details.txt"

    while IFS= read -r hash; do
        [[ -z "$hash" ]] && continue
        jitter 1 2

        # ?d=404 returns 404 if hash is unregistered, 200 if registered
        local status
        status=$(curl -so /dev/null -w "%{http_code}" --max-time 8 \
            -H "User-Agent: $UA" \
            "https://www.gravatar.com/avatar/${hash}?d=404" 2>/dev/null)

        if [[ "$status" == "200" ]]; then
            # Fetch profile JSON — may expose display name, username, bio
            local profile_temp
            profile_temp=$(make_temp)
            curl -sL --max-time 8 -H "User-Agent: $UA" \
                "https://en.gravatar.com/${hash}.json" 2>/dev/null > "$profile_temp"

            if [[ -s "$profile_temp" ]]; then
                local display_name username profile_url
                display_name=$(grep -o '"displayName":"[^"]*"' "$profile_temp" \
                    | sed 's/"displayName":"//;s/"//' | head -1)
                username=$(grep -o '"preferredUsername":"[^"]*"' "$profile_temp" \
                    | sed 's/"preferredUsername":"//;s/"//' | head -1)
                profile_url="https://gravatar.com/${hash}"

                if [[ -n "$display_name" || -n "$username" ]]; then
                    high "GRAVATAR PROFILE PUBLIC: hash=${hash} name=${display_name:-N/A} user=${username:-N/A}"
                    info "Profile URL: $profile_url"
                    printf '%s\tdisplay=%s\tuser=%s\turl=%s\n' \
                        "$hash" "${display_name:-unknown}" "${username:-unknown}" "$profile_url" \
                        >> "$details_file"
                else
                    medium "Gravatar registered (profile exists, no public name): $hash"
                    info "Profile: $profile_url"
                    printf '%s\tdisplay=private\tuser=private\turl=%s\n' \
                        "$hash" "$profile_url" >> "$details_file"
                fi
            else
                medium "Gravatar registered but profile JSON unavailable: $hash"
            fi
        elif [[ "$status" == "404" ]]; then
            info "Gravatar hash not registered: $hash"
        else
            info "Gravatar check inconclusive (HTTP $status): $hash"
        fi
    done < "$GRAVATAR_FILE"

    if [[ -f "$details_file" ]]; then
        found "Gravatar detail report: $details_file"
    fi
}

# ════════════════════════════════════════════════════════════
# PHASE 5 — EMAIL & OSINT HARVESTING
# Emails, metadata, breach checks, GitHub exposure, Wayback.
# ════════════════════════════════════════════════════════════

phase5_osint() {
    phase "PHASE 5 ▶ EMAIL & OSINT HARVESTING"

    # ── Email Harvesting ──────────────────────────────────────
    if command -v theHarvester &>/dev/null; then
        info "Running theHarvester (bing, crtsh, dnsdumpster)..."
        jitter 3 7
        theHarvester -d "$TARGET" -b bing,crtsh,dnsdumpster -l 100 \
            -f "$RESULTS_DIR/theharvester" 2>/dev/null \
            | grep -E '@|IP:' \
            | while IFS= read -r line; do high "HARVESTED: $line"; done
    else
        info "theHarvester not installed — extracting emails from WHOIS"
        local whois_emails
        whois_emails=$(whois "$TARGET" 2>/dev/null \
            | grep -oE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | sort -u)
        if [[ -n "$whois_emails" ]]; then
            echo "$whois_emails" | while IFS= read -r email; do
                medium "Email via WHOIS: $email"
            done
        fi
    fi

    jitter 3 8

    # ── GitHub Exposure Check ─────────────────────────────────
    sep
    info "GitHub exposure check (public code referencing $TARGET)..."
    local gh_result gh_count
    gh_result=$(curl -s --max-time 15 \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/search/code?q=${TARGET}+in:file&per_page=5" 2>/dev/null)
    if [[ $? -ne 0 ]] || [[ -z "$gh_result" ]]; then
        warn "GitHub API request failed (rate limited or network error)"
    else
        gh_count=$(echo "$gh_result" | grep -o '"total_count":[0-9]*' | grep -o '[0-9]*')
        if [[ -n "$gh_count" ]] && (( gh_count > 0 )); then
            medium "GitHub: $gh_count public code references to $TARGET found"
            info "Manual review: https://github.com/search?q=$TARGET&type=code"
        else
            found "GitHub: No obvious public code exposure"
        fi
    fi

    jitter 2 5

    # ── Breach Check ──────────────────────────────────────────
    sep
    info "Checking breach exposure (HaveIBeenPwned domain search)..."
    local hibp
    hibp=$(curl -s --max-time 10 \
        -H "hibp-api-key: free" \
        "https://haveibeenpwned.com/api/v3/breachesforaccount/$TARGET" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        warn "HIBP request failed (network error)"
    elif echo "$hibp" | grep -q "Name"; then
        high "Domain appears in known breach data — check https://haveibeenpwned.com"
    else
        found "No immediate breach results (full check requires HIBP API key)"
    fi

    # ── Wayback Machine ───────────────────────────────────────
    sep
    if [[ "$LIGHT_MODE" == "true" ]]; then
        info "Wayback Machine skipped in --light mode"
    else
        info "Wayback Machine — historical URL discovery (limit 30)"
        jitter 2 4
        local wbm_temp
        wbm_temp=$(make_temp)
        if curl -s --max-time 20 \
            "http://web.archive.org/cdx/search/cdx?url=*.${TARGET}&output=text&fl=original&collapse=urlkey&limit=30" \
            2>/dev/null > "$wbm_temp" && [[ -s "$wbm_temp" ]]; then

            # Stream through grep — never load all URLs into a variable
            while IFS= read -r url; do
                high "Wayback sensitive URL: $url"
            done < <(grep -iE '\.(env|sql|bak|backup|config|log|git|svn|htpasswd|passwd)' "$wbm_temp" 2>/dev/null)

            local total_urls
            total_urls=$(wc -l < "$wbm_temp")
            info "Total historical URLs fetched: $total_urls"
            info "Manual review: https://web.archive.org/web/*/$TARGET"
        else
            warn "Wayback Machine fetch failed or returned no results"
        fi
    fi
}

# ════════════════════════════════════════════════════════════
# FINAL REPORT
# ════════════════════════════════════════════════════════════

generate_report() {
    phase "FINAL REPORT ▶ DARK MATTER RECON SUMMARY"

    local total_dur=$(( SECONDS - SCAN_START_SECONDS ))
    local dur_min=$(( total_dur / 60 ))
    local dur_sec=$(( total_dur % 60 ))

    # Append compact machine-readable summary block to report file
    {
        echo ""
        echo "════════════════════════════════════════════════════════════"
        echo "  DARK MATTER RECON v${SCRIPT_VERSION} — FINAL SUMMARY"
        echo "  Target    : $TARGET"
        echo "  Date      : $(date)"
        echo "  Duration  : ${dur_min}m ${dur_sec}s"
        echo "────────────────────────────────────────────────────────────"
        echo "  SEVERITY  | CRITICAL:$COUNT_CRITICAL  HIGH:$COUNT_HIGH  MEDIUM:$COUNT_MEDIUM  INFO:$COUNT_INFO"
        echo "────────────────────────────────────────────────────────────"
        echo "  PHASE TIMINGS"
        local pn=("Passive" "Fingerprint" "Subdomains" "PortScan" "WordPress" "OSINT")
        for i in 0 1 2 3 4 5; do
            local t=${PHASE_TIME[$i]:-0}
            printf "  Phase %-1s  %-12s  %dm%02ds\n" "$i" "${pn[$i]}" "$((t/60))" "$((t%60))"
        done
        echo "────────────────────────────────────────────────────────────"
        echo "  CRITICAL FINDINGS"
        grep '^\[CRITICAL\]' "$REPORT" | while IFS= read -r l; do echo "  $l"; done
        echo "────────────────────────────────────────────────────────────"
        echo "  HIGH FINDINGS"
        grep '^\[HIGH\]' "$REPORT" | while IFS= read -r l; do echo "  $l"; done
        echo "────────────────────────────────────────────────────────────"
        echo "  ORIGIN IP CANDIDATES"
        if [[ -s "$REAL_IP_FILE" ]]; then
            sort -u "$REAL_IP_FILE"
        else
            echo "  None found"
        fi
        echo "════════════════════════════════════════════════════════════"
    } >> "$REPORT"

    # ── Terminal display ──────────────────────────────────────
    echo ""
    echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${RED}║      DARK MATTER RECON v${SCRIPT_VERSION} — FINAL SUMMARY              ║${NC}"
    echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}  Target    : ${BOLD}$TARGET${NC}"
    echo -e "${CYAN}  Date      : $(date)${NC}"
    echo -e "${CYAN}  Duration  : ${dur_min}m ${dur_sec}s${NC}"
    echo -e "${CYAN}  Results   : $RESULTS_DIR${NC}"
    echo ""

    # Severity summary
    echo -e "${BOLD}  ── SEVERITY SUMMARY ─────────────────────────────────────${NC}"
    echo -e "  ${BOLD}${RED}  CRITICAL${NC}  : $COUNT_CRITICAL"
    echo -e "  ${RED}  HIGH${NC}      : $COUNT_HIGH"
    echo -e "  ${YELLOW}  MEDIUM${NC}    : $COUNT_MEDIUM"
    echo -e "  ${CYAN}  INFO${NC}      : $COUNT_INFO"
    echo ""

    # Phase timings
    echo -e "${BOLD}  ── PHASE TIMINGS ────────────────────────────────────────${NC}"
    local phase_labels=("Passive Recon  " "Fingerprint    " "Subdomains     " "Port Scan      " "WordPress      " "OSINT          ")
    for i in 0 1 2 3 4 5; do
        local t=${PHASE_TIME[$i]:-0}
        [[ $t -eq 0 ]] && continue
        printf "  ${DIM}  Phase %s  %s  %dm %02ds${NC}\n" "$i" "${phase_labels[$i]}" "$((t/60))" "$((t%60))"
    done
    echo ""

    # Critical findings
    if (( COUNT_CRITICAL > 0 )); then
        echo -e "${BOLD}${RED}  ── CRITICAL FINDINGS ───────────────────────────────────${NC}"
        grep '^\[CRITICAL\]' "$REPORT" | head -20 | while IFS= read -r l; do
            echo -e "${BOLD}${RED}    $l${NC}"
        done
        echo ""
    fi

    # High findings
    if (( COUNT_HIGH > 0 )); then
        echo -e "${BOLD}${RED}  ── HIGH FINDINGS ───────────────────────────────────────${NC}"
        grep '^\[HIGH\]' "$REPORT" | head -20 | while IFS= read -r l; do
            echo -e "${RED}    $l${NC}"
        done
        echo ""
    fi

    # Origin IPs
    echo -e "${BOLD}${YELLOW}  ── ORIGIN IP CANDIDATES (potential WAF bypass) ─────────${NC}"
    if [[ -s "$REAL_IP_FILE" ]]; then
        sort -u "$REAL_IP_FILE" | while IFS= read -r line; do
            echo -e "${RED}    $line${NC}"
        done
    else
        echo -e "${GREEN}    None found — origin IP appears well protected${NC}"
    fi
    echo ""

    # Blue team challenge
    echo -e "${BOLD}${MAGENTA}  ── BLUE SIDE CHALLENGE QUESTIONS ───────────────────────${NC}"
    echo -e "${DIM}    1. Did your SIEM correlate Phase 0-5 as a single attacker?${NC}"
    echo -e "${DIM}    2. Did Cloudflare/WAF block or challenge any phase?${NC}"
    echo -e "${DIM}    3. Did Suricata fire on the nmap scan (Phase 3)?${NC}"
    echo -e "${DIM}    4. Were the cPanel port probes logged?${NC}"
    echo -e "${DIM}    5. Did WPScan trigger any alerts or auto-blocks?${NC}"
    echo -e "${DIM}    6. Was passive recon (Phase 0) completely invisible?${NC}"
    echo -e "${DIM}    7. If origin IP was found — what does that expose?${NC}"
    echo -e "${DIM}    8. Were gravatar hashes observable in network logs?${NC}"
    echo ""

    echo -e "${GREEN}  Report    : $REPORT${NC}"
    echo -e "${GREEN}  JSON      : $RESULTS_DIR/dark_matter_summary.json${NC}"
    echo -e "${GREEN}  Gravatar  : $GRAVATAR_FILE${NC}"
    echo -e "${GREEN}  Dir       : $RESULTS_DIR${NC}"
    echo ""

    generate_json_report
}

# ════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════

main() {
    print_banner

    # ── Argument parsing ──────────────────────────────────────
    local positional_targets=()
    SINGLE_PHASE=""
    STEALTH_MODE=false
    QUIET=false
    LIGHT_MODE=false
    ENABLE_AMASS=false
    TARGET_FILE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)       usage ;;
            --shodan-key)    SHODAN_API_KEY="$2"; shift ;;
            --phase)         SINGLE_PHASE="$2"; shift ;;
            --stealth)       STEALTH_MODE=true ;;
            --quiet)         QUIET=true ;;
            --light)         LIGHT_MODE=true ;;
            --enable-amass)  ENABLE_AMASS=true ;;
            --target)        TARGET_FILE="$2"; shift ;;
            --report-only)
                local latest
                latest=$(ls -td "$HOME/dark_matter_results/"*/ 2>/dev/null | head -1)
                [[ -n "$latest" ]] && cat "$latest/DARK_MATTER_REPORT.txt" || echo "No reports found"
                exit 0 ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}"
                usage ;;
            *)
                positional_targets+=("$1") ;;
        esac
        shift
    done

    # ── Build target list ─────────────────────────────────────
    local targets=()

    if [[ -n "$TARGET_FILE" ]]; then
        if [[ ! -f "$TARGET_FILE" ]]; then
            echo -e "${RED}Error: target file not found: $TARGET_FILE${NC}"
            exit 1
        fi
        while IFS= read -r t || [[ -n "$t" ]]; do
            t="${t%%#*}"              # strip inline comments
            t="${t//[[:space:]]/}"    # strip all whitespace (domains never have spaces)
            [[ -z "$t" ]] && continue
            targets+=("$t")
        done < "$TARGET_FILE"
        echo -e "${CYAN}  [~] Loaded ${#targets[@]} target(s) from $TARGET_FILE${NC}"
    fi

    targets+=("${positional_targets[@]}")

    if [[ ${#targets[@]} -eq 0 ]]; then
        echo -e "${RED}Error: No target specified${NC}"
        usage
    fi

    # ── System checks ─────────────────────────────────────────
    check_ram

    # ── Run scan per target ───────────────────────────────────
    for tgt in "${targets[@]}"; do
        echo ""
        echo -e "${BOLD}${CYAN}  ══════════════════════════════════════════${NC}"
        echo -e "${BOLD}${CYAN}  TARGET: $tgt${NC}"
        echo -e "${BOLD}${CYAN}  ══════════════════════════════════════════${NC}"

        # Validate domain format + DNS
        if ! validate_domain "$tgt"; then
            echo -e "${RED}  Skipping $tgt (validation failed)${NC}"
            continue
        fi

        init_target_env "$tgt"
        check_deps

        echo ""
        echo -e "${BOLD}${RED}  TARGET  : $TARGET${NC}"
        echo -e "${BOLD}${RED}  RESULTS : $RESULTS_DIR${NC}"
        echo -e "${BOLD}${RED}  STEALTH : $STEALTH_MODE  |  QUIET: $QUIET  |  LIGHT: $LIGHT_MODE  |  AMASS: $ENABLE_AMASS${NC}"
        echo ""
        echo -e "${YELLOW}  ⚠  Only scan domains you own. You own $TARGET, confirmed.${NC}"
        echo ""

        # Prompt only in single-target interactive mode
        if [[ ${#targets[@]} -eq 1 ]] && [[ -t 0 ]]; then
            read -rp "  Press ENTER to begin Dark Matter Recon or Ctrl+C to abort..."
            echo ""
        fi

        SCAN_START_SECONDS=$SECONDS

        # ── Execute phases ────────────────────────────────────
        if [[ -n "$SINGLE_PHASE" ]]; then
            case "$SINGLE_PHASE" in
                0) run_phase 0 phase0_passive ;;
                1) run_phase 1 phase1_stealth_fingerprint ;;
                2) run_phase 2 phase2_subdomains ;;
                3) run_phase 3 phase3_port_scan ;;
                4) run_phase 4 phase4_wordpress ;;
                5) run_phase 5 phase5_osint ;;
                *) echo -e "${RED}Invalid phase: $SINGLE_PHASE (valid: 0-5)${NC}"; exit 1 ;;
            esac
        else
            run_phase 0 phase0_passive
            run_phase 1 phase1_stealth_fingerprint
            run_phase 2 phase2_subdomains
            run_phase 3 phase3_port_scan
            run_phase 4 phase4_wordpress
            run_phase 5 phase5_osint
        fi

        generate_report

        if [[ ${#targets[@]} -gt 1 ]]; then
            echo -e "${CYAN}  ── Completed: $tgt ──${NC}"
        fi
    done
}

main "$@"
