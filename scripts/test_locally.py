"""Exercise the tool body locally against a real Databricks cluster.

This lets you iterate on the Python logic without redeploying the UC function
every time. Once the local test passes, mirror any changes into
sql/02_register_function.sql and re-register the function.

Usage:
    export DATABRICKS_HOST=https://<workspace>.cloud.databricks.com
    export DATABRICKS_TOKEN=<pat>
    export R_CLUSTER_ID=<cluster-id>
    python scripts/test_locally.py
"""

from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
from r_tool import execute_r_code


CASES = [
    (
        "hello world",
        """
        cat("R version:", R.version.string, "\\n")
        print(summary(mtcars$mpg))
        """,
    ),
    (
        "spark sql",
        """
        library(SparkR)
        sdf <- SparkR::sql("SELECT 1 AS x, 'ok' AS msg")
        print(SparkR::collect(sdf))
        """,
    ),
    (
        "linear model",
        """
        fit <- lm(mpg ~ hp + wt, data = mtcars)
        cat("coefficients:\\n")
        print(coef(fit))
        cat("\\nR-squared:", summary(fit)$r.squared, "\\n")
        """,
    ),
    (
        "intentional error",
        "stop('this is a test error')",
    ),
]


def main() -> int:
    for name, code in CASES:
        print(f"\n{'=' * 60}\ncase: {name}\n{'=' * 60}")
        result = execute_r_code(code, timeout_sec=60)
        print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
