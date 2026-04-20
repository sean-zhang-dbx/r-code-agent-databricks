# R Code Agent Tool for Databricks

A Unity Catalog function that lets an [Agent Bricks Supervisor Agent](https://docs.databricks.com/aws/en/generative-ai/agent-bricks/multi-agent-supervisor) execute R code on a Databricks cluster.

The supervisor agent hands a string of R code to this tool; the tool submits it to a pre-provisioned all-purpose cluster (R preinstalled via ML Runtime), polls for completion, and returns stdout + any error.

## Why this pattern

Databricks Apps runs on a serverless Python/Node.js runtime with no R binary and no root access. `subprocess.run(["Rscript", ...])` inside an App will fail. To run R from an agent, the App (or the Agent Bricks supervisor) needs to call out to compute where R is already installed. A Databricks cluster with ML Runtime is the native answer.

This repo wraps the [Command Execution API (v1.2)](https://docs.databricks.com/api/workspace/commandexecution) as a typed UC function so the supervisor agent can call it like any other tool.

## Architecture

```
User
  │
  ▼
Agent Bricks Supervisor Agent
  │   (calls UC function tool)
  ▼
catalog.schema.execute_r_code
  │   (Python body, makes HTTP calls)
  ▼
Databricks Command Execution API
  │   (attaches to cluster context)
  ▼
All-purpose cluster with R (ML Runtime)
  │   (executes code, reads UC tables via SparkR)
  ▼
Unity Catalog tables
```

## What's in the repo

| File | Purpose |
|------|---------|
| `src/r_tool.py` | Pure-Python source of the tool body. Testable locally. |
| `sql/01_setup.sh` | Creates secret scope with workspace host, token, cluster id. |
| `sql/02_register_function.sql` | UC function definition. Body mirrors `src/r_tool.py`. |
| `scripts/test_locally.py` | Runs the tool against a real cluster outside of UC. |
| `examples/agent_bricks_config.md` | How to attach the tool to a supervisor agent. |

## Setup

1. **Create an all-purpose cluster** with a Databricks ML Runtime (e.g., 15.4 LTS ML or later). R + SparkR + common packages come preinstalled.

2. **Create a token** (PAT or service principal OAuth token) with permission to attach to the cluster.

3. **Run the secret-scope setup:**

   ```bash
   export DATABRICKS_HOST=https://<workspace>.cloud.databricks.com
   export R_CLUSTER_ID=<cluster-id>
   export R_TOOL_TOKEN=<token>
   ./sql/01_setup.sh
   ```

4. **Test locally before registering:**

   ```bash
   export DATABRICKS_TOKEN=$R_TOOL_TOKEN
   pip install requests
   python scripts/test_locally.py
   ```

   You should see four cases: hello world, a SparkR SQL query, a linear model, and an intentional error that returns `ok: false` with an error message.

5. **Register the UC function.** Open `sql/02_register_function.sql`, replace `CATALOG.SCHEMA` with your target location, and run it in a SQL editor or via the CLI:

   ```bash
   databricks sql execute --file sql/02_register_function.sql
   ```

6. **Wire env vars into the compute that runs UC functions.** The function body reads `DATABRICKS_HOST`, `DATABRICKS_TOKEN`, and `R_CLUSTER_ID` from the environment. For serverless warehouses that execute UC functions, set these via the workspace's serverless compute environment config, pulling values from the secret scope from step 3.

7. **Add the tool to your supervisor agent.** See `examples/agent_bricks_config.md`.

## Using the tool

The supervisor agent sees a tool with this signature:

```python
execute_r_code(r_code: str, timeout_sec: int = 120) -> {
    "ok": bool,
    "output": str,
    "error": str,
    "elapsed_sec": float,
}
```

Example agent prompt that would trigger it:

> Using mtcars, fit mpg as a function of hp and wt. Report the coefficients and R-squared.

The supervisor generates the R code, calls the tool, parses the returned `output` string, and composes the final answer.

## Auth note (important)

Unity Catalog Python UDFs currently run in a sandboxed environment with **no ambient Databricks auth**. That means `dbutils.secrets.get(...)` and `WorkspaceClient()` fail with "cannot configure default credentials" when called from inside a UC function.

Practical implications for this repo:

- The `sql/02_register_function.sql` file uses a secret-scope pattern that assumes the UDF runtime exposes `dbutils` (it may for some compute types and not others; verify in your workspace before relying on it).
- For a quick POC in your own workspace, hardcode `host`, `token`, `cluster_id` as string literals in the function body. Revoke/rotate the token when the POC ends.
- For production, the right answer is one of: (a) a Model Serving endpoint that hosts this logic with env-var auth, called by the agent as an HTTP tool, or (b) a UC HTTP connection with a secret-backed bearer token, fronted by a thin SQL wrapper that invokes the external service.

## Production considerations

This is a baseline single-cluster pattern good for demos and small teams. For scale:

- **Concurrency.** A single all-purpose cluster will not hold up at 40+ concurrent users running arbitrary R on large data. Move to either (a) an **instance pool** with ephemeral job clusters per invocation, (b) **serverless compute** where supported for R, or (c) one dedicated cluster per user cohort. Cluster-sharing causes one user's runaway code to OOM everyone.

- **Data size.** LLM-generated R using base-R in-memory data frames will OOM on GB/TB tables regardless of cluster RAM. Force generated code to use SparkR / sparklyr (prompt the supervisor's system prompt with examples) and provide a `sample_table` companion tool so exploratory work runs on 100k-row samples, not full tables.

- **Isolation.** Session state persists across calls in the same execution context. For multi-tenant use, create a fresh context per user or per session rather than reusing one, and destroy it on session end.

- **Secrets.** Don't bake tokens into function source. Use UC service credentials or HTTP connections instead of raw env vars for long-term deployments.

- **Observability.** Log every R code string with a correlation id from the agent trace. Redact obvious PII before persisting. Enable MLflow tracing on the supervisor so tool calls show up in the agent observability UI.

- **Security.** Arbitrary code execution from an LLM is hostile input by definition. Use a read-only service principal on the R cluster's UC permissions so a malicious generation can at worst read data the agent is already allowed to read. Apply egress ACLs on the cluster so generated R cannot reach arbitrary external hosts.

## References

- [Agent Bricks overview](https://docs.databricks.com/aws/en/generative-ai/agent-bricks/)
- [Supervisor Agent docs](https://docs.databricks.com/aws/en/generative-ai/agent-bricks/multi-agent-supervisor)
- [Create AI agent tools using Unity Catalog functions](https://docs.databricks.com/aws/en/generative-ai/agent-framework/create-custom-tool)
- [Command Execution API](https://docs.databricks.com/api/workspace/commandexecution)
- [Databricks for R developers](https://docs.databricks.com/aws/en/sparkr/)

## License

MIT
