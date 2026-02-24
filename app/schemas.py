from pydantic import BaseModel
from typing import Optional


class Prompt(BaseModel):
    name: str
    prompt: str

class YAMLPrompts(BaseModel):
    yaml_content: str

class ChatMessage(BaseModel):
    message: str
    sessionId: Optional[str] = None
