#!/usr/bin/env bash
# setup.sh — Notifiier agent-host-setup
#
# Idempotent Debian 13 (trixie) provisioning for the local-LLM / agent box.
# Target hardware: 16 GB RAM, 6-core CPU, no GPU, headless.
#
# USAGE
#   sudo ./setup.sh [--base] [--inference] [--agent] [--paperclip] [--verify] [--all]
#
# FLAGS
#   --base        OS packages, zram, unattended-upgrades
#   --inference   Ollama install, model pulls, LAN-bound systemd unit
#   --agent       Claude Code, Aider, systemd unit scaffolding
#   --paperclip   Node CLI, env template, git identity
#   --verify      Health-check all services + decode benchmark
#   --all         All phases in order
#
# ENV VARS (for --paperclip / --verify)
#   GITHUB_TOKEN  notifiier org PAT — required for identity verification
#
# DESIGN
#   Idempotent: safe to re-run to converge.
#   Logs to /var/log/agent-host-setup/setup.log — never writes secrets.
#   Multi-agent-ready: second agent = drop a config file + systemd unit.

set -euo pipefail

SCRIPT_VERSION="1.0.0"
LOG_DIR="/var/log/agent-host-setup"
LOG_FILE="$LOG_DIR/setup.log"
STATE_DIR="/var/lib/agent-host-setup"
ENV_TEMPLATE_DIR="/etc/agent-host-setup"
OLLAMA_OVERRIDE_DIR="/etc/systemd/system/ollama.service.d"
NODE_MAJOR=22
GIT_EMAIL="notifiier@users.noreply.github.com"
GIT_NAME="Notifiier"

# Ollama model set
MODEL_PRIMARY="qwen3:8b"          # Q4_K_M default quantisation; primary decode benchmark model
MODELS_SECONDARY=("qwen3.5:4b" "phi4-mini")
MODEL_MOE="qwen3:30b-a3b"         # stretch MoE candidate; ~6 GB active RAM

# ── output helpers ──────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    C_GREEN='\033[0;32m' C_YELLOW='\033[1;33m' C_RED='\033[0;31m'
    C_BLUE='\033[0;34m'  C_BOLD='\033[1m'       C_RESET='\033[0m'
else
    C_GREEN='' C_YELLOW='' C_RED='' C_BLUE='' C_BOLD='' C_RESET=''
fi

_ts()     { date '+%Y-%m-%d %H:%M:%S'; }
_log()    { mkdir -p "$LOG_DIR" 2>/dev/null || true; echo -e "[$(_ts)] [$1] $2" | tee -a "$LOG_FILE"; }
info()    { _log "INFO " "${C_BLUE}$*${C_RESET}"; }
ok()      { _log "OK   " "${C_GREEN}$*${C_RESET}"; }
warn()    { _log "WARN " "${C_YELLOW}$*${C_RESET}"; }
die()     { _log "ERROR" "${C_RED}$*${C_RESET}"; exit 1; }
section() { printf "\n${C_BOLD}══ %s ══${C_RESET}\n" "$*" | tee -a "$LOG_FILE"; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Must run as root. Try: sudo $0 $*"
}

# Return the primary LAN IP (non-loopback next-hop src address)
get_lan_ip() {
    ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}'
}

# ── phase: base ─────────────────────────────────────────────────────────────────
phase_base() {
    section "base — OS packages, zram, unattended-upgrades"

    info "apt update + upgrade"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

    info "Installing base packages"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        build-essential git curl wget ca-certificates gnupg \
        python3 python3-pip python3-venv python3-dev \
        tmux vim nano htop lsof net-tools bc jq \
        unattended-upgrades apt-listchanges \
        zram-tools

    # Configure unattended security updates
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT

    # zram: 50% of RAM ≈ 8 GB on this box; acts as headroom for large model weights
    local zconf="/etc/default/zramswap"
    if ! grep -q "^PERCENT=50" "$zconf" 2>/dev/null; then
        cat > "$zconf" <<'ZRAM'
PERCENT=50
PRIORITY=100
ZRAM
        systemctl restart zramswap 2>/dev/null || true
        ok "zram configured: 50% of RAM"
    else
        ok "zram already configured"
    fi

    mkdir -p "$STATE_DIR" "$LOG_DIR" "$ENV_TEMPLATE_DIR"
    ok "base phase done"
}

# ── phase: inference ─────────────────────────────────────────────────────────────
phase_inference() {
    section "inference — Ollama + model set + systemd unit"

    if ! command -v ollama &>/dev/null; then
        info "Downloading and installing Ollama"
        curl -fsSL https://ollama.com/install.sh | sh
        ok "Ollama installed"
    else
        ok "Ollama already present: $(ollama --version 2>/dev/null | tr -d '\n')"
    fi

    # Detect LAN IP — board decision (NOT-114): no host firewall; bind to LAN interface
    local lan_ip; lan_ip=$(get_lan_ip)
    if [[ -z "$lan_ip" ]]; then
        warn "Cannot auto-detect LAN IP; defaulting to 0.0.0.0"
        lan_ip="0.0.0.0"
    fi
    info "Binding Ollama endpoint to $lan_ip:11434"

    mkdir -p "$OLLAMA_OVERRIDE_DIR"
    cat > "$OLLAMA_OVERRIDE_DIR/lan-bind.conf" <<EOF
# Bind to LAN interface only.
# Board decision NOT-114: no host firewall; LAN binding is the perimeter.
[Service]
Environment="OLLAMA_HOST=${lan_ip}:11434"
Environment="OLLAMA_ORIGINS=*"
EOF
    systemctl daemon-reload
    systemctl enable --now ollama

    # Wait up to 30 s for the API to respond
    local waited=0
    until curl -sf "http://127.0.0.1:11434/api/tags" >/dev/null 2>&1; do
        sleep 1; (( waited++ )) || true
        [[ $waited -ge 30 ]] && die "Ollama did not respond within 30 s"
    done
    ok "Ollama running at $lan_ip:11434"

    info "Pulling primary model: $MODEL_PRIMARY"
    ollama pull "$MODEL_PRIMARY" \
        || warn "Failed to pull $MODEL_PRIMARY — check network / disk space"

    for m in "${MODELS_SECONDARY[@]}"; do
        info "Pulling secondary model: $m"
        ollama pull "$m" || warn "Failed to pull $m (non-fatal)"
    done

    info "Pulling MoE stretch candidate: $MODEL_MOE (large download)"
    ollama pull "$MODEL_MOE" || warn "Failed to pull $MODEL_MOE (non-fatal; stretch model)"

    ok "inference phase done"
}

# ── phase: agent ─────────────────────────────────────────────────────────────────
phase_agent() {
    section "agent — Claude Code, Aider, systemd scaffolding"

    _ensure_nodejs

    # Claude Code — primary agent runtime (claude CLI)
    if ! command -v claude &>/dev/null; then
        info "Installing @anthropic-ai/claude-code"
        npm install -g @anthropic-ai/claude-code
        ok "claude installed"
    else
        ok "claude already installed: $(claude --version 2>/dev/null || echo 'ok')"
    fi

    # Aider — AI pair-programming assistant and Aider deps
    if ! command -v aider &>/dev/null; then
        info "Installing aider-chat"
        pip3 install --break-system-packages aider-chat
        ok "aider installed"
    else
        ok "aider already installed: $(aider --version 2>/dev/null | head -1 || echo 'ok')"
    fi

    # Agent config drop-in directory.
    # A second agent needs only: /etc/notifiier/agents/<name>.env + a systemd unit.
    mkdir -p /etc/notifiier/agents

    local unit_tpl="/etc/notifiier/agents/agent.service.template"
    if [[ ! -f "$unit_tpl" ]]; then
        cat > "$unit_tpl" <<'UNIT'
# Notifiier Paperclip local-adapter agent — systemd unit template
# Copy to /etc/systemd/system/notifiier-agent-<name>.service and fill in NAME.
[Unit]
Description=Notifiier Paperclip Agent – %i
After=network-online.target ollama.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/notifiier/agents/%i.env
ExecStart=/usr/bin/env paperclipai agent local-cli %i
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
        ok "agent unit template: $unit_tpl"
    else
        ok "agent unit template already present"
    fi

    ok "agent phase done"
}

# ── phase: paperclip ─────────────────────────────────────────────────────────────
phase_paperclip() {
    section "paperclip — env template, git identity"

    _ensure_nodejs

    # Write env template — secrets must be entered at install time, never committed
    local tpl="$ENV_TEMPLATE_DIR/paperclip.env.template"
    cat > "$tpl" <<'ENV'
# Paperclip local adapter — environment template
# Copy to /etc/notifiier/agents/<name>.env and populate secrets.
# NEVER commit the filled-in copy to any repository.

# ── Paperclip ────────────────────────────────────────────────────────────────
PAPERCLIP_API_URL=https://app.paperclip.ing
PAPERCLIP_API_KEY=<insert-service-token>
PAPERCLIP_AGENT_ID=<agent-uuid>
PAPERCLIP_COMPANY_ID=<company-uuid>

# ── GitHub ───────────────────────────────────────────────────────────────────
GITHUB_TOKEN=<notifiier-org-pat>

# ── Ollama (local inference) ─────────────────────────────────────────────────
OLLAMA_BASE_URL=http://127.0.0.1:11434
OLLAMA_MODEL=qwen3:8b
ENV
    ok "env template: $tpl"

    # System-wide git identity (per-agent config may override)
    info "Setting global git identity"
    git config --global user.email "$GIT_EMAIL"
    git config --global user.name  "$GIT_NAME"
    ok "git identity: $GIT_NAME <$GIT_EMAIL>"

    _verify_github_identity

    ok "paperclip phase done"
}

_verify_github_identity() {
    local token="${GITHUB_TOKEN:-}"
    if [[ -z "$token" ]]; then
        warn "GITHUB_TOKEN not set — skipping live identity check"
        warn "Export GITHUB_TOKEN=<notifiier-org-pat> and re-run --paperclip or --verify"
        return 0
    fi

    local login
    login=$(curl -sf -H "Authorization: token $token" \
        https://api.github.com/user 2>/dev/null \
        | jq -r '.login // empty' 2>/dev/null) \
        || { warn "GitHub API unreachable — cannot verify identity"; return 0; }

    if [[ -z "$login" ]]; then
        warn "Could not determine GitHub login — token may be invalid"; return 0
    fi

    case "$login" in
        notifiier|notifiier-*)
            ok "GitHub identity confirmed: $login (notifiier org)" ;;
        *)
            die "GitHub credential resolves to '$login' — must be notifiier. " \
                "Rotate the token before proceeding (see NOT-115 GitHub policy)." ;;
    esac
}

_ensure_nodejs() {
    if command -v node &>/dev/null; then
        ok "Node.js already present: $(node --version)"
        return 0
    fi
    info "Installing Node.js $NODE_MAJOR LTS via NodeSource"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
    ok "Node.js $(node --version) installed"
}

# ── phase: verify ─────────────────────────────────────────────────────────────
phase_verify() {
    section "verify — health check + decode benchmark"

    local ok_count=0 fail_count=0
    local lan_ip; lan_ip=$(get_lan_ip)

    _pass() {
        printf "  %-52s ${C_GREEN}OK${C_RESET}\n"   "$1"
        ok_count=$(( ok_count + 1 ))
    }
    _fail() {
        printf "  %-52s ${C_RED}FAIL${C_RESET}\n"   "$1"
        fail_count=$(( fail_count + 1 ))
    }
    # Simple command check
    _chk() {
        local n="$1"; shift
        if "$@" 2>/dev/null; then _pass "$n"; else _fail "$n"; fi
    }
    # Piped / compound expression check
    _chkp() {
        local n="$1" expr="$2"
        if bash -c "$expr" >/dev/null 2>&1; then _pass "$n"; else _fail "$n"; fi
    }

    printf "\n${C_BOLD}%-52s %s${C_RESET}\n" "Check" "Status"
    printf '%s\n' "──────────────────────────────────────────────────────────────"

    # OS
    _chkp "OS: Debian 13 (trixie)"                 "grep -q trixie /etc/os-release"
    _chkp "zram swap active"                        "swapon --show | grep -q zram"
    _chk  "unattended-upgrades"                     systemctl is-active --quiet unattended-upgrades

    # Inference
    _chk  "ollama: service active"                  systemctl is-active --quiet ollama
    _chkp "ollama: API responds (127.0.0.1)"        "curl -sf http://127.0.0.1:11434/api/tags"
    _chkp "ollama: LAN endpoint ($lan_ip)"          "curl -sf http://${lan_ip}:11434/api/tags"
    local primary_name="${MODEL_PRIMARY%%:*}"
    _chkp "ollama: primary model present"           "ollama list | grep -q '$primary_name'"

    # Agent runtime
    _chk  "claude: installed"                       command -v claude
    _chk  "aider: installed"                        command -v aider
    _chk  "node: installed"                         command -v node
    _chk  "python3: installed"                      command -v python3
    _chk  "git: installed"                          command -v git

    # Identity & config
    local git_email; git_email=$(git config --global user.email 2>/dev/null || echo "")
    _chk  "git identity: notifiier email"           test "$git_email" = "$GIT_EMAIL"
    _chk  "paperclip env template exists"           test -f "$ENV_TEMPLATE_DIR/paperclip.env.template"

    printf '%s\n' "──────────────────────────────────────────────────────────────"
    printf "  ${C_GREEN}OK: %d${C_RESET}   ${C_RED}FAIL: %d${C_RESET}\n\n" \
        "$ok_count" "$fail_count"

    # ── Decode benchmark ───────────────────────────────────────────────────────
    section "Inference benchmark — $MODEL_PRIMARY"

    if ! systemctl is-active --quiet ollama 2>/dev/null; then
        warn "Ollama not active — skipping benchmark"
    else
        info "Sending short prompt, requesting 50-token decode…"

        local bm_resp
        bm_resp=$(curl -sf http://127.0.0.1:11434/api/generate \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"$MODEL_PRIMARY\",\"prompt\":\"The quick brown fox\",
                 \"stream\":false,\"options\":{\"num_predict\":50}}" 2>/dev/null) \
            || { warn "Benchmark request failed (model may not be loaded)"; bm_resp="{}"; }

        local eval_count eval_dur prompt_count prompt_dur
        eval_count=$(  echo "$bm_resp" | jq -r '.eval_count          // 0')
        eval_dur=$(    echo "$bm_resp" | jq -r '.eval_duration       // 0')
        prompt_count=$(echo "$bm_resp" | jq -r '.prompt_eval_count   // 0')
        prompt_dur=$(  echo "$bm_resp" | jq -r '.prompt_eval_duration // 0')

        if [[ "$eval_count" -gt 0 && "$eval_dur" -gt 0 ]]; then
            local decode_tps
            decode_tps=$(awk "BEGIN{printf \"%.1f\", $eval_count * 1e9 / $eval_dur}")

            local prefill_tps="n/a"
            if [[ "$prompt_count" -gt 0 && "$prompt_dur" -gt 0 ]]; then
                prefill_tps=$(awk "BEGIN{printf \"%.1f\", $prompt_count * 1e9 / $prompt_dur}")
            fi

            printf "  %-25s %s tok/s\n"  "Decode:"  "$decode_tps"
            printf "  %-25s %s tok/s\n"  "Prefill:" "$prefill_tps"
            printf "  %-25s %s tokens\n" "Output:"  "$eval_count"
            echo ""

            # Acceptance criterion: decode ≥ 5 tok/s
            if awk "BEGIN{exit !($decode_tps >= 5)}"; then
                ok "Decode ≥ 5 tok/s — acceptance criterion MET"
            else
                warn "Decode $decode_tps tok/s is below the 5 tok/s minimum"
                fail_count=$(( fail_count + 1 ))
            fi
        else
            warn "No eval_count in response — model may not be loaded yet"
        fi
    fi

    echo ""
    if [[ $fail_count -eq 0 ]]; then
        ok "All checks passed (${ok_count} OK, 0 FAIL)"
        return 0
    else
        warn "$fail_count check(s) failed — review output above"
        return 1
    fi
}

# ── main ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<'USAGE'
Usage: sudo ./setup.sh [OPTIONS]

Options:
  --base        Install OS base packages, zram, unattended-upgrades
  --inference   Install Ollama, pull model set, bind to LAN interface only
  --agent       Install Claude Code, Aider, agent systemd unit scaffolding
  --paperclip   Write env template, configure git identity (verifies GitHub)
  --verify      Health-check all services + print decode benchmark
  --all         Run all phases in order: base → inference → agent → paperclip → verify
  --help        Show this help

Environment variables:
  GITHUB_TOKEN  notifiier org PAT — required for GitHub identity verification

Logs: /var/log/agent-host-setup/setup.log
USAGE
}

main() {
    # Handle --help before root check so it's readable without sudo
    for arg in "$@"; do
        [[ "$arg" == "--help" || "$arg" == "-h" ]] && { usage; exit 0; }
    done

    require_root "$@"
    mkdir -p "$LOG_DIR" "$STATE_DIR"
    _log "INFO " "agent-host-setup v$SCRIPT_VERSION — args: $*"

    [[ $# -eq 0 ]] && { usage; exit 1; }

    local do_base=0 do_inference=0 do_agent=0 do_paperclip=0 do_verify=0

    for arg in "$@"; do
        case "$arg" in
            --base)       do_base=1 ;;
            --inference)  do_inference=1 ;;
            --agent)      do_agent=1 ;;
            --paperclip)  do_paperclip=1 ;;
            --verify)     do_verify=1 ;;
            --all)
                do_base=1; do_inference=1; do_agent=1
                do_paperclip=1; do_verify=1 ;;
            --help|-h)    usage; exit 0 ;;
            *)            die "Unknown option: $arg. Use --help." ;;
        esac
    done

    [[ $do_base      -eq 1 ]] && phase_base
    [[ $do_inference -eq 1 ]] && phase_inference
    [[ $do_agent     -eq 1 ]] && phase_agent
    [[ $do_paperclip -eq 1 ]] && phase_paperclip
    [[ $do_verify    -eq 1 ]] && phase_verify

    _log "INFO " "agent-host-setup v$SCRIPT_VERSION — complete"
}

main "$@"
