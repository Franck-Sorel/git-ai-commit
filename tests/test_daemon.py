"""Daemon tests: debounce, per-cwd diff cache, stale discard, end-to-end
against a mock OpenAI-compatible LLM server (ADR-0003/0008/0012)."""

import asyncio
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

import aiohttp
import aiohttp.web
import pytest

from git_ai_commit.config import Config
from git_ai_commit.daemon import Daemon, DiffCache


def _short_sock(name: str) -> str:
    # macOS caps AF_UNIX paths at ~104 bytes; tmp_path lives under the long
    # /var/folders/... tree, so a socket there would raise "AF_UNIX path too
    # long". Use a short path in the CWD (repo checkout) instead, which stays
    # well under the limit on every runner.
    return str(Path.cwd() / f"_gai_{name}.sock")


# --------------------------------------------------------------------------- DiffCache
def _make_repo(root: Path, filename: str, content: str) -> Path:
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(["git", "-C", str(root), "config", "user.email", "t@t"], check=True)
    subprocess.run(["git", "-C", str(root), "config", "user.name", "t"], check=True)
    (root / filename).write_text(content)
    subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
    return root


def test_diff_cache_is_per_cwd(tmp_path):
    repo_a = _make_repo(tmp_path / "a", "a.txt", "alpha\n")
    repo_b = _make_repo(tmp_path / "b", "b.txt", "beta\n")

    cache = DiffCache(ttl=300, max_chars=100000)
    diff_a = cache.get(str(repo_a))
    diff_b = cache.get(str(repo_b))

    assert "alpha" in diff_a
    assert "beta" in diff_b
    # No cross-contamination (ADR-0008)
    assert "beta" not in diff_a
    assert "alpha" not in diff_b


def test_diff_cache_truncates(tmp_path):
    repo = _make_repo(tmp_path / "c", "long.txt", "x" * 10000)
    cache = DiffCache(ttl=300, max_chars=100)
    diff = cache.get(str(repo))
    assert len(cache.truncate(diff)) <= 100


def test_build_prompt_mentions_conventional_commits():
    d = Daemon.__new__(Daemon)
    prompt = d._build_prompt("diff", "feat(auth): add")
    assert "Conventional Commits" in prompt
    assert "feat(auth): add" in prompt
    assert "Completion:" in prompt


# ----------------------------------------------------------------------- debounce
async def _teardown(daemon, server, runner):
    server.close()
    await server.wait_closed()
    await daemon.session.close()
    await runner.cleanup()


async def _start_mock_llm(port):
    async def handler(request):
        await request.json()
        # Continuation text has no leading space because the request prefix
        # already ends with a space (whitespace-trigger). Daemon strips it.
        return aiohttp.web.json_response(
            {"choices": [{"text": "login validation"}]}
        )

    app = aiohttp.web.Application()
    app.router.add_post("/v1/completions", handler)
    runner = aiohttp.web.AppRunner(app)
    await runner.setup()
    site = aiohttp.web.TCPSite(runner, "127.0.0.1", port or 0)
    await site.start()
    sock = site._server.sockets[0]
    return runner, sock.getsockname()[1]


@pytest.mark.asyncio
async def test_end_to_end_suggestion(tmp_path):
    runner, port = await _start_mock_llm(0)
    sock_path = Path(_short_sock("e2e"))
    cfg = Config(socket_path=str(sock_path), debounce_ms=0,
                 llama_url=f"http://127.0.0.1:{port}/v1/completions")
    daemon = Daemon(cfg)
    daemon.session = aiohttp.ClientSession()
    server = await asyncio.start_unix_server(daemon.handle_client, path=sock_path)

    try:
        reader, writer = await asyncio.open_unix_connection(str(sock_path))
        writer.write(b'{"id":1,"prefix":"feat(auth): add","cwd":"/no/such/repo"}\n')
        await writer.drain()
        raw = await asyncio.wait_for(reader.readline(), timeout=5)
        resp = json.loads(raw.decode())
        assert resp["id"] == 1
        assert resp["status"] == "ok"
        assert resp["suggestion"] == "login validation"
        writer.close()
        await writer.wait_closed()
    finally:
        await _teardown(daemon, server, runner)
        sock_path.unlink(missing_ok=True)


@pytest.mark.asyncio
async def test_stale_request_discarded(tmp_path):
    """A request superseded during debounce must not produce a response."""
    runner, port = await _start_mock_llm(0)
    sock_path = Path(_short_sock("stale"))
    cfg = Config(socket_path=str(sock_path), debounce_ms=200,
                 llama_url=f"http://127.0.0.1:{port}/v1/completions")
    daemon = Daemon(cfg)
    daemon.session = aiohttp.ClientSession()
    server = await asyncio.start_unix_server(daemon.handle_client, path=sock_path)

    try:
        # First connection: id=1 (starts debounce)
        r1, w1 = await asyncio.open_unix_connection(str(sock_path))
        w1.write(b'{"id":1,"prefix":"a","cwd":"/no/such/repo"}\n')
        await w1.drain()

        # Second connection: id=2 supersedes during debounce
        r2, w2 = await asyncio.open_unix_connection(str(sock_path))
        w2.write(b'{"id":2,"prefix":"b","cwd":"/no/such/repo"}\n')
        await w2.drain()

        # id=2 wins
        raw = await asyncio.wait_for(r2.readline(), timeout=5)
        resp = json.loads(raw.decode())
        assert resp["id"] == 2
        assert resp["status"] == "ok"

        # id=1 connection gets closed with no response (EOF)
        line = await asyncio.wait_for(r1.readline(), timeout=5)
        assert line == b""

        w1.close(); w2.close()
        await w1.wait_closed(); await w2.wait_closed()
    finally:
        await _teardown(daemon, server, runner)
        sock_path.unlink(missing_ok=True)
