#!/bin/bash

# =============================================================================
# ShellMate Cost Tracker Script
# =============================================================================
# Script to track AWS costs for ShellMate, focusing on Lambda and Bedrock usage
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Default configuration
REGION="us-east-1"
STACK_NAME="shellmate-dev"
DEFAULT_DAYS=7
DEFAULT_GRANULARITY="DAILY"

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() {
    echo -e "${BOLD}${BLUE}========================================${NC}"
    echo -e "${BOLD}${BLUE}$1${NC}"
    echo -e "${BOLD}${BLUE}========================================${NC}"
}

check_prerequisites() {
    local missing=()
    
    # Check AWS CLI and jq
    if ! command -v aws >/dev/null 2>&1; then
        missing+=("aws-cli")
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        missing+=("jq")
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing prerequisites: ${missing[*]}"
        exit 1
    fi
}

calculate_date_range() {
    local days=${1:-$DEFAULT_DAYS}
    
    # End date is today
    END_DATE=$(date -u +"%Y-%m-%d")
    
    # Start date is X days ago
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS date command
        START_DATE=$(date -u -v-${days}d +"%Y-%m-%d")
    else
        # Linux date command
        START_DATE=$(date -u -d "${days} days ago" +"%Y-%m-%d")
    fi
    
    # For CloudWatch metrics (needs different format)
    END_DATE_TIME=$(date -u +"%Y-%m-%dT%H:%M:%S")
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        START_DATE_TIME=$(date -u -v-${days}d +"%Y-%m-%dT%H:%M:%S")
    else
        START_DATE_TIME=$(date -u -d "${days} days ago" +"%Y-%m-%dT%H:%M:%S")
    fi
    
    print_info "Date range: $START_DATE to $END_DATE"
}

get_function_name() {
    print_info "Getting Lambda function name from CloudFormation..."
    
    FUNCTION_NAME=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='FunctionName'].OutputValue" \
        --output text)
    
    if [ -z "$FUNCTION_NAME" ] || [ "$FUNCTION_NAME" = "None" ]; then
        print_error "Could not find Lambda function name. Is your stack name correct?"
        exit 1
    fi
    
    print_info "Found function: $FUNCTION_NAME"
}

get_model_id() {
    print_info "Getting Bedrock model ID from CloudFormation..."
    
    MODEL_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='ModelId'].OutputValue" \
        --output text)
    
    if [ -z "$MODEL_ID" ] || [ "$MODEL_ID" = "None" ]; then
        print_warning "Could not find model ID from stack outputs"
        MODEL_ID="anthropic.claude-3-haiku-20240307-v1:0"
        print_info "Using default model ID: $MODEL_ID"
    else
        print_info "Found model: $MODEL_ID"
    fi
}

get_lambda_costs() {
    print_header "LAMBDA COSTS"
    
    print_info "Querying Lambda costs for ${1:-$DEFAULT_DAYS} days..."
    
    # Query Lambda costs with AWS Cost Explorer API
    local response=$(aws ce get-cost-and-usage \
        --time-period Start=${START_DATE},End=${END_DATE} \
        --granularity ${2:-$DEFAULT_GRANULARITY} \
        --metrics "UnblendedCost" \
        --filter '{"And": [{"Dimensions": {"Key": "SERVICE", "Values": ["AWS Lambda"]}}, {"Dimensions": {"Key": "REGION", "Values": ["'"$REGION"'"]}}]}' \
        --region "$REGION" 2>/dev/null || echo '{"ResultsByTime": [{"TimePeriod": {"Start": "'"$START_DATE"'", "End": "'"$END_DATE"'"}, "Total": {"UnblendedCost": {"Amount": "0", "Unit": "USD"}}}]}')
    
    # Extract total cost
    local total_cost=$(echo "$response" | jq -r '.ResultsByTime | map(.Total.UnblendedCost.Amount | tonumber) | add')
    total_cost=$(printf "%.2f" $total_cost)
    local currency=$(echo "$response" | jq -r '.ResultsByTime[0].Total.UnblendedCost.Unit')
    
    if (( $(echo "$total_cost == 0" | bc -l) )); then
        print_warning "Total Lambda cost: $total_cost $currency (Note: Cost data may be delayed by 24-48 hours)"
    else
        print_success "Total Lambda cost: $total_cost $currency"
    fi
    
    # Show daily/monthly breakdown
    echo -e "\n${BOLD}Cost Breakdown:${NC}"
    echo "$response" | jq -r '.ResultsByTime[] | .TimePeriod.Start + " to " + .TimePeriod.End + ": " + .Total.UnblendedCost.Amount + " " + .Total.UnblendedCost.Unit'
    
    # Store for total calculation
    LAMBDA_COST=$total_cost
}

get_bedrock_costs() {
    print_header "BEDROCK COSTS"
    
    print_info "Querying Bedrock costs for ${1:-$DEFAULT_DAYS} days..."
    
    # Query Bedrock costs with AWS Cost Explorer API
    local response=$(aws ce get-cost-and-usage \
        --time-period Start=${START_DATE},End=${END_DATE} \
        --granularity ${2:-$DEFAULT_GRANULARITY} \
        --metrics "UnblendedCost" \
        --filter '{"And": [{"Dimensions": {"Key": "SERVICE", "Values": ["Amazon Bedrock"]}}, {"Dimensions": {"Key": "REGION", "Values": ["'"$REGION"'"]}}]}' \
        --region "$REGION" 2>/dev/null || echo '{"ResultsByTime": [{"TimePeriod": {"Start": "'"$START_DATE"'", "End": "'"$END_DATE"'"}, "Total": {"UnblendedCost": {"Amount": "0", "Unit": "USD"}}}]}')
    
    # Extract total cost
    local total_cost=$(echo "$response" | jq -r '.ResultsByTime | map(.Total.UnblendedCost.Amount | tonumber) | add')
    total_cost=$(printf "%.2f" $total_cost)
    local currency=$(echo "$response" | jq -r '.ResultsByTime[0].Total.UnblendedCost.Unit')
    
    if (( $(echo "$total_cost == 0" | bc -l) )); then
        print_warning "Total Bedrock cost: $total_cost $currency (Note: Cost data may be delayed by 24-48 hours)"
    else
        print_success "Total Bedrock cost: $total_cost $currency"
    fi
    
    # Show daily/monthly breakdown
    echo -e "\n${BOLD}Cost Breakdown:${NC}"
    echo "$response" | jq -r '.ResultsByTime[] | .TimePeriod.Start + " to " + .TimePeriod.End + ": " + .Total.UnblendedCost.Amount + " " + .Total.UnblendedCost.Unit'
    
    # Store for total calculation
    BEDROCK_COST=$total_cost
}

get_api_costs() {
    print_header "API GATEWAY COSTS"
    
    print_info "Querying API Gateway costs for ${1:-$DEFAULT_DAYS} days..."
    
    # Query API Gateway costs with AWS Cost Explorer API
    local response=$(aws ce get-cost-and-usage \
        --time-period Start=${START_DATE},End=${END_DATE} \
        --granularity ${2:-$DEFAULT_GRANULARITY} \
        --metrics "UnblendedCost" \
        --filter '{"And": [{"Dimensions": {"Key": "SERVICE", "Values": ["Amazon API Gateway"]}}, {"Dimensions": {"Key": "REGION", "Values": ["'"$REGION"'"]}}]}' \
        --region "$REGION" 2>/dev/null || echo '{"ResultsByTime": [{"TimePeriod": {"Start": "'"$START_DATE"'", "End": "'"$END_DATE"'"}, "Total": {"UnblendedCost": {"Amount": "0", "Unit": "USD"}}}]}')
    
    # Extract total cost
    local total_cost=$(echo "$response" | jq -r '.ResultsByTime | map(.Total.UnblendedCost.Amount | tonumber) | add')
    total_cost=$(printf "%.2f" $total_cost)
    local currency=$(echo "$response" | jq -r '.ResultsByTime[0].Total.UnblendedCost.Unit')
    
    if (( $(echo "$total_cost == 0" | bc -l) )); then
        print_warning "Total API Gateway cost: $total_cost $currency (Note: Cost data may be delayed by 24-48 hours)"
    else
        print_success "Total API Gateway cost: $total_cost $currency"
    fi
    
    # Show daily/monthly breakdown
    echo -e "\n${BOLD}Cost Breakdown:${NC}"
    echo "$response" | jq -r '.ResultsByTime[] | .TimePeriod.Start + " to " + .TimePeriod.End + ": " + .Total.UnblendedCost.Amount + " " + .Total.UnblendedCost.Unit'
    
    # Store for total calculation
    API_COST=$total_cost
}

get_lambda_invocations() {
    print_header "LAMBDA INVOCATIONS"
    
    print_info "Querying Lambda invocations for $FUNCTION_NAME..."
    
    # Get Lambda invocation metrics from CloudWatch
    local response=$(aws cloudwatch get-metric-statistics \
        --namespace "AWS/Lambda" \
        --metric-name "Invocations" \
        --dimensions Name=FunctionName,Value=$FUNCTION_NAME \
        --start-time $START_DATE_TIME \
        --end-time $END_DATE_TIME \
        --period 86400 \
        --statistics "Sum" \
        --region "$REGION" 2>/dev/null || echo '{"Datapoints": []}')
    
    # Extract total invocations
    local datapoints=$(echo "$response" | jq -r '.Datapoints | length')
    
    if [ "$datapoints" -eq 0 ]; then
        print_warning "No Lambda invocation data found"
        LAMBDA_INVOCATIONS=0
    else
        LAMBDA_INVOCATIONS=$(echo "$response" | jq -r '.Datapoints | map(.Sum) | add')
        LAMBDA_INVOCATIONS=$(printf "%.0f" $LAMBDA_INVOCATIONS)
        print_success "Total Lambda invocations: $LAMBDA_INVOCATIONS"
        
        # Show daily breakdown
        echo -e "\n${BOLD}Invocation Breakdown:${NC}"
        echo "$response" | jq -r '.Datapoints[] | (.Timestamp | split("T")[0]) + ": " + (.Sum | tostring) + " invocations"'
    fi
}

get_bedrock_invocations() {
    print_header "BEDROCK INVOCATIONS"
    
    print_info "Estimating Bedrock invocations from Lambda logs..."
    
    # Get log group for the Lambda function
    local log_group_name="/aws/lambda/$FUNCTION_NAME"
    
    # Start a CloudWatch Logs Insights query
    local start_timestamp=""
    local end_timestamp=""
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS date command
        start_timestamp=$(date -j -f "%Y-%m-%d" "$START_DATE" +%s 2>/dev/null || echo "")
        end_timestamp=$(date -j -f "%Y-%m-%d" "$END_DATE" +%s 2>/dev/null || echo "")
    else
        # Linux date command
        start_timestamp=$(date -d "$START_DATE" +%s 2>/dev/null || echo "")
        end_timestamp=$(date -d "$END_DATE" +%s 2>/dev/null || echo "")
    fi
    
    if [ -z "$start_timestamp" ] || [ -z "$end_timestamp" ]; then
        print_warning "Could not convert dates for CloudWatch Logs query"
        BEDROCK_INVOCATIONS=0
        return
    fi
    
    local query_id=$(aws logs start-query \
        --log-group-name "$log_group_name" \
        --start-time $start_timestamp \
        --end-time $end_timestamp \
        --query-string 'filter @message like "Invoking Bedrock" | stats count(*) as invocations' \
        --region "$REGION" \
        --query 'queryId' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$query_id" ]; then
        print_warning "Could not initiate CloudWatch Logs Insights query"
        BEDROCK_INVOCATIONS=0
    else
        # Wait for the query to complete
        sleep 3
        
        local query_result=$(aws logs get-query-results \
            --query-id "$query_id" \
            --region "$REGION" 2>/dev/null || echo '{"results": []}')
        
        # Extract invocation count
        local result_count=$(echo "$query_result" | jq -r '.results | length')
        
        if [ "$result_count" -eq 0 ]; then
            print_warning "No Bedrock invocation data found in Lambda logs"
            BEDROCK_INVOCATIONS=0
        else
            BEDROCK_INVOCATIONS=$(echo "$query_result" | jq -r '.results[0][0].value // "0"')
            print_success "Estimated Bedrock invocations: $BEDROCK_INVOCATIONS"
        fi
    fi
    
    # Alternative: Assume each Lambda invocation generates one Bedrock call
    if [ "$BEDROCK_INVOCATIONS" -eq 0 ] && [ "$LAMBDA_INVOCATIONS" -gt 0 ]; then
        BEDROCK_INVOCATIONS=$LAMBDA_INVOCATIONS
        print_warning "Using Lambda invocations as estimate for Bedrock calls: $BEDROCK_INVOCATIONS"
    fi
}

calculate_per_call_costs() {
    print_header "PER-CALL COST ANALYSIS"
    
    # Calculate API costs per call
    if [ "$LAMBDA_INVOCATIONS" -gt 0 ]; then
        # Lambda cost per invocation
        local lambda_per_call=$(echo "scale=4; $LAMBDA_COST / $LAMBDA_INVOCATIONS" | bc)
        
        # Bedrock cost per invocation
        local bedrock_per_call=0
        if [ "$BEDROCK_INVOCATIONS" -gt 0 ]; then
            bedrock_per_call=$(echo "scale=4; $BEDROCK_COST / $BEDROCK_INVOCATIONS" | bc)
        fi
        
        # API Gateway cost per call
        local api_per_call=$(echo "scale=4; $API_COST / $LAMBDA_INVOCATIONS" | bc)
        
        # Total cost per API call
        local total_per_call=$(echo "scale=4; $lambda_per_call + $bedrock_per_call + $api_per_call" | bc)
        
        print_success "Cost per API call: $total_per_call USD"
        echo
        echo "Breakdown per call:"
        echo "  - Lambda:        $lambda_per_call USD"
        echo "  - Bedrock:       $bedrock_per_call USD"
        echo "  - API Gateway:   $api_per_call USD"
        
        # Claude 3 Haiku pricing estimate
        if (( $(echo "$bedrock_per_call > 0" | bc -l) )); then
            # Estimated token counts based on pricing
            # Claude 3 Haiku is $0.00025 per 1K input tokens and $0.00125 per 1K output tokens
            # Assume average ratio of 5:1 (input:output) based on command generation use case
            
            local avg_cost_per_1k_tokens=$(echo "scale=6; (0.00025 * 5 + 0.00125) / 6" | bc)
            local estimated_avg_tokens=$(echo "scale=0; $bedrock_per_call / $avg_cost_per_1k_tokens * 1000" | bc)
            
            print_info "Estimated average tokens per call: ~$estimated_avg_tokens tokens"
        fi
    else
        print_warning "No invocation data to calculate per-call costs"
    fi
}

get_total_costs() {
    print_header "TOTAL SHELLMATE COSTS"
    
    # Calculate total cost (Lambda + Bedrock + API Gateway)
    TOTAL_COST=$(echo "$LAMBDA_COST + $BEDROCK_COST + $API_COST" | bc)
    TOTAL_COST=$(printf "%.2f" $TOTAL_COST)
    
    if (( $(echo "$TOTAL_COST == 0" | bc -l) )); then
        print_warning "Total ShellMate costs: $TOTAL_COST USD (Note: Cost data may be delayed 24-48 hours)"
        print_info "If you've just deployed ShellMate or haven't used it much yet, costs may not appear immediately."
        print_info "AWS Cost Explorer typically has a delay of 24-48 hours before costs are visible."
    else
        print_success "Total ShellMate costs: $TOTAL_COST USD"
    fi
    
    echo
    echo "Breakdown:"
    echo "  - Lambda:        $LAMBDA_COST USD"
    echo "  - Bedrock:       $BEDROCK_COST USD"
    echo "  - API Gateway:   $API_COST USD"
    echo
    
    # Show monthly estimate based on current usage
    local days=${1:-$DEFAULT_DAYS}
    if (( $(echo "$TOTAL_COST > 0" | bc -l) )); then
        local monthly_estimate=$(echo "scale=2; $TOTAL_COST / $days * 30" | bc)
        
        echo -e "${BOLD}Monthly cost estimate (based on current usage):${NC}"
        echo "  $monthly_estimate USD per month"
    fi
    
    # Show usage summary
    echo -e "\n${BOLD}Usage Summary:${NC}"
    echo "  - Lambda Invocations:  $LAMBDA_INVOCATIONS"
    echo "  - Bedrock Invocations: $BEDROCK_INVOCATIONS"
    
    if (( $(echo "$TOTAL_COST == 0" | bc -l) && LAMBDA_INVOCATIONS > 0 )); then
        echo
        print_info "You have usage ($LAMBDA_INVOCATIONS invocations) but no cost data yet."
        print_info "This likely means you're within the AWS free tier or costs haven't appeared in Cost Explorer."
    fi
}

show_help() {
    cat << EOF
${BOLD}ShellMate Cost Tracker${NC}

${BOLD}Usage:${NC}
  $0 [options]

${BOLD}Options:${NC}
  -d, --days <number>       Number of days to query (default: $DEFAULT_DAYS)
  -g, --granularity <gran>  Cost granularity: DAILY|MONTHLY (default: $DEFAULT_GRANULARITY)
  -r, --region <region>     AWS region (default: $REGION)
  -s, --stack <name>        CloudFormation stack name (default: $STACK_NAME)
  -h, --help                Show this help message

${BOLD}Example:${NC}
  $0 --days 7               # Show costs for last 7 days
  $0 --granularity MONTHLY  # Show monthly breakdown

${BOLD}Note:${NC}
  This script requires AWS CLI and jq to be installed and configured.
  Your AWS account must have Cost Explorer enabled.
  Cost data typically has a 24-48 hour delay in AWS Cost Explorer.
EOF
}

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--days)
                DAYS="$2"
                shift 2
                ;;
            -g|--granularity)
                GRANULARITY="$2"
                if [[ "$GRANULARITY" != "DAILY" && "$GRANULARITY" != "MONTHLY" ]]; then
                    print_error "Invalid granularity: $GRANULARITY. Use DAILY or MONTHLY."
                    exit 1
                fi
                shift 2
                ;;
            -r|--region)
                REGION="$2"
                shift 2
                ;;
            -s|--stack)
                STACK_NAME="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

main() {
    print_header "SHELLMATE COST TRACKER"
    
    # Check prerequisites
    check_prerequisites
    
    # Set default values if not provided
    DAYS=${DAYS:-$DEFAULT_DAYS}
    GRANULARITY=${GRANULARITY:-$DEFAULT_GRANULARITY}
    
    # Calculate date range
    calculate_date_range "$DAYS"
    
    # Get resources from CloudFormation
    get_function_name
    get_model_id
    
    # Get invocation counts
    get_lambda_invocations
    get_bedrock_invocations
    
    # Get costs
    get_lambda_costs "$DAYS" "$GRANULARITY"
    get_bedrock_costs "$DAYS" "$GRANULARITY"
    get_api_costs "$DAYS" "$GRANULARITY"
    
    # Calculate per-call costs if we have invocation data
    if [ "$LAMBDA_INVOCATIONS" -gt 0 ]; then
        calculate_per_call_costs
    fi
    
    # Show total costs
    get_total_costs "$DAYS"
}

# Parse command line arguments
parse_args "$@"

# Run main function
main
