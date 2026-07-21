#!/usr/bin/env bash
# ccstatusline-install.sh — installs/updates/uninstalls ccstatusline with a
# Claude Code usage widget. Works over SSH (no browser needed). macOS/Linux.
# Only real dependencies: curl and Node.js (used instead of jq for JSON).
#
# Usage:
#   ./ccstatusline-install.sh              interactive install/repair
#   ./ccstatusline-install.sh --uninstall  remove ccstatusline + aliases
set -o pipefail

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi
section() { echo; echo "${C_BOLD}${C_CYAN}▸ $1${C_RESET}"; }
ok()      { echo "  ${C_GREEN}✓${C_RESET} $1"; }
warn()    { echo "  ${C_YELLOW}!${C_RESET} $1"; }
fail()    { echo "  ${C_RED}✗${C_RESET} $1"; }
info()    { echo "  ${C_DIM}·${C_RESET} $1"; }
tolower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }

echo "${C_BOLD}╭─────────────────────────────────────────────╮${C_RESET}"
echo "${C_BOLD}│  ccstatusline · SSH installer for Claude     │${C_RESET}"
echo "${C_BOLD}╰─────────────────────────────────────────────╯${C_RESET}"

PLATFORM="$(uname -s)"
case "$PLATFORM" in
    Darwin) PLATFORM=macos ;;
    Linux)  PLATFORM=linux ;;
    *) fail "Unsupported system: $PLATFORM"; exit 1 ;;
esac
info "Platform: $PLATFORM"

XDG_BASE="${XDG_CONFIG_HOME:-$HOME/.config}"
CCSTATUS_DIR="$XDG_BASE/ccstatusline"
SHELL_NAME="$(basename "${SHELL:-bash}")"
[ "$SHELL_NAME" = "zsh" ] && SHELL_RC="$HOME/.zshrc" || SHELL_RC="$HOME/.bashrc"

check_tool() { command -v "$1" >/dev/null 2>&1 || { fail "Missing '$1'. $2"; return 1; }; }

ensure_node() {
    command -v node >/dev/null 2>&1 && { ok "Node.js detected ($(node -v))"; return 0; }
    warn "Node.js not found. Installing it (needed for npx and JSON parsing)..."
    case "$PLATFORM" in
        macos)
            command -v brew >/dev/null 2>&1 && brew install node \
                || { fail "Homebrew not found. Install Node.js manually: https://nodejs.org/"; return 1; }
            ;;
        linux)
            if command -v apt-get >/dev/null 2>&1; then sudo apt-get update && sudo apt-get install -y nodejs npm
            elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y nodejs npm
            elif command -v yum >/dev/null 2>&1; then sudo yum install -y nodejs npm
            elif command -v pacman >/dev/null 2>&1; then sudo pacman -Sy --noconfirm nodejs npm
            elif command -v apk >/dev/null 2>&1; then sudo apk add --no-cache nodejs npm
            else fail "No supported package manager found. Install Node.js manually: https://nodejs.org/"; return 1
            fi
            ;;
    esac
    command -v node >/dev/null 2>&1 || { fail "Node.js installation failed."; return 1; }
    ok "Node.js installed successfully ($(node -v))"
}

NERD_FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Hack.zip"
NERD_FONT_INSTALLED_NOW=false

# The statusline's powerline separators need a Nerd Font-patched font. On
# Linux and Windows terminals this has been fine without any extra font (their
# default/fallback fonts already cover the glyph); macOS's Terminal.app and
# iTerm2 don't, so a fresh Mac renders the separator as a "?" in a box. Only
# macOS needs this step.
ensure_nerd_font_macos() {
    [ "$PLATFORM" = "macos" ] || return 0
    find "$HOME/Library/Fonts" /Library/Fonts -iname "*nerdfont*" 2>/dev/null | grep -q . \
        && { ok "A Nerd Font is already installed"; return 0; }

    warn "No Nerd Font found. Installing Hack Nerd Font (needed for the statusline's separator glyphs)..."
    local font_dir="$HOME/Library/Fonts" tmp_dir
    mkdir -p "$font_dir"
    tmp_dir=$(mktemp -d) || return 1
    if ! curl -fsSL "$NERD_FONT_URL" -o "$tmp_dir/Hack.zip"; then
        fail "Could not download Hack Nerd Font. Install one manually: https://www.nerdfonts.com/font-downloads"
        rm -rf "$tmp_dir"; return 1
    fi
    unzip -oq "$tmp_dir/Hack.zip" '*.ttf' -d "$font_dir"
    rm -rf "$tmp_dir"
    ok "Hack Nerd Font installed to $font_dir"
    NERD_FONT_INSTALLED_NOW=true
}

section "Checking required tools"
check_tool curl "Check your system's installation." || exit 1
ensure_node || exit 1
ensure_nerd_font_macos

# Resolve the real, absolute path of the claude binary once (via PATH, an
# interactive shell — since rc files often skip loading for non-interactive
# ones — "alias claude", or common install locations), so generated aliases
# call it directly instead of depending on shell resolution at call time.
CLAUDE_REAL_BIN=""
resolve_claude_bin() {
    local candidate dump alias_line shell_bin="bash"
    candidate="$(command -v claude 2>/dev/null)"

    if [ -z "$candidate" ] && [ -f "$SHELL_RC" ]; then
        [ "$SHELL_NAME" = "zsh" ] && command -v zsh >/dev/null 2>&1 && shell_bin="zsh"
        dump="$("$shell_bin" -ic 'echo "==P=="; command -v claude 2>/dev/null; echo "==A=="; alias claude 2>/dev/null' 2>/dev/null)"
        candidate="$(sed -n '/==P==/,/==A==/p' <<<"$dump" | sed '1d;$d' | head -n1)"
        if [ -z "$candidate" ] || [ "${candidate#/}" = "$candidate" ]; then
            alias_line="$(sed -n '/==A==/,$p' <<<"$dump" | sed '1d')"
            # bash: alias claude='/path'   |   zsh: claude=/path
            candidate="$(sed -E "s/^alias //; s/^claude=//; s/^['\"]//; s/['\"]\$//" <<<"$alias_line" | awk '{print $1}')"
        fi
    fi

    if [ -z "$candidate" ]; then
        for candidate in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" "$HOME/.npm-global/bin/claude" \
                          "/usr/local/bin/claude" "/opt/homebrew/bin/claude" "$(npm bin -g 2>/dev/null)/claude"; do
            [ -x "$candidate" ] && break
            candidate=""
        done
    fi

    [ -z "$candidate" ] && return 1
    [ "${candidate#/}" != "$candidate" ] || return 1   # must be an absolute path
    command -v readlink >/dev/null 2>&1 && candidate="$(readlink -f "$candidate" 2>/dev/null || readlink "$candidate" 2>/dev/null || echo "$candidate")"
    [ -x "$candidate" ] || return 1
    CLAUDE_REAL_BIN="$candidate"
}
if resolve_claude_bin; then
    ok "Resolved claude binary: $CLAUDE_REAL_BIN"
else
    warn "Could not resolve an absolute path for 'claude'. Aliases will call 'claude' directly (not 'command claude'), so any existing function/alias in $SHELL_RC still works."
fi

CCSTATUSLINE_INSTALLED=false
[ -f "$CCSTATUS_DIR/settings.json" ] && CCSTATUSLINE_INSTALLED=true

EXIST_NAMES=(); EXIST_DIRS=()
for d in "$HOME"/.claude-*; do
    [ -d "$d" ] || continue
    EXIST_NAMES+=("${d##*/.claude-}"); EXIST_DIRS+=("$d")
done

uninstall_ccstatusline() {
    section "Uninstalling ccstatusline"
    if [ "$CCSTATUSLINE_INSTALLED" != true ] && [ "${#EXIST_NAMES[@]}" -eq 0 ]; then
        info "Nothing to uninstall — no ccstatusline config or accounts found."; exit 0
    fi
    read -rp "  Remove ccstatusline config, statusLine settings and shell aliases. Continue? [y/N]: " CONFIRM
    [ "$(tolower "${CONFIRM:-n}")" = "y" ] || [ "$(tolower "${CONFIRM:-n}")" = "yes" ] || { info "Uninstall cancelled."; exit 0; }

    for i in "${!EXIST_NAMES[@]}"; do
        d="${EXIST_DIRS[$i]}"; name="${EXIST_NAMES[$i]}"
        if [ -f "$d/settings.json" ]; then
            node -e '
                const fs=require("fs"),f=process.argv[1];
                let d={}; try{d=JSON.parse(fs.readFileSync(f,"utf8"));}catch(e){process.exit(0);}
                delete d.statusLine; fs.writeFileSync(f,JSON.stringify(d,null,2));
            ' "$d/settings.json"
            ok "Removed statusLine from $d/settings.json"
        fi
        if [ -f "$SHELL_RC" ]; then
            [ "$PLATFORM" = "macos" ] && sed -i '' "/claude-$name()/d" "$SHELL_RC" 2>/dev/null || sed -i "/claude-$name()/d" "$SHELL_RC" 2>/dev/null
            ok "Removed alias claude-$name from $SHELL_RC"
        fi
    done
    [ -d "$CCSTATUS_DIR" ] && { rm -rf "$CCSTATUS_DIR"; ok "Removed $CCSTATUS_DIR"; }

    echo; echo "${C_BOLD}${C_GREEN}== Uninstall complete ==${C_RESET}"
    echo "Account directories (~/.claude-*) were kept — they may hold credentials unrelated to ccstatusline."
    echo "Run: source $SHELL_RC   to apply the alias removal."
    exit 0
}
[ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "-u" ] && uninstall_ccstatusline

MODE="fresh"
if [ "$CCSTATUSLINE_INSTALLED" = true ]; then
    section "Existing installation detected"
    for name in "${EXIST_NAMES[@]}"; do ok "Active account: '$name'"; done
    echo
    echo "  What would you like to do?"
    echo "    1) Repair aliases and update statusline (Recommended)"
    echo "    2) Reconfigure everything from scratch"
    echo "    3) Uninstall ccstatusline and remove aliases"
    read -rp "  Choose an option [1]: " MENU_CHOICE
    case "${MENU_CHOICE:-1}" in
        2) MODE="reset" ;;
        3) uninstall_ccstatusline ;;
        *) MODE="verify" ;;
    esac
fi

ALL_CFG_DIRS=(); ALL_CFG_NAMES=()
add_unique_cfgdir() {
    local dir="$1" name="$2" existing
    for existing in "${ALL_CFG_DIRS[@]}"; do [ "$existing" = "$dir" ] && return 0; done
    ALL_CFG_DIRS+=("$dir"); ALL_CFG_NAMES+=("$name")
}

ensure_account_extras() {
    local NOMBRE="$1" CFGDIR="$2"
    touch "$SHELL_RC"
    [ "$PLATFORM" = "macos" ] && sed -i '' "/claude-$NOMBRE()/d" "$SHELL_RC" 2>/dev/null || sed -i "/claude-$NOMBRE()/d" "$SHELL_RC" 2>/dev/null

    # Use the resolved real binary when we have one; otherwise call "claude"
    # plainly (no "command") so it still resolves through your own
    # function/alias — "command" would skip shell functions entirely.
    {
        echo ""
        if [ -n "$CLAUDE_REAL_BIN" ]; then
            echo "claude-$NOMBRE() { CLAUDE_CONFIG_DIR=\"$CFGDIR\" \"$CLAUDE_REAL_BIN\" \"\$@\"; }"
        else
            echo "claude-$NOMBRE() { CLAUDE_CONFIG_DIR=\"$CFGDIR\" claude \"\$@\"; }"
        fi
    } >>"$SHELL_RC"
    ok "Alias added successfully: claude-$NOMBRE"
}

configure_account_slots() {
    local count="$1" i NOMBRE CFGDIR
    for ((i = 1; i <= count; i++)); do
        section "Configuring Account $i of $count"
        read -rp "  Short account name [$i]: " NOMBRE
        NOMBRE="$(tolower "${NOMBRE:-$i}" | tr -cd 'a-z0-9-')"
        [ -z "$NOMBRE" ] && { warn "Invalid name, skipping slot."; continue; }
        CFGDIR="$HOME/.claude-$NOMBRE"
        mkdir -p "$CFGDIR"
        add_unique_cfgdir "$CFGDIR" "$NOMBRE"
        ensure_account_extras "$NOMBRE" "$CFGDIR"
    done
}

if [ "$MODE" = "fresh" ] || [ "$MODE" = "reset" ]; then
    section "How many Claude Code accounts will you use?"
    read -rp "  Amount [2]: " NCUENTAS
    configure_account_slots "${NCUENTAS:-2}"
else
    for i in "${!EXIST_NAMES[@]}"; do
        add_unique_cfgdir "${EXIST_DIRS[$i]}" "${EXIST_NAMES[$i]}"
        ensure_account_extras "${EXIST_NAMES[$i]}" "${EXIST_DIRS[$i]}"
    done
fi

# ============================================================
# ccstatusline runtime & settings
# ============================================================
mkdir -p "$CCSTATUS_DIR"
if command -v npx >/dev/null 2>&1; then CCS_CMD="npx -y ccstatusline@latest"
else npm install -g ccstatusline && CCS_CMD="ccstatusline"; fi

SEP=$(node -e "process.stdout.write(String.fromCharCode(0xE0B0))")
cat >"$CCSTATUS_DIR/settings.json" <<EOF
{
  "version": 3,
  "lines": [
    [
      {"id": "1","type": "model","color": "hex:ECEFF4","backgroundColor": "hex:BF616A"},
      {"id": "5","type": "context-percentage-usable","color": "hex:2E3440","backgroundColor": "hex:EBCB8B"},
      {"id": "3","type": "custom-command","color": "hex:FDF6E3","backgroundColor": "hex:5E81AC","commandPath": "$CCSTATUS_DIR/usage.sh","timeout": 5000},
      {"id": "7","type": "session-clock","color": "hex:2E3440","backgroundColor": "hex:A3BE8C"}
    ],
    [{"id": "493b0a05-78ed-46f4-a625-44658237886f","type": "current-working-dir","color": "hex:ECEFF4","backgroundColor": "bgMagenta"}],
    []
  ],
  "flexMode": "full-until-compact", "compactThreshold": 60, "colorLevel": 3, "defaultPadding": " ", "minimalistMode": true,
  "powerline": { "enabled": true, "separators": ["$SEP"], "separatorInvertBackground": [false], "endCaps": ["$SEP"], "theme": "custom" }
}
EOF

# ============================================================
# usage.sh — the widget script (Node instead of jq for JSON)
# ============================================================
cat >"$CCSTATUS_DIR/usage.sh" <<'USAGE_EOF'
#!/usr/bin/env bash
UNAME_S="$(uname -s)"
CACHE_KEY=$(tr -c 'A-Za-z0-9' '_' <<<"${CLAUDE_CONFIG_DIR:-default}")
CACHE_FILE="${TMPDIR:-/tmp}/ccstatusline-usage-cache-${CACHE_KEY}.json"
CACHE_MAX_AGE=300
CLAUDE_OAUTH_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"

# jval <dot.path> [default]  -> reads JSON from stdin, prints value or default
jval() {
    node -e '
        let raw=""; process.stdin.on("data",c=>raw+=c); process.stdin.on("end",()=>{
            const [p,d]=process.argv.slice(1); let v;
            try{v=JSON.parse(raw);}catch(e){console.log(d??"");return;}
            for(const k of p.split(".")){ if(v==null){v=undefined;break;} v=v[k]; }
            console.log(v==null?(d??""):v);
        });' "$1" "${2:-}"
}
# jok <dot.path>  -> reads JSON from stdin, exit 0 if truthy, 1 otherwise
jok() {
    node -e '
        let raw=""; process.stdin.on("data",c=>raw+=c); process.stdin.on("end",()=>{
            const p=process.argv[1]; let v;
            try{v=JSON.parse(raw);}catch(e){process.exit(1);}
            for(const k of p.split(".")){ if(v==null){v=undefined;break;} v=v[k]; }
            process.exit(v?0:1);
        });' "$1" >/dev/null 2>&1
}
# jrst <dot.path>  -> reads JSON from stdin, prints "<Xd/Xh/Xm> left" for a
# resets_at timestamp field, or empty if missing/unparseable/in the past
jrst() {
    node -e '
        let raw=""; process.stdin.on("data",c=>raw+=c); process.stdin.on("end",()=>{
            const p=process.argv[1]; let v;
            try{v=JSON.parse(raw);}catch(e){console.log("");return;}
            for(const k of p.split(".")){ if(v==null){v=undefined;break;} v=v[k]; }
            if(!v){console.log("");return;}
            const ms=new Date(v).getTime()-Date.now();
            if(!isFinite(ms)||ms<=0){console.log("");return;}
            const totalMin=Math.round(ms/60000);
            const d=Math.floor(totalMin/1440),h=Math.floor((totalMin%1440)/60),m=totalMin%60;
            console.log(d>0?`${d}d${h}h`:(h>0?`${h}h${m}m`:`${m}m`));
        });' "$1"
}
# jnextmonth  -> prints "<Xd/Xh/Xm> left" until the 1st of next month, 00:00
# UTC (enterprise spend caps reset monthly and the API doesn't expose a
# resets_at for them, so this is computed rather than read from the response)
jnextmonth() {
    node -e '
        const now=new Date();
        const target=new Date(Date.UTC(now.getUTCFullYear(),now.getUTCMonth()+1,1,0,0,0));
        const totalMin=Math.round((target.getTime()-now.getTime())/60000);
        const d=Math.floor(totalMin/1440),h=Math.floor((totalMin%1440)/60),m=totalMin%60;
        console.log(d>0?`${d}d${h}h`:(h>0?`${h}h${m}m`:`${m}m`));
    '
}

get_token() {
    case "$UNAME_S" in
        Darwin)
            local hash_suffix token

            # Claude Code stores each CLAUDE_CONFIG_DIR's credentials under its own
            # Keychain service, named "Claude Code-credentials-<hash>" where <hash>
            # is the first 8 hex chars of the sha256 of the config dir's absolute
            # path. Looking that up directly (instead of guessing via the item's
            # "acct" attribute, which isn't the login email on every system) is the
            # only way to reliably pick the right credentials among several accounts.
            if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
                hash_suffix=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
                token=$(security find-generic-password -s "Claude Code-credentials-$hash_suffix" -w 2>/dev/null | jval "claudeAiOauth.accessToken")
                [ -n "$token" ] && { echo "$token"; return 0; }
            fi

            # Fallback: default/unsuffixed service, used when CLAUDE_CONFIG_DIR is
            # unset or that alias hasn't been logged into yet.
            security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jval "claudeAiOauth.accessToken"
            ;;
        Linux)
            local credfile="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
            [ -f "$credfile" ] && jval "claudeAiOauth.accessToken" < "$credfile"
            ;;
    esac
}

TOKEN=$(get_token)
[ -z "${TOKEN:-}" ] && exit 0

fetch_usage() {
    local tmp; tmp=$(mktemp) || return 1
    curl -s --max-time 3 "https://api.anthropic.com/api/oauth/usage" -H "Authorization: Bearer $TOKEN" -H "anthropic-beta: oauth-2025-04-20" -o "$tmp" 2>/dev/null
    jok "error" < "$tmp" 2>/dev/null && { rm -f "$tmp"; return 1; }
    jok "spend.enabled" < "$tmp" 2>/dev/null && { mv "$tmp" "$CACHE_FILE"; return 0; }

    curl -s --max-time 3 "https://api.anthropic.com/api/oauth/usage" -H "Authorization: Bearer $TOKEN" -H "X-OAuth-Client-ID: $CLAUDE_OAUTH_CLIENT_ID" -H "anthropic-beta: oauth-2025-04-20" -o "$tmp" 2>/dev/null
    if jok "error" < "$tmp" 2>/dev/null; then rm -f "$tmp"; return 1; fi
    [ -s "$tmp" ] && mv "$tmp" "$CACHE_FILE" || rm -f "$tmp"
}

CACHE_AGE=999999
if [ -f "$CACHE_FILE" ]; then
    [ "$UNAME_S" = "Darwin" ] && MTIME=$(stat -f %m "$CACHE_FILE" 2>/dev/null) || MTIME=$(stat -c %Y "$CACHE_FILE" 2>/dev/null)
    CACHE_AGE=$(( $(date -u +%s) - MTIME ))
fi
[ "$CACHE_AGE" -gt "$CACHE_MAX_AGE" ] && fetch_usage
[ -f "$CACHE_FILE" ] || exit 0
DATA=$(cat "$CACHE_FILE" 2>/dev/null)
[ -z "$DATA" ] && exit 0

OUT=""
# Non-enterprise (Pro/Max) accounts expose 5h/7d rate-limit windows in
# five_hour/seven_day; enterprise accounts don't get those windows at all and
# instead track a dollar spend cap via "spend" — so bucket presence, not
# spend.enabled (which is true for both account types), is what tells them apart.
BUCKETS=""; MAXPCT=0
for pair in "five_hour:5h" "seven_day:7d" "seven_day_sonnet:son"; do
    key="${pair%%:*}"; label="${pair##*:}"
    val=$(jval "${key}.utilization" <<<"$DATA")
    [ -z "$val" ] && continue
    pct=$(awk -v v="$val" 'BEGIN{printf "%.0f", v}')
    RESET=$(jrst "${key}.resets_at" <<<"$DATA")
    SEG=" ${label}:${pct}%"
    [ -n "$RESET" ] && SEG="${SEG}(⏳${RESET})"
    BUCKETS="$BUCKETS$SEG"
    [ "$pct" -gt "$MAXPCT" ] && MAXPCT=$pct
done

if [ -n "$BUCKETS" ]; then
    [ "$MAXPCT" -ge 90 ] && ICON="🔴" || { [ "$MAXPCT" -ge 70 ] && ICON="🟡" || ICON="🟢"; }
    OUT="$ICON$BUCKETS"
else
    SPEND_ENABLED=$(jval "spend.enabled" "false" <<<"$DATA")
    if [ "$SPEND_ENABLED" = "true" ]; then
        USED=$(awk -v m="$(jval "spend.used.amount_minor" "0" <<<"$DATA")" 'BEGIN{printf "%.2f", m/100}')
        LIMIT=$(awk -v m="$(jval "spend.limit.amount_minor" "0" <<<"$DATA")" 'BEGIN{printf "%.2f", m/100}')
        PERCENT=$(awk -v u="$USED" -v l="$LIMIT" 'BEGIN{ if (l>0) printf "%.0f", (u/l*100); else print 0 }')
        [ "$PERCENT" -ge 90 ] && ICON="🔴" || { [ "$PERCENT" -ge 70 ] && ICON="🟡" || ICON="🟢"; }
        OUT="$ICON \$${USED}/\$${LIMIT} (${PERCENT}%)"
        RESET=$(jnextmonth)
        [ -n "$RESET" ] && OUT="$OUT (⏳${RESET})"
    fi
fi
[ -z "$OUT" ] && exit 0
echo "$OUT"
USAGE_EOF

chmod +x "$CCSTATUS_DIR/usage.sh"

for d in "${ALL_CFG_DIRS[@]}"; do
    mkdir -p "$d"
    [ -f "$d/settings.json" ] || echo '{}' >"$d/settings.json"
    node -e '
        const fs=require("fs"),[f,cmd]=process.argv.slice(1);
        let d={}; try{d=JSON.parse(fs.readFileSync(f,"utf8"));}catch(e){d={};}
        d.statusLine={type:"command",command:cmd,padding:0,refreshInterval:10};
        fs.writeFileSync(f,JSON.stringify(d,null,2));
    ' "$d/settings.json" "$CCS_CMD"
done

echo
echo "${C_BOLD}${C_GREEN}== Setup ready for SSH ==${C_RESET}"
echo "1. Run: source $SHELL_RC"
echo "2. Open a fresh session with each corresponding alias."
if [ "$NERD_FONT_INSTALLED_NOW" = true ]; then
    echo
    warn "Set your terminal's font to 'Hack Nerd Font Mono' (Terminal.app: Settings > Profiles > Text; iTerm2: Settings > Profiles > Text) so the statusline separators render correctly instead of as boxes."
fi
echo
info "To uninstall later, run: $0 --uninstall"
