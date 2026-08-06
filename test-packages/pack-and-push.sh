#!/usr/bin/env bash
# Builds .nupkg files for the 3 test packages and pushes them to the
# two Nexus NuGet (hosted) feeds. Run this from inside the test-packages/ folder.
#
# Usage:
#   NEXUS_URL=http://localhost:8081 \
#   NEXUS_API_KEY=xxx \
#   MAIN_FEED_NAME=contoso-nuget-main \
#   INTERNAL_FEED_NAME=contoso-nuget-internal \
#   ./pack-and-push.sh
#
# Get NEXUS_API_KEY from: Nexus UI -> click your username (top right) ->
# "NuGet API Key" tab -> "Access API Key".
#
# Unlike Artifactory, Nexus's push URL and consume URL are the same
# {base}/repository/{repo}/index.json -- no separate publish endpoint to
# juggle.
#
# Since .NET 10 SDK, the NuGet client refuses HTTP sources by default ("NuGet
# HTTPS Everywhere"). Since this is a local-only Nexus over plain HTTP, we
# pass --allow-insecure-connections on push (a .NET 10 SDK flag). If you're on
# an older SDK, add allowInsecureConnections="true" to the source's <add> in
# nuget.config instead -- there's no CLI flag pre-.NET 10.

set -euo pipefail

: "${NEXUS_URL:?Set NEXUS_URL, e.g. http://localhost:8081}"
: "${NEXUS_API_KEY:?Set NEXUS_API_KEY (Nexus UI > username > NuGet API Key)}"
: "${MAIN_FEED_NAME:?Set MAIN_FEED_NAME, e.g. contoso-nuget-main}"
: "${INTERNAL_FEED_NAME:?Set INTERNAL_FEED_NAME, e.g. contoso-nuget-internal}"

MAIN_FEED_URL="${NEXUS_URL%/}/repository/${MAIN_FEED_NAME}/index.json"
INTERNAL_FEED_URL="${NEXUS_URL%/}/repository/${INTERNAL_FEED_NAME}/index.json"

rm -rf artifacts && mkdir -p artifacts

for proj in Contoso.Core Contoso.Utils Internal.Contoso.Secrets; do
  echo "==> Packing $proj"
  dotnet pack "$proj/$proj.csproj" -c Release -o artifacts
done

echo "==> Pushing Contoso.Core and Contoso.Utils to MAIN feed ($MAIN_FEED_URL)"
dotnet nuget push "artifacts/Contoso.Core.1.0.0.nupkg" \
  --source "$MAIN_FEED_URL" --api-key "$NEXUS_API_KEY" --allow-insecure-connections
dotnet nuget push "artifacts/Contoso.Utils.1.0.0.nupkg" \
  --source "$MAIN_FEED_URL" --api-key "$NEXUS_API_KEY" --allow-insecure-connections

echo "==> Pushing Internal.Contoso.Secrets to INTERNAL feed ONLY ($INTERNAL_FEED_URL)"
dotnet nuget push "artifacts/Internal.Contoso.Secrets.1.0.0.nupkg" \
  --source "$INTERNAL_FEED_URL" --api-key "$NEXUS_API_KEY" --allow-insecure-connections

echo
echo "Done. Feed URLs to use in nuget.config / the Snyk NuGet integration:"
echo "  Main feed:     $MAIN_FEED_URL"
echo "  Internal feed: $INTERNAL_FEED_URL"
echo
echo "Note: these are only reachable from this machine right now. For the DIRECT"
echo "Snyk integration path, expose them publicly over HTTPS (e.g. 'ngrok http 8081')"
echo "and use the tunnel URL instead. For the BROKERED path, leave them exactly as"
echo "they are -- that's the point of the Broker."
