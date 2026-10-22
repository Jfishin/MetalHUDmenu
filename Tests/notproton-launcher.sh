#!/bin/sh
# The installed NotProton launcher's relevant shell boundary.
if [ -n "$STEAM_DYLD_INSERT_LIBRARIES" ]; then
  export DYLD_INSERT_LIBRARIES="$STEAM_DYLD_INSERT_LIBRARIES"
fi
exec "$@"
