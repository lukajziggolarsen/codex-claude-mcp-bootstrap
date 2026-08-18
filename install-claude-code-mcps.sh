#!/usr/bin/env bash
# Bootstrap Claude Code and replicate this machine's five locally configured
# MCP servers on macOS, Linux, or WSL.
#
# Servers installed:
#   - powerbi-modeling  (Microsoft Power BI Modeling MCP)
#   - postgres-rep      (Postgres MCP Pro, restricted mode)
#   - postgres-f1       (Postgres MCP Pro, restricted mode)
#   - mssql-bi          (MCP Toolbox for Databases)
#   - mssql-qisa        (MCP Toolbox for Databases)
#
# Credentials are never placed in ~/.claude.json. They are stored in a
# chmod-600 shell file and loaded by small chmod-700 MCP launcher scripts.

set -Eeuo pipefail
IFS=$'\n\t'
set +x

readonly SCRIPT_NAME="${0##*/}"
readonly DEFAULT_CONFIG_ROOT="${HOME}/.config/claude-mcps"
readonly DEFAULT_BIN_DIR="${HOME}/.local/bin"

NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
SKIP_POWERBI="${SKIP_POWERBI:-0}"
SKIP_POSTGRES_REP="${SKIP_POSTGRES_REP:-0}"
SKIP_POSTGRES_F1="${SKIP_POSTGRES_F1:-0}"
SKIP_MSSQL_BI="${SKIP_MSSQL_BI:-0}"
SKIP_MSSQL_QISA="${SKIP_MSSQL_QISA:-0}"
VERIFY_CONNECTIONS="${VERIFY_CONNECTIONS:-1}"
# Claude starts stdio servers during the final health check, which naturally
# downloads npx/uvx packages. A separate prefetch is optional because some
# corporate package proxies keep CLI help commands open indefinitely.
PREFETCH_MCP_PACKAGES="${PREFETCH_MCP_PACKAGES:-0}"
POWERBI_PREFER_WINDOWS="${POWERBI_PREFER_WINDOWS:-1}"

CONFIG_ROOT="${CLAUDE_MCP_CONFIG_ROOT:-${DEFAULT_CONFIG_ROOT}}"
BIN_DIR="${CLAUDE_MCP_BIN_DIR:-${DEFAULT_BIN_DIR}}"
SECRETS_FILE="${CONFIG_ROOT}/secrets.env"
RUNTIME_FILE="${CONFIG_ROOT}/runtime.env"
MSSQL_TOOLBOX_CONFIG="${CONFIG_ROOT}/mssql.tools.yaml"
BACKUP_DIR="${CONFIG_ROOT}/backups"

CLAUDE_RELEASE="${CLAUDE_RELEASE:-latest}"
NODE_MAJOR="${NODE_MAJOR:-24}"
NVM_INSTALL_VERSION="${NVM_INSTALL_VERSION:-v0.40.3}"
POSTGRES_MCP_PACKAGE="${POSTGRES_MCP_PACKAGE:-postgres-mcp}"
TOOLBOX_MCP_PACKAGE="${TOOLBOX_MCP_PACKAGE:-@toolbox-sdk/server@latest}"
POWERBI_MCP_PACKAGE="${POWERBI_MCP_PACKAGE:-@microsoft/powerbi-modeling-mcp@latest}"

BOOTSTRAP_TMP_DIR=""
CLAUDE_BIN=""
NODE_BIN=""
NPX_BIN=""
UVX_BIN=""
POWERBI_USE_WINDOWS_NPX="0"

note() { printf '\n[%s] %s\n' "$SCRIPT_NAME" "$*"; }
warn() { printf '\n[%s] WARNING: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die()  { printf '\n[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'USAGE'
Usage:
  bash install-claude-code-mcps.sh [options]

Options:
  --env-file PATH       Source a trusted shell env file before installation.
  --non-interactive     Fail instead of prompting for missing credentials.
  --skip-powerbi        Do not configure the Power BI Modeling MCP.
  --skip-postgres-rep   Do not configure postgres-rep.
  --skip-postgres-f1    Do not configure postgres-f1.
  --skip-mssql-bi       Do not configure mssql-bi.
  --skip-mssql-qisa     Do not configure mssql-qisa.
  --no-verify           Register servers without starting health checks.
  -h, --help            Show this help.

Required values can be exported beforehand or entered at secure prompts:
  POSTGRES_REP_DATABASE_URI
  POSTGRES_F1_DATABASE_URI

  MSSQL_BI_HOST       MSSQL_BI_PORT       MSSQL_BI_DATABASE
  MSSQL_BI_USER       MSSQL_BI_PASSWORD   MSSQL_BI_ENCRYPT

  MSSQL_QISA_HOST     MSSQL_QISA_PORT     MSSQL_QISA_DATABASE
  MSSQL_QISA_USER     MSSQL_QISA_PASSWORD MSSQL_QISA_ENCRYPT

Defaults:
  MSSQL_*_PORT=1433
  MSSQL_*_ENCRYPT=disable   (matches the source machine; override where TLS works)

Example, fully non-interactive:
  POSTGRES_REP_DATABASE_URI='postgresql://readonly:pass@host:5432/db' \
  POSTGRES_F1_DATABASE_URI='postgresql://readonly:pass@host:5432/db' \
  MSSQL_BI_HOST='host' MSSQL_BI_DATABASE='db' \
  MSSQL_BI_USER='readonly' MSSQL_BI_PASSWORD='pass' \
  MSSQL_QISA_HOST='host' MSSQL_QISA_DATABASE='db' \
  MSSQL_QISA_USER='readonly' MSSQL_QISA_PASSWORD='pass' \
  bash install-claude-code-mcps.sh --non-interactive

Security:
  Use database accounts that are read-only at the database permission layer.
  postgres-mcp restricted mode is defense-in-depth, not a replacement for a
  read-only PostgreSQL role. The MSSQL execute_sql tool can submit arbitrary
  SQL, so the SQL Server login itself must be restricted.
USAGE
}

load_env_file() {
  local input_file="$1"
  [[ -f "$input_file" ]] || die "Environment file not found: $input_file"
  note "Loading trusted environment file: $input_file"
  set -a
  # This intentionally sources a user-supplied shell file. Only pass a file
  # that you trust; it can contain shell code, not just KEY=value entries.
  # shellcheck disable=SC1090
  source "$input_file"
  set +a
}

while (($#)); do
  case "$1" in
    --env-file)
      (($# >= 2)) || die "--env-file requires a path"
      load_env_file "$2"
      shift 2
      ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --skip-powerbi) SKIP_POWERBI=1; shift ;;
    --skip-postgres-rep) SKIP_POSTGRES_REP=1; shift ;;
    --skip-postgres-f1) SKIP_POSTGRES_F1=1; shift ;;
    --skip-mssql-bi) SKIP_MSSQL_BI=1; shift ;;
    --skip-mssql-qisa) SKIP_MSSQL_QISA=1; shift ;;
    --no-verify) VERIFY_CONNECTIONS=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

case "$(uname -s)" in
  Linux|Darwin) ;;
  MINGW*|MSYS*|CYGWIN*)
    die "Run this Bash installer inside WSL, not Git Bash. Native Windows Claude Code uses the PowerShell installer."
    ;;
  *) die "Unsupported operating system: $(uname -s)" ;;
esac

is_wsl() {
  [[ "$(uname -s)" == "Linux" ]] &&
    { grep -qi microsoft /proc/version 2>/dev/null || [[ -n "${WSL_DISTRO_NAME:-}" ]]; }
}

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif have sudo; then
    sudo "$@"
  else
    die "Root privileges are required for: $* (install sudo or run as root)"
  fi
}

install_curl_if_missing() {
  have curl && return 0
  note "Installing curl and CA certificates"
  if have apt-get; then
    as_root apt-get update
    as_root apt-get install -y curl ca-certificates
  elif have dnf; then
    as_root dnf install -y curl ca-certificates
  elif have yum; then
    as_root yum install -y curl ca-certificates
  elif have apk; then
    as_root apk add --no-cache curl ca-certificates
  elif have brew; then
    brew install curl
  else
    die "curl is required and no supported package manager was found"
  fi
}

cleanup() {
  if [[ -n "${BOOTSTRAP_TMP_DIR:-}" && -d "$BOOTSTRAP_TMP_DIR" ]]; then
    case "$BOOTSTRAP_TMP_DIR" in
      "${TMPDIR:-/tmp}"/claude-mcp-bootstrap.*|/tmp/claude-mcp-bootstrap.*)
        rm -rf -- "$BOOTSTRAP_TMP_DIR"
        ;;
    esac
  fi
}
trap cleanup EXIT

install_curl_if_missing
BOOTSTRAP_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-mcp-bootstrap.XXXXXX")"

download() {
  local url="$1"
  local destination="$2"
  curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$destination"
}

export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"

install_claude_code() {
  if have claude; then
    CLAUDE_BIN="$(command -v claude)"
    note "Claude Code already installed: $($CLAUDE_BIN --version)"
    return 0
  fi

  note "Installing Claude Code (${CLAUDE_RELEASE} channel) from Anthropic"
  local installer="${BOOTSTRAP_TMP_DIR}/install-claude.sh"
  download "https://claude.ai/install.sh" "$installer"
  bash "$installer" "$CLAUDE_RELEASE"
  export PATH="${HOME}/.local/bin:${PATH}"
  CLAUDE_BIN="$(command -v claude || true)"
  [[ -n "$CLAUDE_BIN" ]] || die "Claude Code installed but 'claude' is not on PATH"
  "$CLAUDE_BIN" --version
}

install_node_if_needed() {
  local node_major_found="0"
  local node_platform=""

  if have node; then
    node_major_found="$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || printf '0')"
    node_platform="$(node -p 'process.platform' 2>/dev/null || true)"
  fi

  if [[ "$node_major_found" =~ ^[0-9]+$ ]] &&
     ((node_major_found >= 22)) &&
     have npx &&
     { [[ "$(uname -s)" != "Linux" ]] || [[ "$node_platform" == "linux" ]]; }; then
    NODE_BIN="$(command -v node)"
    NPX_BIN="$(command -v npx)"
    note "Using Node.js $(node --version) at $NODE_BIN"
    return 0
  fi

  note "Installing Linux/macOS Node.js ${NODE_MAJOR} with nvm"
  local bootstrap_nvm_dir="${NVM_DIR:-${HOME}/.nvm}"
  if [[ ! -s "${bootstrap_nvm_dir}/nvm.sh" ]]; then
    local nvm_installer="${BOOTSTRAP_TMP_DIR}/install-nvm.sh"
    download "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_INSTALL_VERSION}/install.sh" "$nvm_installer"
    PROFILE=/dev/null NVM_DIR="$bootstrap_nvm_dir" bash "$nvm_installer"
  fi

  # nvm's scripts are compatible with nounset only inconsistently across
  # versions, so disable it just around sourcing and invoking nvm.
  set +u
  # shellcheck disable=SC1090
  source "${bootstrap_nvm_dir}/nvm.sh"
  nvm install "$NODE_MAJOR"
  nvm use "$NODE_MAJOR"
  set -u

  NODE_BIN="$(command -v node || true)"
  NPX_BIN="$(command -v npx || true)"
  [[ -n "$NODE_BIN" && -n "$NPX_BIN" ]] || die "Node.js/npx installation failed"
  note "Installed Node.js $($NODE_BIN --version)"
}

install_uv_if_needed() {
  if have uvx; then
    UVX_BIN="$(command -v uvx)"
    note "Using uvx at $UVX_BIN"
    return 0
  fi

  note "Installing uv/uvx from Astral"
  local uv_installer="${BOOTSTRAP_TMP_DIR}/install-uv.sh"
  download "https://astral.sh/uv/install.sh" "$uv_installer"
  sh "$uv_installer"
  export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
  UVX_BIN="$(command -v uvx || true)"
  [[ -n "$UVX_BIN" ]] || die "uv installed but 'uvx' is not on PATH"
  "$UVX_BIN" --version
}

install_claude_code
install_node_if_needed
install_uv_if_needed

prompt_value() {
  local variable_name="$1"
  local prompt_label="$2"
  local secret_input="$3"
  local default_value="${4:-}"
  local current_value=""
  local entered_value=""

  set +u
  current_value="${!variable_name}"
  set -u
  if [[ -n "$current_value" ]]; then
    return 0
  fi

  if [[ -n "$default_value" ]]; then
    printf -v "$variable_name" '%s' "$default_value"
    export "$variable_name"
    return 0
  fi

  if is_true "$NON_INTERACTIVE" || [[ ! -t 0 ]]; then
    die "Missing required environment variable: $variable_name"
  fi

  if is_true "$secret_input"; then
    read -r -s -p "${prompt_label}: " entered_value
    printf '\n'
  else
    read -r -p "${prompt_label}: " entered_value
  fi
  [[ -n "$entered_value" ]] || die "$variable_name cannot be empty"
  printf -v "$variable_name" '%s' "$entered_value"
  export "$variable_name"
}

collect_credentials() {
  note "Collecting connection settings (prompted secrets are hidden)"

  if ! is_true "$SKIP_POSTGRES_REP"; then
    prompt_value POSTGRES_REP_DATABASE_URI "postgres-rep PostgreSQL URI" 1
  fi
  if ! is_true "$SKIP_POSTGRES_F1"; then
    prompt_value POSTGRES_F1_DATABASE_URI "postgres-f1 PostgreSQL URI" 1
  fi

  if ! is_true "$SKIP_MSSQL_BI"; then
    prompt_value MSSQL_BI_HOST "mssql-bi host" 0
    prompt_value MSSQL_BI_PORT "mssql-bi port" 0 1433
    prompt_value MSSQL_BI_DATABASE "mssql-bi database" 0
    prompt_value MSSQL_BI_USER "mssql-bi read-only user" 0
    prompt_value MSSQL_BI_PASSWORD "mssql-bi password" 1
    prompt_value MSSQL_BI_ENCRYPT "mssql-bi encrypt setting" 0 disable
  fi

  if ! is_true "$SKIP_MSSQL_QISA"; then
    prompt_value MSSQL_QISA_HOST "mssql-qisa host" 0
    prompt_value MSSQL_QISA_PORT "mssql-qisa port" 0 1433
    prompt_value MSSQL_QISA_DATABASE "mssql-qisa database" 0
    prompt_value MSSQL_QISA_USER "mssql-qisa read-only user" 0
    prompt_value MSSQL_QISA_PASSWORD "mssql-qisa password" 1
    prompt_value MSSQL_QISA_ENCRYPT "mssql-qisa encrypt setting" 0 disable
  fi
}

validate_credentials() {
  if ! is_true "$SKIP_POSTGRES_REP"; then
    [[ "$POSTGRES_REP_DATABASE_URI" == postgres://* || "$POSTGRES_REP_DATABASE_URI" == postgresql://* ]] ||
      die "POSTGRES_REP_DATABASE_URI must begin with postgres:// or postgresql://"
  fi
  if ! is_true "$SKIP_POSTGRES_F1"; then
    [[ "$POSTGRES_F1_DATABASE_URI" == postgres://* || "$POSTGRES_F1_DATABASE_URI" == postgresql://* ]] ||
      die "POSTGRES_F1_DATABASE_URI must begin with postgres:// or postgresql://"
  fi

  local port_variable=""
  local port_value=""
  for port_variable in MSSQL_BI_PORT MSSQL_QISA_PORT; do
    if [[ "$port_variable" == MSSQL_BI_PORT ]] && is_true "$SKIP_MSSQL_BI"; then continue; fi
    if [[ "$port_variable" == MSSQL_QISA_PORT ]] && is_true "$SKIP_MSSQL_QISA"; then continue; fi
    set +u
    port_value="${!port_variable}"
    set -u
    [[ "$port_value" =~ ^[0-9]+$ ]] && ((10#$port_value >= 1 && 10#$port_value <= 65535)) ||
      die "$port_variable must be an integer from 1 to 65535"
  done

  if ! is_true "$SKIP_MSSQL_BI" && [[ "${MSSQL_BI_ENCRYPT}" == "disable" ]]; then
    warn "mssql-bi TLS encryption is disabled to match the source machine. Set MSSQL_BI_ENCRYPT to a supported secure mode when possible."
  fi
  if ! is_true "$SKIP_MSSQL_QISA" && [[ "${MSSQL_QISA_ENCRYPT}" == "disable" ]]; then
    warn "mssql-qisa TLS encryption is disabled to match the source machine. Set MSSQL_QISA_ENCRYPT to a supported secure mode when possible."
  fi
}

collect_credentials
validate_credentials

mkdir -p "$CONFIG_ROOT" "$BIN_DIR" "$BACKUP_DIR"
# Do not change permissions on an existing ~/.local/bin because it may contain
# unrelated user tools. The generated launchers themselves are mode 0700.
chmod 700 "$CONFIG_ROOT" "$BACKUP_DIR"
umask 077

backup_existing_claude_config() {
  local claude_config="${HOME}/.claude.json"
  if [[ -f "$claude_config" ]]; then
    local timestamp
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p "$claude_config" "${BACKUP_DIR}/claude.json.${timestamp}.bak"
    note "Backed up existing Claude configuration to ${BACKUP_DIR}/claude.json.${timestamp}.bak"
  fi
}

print_assignment() {
  local variable_name="$1"
  local variable_value=""
  set +u
  variable_value="${!variable_name}"
  set -u
  printf '%s=' "$variable_name"
  printf '%q' "$variable_value"
  printf '\n'
}

write_secret_file() {
  {
    printf '# Generated by %s on %s. Keep mode 0600.\n' "$SCRIPT_NAME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if ! is_true "$SKIP_POSTGRES_REP"; then print_assignment POSTGRES_REP_DATABASE_URI; fi
    if ! is_true "$SKIP_POSTGRES_F1"; then print_assignment POSTGRES_F1_DATABASE_URI; fi
    if ! is_true "$SKIP_MSSQL_BI"; then
      print_assignment MSSQL_BI_HOST
      print_assignment MSSQL_BI_PORT
      print_assignment MSSQL_BI_DATABASE
      print_assignment MSSQL_BI_USER
      print_assignment MSSQL_BI_PASSWORD
      print_assignment MSSQL_BI_ENCRYPT
    fi
    if ! is_true "$SKIP_MSSQL_QISA"; then
      print_assignment MSSQL_QISA_HOST
      print_assignment MSSQL_QISA_PORT
      print_assignment MSSQL_QISA_DATABASE
      print_assignment MSSQL_QISA_USER
      print_assignment MSSQL_QISA_PASSWORD
      print_assignment MSSQL_QISA_ENCRYPT
    fi
  } > "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
}

write_runtime_file() {
  {
    printf '# Non-secret runtime paths and package selections.\n'
    printf 'NPX_BIN='; printf '%q' "$NPX_BIN"; printf '\n'
    printf 'UVX_BIN='; printf '%q' "$UVX_BIN"; printf '\n'
    printf 'MSSQL_TOOLBOX_CONFIG='; printf '%q' "$MSSQL_TOOLBOX_CONFIG"; printf '\n'
    printf 'POSTGRES_MCP_PACKAGE='; printf '%q' "$POSTGRES_MCP_PACKAGE"; printf '\n'
    printf 'TOOLBOX_MCP_PACKAGE='; printf '%q' "$TOOLBOX_MCP_PACKAGE"; printf '\n'
    printf 'POWERBI_MCP_PACKAGE='; printf '%q' "$POWERBI_MCP_PACKAGE"; printf '\n'
    printf 'POWERBI_USE_WINDOWS_NPX='; printf '%q' "$POWERBI_USE_WINDOWS_NPX"; printf '\n'
  } > "$RUNTIME_FILE"
  chmod 600 "$RUNTIME_FILE"
}

write_mssql_toolbox_config() {
  cat > "$MSSQL_TOOLBOX_CONFIG" <<'YAML'
# Credentials and connection fields are substituted from the launcher's
# environment. Database permissions, not this file, must enforce read-only use.
kind: source
name: mssql-source
type: mssql
host: ${MSSQL_HOST}
port: ${MSSQL_PORT}
database: ${MSSQL_DATABASE}
user: ${MSSQL_USER}
password: ${MSSQL_PASSWORD}
encrypt: ${MSSQL_ENCRYPT}
---
kind: tool
name: execute_sql
type: mssql-execute-sql
source: mssql-source
description: Execute SQL using the permissions of the configured database login.
---
kind: tool
name: list_tables
type: mssql-list-tables
source: mssql-source
description: Lists detailed schema information for user-created tables.
---
kind: toolset
name: data
tools:
- execute_sql
- list_tables
YAML
  chmod 600 "$MSSQL_TOOLBOX_CONFIG"
}

configure_wsl_powerbi_bridge() {
  is_true "$SKIP_POWERBI" && return 0
  is_wsl || return 0
  is_true "$POWERBI_PREFER_WINDOWS" || return 0
  have powershell.exe || { warn "WSL detected but powershell.exe is unavailable; Power BI MCP will use the Linux package."; return 0; }

  if powershell.exe -NoProfile -NonInteractive -Command \
      'if (Get-Command npx.cmd -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }' \
      >/dev/null 2>&1; then
    POWERBI_USE_WINDOWS_NPX=1
    note "Power BI MCP will run through Windows npx for Power BI Desktop interoperability"
    return 0
  fi

  if have winget.exe; then
    note "Installing Windows Node.js LTS for the Power BI Desktop MCP bridge"
    if powershell.exe -NoProfile -NonInteractive -Command \
        '& winget.exe install --id OpenJS.NodeJS.LTS --exact --silent --accept-package-agreements --accept-source-agreements' \
        >/dev/null; then
      if powershell.exe -NoProfile -NonInteractive -Command \
          'if (Get-Command npx.cmd -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }' \
          >/dev/null 2>&1; then
        POWERBI_USE_WINDOWS_NPX=1
        note "Windows Node.js bridge installed"
        return 0
      fi
    fi
  fi

  warn "Could not provision Windows npx. Power BI MCP will use its Linux package; Power BI Desktop auto-discovery may not work from WSL."
}

write_launcher_header() {
  local destination="$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -Eeuo pipefail\n'
    printf 'set +x\n'
    printf 'readonly MCP_CONFIG_ROOT='
    printf '%q' "$CONFIG_ROOT"
    printf '\n'
    cat <<'HEADER'
# shellcheck disable=SC1090
source "${MCP_CONFIG_ROOT}/runtime.env"
# shellcheck disable=SC1090
source "${MCP_CONFIG_ROOT}/secrets.env"
HEADER
  } > "$destination"
}

write_launchers() {
  local launcher=""

  if ! is_true "$SKIP_POSTGRES_REP"; then
    launcher="${BIN_DIR}/claude-mcp-postgres-rep"
    write_launcher_header "$launcher"
    cat >> "$launcher" <<'LAUNCHER'
export DATABASE_URI="$POSTGRES_REP_DATABASE_URI"
exec "$UVX_BIN" --from "$POSTGRES_MCP_PACKAGE" --with 'mcp[cli]<2' \
  postgres-mcp --access-mode=restricted
LAUNCHER
    chmod 700 "$launcher"
  fi

  if ! is_true "$SKIP_POSTGRES_F1"; then
    launcher="${BIN_DIR}/claude-mcp-postgres-f1"
    write_launcher_header "$launcher"
    cat >> "$launcher" <<'LAUNCHER'
export DATABASE_URI="$POSTGRES_F1_DATABASE_URI"
exec "$UVX_BIN" --from "$POSTGRES_MCP_PACKAGE" --with 'mcp[cli]<2' \
  postgres-mcp --access-mode=restricted
LAUNCHER
    chmod 700 "$launcher"
  fi

  if ! is_true "$SKIP_MSSQL_BI"; then
    launcher="${BIN_DIR}/claude-mcp-mssql-bi"
    write_launcher_header "$launcher"
    cat >> "$launcher" <<'LAUNCHER'
export MSSQL_HOST="$MSSQL_BI_HOST"
export MSSQL_PORT="$MSSQL_BI_PORT"
export MSSQL_DATABASE="$MSSQL_BI_DATABASE"
export MSSQL_USER="$MSSQL_BI_USER"
export MSSQL_PASSWORD="$MSSQL_BI_PASSWORD"
export MSSQL_ENCRYPT="$MSSQL_BI_ENCRYPT"
export PATH="$(dirname "$NPX_BIN"):$PATH"
exec "$NPX_BIN" -y "$TOOLBOX_MCP_PACKAGE" \
  --config "$MSSQL_TOOLBOX_CONFIG" --stdio
LAUNCHER
    chmod 700 "$launcher"
  fi

  if ! is_true "$SKIP_MSSQL_QISA"; then
    launcher="${BIN_DIR}/claude-mcp-mssql-qisa"
    write_launcher_header "$launcher"
    cat >> "$launcher" <<'LAUNCHER'
export MSSQL_HOST="$MSSQL_QISA_HOST"
export MSSQL_PORT="$MSSQL_QISA_PORT"
export MSSQL_DATABASE="$MSSQL_QISA_DATABASE"
export MSSQL_USER="$MSSQL_QISA_USER"
export MSSQL_PASSWORD="$MSSQL_QISA_PASSWORD"
export MSSQL_ENCRYPT="$MSSQL_QISA_ENCRYPT"
export PATH="$(dirname "$NPX_BIN"):$PATH"
exec "$NPX_BIN" -y "$TOOLBOX_MCP_PACKAGE" \
  --config "$MSSQL_TOOLBOX_CONFIG" --stdio
LAUNCHER
    chmod 700 "$launcher"
  fi

  if ! is_true "$SKIP_POWERBI"; then
    launcher="${BIN_DIR}/claude-mcp-powerbi-modeling"
    write_launcher_header "$launcher"
    cat >> "$launcher" <<'LAUNCHER'
if [[ "$POWERBI_USE_WINDOWS_NPX" == "1" ]] && command -v powershell.exe >/dev/null 2>&1; then
  cd /mnt/c
  powershell_command=$(printf '%s' \
    '$ErrorActionPreference="Stop"; Set-Location C:\; $npx=(Get-Command npx.cmd -ErrorAction Stop).Source; & $npx -y ' \
    "'$POWERBI_MCP_PACKAGE'" \
    ' --start --readwrite; exit $LASTEXITCODE')
  exec powershell.exe -NoProfile -NonInteractive -Command "$powershell_command"
fi

export PATH="$(dirname "$NPX_BIN"):$PATH"
exec "$NPX_BIN" -y "$POWERBI_MCP_PACKAGE" --start --readwrite
LAUNCHER
    chmod 700 "$launcher"
  fi
}

prefetch_packages() {
  is_true "$PREFETCH_MCP_PACKAGES" || return 0
  note "Pre-fetching MCP packages"

  if ! is_true "$SKIP_POSTGRES_REP" || ! is_true "$SKIP_POSTGRES_F1"; then
    "$UVX_BIN" --from "$POSTGRES_MCP_PACKAGE" --with 'mcp[cli]<2' \
      postgres-mcp --help >/dev/null || warn "postgres-mcp pre-fetch failed; Claude will retry when connecting."
  fi

  if ! is_true "$SKIP_MSSQL_BI" || ! is_true "$SKIP_MSSQL_QISA"; then
    "$NPX_BIN" -y "$TOOLBOX_MCP_PACKAGE" help >/dev/null ||
      warn "MCP Toolbox pre-fetch failed; Claude will retry when connecting."
  fi

  if ! is_true "$SKIP_POWERBI" && [[ "$POWERBI_USE_WINDOWS_NPX" != "1" ]]; then
    "$NPX_BIN" -y "$POWERBI_MCP_PACKAGE" --help >/dev/null ||
      warn "Power BI MCP pre-fetch failed; Claude will retry when connecting."
  fi
}

register_server() {
  local server_name="$1"
  local launcher_path="$2"

  "$CLAUDE_BIN" mcp remove --scope user "$server_name" >/dev/null 2>&1 || true
  "$CLAUDE_BIN" mcp add --scope user --transport stdio "$server_name" -- "$launcher_path"
}

register_servers() {
  note "Registering MCP servers in Claude Code user scope"
  if ! is_true "$SKIP_POWERBI"; then
    register_server powerbi-modeling "${BIN_DIR}/claude-mcp-powerbi-modeling"
  fi
  if ! is_true "$SKIP_POSTGRES_REP"; then
    register_server postgres-rep "${BIN_DIR}/claude-mcp-postgres-rep"
  fi
  if ! is_true "$SKIP_POSTGRES_F1"; then
    register_server postgres-f1 "${BIN_DIR}/claude-mcp-postgres-f1"
  fi
  if ! is_true "$SKIP_MSSQL_BI"; then
    register_server mssql-bi "${BIN_DIR}/claude-mcp-mssql-bi"
  fi
  if ! is_true "$SKIP_MSSQL_QISA"; then
    register_server mssql-qisa "${BIN_DIR}/claude-mcp-mssql-qisa"
  fi
}

configure_wsl_powerbi_bridge
backup_existing_claude_config
write_secret_file
write_runtime_file
write_mssql_toolbox_config
write_launchers
prefetch_packages
register_servers

if is_true "$VERIFY_CONNECTIONS"; then
  note "Checking MCP server status (an unreachable database may show as failed)"
  MCP_TIMEOUT="${MCP_TIMEOUT:-20000}" "$CLAUDE_BIN" mcp list ||
    warn "One or more health checks failed. Run 'claude mcp list' after fixing connectivity."
fi

if ! "$CLAUDE_BIN" auth status >/dev/null 2>&1; then
  warn "Claude Code is installed but not authenticated. Run 'claude' once and complete sign-in."
fi

cat <<EOF

Installation complete.

Claude Code:  $CLAUDE_BIN
MCP config:   user scope (~/.claude.json)
Secrets:      $SECRETS_FILE (mode 0600)
Launchers:    $BIN_DIR/claude-mcp-*

Next:
  1. Run: claude
  2. Inside Claude Code, run: /mcp
  3. Confirm each server is connected.

Power BI Desktop must be installed and running before its local model can be
discovered. Use read-only database accounts even though postgres-mcp is also
started in restricted mode.
EOF
