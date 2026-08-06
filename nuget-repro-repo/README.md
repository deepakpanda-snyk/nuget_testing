# nuget-repro-repo

Minimal repro of a customer's private-NuGet-feed setup (Nexus edition — no JFrog signup
required; see the main runbook's Appendix if you later get access to Artifactory instead):

- Central Package Management (`Directory.Build.props` + `Directory.Packages.props`)
- `nuget.config` with `<clear/>` (no nuget.org fallback) and `packageSourceMapping`:
  - `*` -> `ContosoMain` (main feed)
  - `Internal.*` -> `ContosoInternal` (second feed)
- Three projects under `src/`:
  - `App` -> depends on `Contoso.Core` (main feed)
  - `Lib` -> depends on `Contoso.Utils` (main feed)
  - `Internal` -> depends on `Internal.Contoso.Secrets` (ONLY on the second feed)

## Before this will restore anywhere (locally, CLI, or Snyk)

1. Run Nexus (`docker run -d -p 8081:8081 --name nexus sonatype/nexus3`) and create the two
   hosted NuGet repos: `contoso-nuget-main`, `contoso-nuget-internal`.
2. Replace the `REPLACE-ME` placeholder in `nuget.config` with your Nexus host (e.g.
   `localhost`, or an ngrok/tunnel hostname if Snyk's cloud needs to reach it directly for
   the DIRECT integration path).
3. Build and push the 3 test packages from `../test-packages/` (see its `pack-and-push.sh`).
4. If your Nexus repos require authenticated reads, export `NEXUS_USER` / `NEXUS_API_KEY`
   env vars locally before running `dotnet restore`, since `nuget.config` reads credentials
   from those env vars. A fresh Nexus install allows anonymous reads by default, in which
   case you can delete the `<packageSourceCredentials>` block entirely.

See the main runbook (`nuget-broker-repro-runbook.md`) for the full step-by-step,
including the Snyk-side configuration and how to reproduce the NU1100 / import-timeout
failure on purpose.
