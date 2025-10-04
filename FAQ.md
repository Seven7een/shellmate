# ShellMate FAQ

## 📦 Installation

### Q: How do I install ShellMate completely (AWS + Local)?
```bash
# Complete setup - deploys AWS infrastructure and installs locally
./shellmate-installer.sh deploy              # 1. Deploy AWS infrastructure
./shellmate-installer.sh install             # 2. Choose and install implementation

# Verify installation
./shellmate-installer.sh status              # Check everything is working
shellmate "test query"                       # Test end-to-end
```

### Q: Installation options
- **Standard installation**: Simple setup with bash implementation
- **Custom installation**: Manual configuration options available

### Q: How do I use ShellMate?
```bash
# Basic usage:
shellmate "query"                  # Use ShellMate to generate a command
shellmate-sh "query"               # Direct access to bash implementation
```

### Q: How do I install on a new machine (AWS already exists)?
```bash
# On new machine, clone repo and install
git clone <your-shellmate-repo>
cd shellmate
./shellmate-installer.sh install             # Auto-detects existing AWS deployment

# Or get API credentials from machine that deployed AWS
# On original machine: ./shellmate-installer.sh api-key
# Then install and manually configure if auto-detection fails
```

## 🗑️ Uninstallation

### Q: How do I uninstall everything (AWS + Local)?
```bash
# Complete removal - removes everything
./shellmate-installer.sh destroy             # 1. Delete AWS resources (PERMANENT!)
./shellmate-installer.sh uninstall           # 2. Remove local installation
```

### Q: How do I remove local installation but keep AWS running?
```bash
# Remove from current machine, keep AWS for other machines
./shellmate-installer.sh uninstall           # Remove binaries + config + shell integration

# AWS stays running, get credentials for new machine with:
./shellmate-installer.sh api-key             # Run this before uninstalling
```

## 🔧 Setup Issues

### Q: "AWS CLI not configured" error
```bash
aws configure
# Enter your AWS Access Key ID, Secret Key, Region (us-east-1), and output format (json)
```

### Q: "Bedrock access denied" error
1. Go to AWS Console → Bedrock → Model access
2. Click "Request model access" 
3. Enable Claude models (usually instant approval)

### Q: "Bedrock throttling" or quota exceeded errors
**Problem**: You're hitting Bedrock service quotas, though this is rare with Claude 3 Haiku.

**Solution**: If you encounter throttling:
1. Wait a few minutes and try again (ShellMate has built-in retry logic)
2. If persistent, check **AWS Console → Service Quotas → Amazon Bedrock**
3. Look for "Claude 3 Haiku" quotas and request increases if needed
4. Justification: "AI-powered shell command generation tool for development productivity"

**Note**: Claude 3 Haiku typically has generous quotas (20+ requests/minute) and should work smoothly for most users.

### Q: "SAM CLI not found" error
```bash
pip install aws-sam-cli
```

### Q: "curl not found" error (Bash version)
```bash
# Ubuntu/Debian
sudo apt install curl

# CentOS/RHEL
sudo yum install curl

# macOS
curl is pre-installed
```

## 🚀 Usage Issues

### Q: "API endpoint not set" error
```bash
./shellmate-installer.sh api-key              # Shows your API key
./shellmate-installer.sh install              # Reinstall to fix config
```

### Q: "HTTP 403" error
Your API key may be wrong. Run `./shellmate-installer.sh api-key` to get the correct one.

### Q: "HTTP 429" error
Rate limit exceeded. Wait a few minutes and try again.

### Q: Command not found after installation
```bash
# Check installation
./shellmate-installer.sh status

# Restart your shell
source ~/.bashrc   # or ~/.zshrc

# Check if binaries exist
ls -la /usr/local/bin/shellmate*
```

## 🔍 Troubleshooting

### Q: "Failed to get command from ShellMate" error

This error means ShellMate can't connect to or get a response from the AWS API. Follow these debug steps:

**Step 1: Check installation**
```bash
which shellmate                    # Should show: /usr/local/bin/shellmate
shellmate --help                  # Should show help text
ls -la /usr/local/bin/shellmate*   # Check what's installed
```

**Step 2: Check configuration**
```bash
./shellmate-installer.sh status              # Check overall system status
cat ~/.config/shellmate/config     # Check config file exists and has values
```

**Step 3: Test AWS connectivity**
```bash
./shellmate-installer.sh api-key             # Get current API endpoint and key
curl -X POST "YOUR_API_ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: YOUR_API_KEY" \
  -d '{"query":"test"}'             # Replace with actual endpoint/key
```

**Step 4: Test the implementation**
```bash
# Test Bash version directly  
shellmate-sh --seamless "test query"
```

**Step 5: Check AWS infrastructure**
```bash
aws cloudformation describe-stacks --stack-name shellmate-dev --region us-east-1
aws apigateway get-api-keys --region us-east-1 --include-values
```

**Step 6: Check Lambda logs**
```bash
./shellmate-installer.sh logs                # View recent Lambda execution logs
```

### Q: Shell function issues (ANSI escape sequences, weird characters)

**Debug Control:**
```bash
# Turn debug ON
export SHELLMATE_DEBUG=1
shellmate "your query"             # Shows debug output

# Turn debug OFF
unset SHELLMATE_DEBUG
```

**Debug Script:**
```bash
./debug-shell-issue.sh "list python files"
```

This will show you exactly where any ANSI escape sequences are coming from.

**Common fixes:**
- All color codes have been removed from `src/shellmate.sh`
- Check your ZSH configuration for plugins that might affect `print -z`
- Check terminal settings for ANSI sequence handling

## ⚙️ Management

### Q: What AI model does ShellMate use?
ShellMate uses Claude 3 Haiku, which provides fast, reliable command generation with excellent quota limits and cost-effectiveness.

### Q: How do I check costs?
Check your AWS billing dashboard. Typical usage is under $5/month.

### Q: How do I update ShellMate?
```bash
git pull                           # Get updates
./shellmate-installer.sh deploy    # Update AWS infrastructure
./shellmate-installer.sh install   # Update local installation
```

### Q: How do I check system status?
```bash
./shellmate-installer.sh status              # Overall system status
./shellmate-installer.sh api-key             # API credentials
./shellmate-installer.sh logs                # Recent Lambda logs
```

## 🏠 Multi-Machine Setup

### Q: Can I use ShellMate on multiple machines?
Yes! Deploy AWS once, then install on each machine:

```bash
# Machine 1 (deploy AWS)
./shellmate-installer.sh deploy              # Deploy AWS infrastructure
./shellmate-installer.sh install             # Install locally

# Machine 2, 3, etc. (install only)  
git clone <repo> && cd shellmate
./shellmate-installer.sh install             # Auto-detects existing AWS deployment
```

### Q: Can I install ShellMate on multiple machines?
Absolutely! Install it on as many machines as you need:

```bash
# All machines can use the same AWS infrastructure
# Just run the installer on each machine:
./shellmate-installer.sh install
```

## 📋 Usage Examples

### Basic Queries
```bash
shellmate "list all python files older than 5 days"
shellmate "show disk usage"
shellmate "find large files bigger than 100MB"
shellmate "count lines in all text files"
shellmate "show running processes"
shellmate "find files modified today"
```

### Command Options
```bash
shellmate --seamless "query"       # Output command to stdout (for scripting)
shellmate --help                   # Show help
```

### Management Commands
```bash
./shellmate-installer.sh deploy              # Deploy AWS infrastructure  
./shellmate-installer.sh install             # Install ShellMate (choose Python/Bash)
./shellmate-installer.sh status              # Check system status
./shellmate-installer.sh api-key             # Show API key and endpoint
./shellmate-installer.sh destroy             # Remove AWS resources
./shellmate-installer.sh help                # Show all commands
```

### Testing & Monitoring
```bash
./shellmate-installer.sh test "your query"   # Test without deploying
./shellmate-installer.sh logs                # View AWS Lambda logs
```

## 🔧 Manual Cleanup (Uninstall Issues)

If the uninstaller leaves remnants in your shell config, manually remove these lines from `~/.bashrc` or `~/.zshrc`:

1. The line: `# ShellMate configuration`
2. The line: `source ~/.config/shellmate/config`
4. The entire `_shellmate_debug_result()` function (if present)
5. The entire `_shellmate_handle_error()` function (if present)
6. Any other lines containing 'shellmate' or 'ShellMate'

After editing, restart your shell: `exec $SHELL`
