#!/usr/bin/env bash
# Bootstrap Codex CLI and replicate this machine's five locally configured
# MCP servers on macOS, Linux, or WSL.
#
# This installer accepts the exact same --env-file used by
# install-claude-code-mcps.sh. Credentials are stored outside config.toml in a
# chmod-600 file and loaded by chmod-700 launcher scripts.

set -Eeuo pipefail
IFS=$'\n\t'
set +x

readonly SCRIPT_NAME="${0##*/}"
readonly DEFAULT_CONFIG_ROOT="${HOME}/.config/codex-mcps"
readonly DEFAULT_BIN_DIR="${HOME}/.local/bin"

NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
SKIP_POWERBI="${SKIP_POWERBI:-0}"
SKIP_POSTGRES_REP="${SKIP_POSTGRES_REP:-0}"
SKIP_POSTGRES_F1="${SKIP_POSTGRES_F1:-0}"
SKIP_MSSQL_BI="${SKIP_MSSQL_BI:-0}"
SKIP_MSSQL_QISA="${SKIP_MSSQL_QISA:-0}"
VERIFY_CONFIGURATION="${VERIFY_CONFIGURATION:-1}"
POWERBI_PREFER_WINDOWS="${POWERBI_PREFER_WINDOWS:-1}"

CONFIG_ROOT="${CODEX_MCP_CONFIG_ROOT:-${DEFAULT_CONFIG_ROOT}}"
BIN_DIR="${CODEX_MCP_BIN_DIR:-${DEFAULT_BIN_DIR}}"
SECRETS_FILE="${CONFIG_ROOT}/secrets.env"
RUNTIME_FILE="${CONFIG_ROOT}/runtime.env"
MSSQL_TOOLBOX_CONFIG="${CONFIG_ROOT}/mssql.tools.yaml"
BACKUP_DIR="${CONFIG_ROOT}/backups"
CODEX_CONFIG_DIR="${CODEX_HOME:-${HOME}/.codex}"
CODEX_CONFIG_FILE="${CODEX_CONFIG_DIR}/config.toml"

NODE_MAJOR="${NODE_MAJOR:-24}"
NVM_INSTALL_VERSION="${NVM_INSTALL_VERSION:-v0.40.3}"
CODEX_NPM_PACKAGE="${CODEX_NPM_PACKAGE:-@openai/codex@latest}"
POSTGRES_MCP_PACKAGE="${POSTGRES_MCP_PACKAGE:-postgres-mcp}"
TOOLBOX_MCP_PACKAGE="${TOOLBOX_MCP_PACKAGE:-@toolbox-sdk/server@latest}"
POWERBI_MCP_PACKAGE="${POWERBI_MCP_PACKAGE:-@microsoft/powerbi-modeling-mcp@latest}"
CODEX_MCP_APPROVAL_MODE="${CODEX_MCP_APPROVAL_MODE:-approve}"

BOOTSTRAP_TMP_DIR=""
CODEX_BIN=""
NODE_BIN=""
NPM_BIN=""
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
  bash install-codex-mcps.sh [options]

Options:
  --env-file PATH       Source the same trusted env file used by the Claude installer.
  --non-interactive     Fail instead of prompting for missing credentials.
  --skip-powerbi        Do not configure powerbi-modeling.
  --skip-postgres-rep   Do not configure postgres-rep.
  --skip-postgres-f1    Do not configure postgres-f1.
  --skip-mssql-bi       Do not configure mssql-bi.
  --skip-mssql-qisa     Do not configure mssql-qisa.
  --no-verify           Do not run the final Codex MCP configuration check.
  -h, --help            Show this help.

Required values:
  POSTGRES_REP_DATABASE_URI
  POSTGRES_F1_DATABASE_URI

  MSSQL_BI_HOST       MSSQL_BI_PORT       MSSQL_BI_DATABASE
  MSSQL_BI_USER       MSSQL_BI_PASSWORD   MSSQL_BI_ENCRYPT

  MSSQL_QISA_HOST     MSSQL_QISA_PORT     MSSQL_QISA_DATABASE
  MSSQL_QISA_USER     MSSQL_QISA_PASSWORD MSSQL_QISA_ENCRYPT

Defaults:
  MSSQL_*_PORT=1433
  MSSQL_*_ENCRYPT=disable
  CODEX_MCP_APPROVAL_MODE=approve   (matches the source Codex configuration)

Example:
  ./install-codex-mcps.sh --env-file ~/.mcp-bootstrap.env --non-interactive

Security:
  Use read-only database roles/logins. PostgreSQL restricted mode and Codex
  approval settings are defense-in-depth, not database permission boundaries.
USAGE
}

load_env_file() {
  local input_file="$1"
  [[ -f "$input_file" ]] || die "Environment file not found: $input_file"
  note "Loading trusted environment file: $input_file"
  set -a
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
    --no-verify) VERIFY_CONFIGURATION=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

case "$(uname -s)" in
  Linux|Darwin) ;;
  MINGW*|MSYS*|CYGWIN*)
    die "Run this Bash installer inside WSL, not Git Bash."
    ;;
  *) die "Unsupported operating system: $(uname -s)" ;;
esac

case "$CODEX_MCP_APPROVAL_MODE" in
  auto|prompt|writes|approve) ;;
  *) die "CODEX_MCP_APPROVAL_MODE must be auto, prompt, writes, or approve" ;;
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
    die "Root privileges are required for: $*"
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
      "${TMPDIR:-/tmp}"/codex-mcp-bootstrap.*|/tmp/codex-mcp-bootstrap.*)
        rm -rf -- "$BOOTSTRAP_TMP_DIR"
        ;;
    esac
  fi
}
trap cleanup EXIT

install_curl_if_missing
BOOTSTRAP_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-mcp-bootstrap.XXXXXX")"

download() {
  local url="$1"
  local destination="$2"
  curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$destination"
}

export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"

install_nvm_node() {
  local bootstrap_nvm_dir="${NVM_DIR:-${HOME}/.nvm}"
  if [[ ! -s "${bootstrap_nvm_dir}/nvm.sh" ]]; then
    local installer="${BOOTSTRAP_TMP_DIR}/install-nvm.sh"
    download "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_INSTALL_VERSION}/install.sh" "$installer"
    PROFILE=/dev/null NVM_DIR="$bootstrap_nvm_dir" bash "$installer"
  fi

  set +u
  # shellcheck disable=SC1090
  source "${bootstrap_nvm_dir}/nvm.sh"
  nvm install "$NODE_MAJOR"
  nvm use "$NODE_MAJOR"
  set -u
}

ensure_node() {
  local major="0"
  local platform=""
  if have node; then
    major="$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || printf '0')"
    platform="$(node -p 'process.platform' 2>/dev/null || true)"
  fi

  if ! [[ "$major" =~ ^[0-9]+$ ]] ||
     ((major < 22)) ||
     ! have npm || ! have npx ||
     { [[ "$(uname -s)" == "Linux" ]] && [[ "$platform" != "linux" ]]; }; then
    note "Installing Linux/macOS Node.js ${NODE_MAJOR} with nvm"
    install_nvm_node
  fi

  NODE_BIN="$(command -v node || true)"
  NPM_BIN="$(command -v npm || true)"
  NPX_BIN="$(command -v npx || true)"
  [[ -n "$NODE_BIN" && -n "$NPM_BIN" && -n "$NPX_BIN" ]] || die "Node.js/npm/npx setup failed"
  note "Using Node.js $($NODE_BIN --version) at $NODE_BIN"
}

install_codex_if_needed() {
  if have codex; then
    CODEX_BIN="$(command -v codex)"
    note "Codex already installed: $($CODEX_BIN --version)"
    return 0
  fi

  note "Installing Codex CLI from ${CODEX_NPM_PACKAGE}"
  if ! "$NPM_BIN" install -g "$CODEX_NPM_PACKAGE"; then
    warn "The current npm global directory is not writable; switching to user-owned nvm Node.js."
    install_nvm_node
    NODE_BIN="$(command -v node)"
    NPM_BIN="$(command -v npm)"
    NPX_BIN="$(command -v npx)"
    "$NPM_BIN" install -g "$CODEX_NPM_PACKAGE"
  fi
  CODEX_BIN="$(command -v codex || true)"
  [[ -n "$CODEX_BIN" ]] || die "Codex installed but 'codex' is not on PATH"
  "$CODEX_BIN" --version
}

install_uv_if_needed() {
  if have uvx; then
    UVX_BIN="$(command -v uvx)"
    note "Using uvx at $UVX_BIN"
    return 0
  fi

  note "Installing uv/uvx from Astral"
  local installer="${BOOTSTRAP_TMP_DIR}/install-uv.sh"
  download "https://astral.sh/uv/install.sh" "$installer"
  sh "$installer"
  export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
  UVX_BIN="$(command -v uvx || true)"
  [[ -n "$UVX_BIN" ]] || die "uv installed but 'uvx' is not on PATH"
}

ensure_node
install_codex_if_needed
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
  [[ -n "$current_value" ]] && return 0

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

  if ! is_true "$SKIP_MSSQL_BI" && [[ "$MSSQL_BI_ENCRYPT" == "disable" ]]; then
    warn "mssql-bi TLS is disabled to match the source configuration. Use a secure supported mode where possible."
  fi
  if ! is_true "$SKIP_MSSQL_QISA" && [[ "$MSSQL_QISA_ENCRYPT" == "disable" ]]; then
    warn "mssql-qisa TLS is disabled to match the source configuration. Use a secure supported mode where possible."
  fi
}

collect_credentials
validate_credentials

mkdir -p "$CONFIG_ROOT" "$BIN_DIR" "$BACKUP_DIR" "$CODEX_CONFIG_DIR"
# Preserve permissions on an existing ~/.codex and ~/.local/bin because both
# can contain unrelated user state. Only installer-owned paths are tightened.
chmod 700 "$CONFIG_ROOT" "$BACKUP_DIR"
umask 077

backup_existing_codex_config() {
  if [[ -f "$CODEX_CONFIG_FILE" ]]; then
    local timestamp
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p "$CODEX_CONFIG_FILE" "${BACKUP_DIR}/config.toml.${timestamp}.bak"
    note "Backed up Codex configuration to ${BACKUP_DIR}/config.toml.${timestamp}.bak"
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
# Connection fields are substituted from each launcher's environment.
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
  have powershell.exe || { warn "powershell.exe unavailable; Power BI MCP will use the Linux package."; return 0; }

  if powershell.exe -NoProfile -NonInteractive -Command \
      'if (Get-Command npx.cmd -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }' \
      >/dev/null 2>&1; then
    POWERBI_USE_WINDOWS_NPX=1
    note "Power BI MCP will use Windows npx for Desktop interoperability"
    return 0
  fi

  if have winget.exe; then
    note "Installing Windows Node.js LTS for the Power BI Desktop bridge"
    if powershell.exe -NoProfile -NonInteractive -Command \
        '& winget.exe install --id OpenJS.NodeJS.LTS --exact --silent --accept-package-agreements --accept-source-agreements' \
        >/dev/null &&
       powershell.exe -NoProfile -NonInteractive -Command \
        'if (Get-Command npx.cmd -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }' \
        >/dev/null 2>&1; then
      POWERBI_USE_WINDOWS_NPX=1
      return 0
    fi
  fi

  warn "Windows npx was not provisioned. Power BI Desktop auto-discovery may not work from WSL."
}

write_launcher_header() {
  local destination="$1"
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nset +x\n'
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
    launcher="${BIN_DIR}/codex-mcp-postgres-rep"
    write_launcher_header "$launcher"
    cat >> "$launcher" <<'LAUNCHER'
export DATABASE_URI="$POSTGRES_REP_DATABASE_URI"
exec "$UVX_BIN" --from "$POSTGRES_MCP_PACKAGE" --with 'mcp[cli]<2' \
  postgres-mcp --access-mode=restricted
LAUNCHER
    chmod 700 "$launcher"
  fi

  if ! is_true "$SKIP_POSTGRES_F1"; then
    launcher="${BIN_DIR}/codex-mcp-postgres-f1"
    write_launcher_header "$launcher"
    cat >> "$launcher" <<'LAUNCHER'
export DATABASE_URI="$POSTGRES_F1_DATABASE_URI"
exec "$UVX_BIN" --from "$POSTGRES_MCP_PACKAGE" --with 'mcp[cli]<2' \
  postgres-mcp --access-mode=restricted
LAUNCHER
    chmod 700 "$launcher"
  fi

  if ! is_true "$SKIP_MSSQL_BI"; then
    launcher="${BIN_DIR}/codex-mcp-mssql-bi"
    write_launcher_header "$launcher"
    cat >> "$launcher" <<'LAUNCHER'
export MSSQL_HOST="$MSSQL_BI_HOST" MSSQL_PORT="$MSSQL_BI_PORT"
export MSSQL_DATABASE="$MSSQL_BI_DATABASE" MSSQL_USER="$MSSQL_BI_USER"
export MSSQL_PASSWORD="$MSSQL_BI_PASSWORD" MSSQL_ENCRYPT="$MSSQL_BI_ENCRYPT"
export PATH="$(dirname "$NPX_BIN"):$PATH"
exec "$NPX_BIN" -y "$TOOLBOX_MCP_PACKAGE" --config "$MSSQL_TOOLBOX_CONFIG" --stdio
LAUNCHER
    chmod 700 "$launcher"
  fi

  if ! is_true "$SKIP_MSSQL_QISA"; then
    launcher="${BIN_DIR}/codex-mcp-mssql-qisa"
    write_launcher_header "$launcher"
    cat >> "$launcher" <<'LAUNCHER'
export MSSQL_HOST="$MSSQL_QISA_HOST" MSSQL_PORT="$MSSQL_QISA_PORT"
export MSSQL_DATABASE="$MSSQL_QISA_DATABASE" MSSQL_USER="$MSSQL_QISA_USER"
export MSSQL_PASSWORD="$MSSQL_QISA_PASSWORD" MSSQL_ENCRYPT="$MSSQL_QISA_ENCRYPT"
export PATH="$(dirname "$NPX_BIN"):$PATH"
exec "$NPX_BIN" -y "$TOOLBOX_MCP_PACKAGE" --config "$MSSQL_TOOLBOX_CONFIG" --stdio
LAUNCHER
    chmod 700 "$launcher"
  fi

  if ! is_true "$SKIP_POWERBI"; then
    launcher="${BIN_DIR}/codex-mcp-powerbi-modeling"
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

register_server() {
  local server_name="$1"
  local launcher_path="$2"
  "$CODEX_BIN" mcp remove "$server_name" >/dev/null 2>&1 || true
  "$CODEX_BIN" mcp add "$server_name" -- "$launcher_path"
}

add_approval_mode() {
  local server_name="$1"
  local temporary_file="${BOOTSTRAP_TMP_DIR}/config.${server_name}.toml"
  local header="[mcp_servers.${server_name}]"

  [[ -f "$CODEX_CONFIG_FILE" ]] || die "Codex config was not created at $CODEX_CONFIG_FILE"
  awk -v header="$header" -v mode="$CODEX_MCP_APPROVAL_MODE" '
    $0 == header {
      print
      print "default_tools_approval_mode = \"" mode "\""
      next
    }
    { print }
  ' "$CODEX_CONFIG_FILE" > "$temporary_file"
  mv "$temporary_file" "$CODEX_CONFIG_FILE"
  chmod 600 "$CODEX_CONFIG_FILE"
}

register_servers() {
  note "Registering MCP servers in ${CODEX_CONFIG_FILE}"
  if ! is_true "$SKIP_POWERBI"; then
    register_server powerbi-modeling "${BIN_DIR}/codex-mcp-powerbi-modeling"
    add_approval_mode powerbi-modeling
  fi
  if ! is_true "$SKIP_POSTGRES_REP"; then
    register_server postgres-rep "${BIN_DIR}/codex-mcp-postgres-rep"
    add_approval_mode postgres-rep
  fi
  if ! is_true "$SKIP_POSTGRES_F1"; then
    register_server postgres-f1 "${BIN_DIR}/codex-mcp-postgres-f1"
    add_approval_mode postgres-f1
  fi
  if ! is_true "$SKIP_MSSQL_BI"; then
    register_server mssql-bi "${BIN_DIR}/codex-mcp-mssql-bi"
    add_approval_mode mssql-bi
  fi
  if ! is_true "$SKIP_MSSQL_QISA"; then
    register_server mssql-qisa "${BIN_DIR}/codex-mcp-mssql-qisa"
    add_approval_mode mssql-qisa
  fi
}

configure_wsl_powerbi_bridge
backup_existing_codex_config
write_secret_file
write_runtime_file
write_mssql_toolbox_config
write_launchers
register_servers

if is_true "$VERIFY_CONFIGURATION"; then
  note "Configured Codex MCP servers"
  "$CODEX_BIN" mcp list
fi

if ! "$CODEX_BIN" login status >/dev/null 2>&1; then
  warn "Codex is installed but not authenticated. Run 'codex login' once."
fi

cat <<EOF

Installation complete.

Codex CLI:    $CODEX_BIN
Codex config: $CODEX_CONFIG_FILE
Secrets:      $SECRETS_FILE (mode 0600)
Launchers:    $BIN_DIR/codex-mcp-*

Next:
  1. Run: codex login       (if not already authenticated)
  2. Run: codex
  3. Inside Codex, run: /mcp

The same input env file works for both the Claude and Codex installers.
EOF
