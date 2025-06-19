"""LLM response parsing utilities for termaite."""

import re
from typing import Optional

from ..utils.logging import logger


def parse_suggested_command(llm_output: str) -> Optional[str]:
    """Extract a suggested command from LLM output wrapped in ```agent_command``` tags."""
    match = re.search(r"```agent_command\s*\n(.*?)\n```", llm_output, re.DOTALL)
    return match.group(1).strip() if match else None


def parse_llm_thought(llm_output: str) -> str:
    """Extract the LLM's thought process from <think> tags."""
    match = re.search(r"<think>(.*?)</think>", llm_output, re.DOTALL)
    return match.group(1).strip() if match else ""


def parse_llm_plan(llm_output: str) -> str:
    """Extract the LLM's plan from <checklist> tags."""
    match = re.search(r"<checklist>(.*?)</checklist>", llm_output, re.DOTALL)
    return match.group(1).strip() if match else ""


def parse_llm_instruction(llm_output: str) -> str:
    """Extract the LLM's instruction from <instruction> tags."""
    match = re.search(r"<instruction>(.*?)</instruction>", llm_output, re.DOTALL)
    return match.group(1).strip() if match else ""


def parse_llm_decision(llm_output: str) -> str:
    """Extract the LLM's decision from <decision> tags."""
    match = re.search(r"<decision>(.*?)</decision>", llm_output, re.DOTALL)
    return match.group(1).strip() if match else ""


def parse_llm_summary(llm_output: str) -> str:
    """Extract the LLM's summary from <summary> tags."""
    match = re.search(r"<summary>(.*?)</summary>", llm_output, re.DOTALL)
    return match.group(1).strip() if match else ""


def extract_decision_type_and_message(decision_text: str) -> tuple[str, str]:
    """Extract decision type and message from decision text.
    
    Args:
        decision_text: Raw decision text (e.g., "CONTINUE_PLAN: message here")
    
    Returns:
        Tuple of (decision_type, message)
    """
    if not decision_text:
        return "", ""
    
    if ":" in decision_text:
        decision_type, message = decision_text.split(":", 1)
        return decision_type.strip(), message.strip()
    else:
        return decision_text.strip(), ""


def parse_checklist_items(plan_text: str) -> list[str]:
    """Parse checklist items from plan text.
    
    Args:
        plan_text: Plan text containing checklist items
        
    Returns:
        List of checklist items
    """
    if not plan_text:
        return []
    
    # Split by lines and extract items that look like checklist items
    lines = plan_text.strip().split('\n')
    items = []
    
    for line in lines:
        line = line.strip()
        if not line:
            continue
            
        # Handle different checklist formats
        if line.startswith(('- ', '* ', '+ ')):
            items.append(line[2:].strip())
        elif re.match(r'^\d+\.?\s+', line):
            items.append(re.sub(r'^\d+\.?\s+', '', line).strip())
        elif line:
            # If it's not explicitly formatted as a list, still include it
            items.append(line)
    
    return items


def extract_response_content(response_data: dict, response_path: str) -> Optional[str]:
    """Extract content from LLM response using jq-like path.
    
    Args:
        response_data: LLM response JSON data
        response_path: jq-like path (e.g., ".response", ".choices[0].message.content")
        
    Returns:
        Extracted content or None if not found
    """
    if not response_path.startswith('.'):
        logger.warning(f"Response path should start with '.': {response_path}")
        return None
    
    # Remove leading dot
    path = response_path[1:]
    
    try:
        current = response_data
        
        # Handle simple paths like "response"
        if '.' not in path and '[' not in path:
            return current.get(path)
        
        # Split path by dots, but handle array indices
        parts = []
        current_part = ""
        bracket_depth = 0
        
        for char in path:
            if char == '[':
                bracket_depth += 1
                current_part += char
            elif char == ']':
                bracket_depth -= 1
                current_part += char
            elif char == '.' and bracket_depth == 0:
                if current_part:
                    parts.append(current_part)
                current_part = ""
            else:
                current_part += char
        
        if current_part:
            parts.append(current_part)
        
        # Navigate through the path
        for part in parts:
            if '[' in part and ']' in part:
                # Handle array access like "choices[0]"
                key, bracket_part = part.split('[', 1)
                index_str = bracket_part.rstrip(']')
                
                if key:
                    current = current.get(key, {})
                
                try:
                    index = int(index_str)
                    if isinstance(current, list) and 0 <= index < len(current):
                        current = current[index]
                    else:
                        return None
                except ValueError:
                    return None
            else:
                # Simple key access
                if isinstance(current, dict):
                    current = current.get(part)
                else:
                    return None
                
                if current is None:
                    return None
        
        return current
        
    except Exception as e:
        logger.error(f"Error extracting response content with path '{response_path}': {e}")
        return None
