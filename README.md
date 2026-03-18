# DarkMatterRecon

**GlobalDarkRecon — Dark Matter Recon v2.1**
Red Team OSINT Challenge Framework

> For use on domains you own or have explicit written authorization to test.

---

## Getting Started on Kali Linux

### 1. Clone the repository

```bash
git clone https://github.com/GlobalReconReport/DarkMatterRecon.git ~/DarkMatterRecon
cd ~/DarkMatterRecon
```

### 2. Make the script executable

```bash
chmod +x dark_matter_recon.sh
```

### 3. Install required tools

All core dependencies ship with Kali. Verify they are present:

```bash
sudo apt update
sudo apt install nmap curl dnsutils whois openssl netcat-openbsd -y
```

### 4. Install optional tools (recommended for full coverage)

```bash
sudo apt install wpscan wafw00f whatweb theharvester amass tor torsocks proxychains4 -y
```

Install `subfinder` (Go required):

```bash
go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
```

> If `go` is not installed: `sudo apt install golang -y`

### 5. Run your first scan

```bash
# Basic scan against a domain you own
sudo ./dark_matter_recon.sh yourdomain.com

# Low-RAM mode (recommended for Kali live USB with ~2GB RAM)
sudo ./dark_matter_recon.sh yourdomain.com --light

# Route HTTP traffic through Tor + use DNS-over-HTTPS
sudo ./dark_matter_recon.sh yourdomain.com --tor --doh

# Quiet mode — only CRITICAL and HIGH findings shown on screen
sudo ./dark_matter_recon.sh yourdomain.com --quiet
```

Results are saved to `~/dark_matter_results/<timestamp>_<domain>/`

---

## Overview

`dark_matter_recon.sh` is a six-phase OSINT and active reconnaissance script designed for red team exercises and blue team detection challenges. It mimics realistic attacker behavior — slow stealth fingerprinting, jitter between requests, rotating user agents — while collecting intelligence that blue teams should be able to detect and correlate.

Each phase is independently timed and produces structured output in both human-readable text and machine-readable JSON.

---

## Phases

| Phase | Name | Description |
|-------|------|-------------|
| 0 | Pure Passive Recon | DNS records, WHOIS, certificate transparency (crt.sh), Shodan, DNS history — zero direct contact with target |
| 1 | Stealth Fingerprint | HTTP headers, security header audit, WAF detection, tech stack, cPanel port probes |
| 2 | Subdomain Enumeration | subfinder, crt.sh, DNS brute force, full resolution pass |
| 3 | Port Scan & Service Fingerprint | Evasive nmap (-T2, fragment, data-length), SSL cert extraction, SAN enumeration |
| 4 | WordPress Deep Recon | WPScan aggressive enum (or manual fallback), user enumeration, sensitive path checks, **Gravatar Intelligence** |
| 5 | Email & OSINT Harvesting | theHarvester, GitHub exposure, HaveIBeenPwned breach check, Wayback Machine sensitive URL discovery |

---

## Gravatar Intelligence Module

Built into Phase 4. Extracts MD5 email hashes from:

- Embedded `gravatar.com/avatar/<hash>` URLs in page HTML
- WordPress REST API `/wp-json/wp/v2/users` `avatar_urls` field

For each hash found:
- Confirms whether the Gravatar profile is registered
- Fetches public profile JSON (`displayName`, `preferredUsername`)
- Saves all hashes to `gravatar_hashes.txt` for offline cracking

```bash
# Crack hashes offline with hashcat
hashcat -a 0 -m 0 gravatar_hashes.txt /path/to/email-wordlist.txt
```

Severity: **HIGH** — email MD5 hashes enable username/email enumeration.

---

## Requirements

**Required:**
```
nmap  curl  dig  whois  openssl  host  bash 4.0+
```

**Optional (enhance depth):**
```
subfinder  wpscan  wafw00f  whatweb  theHarvester  amass  shodan
```

Install optional tools on Kali:
```bash
sudo apt install wpscan wafw00f whatweb theharvester -y
go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
```

---

## Usage

```bash
# Single target
./dark_matter_recon.sh example.com

# Multi-target from file
./dark_matter_recon.sh --target targets.txt

# Single phase only
./dark_matter_recon.sh example.com --phase 0

# With Shodan API key
./dark_matter_recon.sh example.com --shodan-key YOUR_KEY

# Quiet mode (CRITICAL/HIGH only on screen)
./dark_matter_recon.sh example.com --quiet

# Low-RAM mode (Kali live USB with ~2GB RAM)
./dark_matter_recon.sh example.com --light
```

## All Flags

| Flag | Description |
|------|-------------|
| `--target <file>` | File with one domain per line (multi-target mode) |
| `--shodan-key <key>` | Shodan API key (or `export SHODAN_API_KEY=xxx`) |
| `--phase <0-5>` | Run a single phase only |
| `--stealth` | Maximum stealth mode (longer jitter ranges) |
| `--quiet` | Suppress verbose output — only CRITICAL/HIGH shown on screen |
| `--light` | Low-RAM mode: cap subfinder@50, nmap `--min-parallelism 1`, skip Wayback |
| `--enable-amass` | Enable amass passive enum (disabled by default — high RAM usage) |
| `--tor` | Route HTTP/WHOIS through Tor SOCKS5 (port 9050); rotate circuit between phases. nmap always runs native — raw SYN scans are incompatible with SOCKS5 |
| `--doh` | Use DNS-over-HTTPS for all A-record lookups (Cloudflare 1.1.1.1) instead of plain `dig` |
| `--report-only` | Print last saved report and exit |

---

## Output

Every scan creates a timestamped directory:

```
~/dark_matter_results/<timestamp>_<domain>/
├── DARK_MATTER_REPORT.txt       # Full structured text report
├── dark_matter_summary.json     # Machine-readable JSON summary
├── origin_ip_candidates.txt     # Potential WAF-bypassing origin IPs
├── gravatar_hashes.txt          # Extracted email MD5 hashes
├── gravatar_hashes_details.txt  # Resolved display names / usernames
├── nmap_common.txt              # Common port scan results
├── nmap_scripts.txt             # Service fingerprint results
└── wpscan.txt                   # WPScan output (if available)
```

### JSON Summary Format

```json
{
  "meta": { "target": "example.com", "duration_seconds": 312 },
  "severity_summary": { "CRITICAL": 2, "HIGH": 7, "MEDIUM": 12, "INFO": 45 },
  "phase_timings_seconds": { "phase0_passive": 45, "phase3_portscan": 180 },
  "origin_ip_candidates": ["1.2.3.4"],
  "findings": [
    { "severity": "CRITICAL", "message": "POTENTIAL ORIGIN IP: 1.2.3.4" }
  ]
}
```

---

## Severity Levels

| Level | Color | Meaning |
|-------|-------|---------|
| `CRITICAL` | Red bold | Immediate action: origin IP exposed, CVEs, credential files |
| `HIGH` | Red | Significant risk: user enumeration, open DB ports, Gravatar hashes |
| `MEDIUM` | Yellow | Notable: missing security headers, version disclosure |
| `INFO` | Cyan | Neutral findings: subdomains, resolved IPs, header values |

CRITICAL and HIGH findings are **always displayed** regardless of `--quiet` mode.

---

## Low-RAM Operation (Kali Live USB)

The script is optimized for Kali live USB environments with ~2GB RAM:

- Subdomain deduplication uses a `/tmp` file instead of an in-memory associative array
- crt.sh JSON is streamed through pipes directly to disk — never loaded into a variable
- Wayback Machine bulk fetch is skipped in `--light` mode
- All temp files land in `/tmp` (tmpfs) and are cleaned after each phase
- After each phase: `sync` + `echo 3 > /proc/sys/vm/drop_caches` (if passwordless sudo available)
- Startup warns if free RAM < 1500 MB or `/tmp` is >60% full

---

## Blue Team Challenge

After a full run, the report poses these detection questions:

1. Did your SIEM correlate Phase 0–5 as a single attacker session?
2. Did Cloudflare / WAF block or challenge any phase?
3. Did Suricata fire on the nmap scan (Phase 3)?
4. Were the cPanel port probes logged?
5. Did WPScan trigger any alerts or auto-blocks?
6. Was passive recon (Phase 0) completely invisible?
7. If origin IP was found — what does that expose?
8. Were gravatar hash lookups observable in network logs?

---

## Disclaimer

This tool is for **authorized security testing only**. Only run against domains you own or have explicit written permission to test. Unauthorized scanning is illegal. The authors accept no liability for misuse.
