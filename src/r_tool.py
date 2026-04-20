"""R execution tool body.

This is the Python logic that gets registered as a Unity Catalog function and
exposed to an Agent Bricks Supervisor Agent as a tool. It submits R code to a
Databricks all-purpose cluster via the Command Execution API (v1.2) and returns
stdout, errors, and timing as a typed dict.

Keep this file as the source of truth. The UC function body in
`sql/02_register_function.sql` is generated from this exact signature and logic.
"""

from __future__ import annotations


def execute_r_code(r_code: str, timeout_sec: int = 120) -> dict:
    """Execute R code on a pre-configured Databricks cluster and return the output.

    The cluster must have R preinstalled (ML Runtime recommended). This tool
    submits the code string to the cluster's execution context, polls for
    completion, and returns stdout, any error message, and the elapsed time.

    R session state persists across calls within a single execution context,
    so variables and loaded libraries carry over between invocations.

    Args:
        r_code: R code to execute. Multi-line is supported. Use SparkR::sql(...)
            to query Unity Catalog tables. For large tables, stay on Spark
            DataFrames and avoid SparkR::collect() on the full result.
        timeout_sec: Max seconds to wait for the command to finish. Defaults to 120.

    Returns:
        A dict with keys:
          - ok (bool): True if execution finished without error.
          - output (str): Captured stdout from R. Empty string on error.
          - error (str): Error message if ok is False, else empty string.
          - elapsed_sec (float): Wall-clock time spent executing.
    """
    import os
    import time
    import requests

    host = os.environ["DATABRICKS_HOST"].rstrip("/")
    token = os.environ["DATABRICKS_TOKEN"]
    cluster_id = os.environ["R_CLUSTER_ID"]

    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    start = time.time()

    ctx_resp = requests.post(
        f"{host}/api/1.2/contexts/create",
        headers=headers,
        json={"clusterId": cluster_id, "language": "r"},
        timeout=30,
    )
    ctx_resp.raise_for_status()
    context_id = ctx_resp.json()["id"]

    try:
        exec_resp = requests.post(
            f"{host}/api/1.2/commands/execute",
            headers=headers,
            json={
                "clusterId": cluster_id,
                "contextId": context_id,
                "language": "r",
                "command": r_code,
            },
            timeout=30,
        )
        exec_resp.raise_for_status()
        command_id = exec_resp.json()["id"]

        deadline = start + timeout_sec
        while time.time() < deadline:
            status_resp = requests.get(
                f"{host}/api/1.2/commands/status",
                headers=headers,
                params={
                    "clusterId": cluster_id,
                    "contextId": context_id,
                    "commandId": command_id,
                },
                timeout=30,
            )
            status_resp.raise_for_status()
            status = status_resp.json()
            state = status.get("status")
            if state in ("Finished", "Error", "Cancelled"):
                elapsed = time.time() - start
                results = status.get("results") or {}
                if results.get("resultType") == "error":
                    return {
                        "ok": False,
                        "output": "",
                        "error": (
                            results.get("summary")
                            or results.get("cause")
                            or "unknown error"
                        ).strip(),
                        "elapsed_sec": round(elapsed, 3),
                    }
                return {
                    "ok": True,
                    "output": str(
                        results.get("data") or results.get("summary") or ""
                    ),
                    "error": "",
                    "elapsed_sec": round(elapsed, 3),
                }
            time.sleep(1)

        # Timed out
        try:
            requests.post(
                f"{host}/api/1.2/commands/cancel",
                headers=headers,
                json={
                    "clusterId": cluster_id,
                    "contextId": context_id,
                    "commandId": command_id,
                },
                timeout=10,
            )
        except requests.RequestException:
            pass
        return {
            "ok": False,
            "output": "",
            "error": f"execution timed out after {timeout_sec}s",
            "elapsed_sec": round(time.time() - start, 3),
        }
    finally:
        try:
            requests.post(
                f"{host}/api/1.2/contexts/destroy",
                headers=headers,
                json={"clusterId": cluster_id, "contextId": context_id},
                timeout=10,
            )
        except requests.RequestException:
            pass
