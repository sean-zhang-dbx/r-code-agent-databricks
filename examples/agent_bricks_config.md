# Wiring the R Tool into an Agent Bricks Supervisor Agent

Once `catalog.schema.execute_r_code` is registered as a Unity Catalog function, add it to a Supervisor Agent as a tool.

## Via the Supervisor Agent UI

1. Open the workspace and go to **Agents → Supervisor Agent → New agent** (or edit an existing one).
2. In the **Tools** section, click **Add tool → Unity Catalog function**.
3. Search for `execute_r_code` and select it.
4. The supervisor reads the function's COMMENT and parameter descriptions to build its tool-calling prompt automatically, so the `COMMENT` fields in `sql/02_register_function.sql` matter. Keep them descriptive.
5. (Optional) Add a **tool usage hint** that tells the supervisor when to route to this tool, e.g., "Use execute_r_code when the user asks for statistical modeling, time-series forecasting, or any analysis that is natural to express in R."

## Grants

The service principal that runs the supervisor agent must have `EXECUTE` on the function:

```sql
GRANT EXECUTE ON FUNCTION catalog.schema.execute_r_code
  TO `<supervisor-agent-sp>`;
```

It also needs permission to attach to the R cluster, since the function talks to it via the Command Execution API.

## Passing secrets at runtime

The UC function body reads `DATABRICKS_HOST`, `DATABRICKS_TOKEN`, and `R_CLUSTER_ID` from environment variables. For a serverless compute context, inject them via the environment configuration on the warehouse or compute where the function runs. The cleanest options:

- Store secrets in a Databricks secret scope (see `sql/01_setup.sh`) and reference them from a UC HTTP connection or from the serverless compute's environment.
- For POC speed: set them as cluster env vars on the warehouse that serves UC function execution.

## Prompt guidance the supervisor will use

The function's docstring becomes the tool description. Keep it tight and behavior-focused. Example additions that help the supervisor route well:

> Use this tool when the user wants R-specific analysis: mixed-effects models (lme4), time-series forecasting (forecast, prophet), survival analysis (survival), or bioinformatics packages.
>
> For simple SQL aggregations, prefer the Genie Spaces tool instead.
>
> For Python-native work, prefer the existing Python tool.

## Testing end-to-end

1. Create a small test chat with the supervisor.
2. Prompt: "Using mtcars, fit mpg ~ hp + wt and report R-squared."
3. Verify the supervisor invokes `execute_r_code`, receives a structured result, and synthesizes a reply.
4. Check the agent trace in MLflow to confirm tool invocations and timings.
