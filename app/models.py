from bson import ObjectId


def prompt_helper(prompt) -> dict:
    return {
        "id": str(prompt["_id"]),
        "name": prompt["name"],
        "prompt": prompt["prompt"],
    }
