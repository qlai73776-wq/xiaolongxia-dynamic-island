#!/bin/bash
set -euo pipefail

AGENT="${1:-main}"
STATE="${2:-thinking}"
MESSAGE="${3:-Working}"

encoded_message="$(MESSAGE="$MESSAGE" python3 - <<'PY'
import os
from urllib.parse import quote
print(quote(os.environ["MESSAGE"]))
PY
)"

open "openclaw://update?agent=$AGENT&state=$STATE&msg=$encoded_message"
