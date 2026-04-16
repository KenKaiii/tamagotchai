#!/usr/bin/env bash
# Streams every log category involved in a Tama voice call. Use alongside the
# call UI to see listen → silence detection → agent TTFB → TTS gen → playback
# in real time, plus the per-turn metric summaries with ⚠️ SLOW warnings.
#
# Usage:
#   ./scripts/call-logs.sh              # full pipeline
#   ./scripts/call-logs.sh --summary    # per-turn summaries only
#   ./scripts/call-logs.sh --warn       # only warnings / errors

set -euo pipefail

SUBSYSTEM='com.unstablemind.tama'
FULL_CATEGORIES='{"callsession","callmetrics","voice","speech","kokoro","agent","tool.screenshot"}'
STYLE='compact'

case "${1:-}" in
    --summary)
        PREDICATE="subsystem == \"$SUBSYSTEM\" AND category == \"callmetrics\""
        ;;
    --warn)
        PREDICATE="subsystem == \"$SUBSYSTEM\" AND category IN $FULL_CATEGORIES AND messageType >= 16"
        ;;
    "")
        PREDICATE="subsystem == \"$SUBSYSTEM\" AND category IN $FULL_CATEGORIES"
        ;;
    *)
        echo "Unknown flag: $1" >&2
        echo "Usage: $0 [--summary | --warn]" >&2
        exit 64
        ;;
esac

echo "━━━ Streaming Tama call logs ━━━" >&2
echo "Predicate: $PREDICATE" >&2
echo "Ctrl-C to stop." >&2
echo >&2

exec log stream --predicate "$PREDICATE" --style "$STYLE"
