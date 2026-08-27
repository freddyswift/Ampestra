#!/usr/bin/env bash

# macOS Local Network privacy keys its decision partly by the main executable's
# Mach-O UUID. These launcher UUIDs are intentionally permanent for each bundle
# identity; app code changes belong in libAmpestraPayload.dylib instead.
AMPESTRA_DEV_LAUNCHER_UUID="5D17FC99-0065-3096-AB78-BD6CEF30EB80"
AMPESTRA_PRODUCTION_LAUNCHER_UUID="727FEE69-98FE-381E-AE19-93E96C50E661"
