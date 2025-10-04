# ShellMate Implementation Details

## 🏗️ Architecture Overview

ShellMate consists of three main components:

1. **AWS Infrastructure** (CloudFormation + Lambda + API Gateway)
2. **Local Binary** (Python or Bash implementation)
3. **Shell Integration** (Seamless shell function)

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Shell Query   │───▶│   Local Binary   │───▶│  AWS Lambda    │
│ "list py files" │    │ (Python or Bash) │    │ (Claude 3 Haiku)│
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                │                        │
                                ▼                        ▼
                       ┌──────────────────┐    ┌─────────────────┐
                       │ Shell Function   │◀───│   API Gateway   │
                       │ (Pre-populate)   │    │ (Rate Limiting) │
                       └──────────────────┘    └─────────────────┘
```

## 🔧 AWS Infrastructure

### CloudFormation Template (`aws/template.yaml`)

**Key Resources:**
- **Lambda Function**: Processes queries using AWS Bedrock
- **API Gateway**: REST API with rate limiting and API key authentication
- **Usage Plan**: 50 req/sec, 100 burst, 5000/day limit

**Model Configuration:**
- **Model**: `anthropic.claude-3-haiku-20240307-v1:0` (fast, cost-effective)
- **Max Tokens**: 200 (sufficient for shell commands)
- **Temperature**: 0.1 (deterministic output)
- **Timeout**: 30 seconds

**Rate Limiting:**
- **API Gateway**: 50 requests/second, 100 burst, 5000/day
- **Bedrock Quotas**: Claude 3 Haiku has excellent quota limits
  - **Default**: 50 requests/minute for Claude 3 Haiku
  - **Throttling**: Standard exponential backoff (2s, 4s, 8s, 16s, 32s delays)

### Lambda Function (`aws/lambda_function.py`)

**Enhanced Retry Logic:**
```python
# 5 retries with 2-second base delay
# Different handling for different error types:
# - ThrottlingException: Aggressive exponential backoff
# - ValidationException: No retry (immediate failure)
# - Other errors: Shorter retry delays
```

**System Prompt:**
- Optimized for safe, portable Unix/Linux commands
- Returns only the command (no explanations)
- Includes safety flags when appropriate
- Handles ambiguous requests with common interpretations

## 💻 Local Implementations

### Python Version (`src/shellmate.py`)

**Features:**
- Full JSON parsing with `json` module
- Robust HTTP handling with `urllib3`
- Comprehensive error handling
- Rich command-line interface with `argparse`
- Configuration file support

**Dependencies:**
- Python 3.9+
- `urllib3` (HTTP requests)
- `json` (built-in)

### Bash Version (`src/shellmate.sh`)

**Features:**
- Pure bash implementation (no external dependencies except `curl`)
- Basic JSON parsing without `jq` (fallback included)
- Minimal but functional
- Works on any system with bash + curl

**Dependencies:**
- Bash 4.0+
- `curl` (HTTP requests)
- `jq` (optional, for better JSON parsing)

## 🔗 Shell Integration

### Shell Function Template (`shell-function-template.sh`)

**Key Features:**
- **Auto-detection**: Detects ZSH vs Bash vs other shells
- **Pre-population**: Uses `print -z` (ZSH) or `read -e -i` (Bash)
- **Error Handling**: Graceful fallback and user-friendly error messages
- **Debug Control**: `SHELLMATE_DEBUG=1` for troubleshooting

**ZSH Integration:**
```bash
print -z "$result"  # Pre-populates command line buffer
```

**Bash Integration:**
```bash
read -e -i "$result" cmd  # Pre-populates readline buffer
eval "$cmd"               # Executes user-confirmed command
```

**Debug Mode:**
```bash
export SHELLMATE_DEBUG=1  # Enable debug output
unset SHELLMATE_DEBUG     # Disable debug output
```

## 📁 Directory Structure

```
shellmate/
├── README.md                    # Barebones user guide
├── FAQ.md                       # Troubleshooting & detailed usage
├── IMPLEMENTATION.md            # This file - technical details
├── shellmate-installer.sh       # Main Unified management script
├── install.py                   # Local binary installer
├── shell-function-template.sh   # Shared shell integration template
├── debug-shell-issue.sh         # Debug script for shell function issues
├── src/
│   ├── shellmate.py             # Python implementation
│   └── shellmate.sh             # Bash implementation (no colors)
├── aws/
│   ├── template.yaml            # CloudFormation template
│   └── lambda_function.py       # AWS Lambda handler
└── python-build/                # Build output directory
    └── shellmate                # Compiled Python binary
```

## 🔐 Security & Configuration

### API Key Management

**Storage:**
- Configuration stored in `~/.config/shellmate/config`
- File permissions set to `600` (user read/write only)
- API key masked in status displays

**Retrieval:**
- Auto-detection from CloudFormation outputs
- Fallback to API Gateway key listing
- Manual configuration if auto-detection fails

### Rate Limiting

**API Gateway Limits:**
- 50 requests/second per API key
- 100 burst capacity
- 5000 requests/day quota

**Lambda Retry Logic:**
- 5 retry attempts with exponential backoff
- Different strategies for different error types
- Detailed logging for troubleshooting

## 🧪 Testing & Debugging

### Debug Tools

**Debug Script (`debug-shell-issue.sh`):**
- Tests Python version directly
- Tests shell function with debug output
- Compares results to identify issues
- Checks for ANSI escape sequences

**Debug Control:**
```bash
export SHELLMATE_DEBUG=1    # Enable debug mode
./debug-shell-issue.sh "test query"
```

**Management Commands:**
```bash
./shellmate-installer.sh status    # System status
./shellmate-installer.sh logs      # Lambda logs
./shellmate-installer.sh api-key   # API credentials
```

### Common Issues & Solutions

**Shell Function Issues:**
- **Cause**: Complex shell integration, terminal settings
- **Fix**: Simplified error handling, better debug output
- **Debug**: Use `debug-shell-issue.sh` script

**API Connectivity:**
- **Cause**: Wrong endpoint, API key, or AWS configuration
- **Fix**: Make sure you have Isengard creds. Use `./shellmate-installer.sh api-key` to verify
- **Debug**: Test with `curl` directly

## 🚀 Deployment Options

### Single Machine
```bash
./shellmate-installer.sh deploy    # Deploy AWS
./shellmate-installer.sh install   # Install locally
```

### Multi-Machine
```bash
# Machine 1 (primary)
./shellmate-installer.sh deploy    # Deploy AWS once
./shellmate-installer.sh install   # Install locally

# Machine 2, 3, etc.
./shellmate-installer.sh install   # Auto-detects existing AWS
```

### Different Versions per Machine
```bash
# Server 1: Python version (full features)
./shellmate-installer.sh install   # Choose Python

# Server 2: Bash version (minimal deps)
./shellmate-installer.sh install   # Choose Bash

# Dev machine: Both versions
./shellmate-installer.sh install   # Choose Both
```

## 📊 Performance & Costs

### Typical Performance
- **Cold start**: 2-3 seconds (first request)
- **Warm requests**: 200-500ms
- **Rate limit**: 50 requests/second

### Cost Estimates (Monthly)
- **Lambda**: $0.50-2.00 (depends on usage)
- **API Gateway**: $1.00-3.00 (per million requests)
- **Bedrock**: $2.00-10.00 (depends on query complexity)
- **Total**: ~$5-15/month for typical usage

### Optimization
- **Model**: Claude 3.5 Sonnet v1 (stable, cost-effective)
- **Tokens**: Limited to 200 max tokens (sufficient for commands)
- **Caching**: API Gateway caching disabled (commands are unique)
- **Retry**: Intelligent backoff prevents unnecessary calls

## 🔧 Customization

### Model Configuration
Edit `aws/template.yaml` to change:
- Model ID (different Claude versions)
- Token limits
- Temperature settings
- Timeout values

### Rate Limits
Edit `ApiConfig` mapping in `aws/template.yaml`:
```yaml
ApiConfig:
  RateLimit:
    Requests: 50      # Requests per second
    Burst: 100        # Burst capacity
    Daily: 5000       # Daily quota
```

### System Prompt
Edit `aws/lambda_function.py` to customize the AI behavior:
```python
system_prompt = """Your custom instructions here..."""
```

## 🔄 Update Process

### Code Updates
```bash
git pull                           # Get latest code
./shellmate-installer.sh deploy   # Update AWS infrastructure
./shellmate-installer.sh install  # Update local binaries
```

### Configuration Changes
```bash
# Edit aws/template.yaml for infrastructure changes
./shellmate-installer.sh deploy   # Apply changes

# Edit ~/.config/shellmate/config for local changes
source ~/.config/shellmate/config # Reload config
```

## 🗑️ Cleanup & Uninstall

### Complete Removal
```bash
./shellmate-installer.sh destroy    # Remove AWS (PERMANENT!)
./shellmate-installer.sh uninstall  # Remove local installation
```

### Manual Shell Config Cleanup
If uninstaller leaves remnants, manually remove from `~/.bashrc` or `~/.zshrc`:
1. `# ShellMate configuration`
2. `source ~/.config/shellmate/config`
3. `shellmate()` function (multi-line)
4. `_shellmate_debug_result()` function
5. `_shellmate_handle_error()` function
6. Any lines containing 'shellmate' or 'ShellMate'

### Verification
```bash
which shellmate                    # Should return nothing
ls -la /usr/local/bin/shellmate*   # Should be empty
ls -la ~/.config/shellmate/        # Should not exist
