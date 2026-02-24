import subprocess
import yaml  # Vulnerable PyYAML import!
import logging
import os
from uuid import uuid4

from fastapi import FastAPI, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from schemas import Prompt, YAMLPrompts, ChatMessage
from database import db
from models import prompt_helper
import boto3
from botocore.exceptions import ClientError

# Configure logger
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI()

# Allow frontend to talk to backend
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # You can limit this to specific frontend origins
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Bedrock Agent configuration
BEDROCK_REGION = os.getenv("AWS_REGION", "us-east-2")
BEDROCK_AGENT_ID = os.getenv("BEDROCK_AGENT_ID")
BEDROCK_AGENT_ALIAS_ID = os.getenv("BEDROCK_AGENT_ALIAS_ID")

# Initialize Bedrock client
bedrock_client = boto3.client(
    "bedrock-agent-runtime",
    region_name=BEDROCK_REGION
)


@app.get("/")
async def root(got_root: str | None = None):
    if got_root == "WelcomeToWizExposureTKO27":
        return "WizCongrats!"
    raise HTTPException(status_code=404)


@app.post("/api/prompts")
async def save_prompt(prompt: Prompt):
    prompt_doc = prompt.dict()
    result = await db.prompts.insert_one(prompt_doc)
    if result.inserted_id:
        saved_prompt = await db.prompts.find_one({"_id": result.inserted_id})
        return prompt_helper(saved_prompt)
    raise HTTPException(status_code=500, detail="Failed to save prompt template.")


@app.get("/api/prompts")
async def get_all_prompts():
    prompts = []
    async for prompt in db.prompts.find():
        prompts.append(prompt_helper(prompt))
    return prompts


@app.get("/api/execute")
async def execute_command(command: str | None = None):
    process = subprocess.Popen(
        command, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    stdout = process.stdout.read().decode()
    stderr = process.stderr.read().decode()

    return {"stdout": stdout, "stderr": stderr}


@app.post("/api/import_prompts")
async def import_prompts(prompt_data: YAMLPrompts):
    try:
        # Use yaml.load (vulnerable to arbitrary code execution)
        prompts_data = yaml.load(prompt_data.yaml_content, Loader=yaml.Loader)

        # Validate the structure of the YAML
        if not isinstance(prompts_data, dict) or "prompts" not in prompts_data:
            raise ValueError("Invalid YAML format. Expected a 'prompts' key.")
        if not all(isinstance(prompt, dict) and "name" in prompt and "prompt" in prompt for prompt in prompts_data["prompts"]):
            raise ValueError("Each prompt must be a dictionary with 'name' and 'prompt' fields.")

        # Insert prompts into the database
        imported_prompts = []
        for prompt_dict in prompts_data["prompts"]:
            result = await db.prompts.insert_one(prompt_dict)
            saved_prompt = await db.prompts.find_one({"_id": result.inserted_id})
            imported_prompts.append(prompt_helper(saved_prompt))

        # Log success
        logger.info(f"Successfully imported {len(imported_prompts)} prompt templates.")
        return {"imported_prompts": imported_prompts}

    except yaml.YAMLError as e:
        logger.error(f"YAML parsing error: {str(e)}")
        raise HTTPException(status_code=422, detail=f"Invalid YAML content: {str(e)}")
    except Exception as e:
        logger.error(f"Prompt import failed: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Import failed: {str(e)}")


@app.post("/api/chat")
async def chat_with_agent(message: ChatMessage):
    """
    Chat endpoint that invokes Bedrock Agent.
    Accepts: { "message": str, "sessionId": str (optional) }
    Returns: { "sessionId": str, "answer": str }
    """
    if not BEDROCK_AGENT_ID or not BEDROCK_AGENT_ALIAS_ID:
        raise HTTPException(
            status_code=500,
            detail="Just a moment — the assistant will be with you shortly."
        )

    if not message.message or not message.message.strip():
        raise HTTPException(
            status_code=400,
            detail="Message cannot be empty"
        )

    # Use provided sessionId or generate a new one
    session_id = message.sessionId or str(uuid4())

    try:
        logger.info(f"Invoking Bedrock Agent: agentId={BEDROCK_AGENT_ID}, aliasId={BEDROCK_AGENT_ALIAS_ID}, sessionId={session_id}")

        # Invoke the Bedrock Agent
        response = bedrock_client.invoke_agent(
            agentId=BEDROCK_AGENT_ID,
            agentAliasId=BEDROCK_AGENT_ALIAS_ID,
            sessionId=session_id,
            inputText=message.message.strip()
        )

        # Aggregate completion chunks into a single response
        answer = ""
        event_stream = response.get("completion")
        if event_stream:
            for event in event_stream:
                if "chunk" in event:
                    chunk = event["chunk"]
                    if "bytes" in chunk:
                        answer += chunk["bytes"].decode("utf-8")

        logger.info(f"Agent response length: {len(answer)} chars")

        return {
            "sessionId": session_id,
            "answer": answer or "I'm sorry, I couldn't generate a response."
        }

    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "Unknown")
        error_message = e.response.get("Error", {}).get("Message", str(e))
        logger.error(f"Bedrock Agent error ({error_code}): {error_message}")
        raise HTTPException(
            status_code=500,
            detail=f"Failed to get response from agent: {error_message}"
        )
    except Exception as e:
        logger.error(f"Unexpected error invoking agent: {str(e)}")
        raise HTTPException(
            status_code=500,
            detail=f"Failed to get response from agent: {str(e)}"
        )
