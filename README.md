# codesmith.sh

> **Batch QR-code & barcode generator with roundtrip verification, multiple content
> types, and print-ready HTML label sheets.**
> Built for corporate labelling: inventory labels, asset tags, WiFi posters, contact sharing.

One self-contained Bash script. No cloud, no API keys, no database — everything is
generated and verified locally, then logged to a CSV you can audit.

---

## Features

- **6 QR content types** — URL, plain text, WiFi join, contact (vCard/MECARD), geo location, raw payload
- **5 barcode symbologies** — EAN-13, UPC-A, Code 128, Code 39, ISBN (Bookland)
- **Roundtrip verification** — every generated code is decoded back with `zbarimg` and compared
  to the original input; mismatches are reported, logged and reflected in the exit code
- **Automatic check digits** — EAN-13, UPC-A and ISBN check digits are computed in pure Bash;
  you only ever supply the data digits (supplying a full 13-digit EAN is rejected with a hint)
- **Batch mode** — one CSV in, verified code images + a **print-ready `contact_sheet.html`** out
- **Logo overlay** — centered logo with error-correction auto-upgrade to level **H** and a
  hard >25%-coverage rejection so you can't print an unscannable code
- **Terminal preview** — render a scannable QR straight into the terminal, no file written
- **Append-only CSV log** with a rendered `--log` table
- **Built-in self-test** (`--selftest`) covering roundtrip decoding, check-digit math and CSV parsing
- **Strict engineering** — `set -euo pipefail`, `trap`-based cleanup, dependency probing with
  install hints, graceful degradation, and a documented exit-code contract
- Runs on the **stock macOS bash 3.2** as well as bash 4/5 on Linux

---

## Requirements

| Tool | Used for | Required? |
|---|---|---|
| `qrencode` ≥ 4.0 | QR generation (colors need ≥ 4.0) | required for `qr` mode |
| `zint` ≥ 2.10 | barcode generation | required for `barcode` / batch |
| `zbarimg` (`zbar-tools`) | roundtrip verification | optional — verification skips with a notice |
| `ImageMagick` 6.9+ / 7 | `--logo`, `--label`, captions | optional — labels skip with a warning |
| `bash` ≥ 3.2 | script interpreter | always |

Install everything:

```bash
# Debian / Ubuntu
sudo apt install qrencode zint zbar-tools imagemagick

# Fedora
sudo dnf install qrencode zint zbar imagemagick

# macOS (Homebrew)
brew install qrencode zint zbar imagemagick
```

See [`requirements.txt`](requirements.txt) for the full dependency manifest.

---

## Getting started

```bash
git clone <this-repo>
cd <repo>
chmod +x codesmith.sh

# sanity-check your installation
./codesmith.sh --selftest

# first code
./codesmith.sh qr --url "https://example.com"   # → generated/qr-url-….png
```

Every command prints the payload it encodes, then `VERIFIED` once the image decoded back
to the exact same payload.

---

## Quick start — five copy-paste examples

```bash
./codesmith.sh qr --url "https://example.com"
./codesmith.sh qr --wifi "OfficeGuest" "welcome123" WPA
./codesmith.sh qr --url "https://x.com" --logo brand.png
./codesmith.sh barcode --ean 890123456789 --label "Neem Oil 250ml"
./codesmith.sh batch products.csv        # → generated/contact_sheet.html
```

---

## QR mode

```bash
./codesmith.sh qr --url|--text|--wifi|--vcard|--geo|--raw … [flags]
```

### Content types

| Flag | Payload produced | Example |
|---|---|---|
| `--url URL` | the URL as-is (warns if scheme missing) | `--url "https://example.com"` |
| `--text TEXT` | arbitrary text | `--text "water the ficus every 3 days"` |
| `--wifi SSID [PASS] [AUTH]` | `WIFI:T:WPA;S:<ssid>;P:<pass>;;` | `--wifi "OfficeGuest" "welcome123" WPA` |
| `--vcard NAME PHONE EMAIL` | `MECARD:N:…;TEL:…;EMAIL:…;;` | `--vcard "Ravi Kumar" "+919876543210" "ravi@corp.com"` |
| `--geo LAT LONG` | `GEO:<lat>,<long>` | `--geo 12.9716 77.5946` *(or one `"lat,long"` value)* |
| `--raw PAYLOAD` | passed through untouched | `--raw "WIFI:T:WPA;S:x;P:y;;"` |

WiFi `AUTH` accepts `WPA` (also WPA2/WPA3), `WEP`, or `none` for open networks.
Special characters in SSIDs/passwords are escaped automatically.

### Flags

| Flag | Meaning | Default |
|---|---|---|
| `--size N` | module size in pixels (1–80) | `4` |
| `--ec L\|M\|Q\|H` | error correction level | `M` |
| `--svg` | vector output for print quality | PNG |
| `--fg HEX` / `--bg HEX` | colors, e.g. `--fg 1a1a2e --bg ffffff` | black on white |
| `--logo FILE` | centered logo overlay (needs ImageMagick, PNG output) | off |
| `--terminal` | scannable QR in the terminal, no file | off |
| `--label TEXT` | caption rendered under the code (raster only) | off |
| `--no-verify` | skip roundtrip verification (warning printed) | on |

**Logo rules (enforced so you can't print dead codes):**
- Logo mode silently requires error correction **H** — lower levels are auto-upgraded with a warning.
- If the logo would cover **more than 25 %** of the symbol, generation is **refused** (exit 3).
- Tune the logo size with `CS_LOGO_PCT` (percent of QR width, default `25`); logos are never upscaled.

Output files are timestamped into `generated/` (e.g. `generated/qr-wifi-20250101-120000-123.png`).

---

## Barcode mode

```bash
./codesmith.sh barcode --ean|--upc|--code128|--code39|--isbn VALUE [flags]
```

| Type | Input format | Notes |
|---|---|---|
| `--ean` 12 digits | EAN-13 | **13th check digit computed for you** — a full 13-digit input is rejected with a hint |
| `--upc` 11 digits | UPC-A | check digit computed automatically |
| `--code128` TEXT | Code 128 | best for SKUs like `SKU-4821-BLUE` |
| `--code39` TEXT | Code 39 | `A-Z 0-9 - . $ / + % space` (lowercase is uppercased) |
| `--isbn` VALUE | ISBN-10 or ISBN-13 | `978`/`979` Bookland; check digit computed **and validated** |

Extra flags: `--label "Product Name"` renders *name — code value* under the bars (retail-ready),
`--svg` for vector output, `--no-verify` to skip verification.

The check-digit math (1×/3× weights mod 10; ISBN mod 11) is implemented in pure Bash and
covered by `--selftest`.

---

## Batch mode

```bash
./codesmith.sh batch products.csv [--no-verify]
```

CSV columns (header optional, `#` comments and blank lines allowed, quote fields that
contain commas; a field cannot span multiple lines):

```csv
name,sku,type,code_value,price
Neem Oil 250ml,SKU-4821,ean,890123456789,₹249
HDMI Cable 2m,HD-2001,code128,HD-2001-CABLE,₹399
Office WiFi,NET-01,wifi,OfficeGuest|welcome123|WPA,
Support,SUP-01,vcard,Ravi Kumar|+919876543210|ravi@corp.com,
Store,LOC-01,geo,"12.9716,77.5946",
Grand Opening,WEB-01,url,https://store.example.com,
```

`type` accepts every QR content type (`url text wifi vcard geo raw`) and every barcode
type (`ean upc code128 code39 isbn`). Sub-values use `|` (wifi/vcard) or `,` (geo).

What a batch run does per row:

1. Builds the payload (check digits computed, values validated)
2. Renders `generated/<slug>.png` (slug from the product name, collision-safe `-2`/`-3` suffixes)
3. Adds a caption label (product name, plus code value for barcodes)
4. **Decodes it back and verifies it**
5. Logs the result and tallies it into the summary:

```
BATCH SUMMARY: 6 generated, 6 verified, 0 failed (0 mismatch, 0 skipped) — sheet: generated/contact_sheet.html
```

Rows that fail validation are reported, logged as `FAILED`, and **do not stop the run** —
the rest of the batch still completes; the exit code tells you something failed.

### The contact sheet

`generated/contact_sheet.html` is a self-contained, print-ready A4 grid — product name,
SKU, price, the code, and a per-label verification badge. Open it in any browser and hit
**Print** (the print button is built in). Unverified items are flagged with a warning banner.
Each cell is sized for ~35 mm shelf labels; always scan one test print before mass printing.

---

## Roundtrip verification

Verification is the core of codesmith: after every code is written, it is decoded again
with `zbarimg -q --raw` and compared byte-for-byte against the payload that was encoded.

| Situation | Behaviour |
|---|---|
| decoded == payload | `[✔] VERIFIED` — exit 0 |
| decoded ≠ payload, or image unreadable | `[✗] MISMATCH` — expected/decoded printed, **exit 1**, logged |
| `--no-verify` | skipped with a warning |
| `zbarimg` not installed | verification disabled with a notice — generation still works, exit 0 |
| SVG output | zbar can't raster-decode SVG — that item is reported as *skipped* |

UPC-A images decode as EAN-13 with a leading zero; the verifier normalizes that automatically.

---

## Logging

`codesmith_log.csv` is an append-only CSV in the working directory:

```
timestamp,mode,content_type,payload,output_file,verified,status
2025-01-01 12:00:00,qr,wifi,WIFI:T:WPA;S:OfficeGuest;P:welcome123;;,generated/qr-wifi-….png,VERIFIED,GENERATED
```

```bash
./codesmith.sh --log     # render the last 10 entries as an aligned color table
```

Fields are CSV-escaped and payloads are newline-sanitized, so the log stays machine-readable
even for multi-line `--text` values.

---

## Self-test

```bash
./codesmith.sh --selftest
```

Covers: QR roundtrip decode (skipped gracefully if `qrencode`/`zbarimg` are missing),
EAN-13/UPC-A check-digit math against known-good examples, ISBN-10 handling, rejection of
bad inputs, WiFi/vCard payload construction, and the CSV parser on a quoted 3-row sample.
Exit `1` if any test fails.

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | success (everything generated and verified) |
| `1` | verification failed (MISMATCH) or batch rows failed |
| `2` | missing dependency |
| `3` | bad input (unknown flag, invalid value, missing file, …) |

Safe to use in CI: `./codesmith.sh batch labels.csv || alert "label batch failed"`.

---

## Environment variables

| Variable | Effect | Default |
|---|---|---|
| `CS_LOGO_PCT` | logo width as % of QR width (1–100, still capped at 25 % area) | `25` |
| `NO_COLOR` | disable colored output | colors on when interactive |
| `TMPDIR` | where batch/self-test temporary files go | `/tmp` |

---

## Troubleshooting

- **“missing dependency: …”** — install the tools listed in the error message; the script
  also prints platform-specific install commands.
- **“logo would cover N% of the QR symbol”** — lower `CS_LOGO_PCT` (e.g. `CS_LOGO_PCT=20 ./codesmith.sh qr … --logo brand.png`).
- **Verification says MISMATCH** — inspect `expected` vs `decoded` in the output and in
  `codesmith_log.csv`; the image itself is still saved for inspection.
- **“SVG could not be raster-decoded”** — expected: zbar verifies raster images; use PNG
  when you need verified output.
- **Mac says “codesmith.sh must be run with bash”** — you invoked it with `sh`/`zsh`;
  run `bash codesmith.sh …` or `./codesmith.sh …`.
- **CSV row rejected** — check the reported column: names/types must be non-empty, EAN/UPC
  must be the right number of digits, wifi/vcard sub-values are `|`-separated.

---

## Project layout

```
codesmith.sh        # the whole tool — single file, no submodules
requirements.txt    # dependency manifest (system packages, not pip)
README.md
generated/          # created on demand: PNG/SVG codes + contact_sheet.html
codesmith_log.csv   # created on demand: append-only activity log
```

---

## Changelog

- **1.0.1** — hardening pass: QR quiet zone raised to the spec-recommended 4 modules,
  ISBN-10 check-digit validation, empty-SSID/empty-name rejection, batch flag validation,
  verification notice ordering fix, contact-sheet failnote counting + HTML escaping,
  `mapfile` removed (macOS bash 3.2 compatible), no `basename` at startup, zero-dimension
  image guard, self-test expanded to 21 cases.
- **1.0.0** — initial release.

## License

Released under the [MIT License](https://opensource.org/licenses/MIT).
