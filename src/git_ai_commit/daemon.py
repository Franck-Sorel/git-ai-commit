"""Long-lived daemon (ADR-0002).

Owns the debounce timer, the per-cwd ``git diff --cached`` cache
(ADR-0008), and the HTTP client to ``llama-server`` (ADR-0003). Serves
any number of per-shell workers over a Unix domain socket and verifies
the peer UID on every connection (ADR-0005).

Never logs staged-diff or prompt contents to disk (rule 12).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import subprocess
import time
from pathlib import Path

import aiohttp

from .config import Config, load_config
from .peer import verify_peer_uid

log = logging.getLogger("git_ai_commit")


class DiffCache:
    """Per-working-directory diff cache (ADR-0008)."""

    def __init__(self, ttl: float, max_chars: int):
        self._ttl = ttl
        self._max_chars = max_chars
        self._cache: dict[str, tuple[float, str]] = {}

    def get(self, cwd: str) -> str:
        now = time.time()
        cached = self._cache.get(cwd)
        if cached and (now - cached[0]) < self._ttl:
            return cached[1]
        diff = self._fetch(cwd)
        self._cache[cwd] = (now, diff)
        return diff

    @staticmethod
    def _fetch(cwd: str) -> str:
        try:
            proc = subprocess.run(
                ["git", "-C", cwd, "diff", "--cached"],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
            return proc.stdout
        except Exception:  # noqa: BLE001 - a diff failure degrades to empty
            return ""

    def truncate(self, diff: str) -> str:
        return diff[: self._max_chars]


class Daemon:
    def __init__(self, config: Config):
        self.cfg = config
        self.diff_cache = DiffCache(config.diff_cache_ttl, config.diff_max_chars)
        self.session: aiohttp.ClientSession | None = None
        self.latest_id = 0
        self._inflight: asyncio.Task | None = None

    # ------------------------------------------------------------------ IPC
    async def handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        sock = writer.get_extra_info("socket")
        if sock is not None and not verify_peer_uid(sock, os.getuid()):
            log.warning("rejecting connection: peer UID mismatch")
            writer.close()
            return

        try:
            raw_line = await reader.readline()
            if not raw_line:
                writer.close()
                return
            req = json.loads(raw_line.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            writer.close()
            return

        req_id = int(req.get("id", 0))
        prefix = str(req.get("prefix", ""))
        cwd = str(req.get("cwd", "."))
        self.latest_id = max(self.latest_id, req_id)

        # Supersede any in-flight request: only the latest survives.
        if self._inflight and not self._inflight.done():
            self._inflight.cancel()
        self._inflight = asyncio.create_task(
            self._process(writer, req_id, prefix, cwd)
        )

    async def _process(
        self,
        writer: asyncio.StreamWriter,
        req_id: int,
        prefix: str,
        cwd: str,
    ):
        try:
            # Debounce: give a faster-typing user a chance to supersede.
            await asyncio.sleep(self.cfg.debounce_seconds())
            if req_id != self.latest_id:
                writer.close()
                return

            diff = self.diff_cache.get(cwd)
            diff = self.diff_cache.truncate(diff)
            prompt = self._build_prompt(diff, prefix)

            suggestion = await self._infer(prompt)

            if req_id == self.latest_id:
                payload = {
                    "id": req_id,
                    "status": "ok",
                    "suggestion": suggestion,
                }
                await self._write(writer, payload)
        except asyncio.CancelledError:
            # Superseded — drop silently (ADR-0012 matching rule).
            writer.close()
        except Exception as exc:  # noqa: BLE001 - surface as IPC error
            if req_id == self.latest_id:
                payload = {
                    "id": req_id,
                    "status": "error",
                    "message": str(exc),
                }
                await self._write(writer, payload)
            writer.close()

    async def _write(self, writer: asyncio.StreamWriter, payload: dict):
        try:
            writer.write((json.dumps(payload) + "\n").encode("utf-8"))
            await writer.drain()
            writer.close()
        except (ConnectionError, BrokenPipeError):
            pass

    # -------------------------------------------------------------- LLM
    async def _infer(self, prompt: str) -> str:
        assert self.session is not None
        body = {
            "prompt": prompt,
            "max_tokens": self.cfg.max_tokens,
            "temperature": self.cfg.temperature,
            "stop": self.cfg.stop,
        }
        async with self.session.post(
            self.cfg.llama_url,
            json=body,
            timeout=aiohttp.ClientTimeout(total=self.cfg.http_timeout()),
        ) as resp:
            result = await resp.json()
        return result["choices"][0]["text"].strip()

    @staticmethod
    def _build_prompt(diff: str, prefix: str) -> str:
        return (
            "You are an expert software engineer writing a git commit "
            "message in Conventional Commits format. Given the staged "
            "diff and the partial message already typed, output ONLY "
            "the remaining text that completes the message. Do not "
            "repeat the partial message. Do not output code or "
            "explanations.\n\n"
            f"Diff:\n{diff}\n\n"
            f"Partial message: {prefix}\n"
            "Completion:"
        )

    # --------------------------------------------------------------- run
    async def run(self) -> None:
        self.session = aiohttp.ClientSession()
        sock_path = Path(self.cfg.socket_path)
        sock_path.parent.mkdir(parents=True, exist_ok=True)
        if sock_path.exists():
            sock_path.unlink()
        server = await asyncio.start_unix_server(self.handle_client, path=sock_path)
        os.chmod(sock_path, 0o600)  # restrict to owning user (ADR-0005)
        log.info("daemon listening on %s", sock_path)
        async with server:
            await server.serve_forever()


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    cfg = load_config()
    try:
        asyncio.run(Daemon(cfg).run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
