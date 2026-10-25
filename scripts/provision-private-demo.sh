#!/bin/bash
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo 'Usage: scripts/provision-private-demo.sh DEVICE_ID'
  exit 1
fi
IFS= read -r -s -p 'Baseten key (saved only in the iPhone Keychain): ' brailio_demo_key
printf '\n'
trap 'unset brailio_demo_key DEVICECTL_CHILD_BRAILIO_DEMO_BASETEN_KEY' EXIT
export DEVICECTL_CHILD_BRAILIO_DEMO_BASETEN_KEY="$brailio_demo_key"
xcrun devicectl device process launch --device "$1" --terminate-existing com.brailio.app
