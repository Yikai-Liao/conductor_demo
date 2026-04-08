from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request


class ConductorClient:
    def __init__(self, base_url: str, timeout_seconds: int = 30) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout_seconds = timeout_seconds

    def poll_task(self, task_type: str, worker_id: str) -> dict | None:
        encoded_task_type = urllib.parse.quote(task_type, safe="")
        encoded_worker_id = urllib.parse.quote(worker_id, safe="")
        return self._request_json(
            "GET",
            f"/tasks/poll/{encoded_task_type}?workerid={encoded_worker_id}",
        )

    def update_task(self, payload: dict) -> dict | None:
        return self._request_json("POST", "/tasks", payload, expect_json=False)

    def _request_json(
        self,
        method: str,
        path: str,
        payload: dict | None = None,
        expect_json: bool = True,
    ) -> dict | list | str | None:
        data = None
        headers = {"Accept": "application/json"}
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"

        request = urllib.request.Request(
            url=f"{self.base_url}{path}",
            method=method,
            data=data,
            headers=headers,
        )

        try:
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                body = response.read().decode("utf-8").strip()
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Conductor {method} {path} failed with {exc.code}: {body}") from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"Conductor {method} {path} failed: {exc.reason}") from exc

        if not body or body == "null":
            return None
        if not expect_json:
            try:
                return json.loads(body)
            except json.JSONDecodeError:
                return body
        return json.loads(body)
