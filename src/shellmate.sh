#!/bin/bash
#
# ShellMate - AI-powered natural language to shell command converter
# Bash implementation using only standard tools (curl, jq if available)
#

set -euo pipefail

# Configuration
SHELLMATE_API_ENDPOINT="${SHELLMATE_API_ENDPOINT:-}"
SHELLMATE_API_KEY="${SHELLMATE_API_KEY:-}"
SHELLMATE_CONFIG_DIR="${HOME}/.config/shellmate"
SHELLMATE_CONFIG_FILE="${SHELLMATE_CONFIG_DIR}/config"

# Load config if it exists
if [[ -f "$SHELLMATE_CONFIG_FILE" ]]; then
    source "$SHELLMATE_CONFIG_FILE"
fi

# Helper functions
error() {
    echo "Error: $1" >&2
}

info() {
    echo "$1"
}

warn() {
    echo "$1"
}

# Check if jq is available for JSON parsing
has_jq() {
    command -v jq >/dev/null 2>&1
}

# Parse JSON without jq (basic implementation)
parse_json_command() {
    local json="$1"
    # Extract command field using sed/grep
    echo "$json" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# Query AI service
query_ai() {
    local query="$1"
    
    if [[ -z "$SHELLMATE_API_ENDPOINT" ]]; then
        error "SHELLMATE_API_ENDPOINT not set. Run installation or set environment variable."
        return 1
    fi
    
    # Prepare JSON payload
    local json_payload
    json_payload=$(cat <<EOF
{
    "query": "$query",
    "context": {
        "os": "$(uname -s)",
        "cwd": "$(pwd)"
    }
}
EOF
)
    
    # Make API request
    local response
    local headers=(-H "Content-Type: application/json")
    
    if [[ -n "$SHELLMATE_API_KEY" ]]; then
        headers+=(-H "X-API-Key: $SHELLMATE_API_KEY")
    fi
    
    response=$(curl -s -X POST "${headers[@]}" -d "$json_payload" "$SHELLMATE_API_ENDPOINT" 2>/dev/null)
    
    if [[ $? -ne 0 ]] || [[ -z "$response" ]]; then
        error "Failed to connect to ShellMate API"
        return 1
    fi
    
    # Check for error in response
    if echo "$response" | grep -q '"error"'; then
        error "API returned error: $response"
        return 1
    fi
    
    # Extract command from JSON response
    local command
    if has_jq; then
        command=$(echo "$response" | jq -r '.command // empty')
    else
        command=$(parse_json_command "$response")
    fi
    
    if [[ -z "$command" ]]; then
        error "No command returned from API"
        return 1
    fi
    
    echo "$command"
}

# Execute command with user interaction
execute_command() {
    local command="$1"
    local seamless="$2"
    
    if [[ -z "$command" ]]; then
        error "No command to execute"
        return 1
    fi
    
    if [[ "$seamless" == "true" ]]; then
        # Seamless mode - just output the command
        echo "$command"
        return 0
    fi
    
    # Interactive mode - pre-populate command for editing
    local shell_name
    shell_name=$(basename "${SHELL:-/bin/bash}")
    local prompt_char="$ "
    [[ "$shell_name" == "zsh" ]] && prompt_char="% "
    
    # Check if we should show prompt
    local show_prompt="${SHELLMATE_SHOW_PROMPT:-true}"
    if [[ "$show_prompt" == "true" ]]; then
        echo "Press Enter to execute, or Ctrl+C to cancel:"
    fi
    
    # Use read with pre-filled command
    local user_command
    echo -n "$prompt_char"
    read -e -i "$command" user_command
    
    if [[ -n "$user_command" ]]; then
        eval "$user_command"
        return $?
    else
        warn "No command to execute"
        return 1
    fi
}

# Main function
main() {
    local query=""
    local seamless="false"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --seamless|-s)
                seamless="true"
                shift
                ;;
            --help|-h)
                cat <<EOF
ShellMate - AI-powered natural language to shell command converter

Usage: shellmate [OPTIONS] "natural language query"

Options:
  --seamless, -s        Output command to stdout for shell function integration
  --help, -h            Show this help message

Examples:
  shellmate "list all python files older than 5 days"
  shellmate "find large files in home directory"
  shellmate "show disk usage"

Environment Variables:
  SHELLMATE_API_ENDPOINT  - AWS API Gateway endpoint URL
  SHELLMATE_API_KEY       - API key for authentication (optional)
EOF
                exit 0
                ;;
            -*)
                error "Unknown option: $1"
                exit 1
                ;;
            *)
                query="$1"
                shift
                ;;
        esac
    done
    
    if [[ -z "$query" ]]; then
        error "No query provided. Use --help for usage information."
        exit 1
    fi
    
    # Get command from AI
    local command
    command=$(query_ai "$query")
    
    if [[ $? -ne 0 ]] || [[ -z "$command" ]]; then
        if [[ "$seamless" != "true" ]]; then
            error "Failed to get command from AI service"
        fi
        exit 1
    fi
    
    # Execute or display command
    if [[ "$seamless" != "true" ]]; then
        local show_prompt="${SHELLMATE_SHOW_PROMPT:-true}"
        if [[ "$show_prompt" == "true" ]]; then
            info "Query: $query"
        fi
    fi
    
    execute_command "$command" "$seamless"
}

# Run main function
main "$@"
