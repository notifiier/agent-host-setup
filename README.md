# agent-host-setup

Idempotent Debian 13 (trixie) provisioning script for the Notifiier local-LLM / agent box.

**Target hardware:** 16 GB RAM · 6-core CPU · no GPU · headless

## Quick start

```sh
git clone https://github.com/notifiier/agent-host-setup.git
cd agent-host-setup
sudo ./setup.sh --all
```

## Phases

| Flag           | What it does                                                              |
|----------------|---------------------------------------------------------------------------|
| `--base`       | `apt` upgrade, build tools, git, python3, tmux, zram (50% RAM), unattended-upgrades |
| `--inference`  | Install [Ollama](https://ollama.com), pull model set, bind to LAN interface via systemd override |
| `--agent`      | Install Claude Code (`claude`) + Aider; write systemd unit template |
| `--paperclip`  | Write env template to `/etc/agent-host-setup/paperclip.env.template`; set git identity; verify GitHub credential |
| `--verify`     | Health-check every service, print status table, run decode benchmark |
| `--all`        | All phases in the order above                                             |

Run any phase individually to converge specific state:

```sh
sudo ./setup.sh --base
sudo ./setup.sh --inference
sudo GITHUB_TOKEN=<pat> ./setup.sh --paperclip
sudo ./setup.sh --verify
```

## Model set

| Model | Tag | Role |
|-------|-----|------|
| Qwen3 8B | `qwen3:8b` (Q4_K_M default) | **Primary** — decode benchmark, main task model |
| Qwen3.5 4B | `qwen3.5:4b` | Fast assistant |
| Phi-4-mini | `phi4-mini` | Lightweight reasoning |
| Qwen3-30B-A3B | `qwen3:30b-a3b` | Stretch MoE — ~6 GB active RAM |

The OpenAI-compatible endpoint is served at `http://<LAN-IP>:11434` (bound to the LAN interface only — board decision on NOT-114; no host firewall).

## Multi-agent support

Each additional agent needs only two files:

1. **`/etc/notifiier/agents/<name>.env`** — secrets (copy from the env template, fill in)
2. **`/etc/systemd/system/notifiier-agent-<name>.service`** — adapt from the template at `/etc/notifiier/agents/agent.service.template`

Then `sudo systemctl enable --now notifiier-agent-<name>`.

## Secrets policy

- No secrets are committed to this repo.
- The env template at `/etc/agent-host-setup/paperclip.env.template` is a placeholder only.
- Fill in secrets at install time in the per-agent env file; that file is never placed in the repo.

## Logs

```
/var/log/agent-host-setup/setup.log
```

## Acceptance criteria (NOT-115)

- Script committed to the notifiier org and reviewed.
- A fresh Debian 13 machine provisioned end-to-end by `--all`; `--verify` passes.
- Endpoint answers a completion request from another machine on the LAN.
- Decode ≥ 5 tok/s for `qwen3:8b`; prefill tok/s documented.
