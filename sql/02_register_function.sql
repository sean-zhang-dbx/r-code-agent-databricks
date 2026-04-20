-- Registers execute_r_code as a Unity Catalog function that the Agent Bricks
-- Supervisor Agent can consume as a tool.
--
-- Replace CATALOG and SCHEMA with your target location before running.
-- Replace SECRET_SCOPE with the scope you created for Databricks credentials.
--
-- The function body mirrors src/r_tool.py. Keep the two in sync.

CREATE OR REPLACE FUNCTION CATALOG.SCHEMA.execute_r_code(
  r_code STRING COMMENT 'R code to execute on the Databricks cluster. Use SparkR::sql(...) to query Unity Catalog tables. Session state persists across calls in the same context.',
  timeout_sec INT DEFAULT 120 COMMENT 'Maximum seconds to wait for the command to finish.'
)
RETURNS STRUCT<
  ok: BOOLEAN,
  output: STRING,
  error: STRING,
  elapsed_sec: DOUBLE
>
LANGUAGE PYTHON
COMMENT 'Execute R code on a Databricks all-purpose cluster with R preinstalled. Returns stdout output and any error message. Use for agent-generated R analysis, modeling, and data exploration.'
AS $$
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

    try:
      requests.post(
        f"{host}/api/1.2/commands/cancel",
        headers=headers,
        json={"clusterId": cluster_id, "contextId": context_id, "commandId": command_id},
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
$$;

-- Grant the agent's service principal (or users who will invoke the agent)
-- permission to execute this function.
-- GRANT EXECUTE ON FUNCTION CATALOG.SCHEMA.execute_r_code TO `agent-service-principal@example.com`;
