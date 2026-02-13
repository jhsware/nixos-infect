#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"
NIX_INFRA_MACHINE_DIR="$HOME/DEV/TEST_INFRA_MACHINE"
DEV_MODE=false

DEFAULT_ALLOWED_PATHS=(
  "./nixos-infect"
  "./mutations"
  "./README.md"
  "./CHANGELOG.md"
  "./.gitignore"
)

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --development|--dev)
      DEV_MODE=true
      shift
      ;;
    --project-dir=*)
      PROJECT_DIR="${1#*=}"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Convert to absolute path
if [[ "$PROJECT_DIR" != /* ]]; then
  PROJECT_DIR="$(cd "$(pwd)" && realpath -m "$PROJECT_DIR")"
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "Error: Project directory does not exist: $PROJECT_DIR" >&2
  exit 1
fi

# Detect OS
case "$(uname -s)" in
  Darwin)
    PATH_TO_CLAUDE="$HOME/Library/Application Support/Claude"
    CLAUDE_BIN="/Applications/Claude.app/Contents/MacOS/Claude"
    ;;
  Linux)
    PATH_TO_CLAUDE="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
    CLAUDE_BIN="claude"
    ;;
  *)
    echo "Unsupported OS: $(uname -s)" >&2
    exit 1
    ;;
esac

if [ ! -d "$PATH_TO_CLAUDE" ]; then
  echo "Claude Application Support directory not found at: $PATH_TO_CLAUDE" >&2
  exit 1
fi

# Backup existing config
if [ -f "$PATH_TO_CLAUDE/claude_desktop_config.json" ]; then
  cp -f "$PATH_TO_CLAUDE/claude_desktop_config.json" "$PATH_TO_CLAUDE/claude_desktop_config.json.dart-dev-mcp.bak"
fi

# Find SSH agent socket
find_ssh_agent_socket() {
  if [ -n "$SSH_AUTH_SOCK" ] && [ -e "$SSH_AUTH_SOCK" ]; then
    echo "$SSH_AUTH_SOCK"
    return
  fi
  if [ "$(uname -s)" = "Darwin" ]; then
    local launchd_sock
    launchd_sock=$(launchctl getenv SSH_AUTH_SOCK 2>/dev/null || true)
    if [ -n "$launchd_sock" ] && [ -e "$launchd_sock" ]; then
      echo "$launchd_sock"
      return
    fi
  fi
  if [ "$(uname -s)" = "Linux" ]; then
    local uid="${UID:-$(id -u)}"
    for sock in "/run/user/$uid/ssh-agent.socket" "/run/user/$uid/keyring/ssh"; do
      if [ -e "$sock" ]; then
        echo "$sock"
        return
      fi
    done
  fi
  echo ""
}

SSH_AGENT_SOCKET=$(find_ssh_agent_socket)

# Output server command configuration based on mode
# Usage: output_server_cmd <binary_name> <dart_source> <env_json> [args...]
output_server_cmd() {
  local binary_name="$1"
  local dart_source="$2"
  local env_json="$3"
  shift 3
  local extra_args=("$@")

  # Look up package directory for this binary
  local package_dir=""
  case "$dart_source" in
    file_edit_mcp.dart) package_dir="filesystem" ;;
    fetch_mcp.dart) package_dir="fetch" ;;
    git_mcp.dart) package_dir="git" ;;
    planner_mcp.dart) package_dir="planner" ;;
    nix_infra_machine_mcp.dart) package_dir="nix_infra_machine" ;;
  esac

  local binary_src_path=""
  if [ -f "$HOME/dev/nix-infra/bin/${dart_source}" ]; then
    binary_src_path="$HOME/dev/nix-infra/bin/${dart_source}"
  elif [ -n "$package_dir" ] && [ -f "$HOME/DEV/agentic-coding/jhsware_code/packages/$package_dir/bin/${dart_source}" ]; then
    binary_src_path="$HOME/DEV/agentic-coding/jhsware_code/packages/$package_dir/bin/${dart_source}"
  elif [ -n "$package_dir" ] && [ -f "$SCRIPT_DIR/packages/$package_dir/bin/${dart_source}" ]; then
    binary_src_path="$SCRIPT_DIR/packages/$package_dir/bin/${dart_source}"
  elif [ -f "$SCRIPT_DIR/bin/${dart_source}" ]; then
    binary_src_path="$SCRIPT_DIR/bin/${dart_source}"
  fi

  if [ "$DEV_MODE" = true ]; then
    echo '      "command": "dart",'
    echo '      "args": ['
    echo '        "run",'
    echo "        \"$binary_src_path\""
    for arg in "${extra_args[@]}"; do
      echo "        ,\"$arg\""
    done
    echo '      ]'
  else
    echo "      \"command\": \"$binary_name\","
    echo '      "args": ['
    local first_arg=true
    for arg in "${extra_args[@]}"; do
      if [ "$first_arg" = true ]; then
        echo "        \"$arg\""
        first_arg=false
      else
        echo "        ,\"$arg\""
      fi
    done
    echo '      ]'
  fi

  if [ "$env_json" != "null" ] && [ -n "$env_json" ]; then
    echo "      ,$env_json"
  fi
}

# Build absolute paths for fs/git
get_abs_paths() {
  local base="$1"
  shift
  for p in "$@"; do
    local clean="${p#git:}"
    local prefix=""
    [[ "$p" == git:* ]] && prefix="git:"
    if [[ "$clean" == /* ]]; then
      echo "${prefix}${clean}"
    else
      echo "${prefix}$(cd "$base" 2>/dev/null && realpath -m "$clean" 2>/dev/null || echo "$base/$clean")"
    fi
  done
}

ABS_PATHS=($(get_abs_paths "$PROJECT_DIR" "${DEFAULT_ALLOWED_PATHS[@]}"))

# Separate regular and git-only paths
REGULAR_PATHS=()
GIT_PATHS=()
for p in "${ABS_PATHS[@]}"; do
  if [[ "$p" == git:* ]]; then
    GIT_PATHS+=("${p#git:}")
  else
    REGULAR_PATHS+=("$p")
    GIT_PATHS+=("$p")
  fi
done

# Build git env
GIT_ENV="null"
if [ -n "$SSH_AGENT_SOCKET" ]; then
  GIT_ENV="\"env\": { \"SSH_AUTH_SOCK\": \"$SSH_AGENT_SOCKET\" }"
fi

# Planner db path
PROJECT_NAME=$(basename "$PROJECT_DIR")
PLANNER_DB="$HOME/Library/Application Support/com.example.dartDevMcpPlannerViewer/projects/$PROJECT_NAME/db/planner.db"

# Generate config
{
  echo '{'
  echo '  "mcpServers": {'

  # fs
  echo '    "dart-dev-mcp-fs": {'
  output_server_cmd "file-edit-mcp" "file_edit_mcp.dart" "null" "--project-dir=$PROJECT_DIR" "${REGULAR_PATHS[@]}"
  echo '    },'

  # fetch
  echo '    "dart-dev-mcp-fetch": {'
  output_server_cmd "fetch-mcp" "fetch_mcp.dart" "null"
  echo '    },'

  # git
  echo '    "dart-dev-mcp-git": {'
  output_server_cmd "git-mcp" "git_mcp.dart" "$GIT_ENV" "--project-dir=$PROJECT_DIR" "${GIT_PATHS[@]}"
  echo '    },'

  # planner
  echo '    "dart-dev-mcp-planner": {'
  output_server_cmd "planner-mcp" "planner_mcp.dart" "null" "--project-dir=$PROJECT_DIR" "--db-path=$PLANNER_DB"
  echo '    },'

  # nix-infra-machine
  echo '    "nix-infra-machine-mcp": {'
  output_server_cmd "nix-infra-machine-mcp" "nix_infra_machine_mcp.dart" "null" "--project-dir=$NIX_INFRA_MACHINE_DIR" "--env=.env-prod"
  echo '    }'

  echo '  }'
  echo '}'
} > "$PATH_TO_CLAUDE/claude_desktop_config.json"

if [ "$DEV_MODE" = true ]; then
  echo "Configured servers (DEVELOPMENT MODE): fs, git, fetch, planner, nix-infra-machine"
else
  echo "Configured servers: fs, git, fetch, planner, nix-infra-machine"
fi
echo "Project directory: $PROJECT_DIR"
echo "Nix-infra-machine directory: $NIX_INFRA_MACHINE_DIR"
echo ""
cat "$PATH_TO_CLAUDE/claude_desktop_config.json"
echo ""

# Start Claude
echo "Starting Claude..."
"$CLAUDE_BIN" 2>/dev/null &
sleep 10

# Restore previous config
echo "Restoring previous claude_desktop_config.json..."
if [ -f "$PATH_TO_CLAUDE/claude_desktop_config.json.dart-dev-mcp.bak" ]; then
  cp -f "$PATH_TO_CLAUDE/claude_desktop_config.json.dart-dev-mcp.bak" "$PATH_TO_CLAUDE/claude_desktop_config.json"
else
  rm -f "$PATH_TO_CLAUDE/claude_desktop_config.json"
fi