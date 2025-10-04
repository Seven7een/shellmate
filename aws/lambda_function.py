import json
import boto3
import logging
import os
import time
from typing import Dict, Any
from botocore.exceptions import ClientError

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize Bedrock client
bedrock = boto3.client('bedrock-runtime')

# Get model ID from environment variable
MODEL_ID = os.environ.get('MODEL_ID', 'anthropic.claude-3-haiku-20240307-v1:0')

def lambda_handler(event: Dict[str, Any], context) -> Dict[str, Any]:
    """
    AWS Lambda handler for converting natural language to shell commands
    """
    
    try:
        # Parse the request body
        if 'body' in event:
            body = json.loads(event['body']) if isinstance(event['body'], str) else event['body']
        else:
            body = event
            
        query = body.get('query', '').strip()
        user_context = body.get('context', {})
        
        if not query:
            return {
                'statusCode': 400,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({
                    'error': 'Query parameter is required'
                })
            }
        
        logger.info(f"Processing query: {query}")
        
        # Generate shell command using AI
        command = generate_shell_command(query, user_context)
        
        if not command:
            return {
                'statusCode': 500,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({
                    'error': 'Failed to generate shell command'
                })
            }
        
        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'command': command,
                'query': query
            })
        }
        
    except Exception as e:
        logger.error(f"Error processing request: {str(e)}")
        return {
            'statusCode': 500,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'error': 'Internal server error'
            })
        }


def generate_shell_command(query: str, context: Dict[str, Any]) -> str:
    """
    Generate shell command using AWS Bedrock Claude model
    """
    
    # Create the prompt for the AI model
    system_prompt = """You are an elite Linux/Unix systems engineer with decades of experience. 
Your task is to convert natural language requests into precise, efficient shell commands.

CORE RULES:
1. Return ONLY the shell command - no explanations, comments, or markdown
2. Optimize for command conciseness while maintaining clarity
3. Default to using relative paths unless absolute paths are explicitly requested
4. Never include placeholders like <filename> - make sensible assumptions instead
5. Use POSIX-compliant commands when possible for maximum portability
6. Use the right tool for each job: 'ls' for simple listings, 'find' for complex file searches
7. Double-check that all commands, especially with pipes and semicolons, are syntactically correct
8. Use simple, standard commands that most users would recognize rather than complex regexes

TECHNICAL GUIDELINES:
1. Safety first - use flags like -i for rm/mv to prevent data loss
2. Quote variables and filenames to handle spaces and special characters properly
3. For user-specific variables, use shell expansions (e.g., $HOME, $(whoami), $(pwd))
4. Default to human-readable output formats (-h, --human-readable) when applicable
5. Use command combinations (pipes, redirects, subshells) efficiently
6. ALWAYS properly escape regex special characters (., *, $, etc.) with backslash in grep
7. Double-escape backslashes in grep patterns (e.g., "\\\\." not "\\." for a literal dot)
8. Handle error cases with reasonable defaults (e.g., || echo "Not found")
9. For distribution-specific commands, prefer the most widely available version
10. Use short flags (-a) for common options, long flags (--all) for clarity when needed
11. For privileged operations, include sudo only when absolutely necessary
12. Understand that in Unix/Linux, hidden files are simply files beginning with a dot (.), not a special type

UNIX/LINUX CONCEPTS:
- Hidden files are simply files that begin with a dot (.) - use 'ls -a' or 'ls -d .*' to view them
- File permissions use the rwx format (read, write, execute) for user, group, and others
- Wildcards: * matches any number of characters, ? matches a single character
- Special directories: . (current dir), .. (parent dir), ~ (home dir), / (root)

COMMON COMMAND TYPES:

FILE OPERATIONS:
Input: "list all files"
Output: ls -la

Input: "list only text files"
Output: find . -name "*.txt" -type f

Input: "list hidden files"
Output: ls -d .*

Input: "find all mp3 files larger than 50MB modified in the last week"
Output: find . -name "*.mp3" -size +50M -mtime -7

Input: "rename all txt files to md"
Output: for file in *.txt; do mv "$file" "${file%.txt}.md"; done

FILE CONTENT:
Input: "count lines with errors in system log"
Output: grep -i error /var/log/syslog | wc -l

Input: "replace foo with bar in all python files"
Output: find . -name "*.py" -exec sed -i 's/foo/bar/g' {} \;

FILE SIZE & DISK USAGE:
Input: "find large files"
Output: find . -type f -size +10M

Input: "show large files with sizes"
Output: du -sh * | sort -hr | head -10

Input: "check disk usage of each directory in /var"
Output: du -h --max-depth=1 /var | sort -hr

NETWORKING:
Input: "check if port 8080 is open"
Output: nc -zv localhost 8080 2>&1 || echo "Port closed"

Input: "download file and show progress"
Output: wget -O- --progress=dot https://example.com/file

ARCHIVE & COMPRESSION:
Input: "compress logs folder into tar.gz"
Output: tar -czf logs.tar.gz logs/

Input: "extract tar.gz archive"
Output: tar -xzf archive.tar.gz

TEXT PROCESSING:
Input: "sort csv file by second column numerically"
Output: sort -t, -k2,2n file.csv

Input: "show unique IP addresses in access log"
Output: grep -oE '\\b([0-9]{1,3}\\.){3}[0-9]{1,3}\\b' access.log | sort | uniq
"""

    user_prompt = f"""Convert this natural language request to a shell command:

Request: {query}

Context:
- Operating System: {context.get('os', 'posix')}
- Current Directory: {context.get('cwd', '.')}

Shell command:"""

    try:
        # Use model from environment variable
        model_id = MODEL_ID
        logger.info(f"Using model: {model_id}")
        
        # Prepare the request for Bedrock
        request_body = {
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 200,
            "system": system_prompt,
            "messages": [
                {
                    "role": "user",
                    "content": user_prompt
                }
            ],
            "temperature": 0.1,
            "top_p": 0.9
        }
        
        # Call Bedrock with enhanced retry logic for Claude 3 Haiku (50 requests/minute)
        max_retries = 5  # Standard retries for better quota
        base_delay = 2   # Start with 2 seconds for Bedrock
        
        for attempt in range(max_retries + 1):
            try:
                start_time = time.time()
                response = bedrock.invoke_model(
                    modelId=model_id,
                    body=json.dumps(request_body),
                    contentType='application/json'
                )
                
                # Log successful call timing
                duration = time.time() - start_time
                logger.info(f"Bedrock call succeeded in {duration:.2f}s on attempt {attempt + 1}")
                break  # Success, exit retry loop
                
            except ClientError as e:
                error_code = e.response['Error']['Code']
                error_message = e.response['Error'].get('Message', '')
                
                logger.warning(f"Bedrock attempt {attempt + 1}/{max_retries + 1} failed: {error_code} - {error_message}")
                
                # Handle different types of throttling and errors
                if error_code in ['ThrottlingException', 'TooManyRequestsException', 'ServiceQuotaExceededException'] and attempt < max_retries:
                    # Exponential backoff for Bedrock throttling (50 requests/minute = ~1.2 seconds between requests)
                    delay = base_delay * (2 ** attempt) + (time.time() % 0.5)  # 2s, 4s, 8s, 16s, 32s with jitter
                    logger.info(f"Bedrock throttled, waiting {delay:.2f}s before retry {attempt + 2}...")
                    time.sleep(delay)
                elif error_code == 'ValidationException':
                    # Don't retry validation errors
                    logger.error(f"Bedrock validation error: {error_message}")
                    raise
                elif attempt < max_retries:
                    # Retry other errors with shorter delay
                    delay = 1 + (attempt * 0.5)  # 1s, 1.5s, 2s, 2.5s, 3s
                    logger.info(f"Retrying Bedrock call in {delay:.2f}s...")
                    time.sleep(delay)
                else:
                    # Max retries exceeded
                    logger.error(f"Bedrock call failed after {max_retries + 1} attempts: {error_code}")
                    raise
        
        # Parse the response
        response_body = json.loads(response['body'].read())
        
        # Extract the command from the response
        command = response_body['content'][0]['text'].strip()
        
        # Clean up the command (remove any extra formatting)
        command = command.replace('```bash', '').replace('```', '').strip()
        
        logger.info(f"Generated command: {command}")
        return command
        
    except Exception as e:
        logger.error(f"Error calling Bedrock: {str(e)}")
        return None


def handle_cors_preflight():
    """Handle CORS preflight requests"""
    return {
        'statusCode': 200,
        'headers': {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type, Authorization'
        },
        'body': ''
    }
