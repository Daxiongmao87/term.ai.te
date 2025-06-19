"""LLM client for API communication in termaite."""

import json
import subprocess
import tempfile
from typing import Dict, Any, Optional
from pathlib import Path

from ..utils.logging import logger
from .parsers import extract_response_content


class LLMClient:
    """Handles communication with LLM APIs."""
    
    def __init__(self, config: Dict[str, Any], response_path_file: Path):
        """Initialize LLM client.
        
        Args:
            config: Application configuration
            response_path_file: Path to response path template file
        """
        self.config = config
        self.response_path_file = response_path_file
        self.endpoint = config.get("endpoint", "")
        self.api_key = config.get("api_key")
        self.command_timeout = config.get("command_timeout", 30)
    
    def send_request(self, payload: str) -> Optional[str]:
        """Send request to LLM API and extract response content.
        
        Args:
            payload: JSON payload string
            
        Returns:
            Extracted response content or None if failed
        """
        if not self.endpoint:
            logger.error("No LLM endpoint configured")
            return None
        
        response_data = self._make_api_call(payload)
        if not response_data:
            return None
        
        response_path = self._get_response_path()
        if not response_path:
            return None
        
        return extract_response_content(response_data, response_path)
    
    def _make_api_call(self, payload: str) -> Optional[Dict[str, Any]]:
        """Make the actual API call using curl."""
        try:
            # Create temporary file for payload
            with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as temp_file:
                temp_file.write(payload)
                temp_payload_path = temp_file.name
            
            # Build curl command
            curl_cmd = self._build_curl_command(temp_payload_path)
            
            logger.debug(f"Making LLM API call to {self.endpoint}")
            
            # Execute curl command
            result = subprocess.run(
                curl_cmd,
                capture_output=True,
                text=True,
                timeout=self.command_timeout
            )
            
            # Clean up temp file
            Path(temp_payload_path).unlink(missing_ok=True)
            
            if result.returncode != 0:
                logger.error(f"LLM API call failed with return code {result.returncode}")
                logger.error(f"stderr: {result.stderr}")
                return None
            
            # Parse JSON response
            try:
                return json.loads(result.stdout)
            except json.JSONDecodeError as e:
                logger.error(f"Failed to parse LLM response as JSON: {e}")
                logger.debug(f"Raw response: {result.stdout}")
                return None
                
        except subprocess.TimeoutExpired:
            logger.error(f"LLM API call timed out after {self.command_timeout} seconds")
            return None
        except Exception as e:
            logger.error(f"Error during LLM API call: {e}")
            return None
    
    def _build_curl_command(self, payload_file_path: str) -> list[str]:
        """Build curl command for API call."""
        cmd = [
            "curl",
            "-s",  # Silent mode
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-d", f"@{payload_file_path}",
        ]
        
        # Add API key header if configured
        if self.api_key:
            cmd.extend(["-H", f"Authorization: Bearer {self.api_key}"])
        
        cmd.append(self.endpoint)
        
        return cmd
    
    def _get_response_path(self) -> Optional[str]:
        """Get the response path from the response path file."""
        try:
            if not self.response_path_file.exists():
                logger.error(f"Response path file not found: {self.response_path_file}")
                return None
            
            response_path = self.response_path_file.read_text().strip()
            if not response_path:
                logger.error(f"Response path file is empty: {self.response_path_file}")
                return None
            
            logger.debug(f"Using response path: {response_path}")
            return response_path
            
        except Exception as e:
            logger.error(f"Error reading response path file {self.response_path_file}: {e}")
            return None
    
    def test_connection(self) -> bool:
        """Test the LLM API connection.
        
        Returns:
            True if connection is successful, False otherwise
        """
        test_payload = {
            "model": "test",
            "prompt": "Hello, this is a connection test.",
            "stream": False
        }
        
        try:
            response_data = self._make_api_call(json.dumps(test_payload))
            return response_data is not None
        except Exception as e:
            logger.error(f"Connection test failed: {e}")
            return False


def create_llm_client(config: Dict[str, Any], response_path_file: Path) -> LLMClient:
    """Create a configured LLM client instance."""
    return LLMClient(config, response_path_file)
