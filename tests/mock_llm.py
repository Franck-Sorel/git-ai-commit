"""A tiny OpenAI-compatible mock of llama-server's /v1/completions.

Used by tests/integration.sh and manual demos so the whole pipeline can
run even where llama-server isn't installed. Returns a deterministic
completion. Do NOT run in production.
"""

import argparse

import aiohttp
import aiohttp.web


async def handler(request):
    await request.json()
    # Deterministic "completion": mirrors the user's partial word.
    body = await request.json()
    prompt = body.get("prompt", "")
    partial = prompt.split("Partial message:")[-1].split("\n")[0].rstrip()
    # Simple heuristic: append "g validation" when they typed "add " etc.
    suggestion = " login validation" if "add" in partial else " implemented"
    return aiohttp.web.json_response({"choices": [{"text": suggestion.strip()}]})


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8099)
    args = p.parse_args()
    app = aiohttp.web.Application()
    app.router.add_post("/v1/completions", handler)
    aiohttp.web.run_app(app, host="127.0.0.1", port=args.port, print=None)


if __name__ == "__main__":
    main()
