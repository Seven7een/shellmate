#!/usr/bin/env python3.9
"""
ShellMate - AI-powered natural language to shell command converter
Python implementation using only standard library modules
"""

import argparse
import json
import os
import readline
import sys
import urllib.request
from urllib.error import URLError, HTTPError


class ShellMate:
    def __init__(self, api_endpoint=None, api_key=None):
        self.api_endpoint = api_endpoint or os.environ.get('SHELLMATE_API_ENDPOINT')
        self.api_key = api_key or os.environ.get('SHELLMATE_API_KEY')
        
        if not self.api_endpoint:
            print("Error: SHELLMATE_API_ENDPOINT environment variable not set", file=sys.stderr)
            sys.exit(1)

    def query_ai(self, natural_language_query):
        """Send natural language query to AWS AI service"""
        try:
            # Prepare the request data
            data = {
                'query': natural_language_query,
                'context': {
                    'os': os.name,
                    'cwd': os.getcwd()
                }
            }
            
            # Convert to JSON
            json_data = json.dumps(data).encode('utf-8')
            
            # Create request
            headers = {'Content-Type': 'application/json'}
            if self.api_key:
                headers['X-API-Key'] = self.api_key
                
            req = urllib.request.Request(
                self.api_endpoint,
                data=json_data,
                headers=headers
            )
            
            # Send request
            with urllib.request.urlopen(req, timeout=30) as response:
                result = json.loads(response.read().decode('utf-8'))
                return result.get('command', '')
                
        except HTTPError as e:
            print(f"HTTP Error {e.code}: {e.reason}", file=sys.stderr)
            return None
        except URLError as e:
            print(f"URL Error: {e.reason}", file=sys.stderr)
            return None
        except json.JSONDecodeError as e:
            print(f"JSON Error: {e}", file=sys.stderr)
            return None
        except Exception as e:
            print(f"Unexpected error: {e}", file=sys.stderr)
            return None

    def execute_command(self, command, show_prompt=None):
        """Load the generated command into the user's shell for interactive execution"""
        if not command:
            print("No command generated", file=sys.stderr)
            return False
            
        print(f"Generated command: {command}")
        
        # Check if we should show the prompt (configurable via environment)
        if show_prompt is None:
            show_prompt = os.environ.get('SHELLMATE_SHOW_PROMPT', 'true').lower() in ('true', '1', 'yes')
        
        # Get the user's shell prompt character
        shell_name = os.path.basename(os.environ.get('SHELL', '/bin/bash'))
        prompt_char = "$ " if shell_name in ('bash', 'sh') else "% " if shell_name == 'zsh' else "$ "
        
        try:
            # Pre-populate readline with the command
            def pre_input_hook():
                readline.insert_text(command)
                readline.redisplay()
            
            # Set up the hook
            readline.set_pre_input_hook(pre_input_hook)
            
            # Show optional prompt message
            if show_prompt:
                print("Press Enter to execute, or Ctrl+C to cancel:")
            
            # Get user input with pre-populated command
            user_command = input(prompt_char)
            
            # Clear the hook
            readline.set_pre_input_hook(None)
            
            if user_command.strip():
                # Execute the command using os.system to run in native shell
                result = os.system(user_command)
                return result == 0
            else:
                print("No command to execute")
                return False
                
        except (KeyboardInterrupt, EOFError):
            print("\nCommand cancelled")
            # Clear the hook in case of interruption
            try:
                readline.set_pre_input_hook(None)
            except:
                pass
            return False
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)
            try:
                readline.set_pre_input_hook(None)
            except:
                pass
            return False

    def run(self, query, seamless=False):
        """Main execution method"""
        # Get command from AI
        command = self.query_ai(query)
        
        if not command:
            if not seamless:
                print("Failed to get command from AI service", file=sys.stderr)
            return False
            
        if seamless:
            # In seamless mode, output the command to stdout
            # Double escape any backslashes in regex patterns for the shell command substitution
            # This ensures the shell gets the command with the right number of escapes
            command = command.replace('\\', '\\\\')
            print(command)
            return True
        else:
            # Check if we should show verbose output
            show_prompt = os.environ.get('SHELLMATE_SHOW_PROMPT', 'true').lower() in ('true', '1', 'yes')
            
            if show_prompt:
                print(f"Query: {query}")
            
            return self.execute_command(command)


def main():
    parser = argparse.ArgumentParser(
        description="Convert natural language to shell commands using AI",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  shellmate "list all python files older than 5 days"
  shellmate list all python files older than 5 days
  shellmate "find large files in home directory"
  shellmate show disk usage
  
Environment Variables:
  SHELLMATE_API_ENDPOINT  - AWS API Gateway endpoint URL
  SHELLMATE_API_KEY       - API key for authentication (optional)
        """
    )
    
    parser.add_argument('query', nargs='*',
                       help='Natural language query to convert to shell command')
    parser.add_argument('--seamless', '-s',
                       action='store_true',
                       help='Output command to stdout for shell function integration')
    
    args = parser.parse_args()
    
    # Handle multiple arguments as a single query (like the shell version)
    if not args.query:
        parser.error("No query provided. Use --help for usage information.")
    
    # Join all query arguments into a single string
    query = ' '.join(args.query)
    
    # Create ShellMate instance
    shellmate = ShellMate()
    
    # Run the query
    success = shellmate.run(
        query=query,
        seamless=args.seamless
    )
    
    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()
