# Codex & Claude Code MCP Bootstrap

Bootstrap the same five MCP servers for either Codex CLI or Claude Code from a
fresh macOS, Linux, or WSL installation.

The installers provision their own runtime dependencies, register MCP servers
at user scope, keep database credentials out of the main client configuration,
and back up existing configuration before replacing servers with the same
names.

## Included installers

| Installer | Target | Main configuration |
| --- | --- | --- |
| `install-codex-mcps.sh` | Codex CLI | `~/.codex/config.toml` |
| `install-claude-code-mcps.sh` | Claude Code | `~/.claude.json` |

Both installers configure:

| MCP server | Implementation | Access behavior |
| --- | --- | --- |
| `powerbi-modeling` | `@microsoft/powerbi-modeling-mcp` | Read/write modeling |
| `postgres-rep` | `postgres-mcp` | Restricted mode |
| `postgres-f1` | `postgres-mcp` | Restricted mode |
| `mssql-bi` | `@toolbox-sdk/server` | Database-login permissions |
| `mssql-qisa` | `@toolbox-sdk/server` | Database-login permissions |

## Requirements

- macOS, Linux, or WSL. Run the scripts inside WSL rather than Git Bash on
  Windows.
- Network access for package downloads.
- Database addresses and credentials.
- Power BI Desktop on Windows when using local Desktop model discovery.

The installers can bootstrap the following when they are missing:

- Codex CLI or Claude Code
- Node.js through `nvm`
- `uv` and `uvx`
- Windows Node.js through WinGet when a WSL Power BI bridge is needed

## Create the environment file

Create a trusted file outside this repository, for example
`~/.mcp-bootstrap.env`:

```bash
# PostgreSQL — use read-only database roles
POSTGRES_REP_DATABASE_URI='postgresql://readonly_user:password@rep-host:5432/database'
POSTGRES_F1_DATABASE_URI='postgresql://readonly_user:password@f1-host:5432/database'

# SQL Server BI
MSSQL_BI_HOST='bi-server.example.com'
MSSQL_BI_PORT='1433'
MSSQL_BI_DATABASE='bi_database'
MSSQL_BI_USER='readonly_user'
MSSQL_BI_PASSWORD='password'
MSSQL_BI_ENCRYPT='disable'

# SQL Server QISA
MSSQL_QISA_HOST='qisa-server.example.com'
MSSQL_QISA_PORT='1433'
MSSQL_QISA_DATABASE='qisa_database'
MSSQL_QISA_USER='readonly_user'
MSSQL_QISA_PASSWORD='password'
MSSQL_QISA_ENCRYPT='disable'
```

Protect it before running either installer:

```bash
chmod 600 ~/.mcp-bootstrap.env
```

Do not commit this file. Values are sourced as Bash, so only use an environment
file you trust. Percent-encode special characters inside PostgreSQL URI
usernames and passwords.

## Install for Codex

```bash
./install-codex-mcps.sh \
  --env-file ~/.mcp-bootstrap.env \
  --non-interactive
```

Then authenticate and inspect the servers:

```bash
codex login
codex mcp list
codex
```

Inside Codex, enter `/mcp` to inspect live server status.

The Codex installer defaults to `CODEX_MCP_APPROVAL_MODE=approve` to match the
source configuration. To require prompts instead:

```bash
CODEX_MCP_APPROVAL_MODE=prompt \
  ./install-codex-mcps.sh --env-file ~/.mcp-bootstrap.env --non-interactive
```

## Install for Claude Code

```bash
./install-claude-code-mcps.sh \
  --env-file ~/.mcp-bootstrap.env \
  --non-interactive
```

Then authenticate and inspect the servers:

```bash
claude
claude mcp list
```

Inside Claude Code, enter `/mcp` to inspect live server status.

## Interactive installation

Omit `--env-file` and `--non-interactive` to enter missing values through
prompts. Password and connection-URI prompts are hidden:

```bash
./install-codex-mcps.sh
# or
./install-claude-code-mcps.sh
```

Run either installer with `--help` for skip flags and the complete input list.

## Secret storage

The supplied environment file is imported into an installer-owned credential
file:

| Client | Generated secret file | Launcher scripts |
| --- | --- | --- |
| Codex | `~/.config/codex-mcps/secrets.env` | `~/.local/bin/codex-mcp-*` |
| Claude Code | `~/.config/claude-mcps/secrets.env` | `~/.local/bin/claude-mcp-*` |

Secret files use mode `0600`; launcher scripts use mode `0700`. Database
passwords are not written into `~/.codex/config.toml` or `~/.claude.json`.

## Security notes

- Use database accounts whose permissions are read-only at the database layer.
- PostgreSQL restricted mode is defense-in-depth, not a replacement for a
  read-only PostgreSQL role.
- The SQL Server `execute_sql` tool can submit arbitrary SQL permitted by its
  login. Restrict that login to the minimum required permissions.
- `MSSQL_*_ENCRYPT=disable` matches the source setup but disables TLS. Select a
  supported secure mode whenever the SQL Server configuration permits it.
- Power BI modeling is configured with `--readwrite`; review proposed modeling
  operations and keep backups or source control for PBIP projects.

## Idempotency and backups

Both installers can be rerun. They remove and recreate only the five named MCP
registrations and preserve unrelated client settings. Before modification they
save timestamped backups under:

```text
~/.config/codex-mcps/backups/
~/.config/claude-mcps/backups/
```

