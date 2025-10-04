#!/usr/bin/env python3
"""
ShellMate Installation Script
Installs ShellMate with choice between Python or Bash implementation
"""

import os
import sys
import subprocess
import shutil
from pathlib import Path

def run_command(cmd, cwd=None):
    """Run a shell command and return success status"""
    print(f"Running: {cmd}")
    try:
        result = subprocess.run(cmd, shell=True, cwd=cwd, check=True)
        return result.returncode == 0
    except subprocess.CalledProcessError as e:
        print(f"Command failed with exit code {e.returncode}")
        return False

def check_python39():
    """Check if Python 3.9 is available"""
    try:
        result = subprocess.run(['python3.9', '--version'], 
                              capture_output=True, text=True)
        if result.returncode == 0:
            print(f"✓ Found: {result.stdout.strip()}")
            return True
    except FileNotFoundError:
        pass
    
    print("✗ Python 3.9 not found")
    return False

def show_python_install_instructions():
    """Show Python 3.9 installation instructions"""
    print("\nPython 3.9 is required for the Python version of ShellMate.")
    print("ShellMate is tested with Python 3.9, but newer versions may work.")
    print("\nTo install Python 3.9:")
    print("- Ubuntu/Debian: sudo apt install python3.9 python3.9-pip")
    print("- CentOS/RHEL: sudo yum install python39 python39-pip")
    print("- Fedora: sudo dnf install python3.9 python3.9-pip")
    print("- macOS: brew install python@3.9")
    print("\nAlternatively, choose the Bash version which only requires curl.")

def get_aws_config():
    """Get AWS configuration from deployed stack"""
    print("Checking for existing AWS deployment...")
    
    try:
        # Get API endpoint from CloudFormation
        result = subprocess.run([
            'aws', 'cloudformation', 'describe-stacks', 
            '--stack-name', 'shellmate-dev',
            '--region', 'us-east-1',
            '--query', 'Stacks[0].Outputs[?OutputKey==`ApiEndpoint`].OutputValue',
            '--output', 'text'
        ], capture_output=True, text=True)
        
        if result.returncode != 0 or not result.stdout.strip() or result.stdout.strip() == 'None':
            print("No ShellMate deployment found")
            return None
            
        endpoint = result.stdout.strip()
        print(f"✓ Found API endpoint: {endpoint}")
        
        # Get API key from API Gateway using multiple methods
        api_key = None
        
        # Method 1: Try to get API key by stack tag (most reliable)
        try:
            result = subprocess.run([
                'aws', 'apigateway', 'get-api-keys',
                '--region', 'us-east-1',
                '--include-values',
                '--output', 'json'
            ], capture_output=True, text=True)
            
            if result.returncode == 0:
                import json
                api_keys = json.loads(result.stdout)
                
                # Look for API key with shellmate stack tag
                for key_info in api_keys.get('items', []):
                    tags = key_info.get('tags', {})
                    if 'aws:cloudformation:stack-name' in tags and 'shellmate-dev' in tags['aws:cloudformation:stack-name']:
                        api_key = key_info.get('value')
                        break
                
                # Fallback: look for key by name pattern
                if not api_key:
                    for key_info in api_keys.get('items', []):
                        if 'shellmate' in key_info.get('name', '').lower():
                            api_key = key_info.get('value')
                            break
                
                # Last resort: use first available key
                if not api_key and api_keys.get('items'):
                    api_key = api_keys['items'][0].get('value')
                    
        except Exception as e:
            print(f"Warning: Could not parse API keys JSON: {e}")
        
        # Method 2: Fallback - try direct query by name
        if not api_key:
            result = subprocess.run([
                'aws', 'apigateway', 'get-api-keys',
                '--region', 'us-east-1',
                '--query', 'items[?name==`shellmate-dev-api-key`].value',
                '--output', 'text',
                '--include-values'
            ], capture_output=True, text=True)
            
            if result.returncode == 0 and result.stdout.strip() and result.stdout.strip() != 'None':
                api_key = result.stdout.strip()
        
        if api_key:
            print(f"✓ Found API key: {api_key[:8]}...")
            return {
                'SHELLMATE_API_ENDPOINT': endpoint,
                'SHELLMATE_API_KEY': api_key
            }
        else:
            print("⚠ Found endpoint but could not retrieve API key")
            return {
                'SHELLMATE_API_ENDPOINT': endpoint
            }
            
    except Exception as e:
        print(f"Error getting AWS config: {e}")
    
    return None

def create_config(config_data):
    """Create ShellMate configuration file"""
    config_dir = Path.home() / '.config' / 'shellmate'
    config_file = config_dir / 'config'
    
    # Create config directory
    config_dir.mkdir(parents=True, exist_ok=True)
    
    # Write config file
    with open(config_file, 'w') as f:
        f.write("# ShellMate Configuration\n")
        f.write("# Auto-generated by installation script\n\n")
        
        for key, value in config_data.items():
            f.write(f'export {key}="{value}"\n')
    
    print(f"✓ Configuration saved to: {config_file}")
    return True

def install_script(script_type):
    """Install the chosen script type"""
    script_dir = Path(__file__).parent
    
    if script_type == 'python':
        source_file = script_dir / 'src' / 'shellmate.py'
        target_name = 'shellmate-py'
    else:  # bash
        source_file = script_dir / 'src' / 'shellmate.sh'
        target_name = 'shellmate-sh'
    
    if not source_file.exists():
        print(f"Error: Source file not found: {source_file}")
        return False
    
    # Install to /usr/local/bin
    target_file = Path('/usr/local/bin') / target_name
    
    print(f"Installing {script_type} version to {target_file}...")
    
    # Copy file
    cmd = f"sudo cp {source_file} {target_file}"
    if not run_command(cmd):
        print("Installation failed")
        return False
    
    # Make executable
    cmd = f"sudo chmod +x {target_file}"
    if not run_command(cmd):
        print("Failed to make executable")
        return False
    
    # Create symlink as 'shellmate'
    symlink_path = Path('/usr/local/bin') / 'shellmate'
    cmd = f"sudo ln -sf {target_file} {symlink_path}"
    if run_command(cmd):
        print(f"✓ {script_type.title()} version installed successfully!")
        print(f"✓ Available as: shellmate, {target_name}")
        return True
    else:
        print("Failed to create symlink, but script is installed")
        print(f"You can run it as: {target_name}")
        return True

def setup_shell_integration():
    """Set up shell integration"""
    # Check which binaries are available
    available_binaries = []
    
    if Path('/usr/local/bin/shellmate-py').exists() or shutil.which('shellmate-py'):
        available_binaries.append('shellmate-py')
    if Path('/usr/local/bin/shellmate-sh').exists() or shutil.which('shellmate-sh'):
        available_binaries.append('shellmate-sh')
    
    # Generate function calls based on available binaries
    if len(available_binaries) == 0:
        # No binaries found - this shouldn't happen but handle gracefully
        function_calls = 'result=$(echo "No ShellMate binaries found" >&2; exit 1)'
    elif len(available_binaries) == 1:
        # Only one binary available - call it directly
        function_calls = f'result=$({available_binaries[0]} --seamless "$@" 2>"$error_output")'
    else:
        # Multiple binaries available - use fallback logic
        calls = ' || '.join([f'{binary} --seamless "$@" 2>"$error_output"' for binary in available_binaries])
        function_calls = f'result=$({calls})'
    
    # Load shared shell function template
    script_dir = Path(__file__).parent
    template_file = script_dir / 'shell-function-template.sh'
    
    if template_file.exists():
        shell_function = template_file.read_text().replace('SHELLMATE_FUNCTION_CALLS', function_calls)
    else:
        # Fallback to inline template if shared file doesn't exist
        shell_function = f'''
# ShellMate configuration
if [[ -f ~/.config/shellmate/config ]]; then
    source ~/.config/shellmate/config
fi

# ShellMate shell integration
shellmate() {{
    # Check which shell we're using for proper command execution
    if [[ -n "$ZSH_VERSION" ]]; then
        # ZSH: Use print -z to pre-populate input buffer
        local result exit_code
        {function_calls}
        exit_code=$?
        if [[ $exit_code -eq 0 && -n "$result" ]]; then
            print -z "$result"
        else
            echo "Failed to get command from ShellMate" >&2
            return 1
        fi
    elif [[ -n "$BASH_VERSION" ]]; then
        # BASH: Use read with pre-populated input
        local result exit_code
        {function_calls}
        exit_code=$?
        if [[ $exit_code -eq 0 && -n "$result" ]]; then
            local cmd
            read -e -i "$result" cmd
            if [[ -n "$cmd" ]]; then
                eval "$cmd"
            fi
        else
            echo "Failed to get command from ShellMate" >&2
            return 1
        fi
    else
        # Fallback for other shells
        local result exit_code
        {function_calls}
        exit_code=$?
        if [[ $exit_code -eq 0 && -n "$result" ]]; then
            echo "Generated: $result"
            echo "Copy and paste to execute"
        else
            echo "Failed to get command from ShellMate" >&2
            return 1
        fi
    fi
}}
'''
    
    # Add to shell config files
    shell_files = [
        Path.home() / '.bashrc',
        Path.home() / '.zshrc'
    ]
    
    updated_files = []
    for shell_file in shell_files:
        if shell_file.exists():
            # Check if already added
            content = shell_file.read_text()
            if 'ShellMate shell integration' not in content:
                with open(shell_file, 'a') as f:
                    f.write('\n' + shell_function)
                print(f"✓ Added shell integration to {shell_file}")
                updated_files.append(shell_file.name)
    
    if updated_files:
        print("✓ Shell integration complete. Restart your shell or run:")
        for file_name in updated_files:
            print(f"  source ~/{file_name}")
    else:
        print("✓ Shell integration already configured")

def main():
    print("ShellMate Installation Script")
    print("=" * 40)
    
    # Check if AWS is configured
    aws_config = get_aws_config()
    if not aws_config or 'SHELLMATE_API_ENDPOINT' not in aws_config:
        print("⚠ AWS ShellMate stack not found or not configured.")
        print("Please run './shellmate.sh deploy' first to set up AWS infrastructure.")
        
        # Allow manual configuration
        endpoint = input("Enter API endpoint (or press Enter to skip): ").strip()
        api_key = input("Enter API key (or press Enter to skip): ").strip()
        
        if endpoint:
            aws_config = {'SHELLMATE_API_ENDPOINT': endpoint}
            if api_key:
                aws_config['SHELLMATE_API_KEY'] = api_key
        else:
            print("Skipping configuration setup.")
            aws_config = {}
    
    # Choose implementation
    print("\nChoose ShellMate implementation:")
    print("1. Python (requires Python 3.9)")
    print("2. Bash (requires bash shell + curl, works on most Linux systems)")
    print("3. Both (install both versions)")
    
    while True:
        choice = input("Enter choice (1/2/3): ").strip()
        if choice in ['1', '2', '3']:
            break
        print("Please enter 1, 2, or 3")
    
    success = True
    
    if choice in ['1', '3']:  # Python version
        print("\n" + "=" * 40)
        print("Installing Python version...")
        
        if not check_python39():
            show_python_install_instructions()
            print("\nSkipping Python version installation.")
            if choice == '1':
                success = False
        else:
            success = install_script('python')
    
    if choice in ['2', '3']:  # Bash version
        print("\n" + "=" * 40)
        print("Installing Bash version...")
        
        # Check for curl
        if not shutil.which('curl'):
            print("Error: curl is required for the Bash version")
            print("Please install curl: sudo apt install curl")
            success = False
        else:
            success = install_script('bash') and success
    
    # Create configuration
    if success and aws_config:
        print("\n" + "=" * 40)
        print("Setting up configuration...")
        create_config(aws_config)
    
    # Set up shell integration
    if success:
        print("\n" + "=" * 40)
        print("Setting up shell integration...")
        setup_shell_integration()
    
    # Final status
    print("\n" + "=" * 40)
    if success:
        print("✓ Installation completed successfully!")
        print("\nUsage:")
        print('  shellmate "list all python files"')
        print('  shellmate --help')
        print("\nRestart your shell to use the new shellmate command")
    else:
        print("✗ Installation failed")
        return 1
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
