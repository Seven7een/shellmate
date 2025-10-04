#!/bin/bash

# =============================================================================
# ShellMate Unified Management Script
# =============================================================================
# Single script to manage all ShellMate operations with configuration
# pulled dynamically from template.yaml (single source of truth)
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/python-build"
AWS_DIR="$SCRIPT_DIR/aws"
TEMPLATE_FILE="$AWS_DIR/template.yaml"
DEFAULT_STACK_NAME="shellmate-dev"
DEFAULT_REGION="us-east-1"

# Installation paths
INSTALL_DIR="/usr/local/bin"
BINARY_NAME="shellmate"
CONFIG_DIR="$HOME/.config/shellmate"
CONFIG_FILE="$CONFIG_DIR/config"

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() {
    echo -e "${BOLD}${BLUE}========================================${NC}"
    echo -e "${BOLD}${BLUE}$1${NC}"
    echo -e "${BOLD}${BLUE}========================================${NC}"
}


show_help() {
    cat << EOF
${BOLD}ShellMate Unified Management Script${NC}

${BOLD}Usage:${NC}
  $0 <command> [options]

${BOLD}Commands:${NC}

  ${BOLD}Installation:${NC}
    install              Install ShellMate (choose Python or Bash version)
    uninstall            Remove ShellMate from system

  ${BOLD}AWS Deployment:${NC}
    deploy [options]     Deploy AWS infrastructure
    redeploy [options]   Force redeploy with new configuration
    destroy              Delete all AWS resources
    status               Show deployment status and configuration


  ${BOLD}Testing & Usage:${NC}
    test [query]         Test the deployed system
    test-local           Test binary with current configuration
    logs                 Show recent Lambda logs
    api-key              Show current API key and endpoint

  ${BOLD}Utilities:${NC}
    info                 Show complete system information
    config               Show current configuration
    clean                Clean build artifacts and temp files

${BOLD}Deploy Options:${NC}
  --stage <stage>        Deployment stage (dev/prod)
  --region <region>      AWS region
  --stack <name>         CloudFormation stack name

${BOLD}Examples:${NC}
  $0 install                                # Install ShellMate (choose implementation)
  $0 deploy                                 # Deploy AWS infrastructure
  $0 test "list python files"              # Test the system
  $0 status                                 # Check current configuration

${BOLD}Configuration:${NC}
  All settings are centralized in: $TEMPLATE_FILE
  Binary config: $CONFIG_FILE

EOF
}

check_prerequisites() {
    local missing=()
    
    # Check Python
    if ! command -v python3 >/dev/null 2>&1; then
        missing+=("python3")
    fi
    
    # Check AWS CLI for deployment commands
    if [[ "$1" =~ ^(deploy|redeploy|destroy|status|logs|api-key)$ ]]; then
        if ! command -v aws >/dev/null 2>&1; then
            missing+=("aws-cli")
        fi
        if [[ "$1" =~ ^(deploy|redeploy|destroy)$ ]]; then
            if ! command -v sam >/dev/null 2>&1; then
                missing+=("sam-cli")
            fi
        fi
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing prerequisites: ${missing[*]}"
        exit 1
    fi
}


build_binary() {
    print_header "BUILDING SHELLMATE BINARY"
    
    cd "$SCRIPT_DIR"
    
    if [ ! -f "build.py" ]; then
        print_error "build.py not found in $SCRIPT_DIR"
        exit 1
    fi
    
    print_info "Building binary using build.py..."
    python3 build.py build
    
    if [ -f "$BUILD_DIR/$BINARY_NAME" ]; then
        local size=$(du -h "$BUILD_DIR/$BINARY_NAME" | cut -f1)
        print_success "Binary built successfully: $BUILD_DIR/$BINARY_NAME ($size)"
    else
        print_error "Binary build failed"
        exit 1
    fi
}

install_binary() {
    print_header "INSTALLING SHELLMATE SYSTEM-WIDE"
    
    # Check if binary exists
    if [ ! -f "$BUILD_DIR/$BINARY_NAME" ]; then
        print_error "Binary not found. Run '$0 build' first."
        exit 1
    fi
    
    # Install binary
    print_info "Installing binary to $INSTALL_DIR..."
    if [ ! -w "$INSTALL_DIR" ]; then
        sudo cp "$BUILD_DIR/$BINARY_NAME" "$INSTALL_DIR/$BINARY_NAME-bin"
        sudo chmod +x "$INSTALL_DIR/$BINARY_NAME-bin"
    else
        cp "$BUILD_DIR/$BINARY_NAME" "$INSTALL_DIR/$BINARY_NAME-bin"
        chmod +x "$INSTALL_DIR/$BINARY_NAME-bin"
    fi
    
    # Setup configuration
    setup_config
    setup_shell_integration
    
    print_success "ShellMate installed successfully!"
    print_info "Restart your shell or run: source $CONFIG_FILE"
    print_info "Test with: shellmate --help"
}

get_api_credentials() {
    local stack_name="${1:-$DEFAULT_STACK_NAME}"
    local region="${2:-$DEFAULT_REGION}"
    
    # Get API endpoint from CloudFormation
    local endpoint=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$region" --query "Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue" --output text 2>/dev/null)
    
    if [ -z "$endpoint" ] || [ "$endpoint" = "None" ]; then
        return 1
    fi
    
    # Get API key from API Gateway - try multiple approaches
    local api_key=""
    
    # Method 1: Use jq if available for precise parsing
    if command -v jq >/dev/null 2>&1; then
        local api_keys=$(aws apigateway get-api-keys --region "$region" --include-values --query "items[?contains(tags.\"aws:cloudformation:stack-name\", '$stack_name')]" --output json 2>/dev/null)
        if [ -n "$api_keys" ] && [ "$api_keys" != "[]" ]; then
            api_key=$(echo "$api_keys" | jq -r '.[0].value' 2>/dev/null)
        fi
    fi
    
    # Method 2: Fallback - try to get API key by name pattern
    if [ -z "$api_key" ] || [ "$api_key" = "null" ]; then
        api_key=$(aws apigateway get-api-keys --region "$region" --include-values --query "items[?name=='$stack_name-api-key'].value" --output text 2>/dev/null | head -1)
    fi
    
    # Method 3: Last resort - get any API key (less reliable but works)
    if [ -z "$api_key" ] || [ "$api_key" = "None" ]; then
        api_key=$(aws apigateway get-api-keys --region "$region" --include-values --query "items[0].value" --output text 2>/dev/null)
    fi
    
    if [ -n "$api_key" ] && [ "$api_key" != "null" ] && [ "$api_key" != "None" ]; then
        # Export variables for use by calling function
        API_ENDPOINT="$endpoint"
        API_KEY="$api_key"
        return 0
    fi
    
    return 1
}

setup_config() {
    print_info "Setting up configuration..."
    mkdir -p "$CONFIG_DIR"
    
    # Try to automatically get configuration from existing deployment
    local endpoint=""
    local api_key=""
    
    if command -v aws >/dev/null 2>&1; then
        print_info "Checking for existing AWS deployment..."
        
        if get_api_credentials; then
            endpoint="$API_ENDPOINT"
            api_key="$API_KEY"
            print_success "Found existing AWS deployment - using automatic configuration"
        else
            print_warning "No deployed ShellMate infrastructure found."
            print_info "Please deploy first with: $0 deploy"
            echo
            
            # Only prompt if we couldn't find AWS deployment
            read -p "API Endpoint URL (or press Enter to skip): " endpoint
            if [ -z "$api_key" ] && [ -n "$endpoint" ]; then
                read -p "API Key: " -s api_key
                echo
            fi
        fi
    else
        print_warning "AWS CLI not available - manual configuration required"
        read -p "API Endpoint URL (or press Enter to skip): " endpoint
        if [ -n "$endpoint" ]; then
            read -p "API Key: " -s api_key
            echo
        fi
    fi
    
    if [ -n "$endpoint" ] && [ -n "$api_key" ]; then
        # Load shared shell function template
        local template_file="$SCRIPT_DIR/shell-function-template.sh"
        
        if [ -f "$template_file" ]; then
            # Use shared template
            local shell_function_content=$(cat "$template_file" | sed "s|SHELLMATE_FUNCTION_CALLS|$function_calls|g")
            
            cat > "$CONFIG_FILE" << EOF
# ShellMate Configuration
# Auto-generated by shellmate.sh on $(date)

export SHELLMATE_API_ENDPOINT="ENDPOINT_PLACEHOLDER"
export SHELLMATE_API_KEY="API_KEY_PLACEHOLDER"

# UI Configuration
export SHELLMATE_SHOW_PROMPT="false"  # Set to "false" to hide verbose output

$shell_function_content
EOF
        else
            # Fallback to inline template if shared file doesn't exist
            cat > "$CONFIG_FILE" << 'EOF'
# ShellMate Configuration
# Auto-generated by shellmate.sh on $(date)

export SHELLMATE_API_ENDPOINT="ENDPOINT_PLACEHOLDER"
export SHELLMATE_API_KEY="API_KEY_PLACEHOLDER"

# UI Configuration
export SHELLMATE_SHOW_PROMPT="false"  # Set to "false" to hide verbose output

# Seamless Shell Function - Pre-loads command for user confirmation
shellmate() {
    # Check if this is a help flag - pass directly to binary
    if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
        # Pass help request directly to the Python script
        python3 "$SCRIPT_DIR/src/shellmate.py" --help
        return $?
    fi
    
    # Check if this is another flag/option - if so, pass directly to binary
    if [[ $# -gt 0 && "$1" =~ ^- ]]; then
        # This is a flag, call the binary directly
        command shellmate "$@"
        return $?
    fi
    
    # This is a query, use seamless mode
    # Check which shell we're using for proper command execution
    if [[ -n "$ZSH_VERSION" ]]; then
        # ZSH: Use print -z to pre-populate input buffer
        local result exit_code
        SHELLMATE_FUNCTION_CALLS
        exit_code=$?
        if [[ $exit_code -eq 0 && -n "$result" ]]; then
            print -z "$result"
        else
            echo "Failed to get command from ShellMate" >&2
            echo "Hint: For queries, use quotes: shellmate \"your query here\"" >&2
            return 1
        fi
    elif [[ -n "$BASH_VERSION" ]]; then
        # BASH: Use read with pre-populated input
        local result exit_code
        SHELLMATE_FUNCTION_CALLS
        exit_code=$?
        if [[ $exit_code -eq 0 && -n "$result" ]]; then
            local cmd
            read -e -i "$result" cmd
            if [[ -n "$cmd" ]]; then
                eval "$cmd"
            fi
        else
            echo "Failed to get command from ShellMate" >&2
            echo "Hint: For queries, use quotes: shellmate \"your query here\"" >&2
            return 1
        fi
    else
        # Fallback for other shells
        local result exit_code
        SHELLMATE_FUNCTION_CALLS
        exit_code=$?
        if [[ $exit_code -eq 0 && -n "$result" ]]; then
            echo "Generated: $result"
            echo "Copy and paste to execute"
        else
            echo "Failed to get command from ShellMate" >&2
            echo "Hint: For queries, use quotes: shellmate \"your query here\"" >&2
            return 1
        fi
    fi
}
EOF
        fi
        # Generate the appropriate function calls based on available binaries
        local function_calls=""
        local available_binaries=()
        
        # Check which binaries are available
        if [ -f "$INSTALL_DIR/shellmate-py" ] || command -v shellmate-py >/dev/null 2>&1; then
            available_binaries+=("shellmate-py")
        fi
        if [ -f "$INSTALL_DIR/shellmate-sh" ] || command -v shellmate-sh >/dev/null 2>&1; then
            available_binaries+=("shellmate-sh")
        fi
        
        # Generate function calls based on available binaries
        if [ ${#available_binaries[@]} -eq 0 ]; then
            # No binaries found - this shouldn't happen but handle gracefully
            function_calls='result=$(echo "No ShellMate binaries found" >&2; exit 1)'
        elif [ ${#available_binaries[@]} -eq 1 ]; then
            # Only one binary available - call it directly
            function_calls="result=\$(${available_binaries[0]} --seamless \"\$@\" 2>\"\$error_output\")"
        else
            # Multiple binaries available - use fallback logic
            local calls=""
            for binary in "${available_binaries[@]}"; do
                if [ -z "$calls" ]; then
                    calls="$binary --seamless \"\$@\" 2>\"\$error_output\""
                else
                    calls="$calls || $binary --seamless \"\$@\" 2>\"\$error_output\""
                fi
            done
            function_calls="result=\$($calls)"
        fi
        
        # Replace placeholders with actual values
        sed -i "s|ENDPOINT_PLACEHOLDER|$endpoint|g" "$CONFIG_FILE"
        sed -i "s|API_KEY_PLACEHOLDER|$api_key|g" "$CONFIG_FILE"
        sed -i "s|SHELLMATE_FUNCTION_CALLS|$function_calls|g" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        print_success "Configuration saved to $CONFIG_FILE"
        
        # Show what was configured
        print_info "Configured with:"
        print_info "  Endpoint: $endpoint"
        print_info "  API Key: ${api_key:0:8}..."
    else
        print_warning "Configuration not saved - deploy first or provide endpoint/key manually"
    fi
}

setup_shell_integration() {
    local shell_name=$(basename "$SHELL")
    local shell_rc=""
    
    case "$shell_name" in
        "bash") shell_rc="$HOME/.bashrc" ;;
        "zsh") shell_rc="$HOME/.zshrc" ;;
        *) 
            print_warning "Unsupported shell: $shell_name"
            print_info "Please manually add: source $CONFIG_FILE"
            return
            ;;
    esac
    
    if [ -f "$shell_rc" ] && ! grep -q "shellmate.*config" "$shell_rc"; then
        echo >> "$shell_rc"
        echo "# ShellMate configuration" >> "$shell_rc"
        echo "source $CONFIG_FILE" >> "$shell_rc"
        print_success "Shell integration added to $shell_rc"
    fi
}

uninstall_binary() {
    print_header "UNINSTALLING SHELLMATE"
    
    # Remove binaries (both Python and Bash versions)
    local removed_binaries=()
    
    for binary in "$INSTALL_DIR/shellmate" "$INSTALL_DIR/shellmate-py" "$INSTALL_DIR/shellmate-sh" "$INSTALL_DIR/shellmate-bin"; do
        if [ -f "$binary" ]; then
            if [ ! -w "$INSTALL_DIR" ]; then
                sudo rm "$binary"
            else
                rm "$binary"
            fi
            removed_binaries+=("$(basename "$binary")")
        fi
    done
    
    if [ ${#removed_binaries[@]} -gt 0 ]; then
        print_success "Removed binaries: ${removed_binaries[*]}"
    else
        print_info "No ShellMate binaries found in $INSTALL_DIR"
    fi
    
    # Remove configuration directory
    if [ -d "$CONFIG_DIR" ]; then
        rm -rf "$CONFIG_DIR"
        print_success "Configuration removed from $CONFIG_DIR"
    fi
    
    # Unset shellmate function in current shell
    if declare -f shellmate >/dev/null 2>&1; then
        unset -f shellmate
        print_success "Unset shellmate function in current shell"
    fi
    
    # Check for shell integration that needs manual cleanup
    local shells_with_shellmate=()
    for shell_rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$shell_rc" ] && grep -q "shellmate\|ShellMate" "$shell_rc"; then
            shells_with_shellmate+=("$(basename "$shell_rc")")
        fi
    done
    
    if [ ${#shells_with_shellmate[@]} -gt 0 ]; then
        echo
        print_warning "MANUAL CLEANUP REQUIRED"
        print_info "ShellMate integration found in: ${shells_with_shellmate[*]}"
        echo
        print_info "Please edit your shell config files and remove these lines:"
        echo
        
        for shell_rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
            if [ -f "$shell_rc" ] && grep -q "shellmate\|ShellMate" "$shell_rc"; then
                echo -e "${BOLD}In $shell_rc, remove:${NC}"
                echo "  1. The line: # ShellMate configuration"
                echo "  2. The line: source ~/.config/shellmate/config"
                echo "  3. The entire shellmate() function (multi-line block)"
                echo "  4. The entire _shellmate_debug_result() function (if present)"
                echo "  5. The entire _shellmate_handle_error() function (if present)"
                echo "  6. Any other lines containing 'shellmate' or 'ShellMate'"
                echo
            fi
        done
        
        print_info "After editing, restart your shell or run: exec \$SHELL"
    fi
    
    print_success "ShellMate binaries and configuration removed!"
    print_info "Optional: Run '$0 destroy' to remove AWS resources"
}

deploy_aws() {
    print_header "DEPLOYING SHELLMATE AWS INFRASTRUCTURE"
    
    local stage="dev"
    local region="$DEFAULT_REGION"
    local stack_name="$DEFAULT_STACK_NAME"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --stage) stage="$2"; shift 2 ;;
            --region) region="$2"; shift 2 ;;
            --stack) stack_name="$2"; shift 2 ;;
            --force) shift ;;  # Ignore force flag
            *) shift ;;
        esac
    done
    
    cd "$AWS_DIR"
    
    print_info "Configuration:"
    print_info "  Model: Claude 3.5 Sonnet v1 (stable)"
    print_info "  Stage: $stage"
    print_info "  Region: $region"
    print_info "  Stack: $stack_name"
    echo
    
    # Build
    print_info "Building SAM application..."
    sam build --template-file template.yaml
    
    # Deploy parameters
    local params="Stage=$stage"
    
    # Deploy
    print_info "Deploying to AWS..."
    sam deploy \
        --template-file .aws-sam/build/template.yaml \
        --stack-name "$stack_name" \
        --region "$region" \
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
        --parameter-overrides $params \
        --no-fail-on-empty-changeset \
        --resolve-s3
    
    # Get outputs and save configuration
    print_info "Retrieving deployment information..."
    local endpoint=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$region" --query "Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue" --output text)
    local api_key=$(aws apigateway get-api-keys --region "$region" --include-values --query "items[?name=='$stack_name-api-key'].value" --output text | head -1)
    
    if [ -n "$endpoint" ] && [ "$endpoint" != "None" ]; then
        print_success "Deployment completed successfully!"
        print_info "API Endpoint: $endpoint"
        
        # Update local configuration if binary is installed
        if command -v shellmate >/dev/null 2>&1; then
            mkdir -p "$CONFIG_DIR"
            cat > "$CONFIG_FILE" << EOF
# ShellMate Configuration
# Updated by deployment on $(date)

export SHELLMATE_API_ENDPOINT="$endpoint"
export SHELLMATE_API_KEY="$api_key"
EOF
            chmod 600 "$CONFIG_FILE"
            print_success "Local configuration updated"
        fi
    else
        print_error "Deployment may have failed - no endpoint found"
    fi
}

destroy_aws() {
    print_header "DESTROYING SHELLMATE AWS INFRASTRUCTURE"
    
    local stack_name="${1:-$DEFAULT_STACK_NAME}"
    local region="${2:-$DEFAULT_REGION}"
    
    print_warning "This will permanently delete all ShellMate AWS resources."
    read -p "Are you sure? Type 'delete' to confirm: " confirm
    
    if [ "$confirm" = "delete" ]; then
        print_info "Deleting CloudFormation stack: $stack_name"
        aws cloudformation delete-stack --stack-name "$stack_name" --region "$region"
        
        print_info "Waiting for deletion to complete..."
        aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region "$region"
        
        print_success "AWS resources destroyed successfully"
    else
        print_info "Destruction cancelled"
    fi
}

show_status() {
    print_header "SHELLMATE STATUS"
    
    # Binary status
    if command -v shellmate >/dev/null 2>&1; then
        local binary_path=$(which shellmate)
        local binary_size=$(du -h "$binary_path" 2>/dev/null | cut -f1 || echo "unknown")
        print_success "✓ Binary installed: $binary_path ($binary_size)"
    else
        print_warning "✗ Binary not installed"
    fi
    
    # Configuration status
    if [ -f "$CONFIG_FILE" ]; then
        print_success "✓ Configuration found: $CONFIG_FILE"
        if [ -r "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE"
            if [ -n "$SHELLMATE_API_ENDPOINT" ]; then
                print_info "  Endpoint: $SHELLMATE_API_ENDPOINT"
            fi
        fi
    else
        print_warning "✗ No configuration file"
    fi
    
    # AWS status
    if command -v aws >/dev/null 2>&1; then
        local stack_status=$(aws cloudformation describe-stacks --stack-name "$DEFAULT_STACK_NAME" --region "$DEFAULT_REGION" --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "NOT_FOUND")
        
        if [ "$stack_status" = "CREATE_COMPLETE" ] || [ "$stack_status" = "UPDATE_COMPLETE" ]; then
            print_success "✓ AWS infrastructure deployed ($stack_status)"
            
            # Show configuration details
            local outputs=$(aws cloudformation describe-stacks --stack-name "$DEFAULT_STACK_NAME" --region "$DEFAULT_REGION" --query "Stacks[0].Outputs" --output json 2>/dev/null || echo "[]")
            
            if command -v jq >/dev/null 2>&1; then
                echo "$outputs" | jq -r '.[] | "  \(.OutputKey): \(.OutputValue)"' 2>/dev/null | while read line; do
                    print_info "$line"
                done
            else
                print_info "  (install 'jq' for detailed output display)"
            fi
        else
            print_warning "✗ AWS infrastructure not deployed ($stack_status)"
        fi
    else
        print_info "AWS CLI not available - skipping infrastructure check"
    fi
}


test_system() {
    local query="${1:-list files}"
    
    print_header "TESTING SHELLMATE SYSTEM"
    
    # Test binary
    if command -v shellmate >/dev/null 2>&1; then
        print_info "Testing binary with query: $query"
        shellmate "$query"
    else
        print_error "ShellMate binary not installed. Run: $0 install"
        exit 1
    fi
}

show_logs() {
    print_header "RECENT LAMBDA LOGS"
    
    local function_name=$(aws cloudformation describe-stacks --stack-name "$DEFAULT_STACK_NAME" --region "$DEFAULT_REGION" --query "Stacks[0].Outputs[?OutputKey=='FunctionName'].OutputValue" --output text 2>/dev/null)
    
    if [ -n "$function_name" ] && [ "$function_name" != "None" ]; then
        print_info "Showing logs for: $function_name"
        aws logs tail "/aws/lambda/$function_name" --region "$DEFAULT_REGION" --since 1h --follow
    else
        print_error "Lambda function not found"
    fi
}

show_api_key() {
    print_header "SHELLMATE API KEY & ENDPOINT"
    
    local stack_name="${1:-$DEFAULT_STACK_NAME}"
    local region="${2:-$DEFAULT_REGION}"
    
    # Get API endpoint from CloudFormation
    local endpoint=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$region" --query "Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue" --output text 2>/dev/null)
    
    if [ -z "$endpoint" ] || [ "$endpoint" = "None" ]; then
        print_error "No deployed infrastructure found"
        print_info "Run: $0 deploy"
        exit 1
    fi
    
    # Get API key from API Gateway
    print_info "Retrieving API key from AWS API Gateway..."
    local api_keys=$(aws apigateway get-api-keys --region "$region" --include-values --query "items[?contains(tags.\"aws:cloudformation:stack-name\", '$stack_name')]" --output json 2>/dev/null)
    
    if [ -n "$api_keys" ] && [ "$api_keys" != "[]" ]; then
        local api_key=$(echo "$api_keys" | jq -r '.[0].value' 2>/dev/null)
        local api_key_name=$(echo "$api_keys" | jq -r '.[0].name' 2>/dev/null)
        
        if [ -n "$api_key" ] && [ "$api_key" != "null" ]; then
            echo -e "\n${BOLD}Current Configuration:${NC}"
            echo -e "  ${BOLD}API Endpoint:${NC} $endpoint"
            echo -e "  ${BOLD}API Key Name:${NC} $api_key_name" 
            echo -e "  ${BOLD}API Key:${NC} $api_key"
            
            # Check if local config exists and matches
            if [ -f "$CONFIG_FILE" ]; then
                source "$CONFIG_FILE"
                echo -e "\n${BOLD}Local Configuration Status:${NC}"
                if [ "$SHELLMATE_API_ENDPOINT" = "$endpoint" ] && [ "$SHELLMATE_API_KEY" = "$api_key" ]; then
                    print_success "✓ Local config matches AWS deployment"
                else
                    print_warning "✗ Local config differs from AWS deployment"
                    echo -e "  Local endpoint: ${SHELLMATE_API_ENDPOINT:-not set}"
                    echo -e "  Local API key: ${SHELLMATE_API_KEY:-not set}"
                    echo
                    print_info "To update local config, run: $0 install"
                fi
            else
                print_warning "✗ No local configuration found"
                print_info "To create local config, run: $0 install"
            fi
            
        else
            print_error "Could not extract API key from response"
        fi
    else
        print_error "No API keys found for stack: $stack_name"
    fi
}

show_info() {
    print_header "SHELLMATE SYSTEM INFORMATION"
    
    echo -e "${BOLD}Binary:${NC}"
    if command -v shellmate >/dev/null 2>&1; then
        echo "  Location: $(which shellmate)"
        echo "  Size: $(du -h $(which shellmate) | cut -f1)"
    else
        echo "  Status: Not installed"
    fi
    
    echo -e "\n${BOLD}Configuration:${NC}"
    echo "  Config file: $CONFIG_FILE"
    if [ -f "$CONFIG_FILE" ]; then
        echo "  Status: Found"
    else
        echo "  Status: Not found"
    fi
    
    echo -e "\n${BOLD}Template Configuration:${NC}"
    echo "  Template: $TEMPLATE_FILE"
    echo "  Model: Claude 3.5 Sonnet v1 (stable)"
    
    echo -e "\n${BOLD}AWS Resources:${NC}"
    show_status | grep -E "(✓|✗)" | sed 's/^/  /'
    
    echo -e "\n${BOLD}Paths:${NC}"
    echo "  Build dir: $BUILD_DIR"
    echo "  Install dir: $INSTALL_DIR"
    echo "  Script dir: $SCRIPT_DIR"
}

clean_artifacts() {
    print_header "CLEANING BUILD ARTIFACTS"
    
    if [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
        print_success "Removed build directory"
    fi
    
    if [ -d "$AWS_DIR/.aws-sam" ]; then
        rm -rf "$AWS_DIR/.aws-sam"
        print_success "Removed SAM build artifacts"
    fi
    
    # Python cache
    find "$SCRIPT_DIR" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    find "$SCRIPT_DIR" -name "*.pyc" -delete 2>/dev/null || true
    
    print_success "Cleanup completed"
}

main() {
    local command="$1"
    shift || true
    
    case "$command" in
        "build")
            check_prerequisites "$command"
            build_binary
            ;;
        "install")
            check_prerequisites "$command"
            print_header "INSTALLING SHELLMATE"
            print_info "Using new simplified installation..."
            python3 install.py
            ;;
        "uninstall")
            uninstall_binary
            ;;
        "deploy")
            check_prerequisites "$command"
            deploy_aws "$@"
            ;;
        "redeploy")
            check_prerequisites "$command"
            deploy_aws --force "$@"
            ;;
        "destroy")
            check_prerequisites "$command"
            destroy_aws "$@"
            ;;
        "status")
            show_status
            ;;
        "test")
            test_system "$1"
            ;;
        "test-local")
            test_system "$1"
            ;;
        "logs")
            check_prerequisites "logs"
            show_logs
            ;;
        "api-key")
            check_prerequisites "api-key"
            show_api_key "$@"
            ;;
        "info")
            show_info
            ;;
        "config")
            show_status | grep -A 20 "Configuration"
            ;;
        "clean")
            clean_artifacts
            ;;
        "help"|"--help"|"-h"|"")
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            echo "Run '$0 help' for usage information"
            exit 1
            ;;
    esac
}

# Change to script directory
cd "$SCRIPT_DIR"

# Run main function
main "$@"
