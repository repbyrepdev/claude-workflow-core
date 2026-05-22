#!/bin/bash
# v4.17.L — sourceable helper: unset OTEL env vars that cause auto-
# instrumented tools (semgrep 1.157+, OpenTelemetry-wrapped python
# tools) to emit 'Tracing initialized' at startup. Sourced by any hook
# that shells out to such tools. To list live consumers, run:
#   grep -l '_otel-silence.sh' .claude/hooks/*.sh
#
# Usage (in hook): source "$(dirname "$0")/_otel-silence.sh"
# `unset` of an unset var is a no-op exit 0 — no error masking needed.
unset OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE OTEL_SERVICE_NAME OTEL_EXPORTER_OTLP_ENDPOINT
