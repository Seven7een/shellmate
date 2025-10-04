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
AWS_DIR="$SCRIPT_DIR/aws"
TEMPLATE_FILE="$AWS_DIR/template.yaml"
DEFAULT_STACK_NAME="shellmate-dev"
DEFAULT_REGION="us-east-1"

# Installation paths
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

# Parse model configuration from template.yaml
get_model_config() {
    if [ ! -f "$TEMPLATE_FILE" ]; then
        print_error "Template file not found: $TEMPLATE_FILE"
        exit 1
    fi
    
    # Extract model configurations using yq or basic parsing
    if command -v yq >/dev/null 2>&1; then
        # Use yq if available for precise YAML parsing
        yq eval '.Mappings.ModelConfig' "$TEMPLATE_FILE" 2>/dev/null
    else
        # Fallback to basic parsing for model list
        grep -A 50 "ModelConfig:" "$TEMPLATE_FILE" | \
        grep -E "^\s+[a-z-]+:" | \
        sed 's/^\s*//' | \
        sed 's/://' | \
        head -20
    fi
}

get_model_list() {
    if command -v yq >/dev/null 2>&1; then
        yq eval '.Mappings.ModelConfig | keys' "$TEMPLATE_FILE" 2>/dev/null | \
        grep -v '^\[' | grep -v '^\]' | sed 's/^- //' | sed 's/"//g'
    else
        # Fallback parsing - extract model names after ModelConfig:
        awk '
        /^[[:space:]]*ModelConfig:/ { in_models = 1; next }
        in_models && /^[[:space:]]*[a-z][a-z0-9-]*:[[:space:]]*$/ { 
            gsub(/^[[:space:]]+/, "", $0)
            gsub(/:.*$/, "", $0)
            print $0
        }
        in_models && /^[[:space:]]*ApiConfig:/ { in_models = 0 }
        in_models && /^# =/ { in_models = 0 }
        in_models && /^[A-Z][a-zA-Z]*:/ { in_models = 0 }
        ' "$TEMPLATE_FILE" | sort
    fi
}

get_model_details() {
    local model="$1"
    
    if command -v yq >/dev/null 2>&1; then
        echo "Model ID: $(yq eval ".Mappings.ModelConfig.\"$model\".ModelId" "$TEMPLATE_FILE" 2>/dev/null)"
        echo "Requires Profile: $(yq eval ".Mappings.ModelConfig.\"$model\".RequiresProfile" "$TEMPLATE_FILE" 2>/dev/null)"
        echo "Description: $(yq eval ".Mappings.ModelConfig.\"$model\".Description" "$TEMPLATE_FILE" 2>/dev/null)"
    else
        # Basic parsing fallback
        print_info "Model: $model (install 'yq' for detailed info)"
    fi
}

show_help() {
    cat << EOF
${BOLD}ShellMate Unified Management Script${NC}

${BOLD}Usage:${NC}
  $0 <command> [options]

${BOLD}Commands:${NC}

  ${BOLD}Configuration Management:${NC}
    install              Install configuration and configure shell
    uninstall            Remove ShellMate from system

  ${BOLD}AWS Deployment:${NC}
    deploy [options]     Deploy AWS infrastructure
    redeploy [options]   Force redeploy with new configuration
    destroy              Delete all AWS resources
    status               Show deployment status and configuration

  ${BOLD}Model Management:${NC}
    models               List all available model configurations from template.yaml
    switch-model <model> Switch to a different model configuration
    enable-profiles      Enable inference profiles for latest models
    disable-profiles     Disable inference profiles (direct model access)

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
  --model <model>        Model to use (see: $0 models)
  --profiles             Enable inference profiles
  --no-profiles          Disable inference profiles  
  --stage <stage>        Deployment stage (dev/prod)
  --region <region>      AWS region
  --stack <name>         CloudFormation stack name

${BOLD}Examples:${NC}
  $0 install                                # Install configuration
  $0 models                                 # See all available models
  $0 deploy --model claude-3-5-sonnet-v2 --profiles  # Deploy with latest model
  $0 switch-model claude-3-5-haiku         # Switch to faster model
  $0 test "list python files"              # Test the system
  $0 status                                 # Check current configuration

${BOLD}Configuration:${NC}
  All settings are centralized in: $TEMPLATE_FILE
  Local config: $CONFIG_FILE

${BOLD}Note:${NC} Install 'yq' for enhanced YAML parsing and detailed model information
EOF
}

check_prerequisites() {
    local missing=()
    
    # Check Python
    if ! command -v python3 >/dev/null 2>&1; then
        missing+=("python3")
    fi
    
    # Check AWS CLI for deployment commands
    if [[ "$1" =~ ^(deploy|redeploy|destroy|status|logs|switch-model|enable-profiles|disable-profiles|api-key)$ ]]; then
        if ! command -v aws >/dev/null 2>&1; then
            missing+=("aws-cli")
        fi
        if [[ "$1" =~ ^(deploy|redeploy|destroy|switch-model|enable-profiles|disable-profiles)$ ]]; then
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

validate_model() {
    local model="$1"
    local valid_models
    
    valid_models=$(get_model_list)
    
    if ! echo "$valid_models" | grep -q "^$model$"; then
        print_error "Invalid model: $model"
        print_info "Available models:"
        echo "$valid_models" | sed 's/^/  /'
        exit 1
    fi
}


install_config() {
    print_header "INSTALLING SHELLMATE SYSTEM-WIDE"
    
    # Setup configuration and shell integration only
    # (Using shell script directly, no binary needed)
    setup_config
    setup_shell_integration
    
    print_success "ShellMate configuration installed successfully!"
    print_info "Restart your shell or run: source $CONFIG_FILE"
    print_info "Test with: shellmate --help"
}

setup_config() {
    print_info "Setting up configuration..."
    mkdir -p "$CONFIG_DIR"
    
    # Try to get configuration from existing deployment
    local endpoint=""
    local api_key=""
    
    if command -v aws >/dev/null 2>&1; then
        endpoint=$(aws cloudformation describe-stacks --stack-name "$DEFAULT_STACK_NAME" --region "$DEFAULT_REGION" --query "Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue" --output text 2>/dev/null || true)
        if [ "$endpoint" != "None" ] && [ -n "$endpoint" ]; then
            # Use CloudFormation tags to find the API key (same logic as show_api_key function)
            local api_keys=$(aws apigateway get-api-keys --region "$DEFAULT_REGION" --include-values --query "items[?contains(tags.\"aws:cloudformation:stack-name\", '$DEFAULT_STACK_NAME')]" --output json 2>/dev/null)
            if [ -n "$api_keys" ] && [ "$api_keys" != "[]" ]; then
                api_key=$(echo "$api_keys" | jq -r '.[0].value' 2>/dev/null || true)
            fi
        fi
    fi
    
    # Prompt for configuration if not found
    if [ -z "$endpoint" ]; then
        echo
        print_warning "No deployed ShellMate infrastructure found."
        print_info "Please deploy first with: $0 deploy"
        echo
        read -p "API Endpoint URL (or press Enter to skip): " endpoint
    fi
    
    if [ -z "$api_key" ] && [ -n "$endpoint" ]; then
        read -p "API Key: " -s api_key
        echo
    fi
    
    if [ -n "$endpoint" ] && [ -n "$api_key" ]; then
        cat > "$CONFIG_FILE" << EOF
# ShellMate Configuration
# Auto-generated by shellmate.sh on $(date)

export SHELLMATE_API_ENDPOINT="$endpoint"
export SHELLMATE_API_KEY="$api_key"

# UI Configuration
export SHELLMATE_SHOW_PROMPT="false"  # Set to "false" to hide verbose output

# Seamless Shell Function - Pre-loads command for user confirmation
shellmate() {
    # Check for --help or -h first
    if [[ "\$1" == "--help" ]] || [[ "\$1" == "-h" ]]; then
        # Pass help request directly to the Python script without --seamless
        python3 "$SCRIPT_DIR/src/shellmate.py" --help
        return \$?
    fi
    
    local cmd
    # Get the command from the AI service using Python script directly
    cmd=\$(python3 "$SCRIPT_DIR/src/shellmate.py" --seamless "\$*" 2>/dev/null)
    local exit_code=\$?
    
    # If we got a command, pre-load it in the shell input
    if [[ -n "\$cmd" && \$exit_code -eq 0 ]]; then
        # Check which shell we're using
        if [[ -n "\$ZSH_VERSION" ]]; then
            # ZSH: Use print -z to pre-populate input buffer
            print -z "\$cmd"
        elif [[ -n "\$BASH_VERSION" ]]; then
            # BASH: Use read with pre-populated input
            local user_cmd
            echo -n "Press Enter to execute (or edit): "
            read -e -i "\$cmd" user_cmd
            if [[ -n "\$user_cmd" ]]; then
                eval "\$user_cmd"
            fi
        else
            # Fallback for other shells
            echo "Generated: \$cmd"
            echo "Copy and paste to execute, or use zsh/bash for better experience."
        fi
    else
        # For any other error, show the error message properly
        python3 "$SCRIPT_DIR/src/shellmate.py" "\$@"
        return \$?
    fi
}
EOF
        chmod 600 "$CONFIG_FILE"
        print_success "Configuration saved to $CONFIG_FILE"
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

uninstall_config() {
    print_header "UNINSTALLING SHELLMATE"
    
    # Remove configuration
    if [ -d "$CONFIG_DIR" ]; then
        rm -rf "$CONFIG_DIR"
        print_success "Configuration removed from $CONFIG_DIR"
    fi
    
    print_info "Manual cleanup required:"
    print_info "- Remove 'source ~/.config/shellmate/config' from shell config"
    print_info "- Run: $0 destroy (to remove AWS resources)"
}

deploy_aws() {
    print_header "DEPLOYING SHELLMATE AWS INFRASTRUCTURE"
    
    local model="claude-3-5-sonnet-v1"
    local use_profiles="false"
    local stage="dev"
    local region="$DEFAULT_REGION"
    local stack_name="$DEFAULT_STACK_NAME"
    local force_deploy=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --model) 
                model="$2"
                validate_model "$model"
                shift 2 
                ;;
            --profiles) use_profiles="true"; shift ;;
            --no-profiles) use_profiles="false"; shift ;;
            --stage) stage="$2"; shift 2 ;;
            --region) region="$2"; shift 2 ;;
            --stack) stack_name="$2"; shift 2 ;;
            --force) force_deploy=true; shift ;;
            *) shift ;;
        esac
    done
    
    cd "$AWS_DIR"
    
    print_info "Configuration:"
    print_info "  Model: $model"
    get_model_details "$model" | sed 's/^/  /'
    print_info "  Inference Profiles: $use_profiles"
    print_info "  Stage: $stage"
    print_info "  Region: $region"
    print_info "  Stack: $stack_name"
    echo
    
    # Build
    print_info "Building SAM application..."
    sam build --template-file template.yaml
    
    # Deploy parameters
    local params="Stage=$stage ModelSelection=$model UseInferenceProfile=$use_profiles"
    
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
    # Use CloudFormation tags to find the API key (consistent with setup_config function)
    local api_keys=$(aws apigateway get-api-keys --region "$region" --include-values --query "items[?contains(tags.\"aws:cloudformation:stack-name\", '$stack_name')]" --output json 2>/dev/null)
    local api_key=""
    if [ -n "$api_keys" ] && [ "$api_keys" != "[]" ]; then
        api_key=$(echo "$api_keys" | jq -r '.[0].value' 2>/dev/null || true)
    fi
    
    if [ -n "$endpoint" ] && [ "$endpoint" != "None" ]; then
        print_success "Deployment completed successfully!"
        print_info "API Endpoint: $endpoint"
        
        # Update local configuration if shellmate is available
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
    
    # Shell function status  
    if command -v shellmate >/dev/null 2>&1; then
        print_success "✓ Shell function available: shellmate"
    else
        print_warning "✗ Shell function not available"
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

list_models() {
    print_header "AVAILABLE MODELS (from template.yaml)"
    
    if ! command -v yq >/dev/null 2>&1; then
        print_warning "Install 'yq' for enhanced model information display"
        echo
    fi
    
    local models=$(get_model_list)
    
    if [ -z "$models" ]; then
        print_error "Could not parse models from template.yaml"
        print_info "Ensure template.yaml exists and has proper ModelConfig mapping"
        exit 1
    fi
    
    echo -e "${BOLD}Available Models:${NC}"
    echo
    
    while IFS= read -r model; do
        echo -e "${BOLD}  $model${NC}"
        
        if command -v yq >/dev/null 2>&1; then
            local model_id=$(yq eval ".Mappings.ModelConfig.\"$model\".ModelId" "$TEMPLATE_FILE" 2>/dev/null)
            local description=$(yq eval ".Mappings.ModelConfig.\"$model\".Description" "$TEMPLATE_FILE" 2>/dev/null)
            local requires_profile=$(yq eval ".Mappings.ModelConfig.\"$model\".RequiresProfile" "$TEMPLATE_FILE" 2>/dev/null)
            
            echo "    ID: $model_id"
            echo "    Description: $description"
            echo "    Requires Profile: $requires_profile"
        else
            echo "    (install 'yq' for detailed information)"
        fi
        echo
    done <<< "$models"
    
    echo -e "${BOLD}Usage:${NC}"
    echo "  $0 deploy --model <model-name> [--profiles]"
    echo "  $0 switch-model <model-name>"
}

switch_model() {
    local new_model="$1"
    
    if [ -z "$new_model" ]; then
        print_error "Model name required. See: $0 models"
        exit 1
    fi
    
    validate_model "$new_model"
    
    print_header "SWITCHING TO MODEL: $new_model"
    
    # Check if model requires inference profile
    local requires_profile="false"
    if command -v yq >/dev/null 2>&1; then
        requires_profile=$(yq eval ".Mappings.ModelConfig.\"$new_model\".RequiresProfile" "$TEMPLATE_FILE" 2>/dev/null)
    fi
    
    # Deploy with appropriate settings
    if [ "$requires_profile" = "true" ]; then
        print_info "Model requires inference profile - enabling profiles"
        deploy_aws --model "$new_model" --profiles --force
    else
        print_info "Model works with direct invocation"
        deploy_aws --model "$new_model" --force
    fi
    
    print_success "Model switched to $new_model"
}

test_system() {
    local query="${1:-list files}"
    
    print_header "TESTING SHELLMATE SYSTEM"
    
    # Test shell function
    if command -v shellmate >/dev/null 2>&1; then
        print_info "Testing system with query: $query"
        shellmate --dry-run "$query"
    else
        print_error "ShellMate not configured. Run: $0 install"
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
    
    echo -e "${BOLD}Shell Function:${NC}"
    if command -v shellmate >/dev/null 2>&1; then
        echo "  Status: Available"
        echo "  Type: Shell function"
    else
        echo "  Status: Not available"
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
    echo "  Available models: $(get_model_list | wc -l)"
    
    echo -e "\n${BOLD}AWS Resources:${NC}"
    show_status | grep -E "(✓|✗)" | sed 's/^/  /'
    
    echo -e "\n${BOLD}Paths:${NC}"
    echo "  Script dir: $SCRIPT_DIR"
    echo "  Config dir: $CONFIG_DIR"
}

clean_artifacts() {
    print_header "CLEANING ARTIFACTS"
    
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
        "install")
            check_prerequisites "$command"
            install_config
            ;;
        "uninstall")
            uninstall_config
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
        "models")
            list_models
            ;;
        "switch-model")
            check_prerequisites "deploy"
            switch_model "$1"
            ;;
        "enable-profiles")
            check_prerequisites "deploy"
            deploy_aws --profiles --force
            ;;
        "disable-profiles")
            check_prerequisites "deploy"
            deploy_aws --no-profiles --force
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
