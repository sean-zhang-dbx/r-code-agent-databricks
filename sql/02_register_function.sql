-- Registers execute_r_code as a Unity Catalog function that the Agent Bricks
-- Supervisor Agent can consume as a tool.
--
-- Replace CATALOG.SCHEMA with your target UC location before running.
-- The function reads credentials from a Databricks secret scope named
-- "r_code_agent" (see sql/01_setup.sh).

CREATE OR REPLACE FUNCTION CATALOG.SCHEMA.execute_r_code(
  r_code STRING COMMENT 'R code to execute on the Databricks cluster. Use SparkR::sql(...) to query Unity Catalog tables. Session state persists across calls in the same context.',
  timeout_sec INT COMMENT 'Maximum seconds to wait for the command to finish. Pass 120 for typical use.'
)
RETURNS STRUCT<
  ok: BOOLEAN,
  output: STRING,
  error: STRING,
  elapsed_sec: DOUBLE
>
LANGUAGE PYTHON
COMMENT 'Execute R code on a Databricks all-purpose cluster with R preinstalled. Returns stdout output and any error message. Use for agent-generated R analysis, modeling, and data exploration on UC tables.'
AS $$
  import time
  import requests

  try:
    from databricks.sdk.runtime import dbutils
    host = dbutils.secrets.get("r_code_agent", "databricks_host").rstrip("/")
    token = dbutils.secrets.get("r_code_agent", "databricks_token")
    cluster_id = dbutils.secrets.get("r_code_agent", "r_cluster_id")
  except Exception as e:
    return {
      "ok": False, "output": "",
      "error": f"failed to load credentials from secret scope: {e}",
      "elapsed_sec": 0.0,
    }

  headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
  start = time.time()

  try:
    ctx_resp = requests.post(
      f"{host}/api/1.2/contexts/create",
      headers=headers,
      json={"clusterId": cluster_id, "language": "r"},
      timeout=30,
    )
    ctx_resp.raise_for_status()
    context_id = ctx_resp.json()["id"]
  except Exception as e:
    return {"ok": False, "output": "", "error": f"context create failed: {e}", "elapsed_sec": round(time.time() - start, 3)}

  try:
    exec_resp = requests.post(
      f"{host}/api/1.2/commands/execute",
      headers=headers,
      json={"clusterId": cluster_id, "contextId": context_id, "language": "r", "command": r_code},
      timeout=30,
    )
    exec_resp.raise_for_status()
    command_id = exec_resp.json()["id"]

    deadline = start + timeout_sec
    while time.time() < deadline:
      status_resp = requests.get(
        f"{host}/api/1.2/commands/status",
        headers=headers,
        params={"clusterId": cluster_id, "contextId": context_id, "commandId": command_id},
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
            "ok": False, "output": "",
            "error": (results.get("summary") or results.get("cause") or "unknown error").strip(),
            "elapsed_sec": round(elapsed, 3),
          }
        return {
          "ok": True,
          "output": str(results.get("data") or results.get("summary") or ""),
          "error": "",
          "elapsed_sec": round(elapsed, 3),
        }
      time.sleep(1)

    return {"ok": False, "output": "", "error": f"execution timed out after {timeout_sec}s", "elapsed_sec": round(time.time() - start, 3)}
  finally:
    try:
      requests.post(
        f"{host}/api/1.2/contexts/destroy",
        headers=headers,
        json={"clusterId": cluster_id, "contextId": context_id},
        timeout=10,
      )
    except Exception:
      pass
$$;

-- Grant the agent's service principal (or users who will invoke the agent)
-- permission to execute this function.
-- GRANT EXECUTE ON FUNCTION CATALOG.SCHEMA.execute_r_code TO `agent-service-principal@example.com`;
