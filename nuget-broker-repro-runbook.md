# Reproducing the private-NuGet-feed / packageSourceMapping import failure
### (self-hosted Nexus edition — no JFrog signup required)

Goal: reproduce, in your own Snyk org, the customer's failure mode — `dotnet restore`
inside Snyk's SCM import can't reach a private NuGet feed behind a broker/IP-allowlist,
`packageSourceMapping` blocks any nuget.org fallback, restore dies with `NU1100`, and the
import ends in "Import timeout / No projects found" — then fix it two ways (direct
integration, and Universal Broker) so you have both the working and broken configs on
hand.

This version uses **self-hosted Sonatype Nexus Repository OSS** (free, runs in Docker, no
signup or email gate) instead of JFrog Artifactory. Snyk supports Nexus as a first-class
registry type for both the direct NuGet integration and the Universal Broker's brokered
package registries, so nothing about the Snyk-side steps changes — only the registry
vendor and its URL shape. A local-only Docker container also has a nice side effect for
this repro: it's naturally unreachable from Snyk's cloud until you expose it, which is
exactly the "broker required" condition you're trying to reproduce.

If you ever do get access to a real Artifactory instance later, see the **Appendix** for
the URL-format differences — everything else in this guide carries over unchanged.

Companion files (same folder):
- `test-packages/` — 3 tiny class libraries + `pack-and-push.sh` to publish them to Nexus
- `nuget-repro-repo/` — the test .NET solution with CPM + `nuget.config` + `packageSourceMapping`

Two things worth flagging before you start:

1. **Plan tier.** Private/brokered NuGet registry integrations (`Organization Settings >
   Integrations > NuGet Repositories` and `Settings > Languages > .NET > Brokered package
   registries`) are Enterprise-plan features. If your day-to-day org isn't on Enterprise,
   you'll need a Snyk-provisioned Enterprise/demo org to see these UI sections at all — the
   CLI restore will still work either way, but the SCM-import behavior you're trying to
   reproduce won't.
2. **Universal Broker needs Tenant Admin.** Setting up a Broker deployment requires the
   Snyk Tenant Admin role, Node.js 20+, and a personal Snyk API token.
3. **On a corporate/security-conscious network, Section 3 (direct path) may not be
   reachable at all.** It needs a public HTTPS tunnel to your local Nexus (ngrok,
   Cloudflare Tunnel, etc.), and those tunnel services are exactly the kind of traffic
   corporate security policies commonly block outright — doubly likely on Snyk's own
   network. If both ngrok and `cloudflared` fail for you, don't fight it: **treat Section 3
   as optional and go straight to Section 4 (Universal Broker).** The Broker only ever
   makes a standard *outbound* HTTPS connection to `broker.snyk.io:443` — the same class of
   traffic as any SaaS API call, not something that's typically blocked the way tunnels
   are — so Nexus can stay on `localhost` the whole time. That also happens to be a closer
   match to the real customer's topology than exposing a feed publicly ever was.

---

## 0. Quick diagnostic: is NuGet already connected?

Before building anything, this is the fastest first check when triaging an import failure
like this (in your repro org or a real customer org):

**Do you have a NuGet feed connection integrated in your Snyk org yet?** Check under
**Organization Settings > Integrations > NuGet**, in the **Package Repositories** section.

- **If it's not configured:** that's very likely the cause. Since all the packages come
  from a private feed, Snyk needs this connection to resolve them during import. Set it up
  there (or via **Add integration** if NuGet isn't listed), then re-run the import and see
  if it completes.
- **One thing to watch:** if Snyk can't reach your feed endpoint — for example it's only
  accessible inside your network, or it's IP-allowlisted and Snyk's egress ranges aren't on
  the allowlist — the connection won't work even once it's configured, and you may need a
  broker.

This one check tells you which failure you're dealing with before you go further:
"not configured at all" (fix: Section 3) vs. "configured but unreachable" (fix: Section 4,
Universal Broker).

Your actual test plan (confirmed correct, worth running in this order):

1. Publish the 3 test packages to Nexus first (Section 1) — the "fix" step later only works
   if the packages already exist somewhere real.
2. Import the repo into Snyk with **no NuGet integration configured at all**. Expect a
   failure — see the note below on which failure you'll actually get.
3. Add the NuGet integration (Section 3) or the Broker (Section 4). Re-run the import.
   Expect success.

**Confirmed finding, worth internalizing before you check results:** with no integration
configured and `nuget.config` pointing at a genuinely unreachable feed (e.g. bare
`http://localhost:8081`, which only ever means "this machine" to whatever's reading the
config — Snyk's cloud reading that string resolves it to itself, never to your laptop, no
matter what your Docker container is bound to), the import does **not** reliably surface as
an overt "Import timeout" error the way the original customer ticket described. Instead,
Snyk can quietly create the project anyway with an **empty dependency graph** — `0 C 0 H 0
M 0 L` issues, but also **0 dependencies** on the project's Dependencies tab. At a glance
this looks like a clean, successful scan. It isn't. **Always check the Dependencies tab
count, not just the Issues count**, when verifying whether an import actually resolved
anything. Both symptoms (hard timeout, or silent empty graph) are real, valid outcomes of
the exact same root cause — which one you get seems to depend on how/where the restore
attempt fails, not on anything you're doing wrong.

A corollary trap that will also produce a false "it worked": if `dotnet restore` has
already been run locally and `obj/project.assets.json` (the resolved lockfile) ends up
committed to the repo, both `snyk test` and Snyk's SCM import can read the dependency graph
straight off that file with no restore and no network call at all. See Section 2, step 3,
before you push anything.

---

## 1. Nexus side

### 1a. Run Nexus locally (no signup)

```bash
docker run -d -p 8081:8081 --name nexus sonatype/nexus3
```

Give it 1–2 minutes to finish starting (`docker logs -f nexus` until you see "Started
Sonatype Nexus"), then grab the generated admin password:

```bash
docker exec nexus cat /nexus-data/admin.password
```

Open `http://localhost:8081`, sign in as `admin` with that password, and complete the
first-run setup wizard (set a new password; you can decline "enable anonymous access").

### 1b. Create two NuGet (hosted) repositories — how to create a repo in Nexus

This is the same UI flow for both feeds; do it twice with different names.

1. Click the **gear icon** (top right) to open **Server administration and configuration**.
2. In the left nav, under **Repository**, click **Repositories**.
3. Click **Create repository**.
4. From the list of recipes, pick **nuget (hosted)** — this is the option that stores
   packages you push to it, as opposed to `nuget (proxy)` (mirrors an upstream feed) or
   `nuget (group)` (merges several feeds behind one URL).
5. **Name:** `contoso-nuget-main`.
6. Leave **Blob store** as the default, and set **Deployment policy** to **Allow redeploy**
   (handy while you're iterating on test packages — lets you re-push the same version).
7. Click **Create repository**.
8. Repeat steps 3–7 with **Name:** `contoso-nuget-internal`.

You now have two independent NuGet feeds under one Nexus instance — `contoso-nuget-main`
(everything maps here via `*`) and `contoso-nuget-internal` (only the `Internal.*`-prefixed
package maps here).

### 1c. Get a NuGet API key (for pushing packages)

On a fresh Community Edition install, the NuGet API-Key realm is disabled by default, so
this section won't show up on your profile until you turn it on:

1. Left nav > **Security** > **Realms**.
2. Move **NuGet API-Key Realm** from the Available column to **Active**, then **Save**.

Now click your username (top right) > **My Account**. The account page should now show a
**NuGet API Token** section (this only appears for users with Deployment permissions —
`admin` has it by default, and only once the realm above is active). Click **Access API
Key** (or **Reset API Key**), re-entering your password if prompted. Copy the key —
you'll pass it to `dotnet nuget push` as `-k`.

### 1d. Publish the 3 test packages

The `test-packages/` folder has 3 minimal packages already scaffolded:

| Package | Published to | Purpose |
|---|---|---|
| `Contoso.Core` 1.0.0 | `contoso-nuget-main` | proves the `*` mapping works |
| `Contoso.Utils` 1.0.0 | `contoso-nuget-main` | second package on the main feed |
| `Internal.Contoso.Secrets` 1.0.0 | `contoso-nuget-internal` | exists **only** here — proves the `Internal.*` mapping and is the thing that breaks if that feed isn't reachable |

Run:

```bash
cd test-packages
NEXUS_URL=http://localhost:8081 \
NEXUS_API_KEY=<your-nuget-api-key> \
MAIN_FEED_NAME=contoso-nuget-main \
INTERNAL_FEED_NAME=contoso-nuget-internal \
./pack-and-push.sh
```

### 1e. The feed URL Snyk expects

Nexus's NuGet v3 feed URL is simpler than Artifactory's — it's just
`{base}/repository/{repo-name}/index.json`, no extra `/v3/` segment:

```
http://localhost:8081/repository/contoso-nuget-main/index.json
http://localhost:8081/repository/contoso-nuget-internal/index.json
```

Sanity-check both resolve and return JSON before moving on:

```bash
curl http://localhost:8081/repository/contoso-nuget-main/index.json
```

**If you're on the .NET 10 SDK:** NuGet now refuses plain-HTTP sources by default
("NuGet HTTPS Everywhere"). Since local Nexus is HTTP-only, you'll need
`--allow-insecure-connections` on `dotnet nuget push`/`dotnet nuget add source` (a .NET 10
CLI flag — already baked into `pack-and-push.sh`), and `allowInsecureConnections="true"` on
the matching `<add>` entries in `nuget.config` (already in the scaffold's `nuget.config`).
Drop both once you're pointed at a real HTTPS endpoint (e.g. after tunneling with ngrok).

**Important — reachability from Snyk's cloud:** `localhost:8081` is only ever reachable
from whatever machine is reading that string — never from a remote server, no matter what
interface your Docker container binds to (`0.0.0.0:8081` only extends reachability to other
devices on *your* local network, not to the public internet). For the DIRECT path (Section
3), Snyk's cloud needs a real internet route to your Nexus instance — the easiest option
for a quick test is a tunnel, e.g.:

```bash
ngrok http 8081
```

...which gives you a public HTTPS URL like `https://abcd1234.ngrok-free.app` to use in
place of `http://localhost:8081` everywhere below. For the BROKERED path (Section 4) you
deliberately do **not** expose it publicly — that's the whole point of the Broker, and is
explained there.

---

## 2. Repo side

Already built for you in `nuget-repro-repo/`. Key pieces:

**`nuget.config`** — `<clear/>` wipes nuget.org and any machine-level sources, then maps
everything (`*`) to the main feed and only `Internal.*` to the second feed:

```xml
<packageSources>
  <clear />
  <add key="ContosoMain" value="http://REPLACE-ME:8081/repository/contoso-nuget-main/index.json" allowInsecureConnections="true" />
  <add key="ContosoInternal" value="http://REPLACE-ME:8081/repository/contoso-nuget-internal/index.json" allowInsecureConnections="true" />
</packageSources>
<packageSourceMapping>
  <packageSource key="ContosoMain"><package pattern="*" /></packageSource>
  <packageSource key="ContosoInternal"><package pattern="Internal.*" /></packageSource>
</packageSourceMapping>
```

**`Directory.Packages.props`** (CPM) — versions live here, not in the `.csproj` files:

```xml
<ItemGroup>
  <PackageVersion Include="Contoso.Core" Version="1.0.0" />
  <PackageVersion Include="Contoso.Utils" Version="1.0.0" />
  <PackageVersion Include="Internal.Contoso.Secrets" Version="1.0.0" />
</ItemGroup>
```

**`src/`** has 3 `.csproj` — `App` and `Lib` reference the main-feed packages, `Internal`
references `Internal.Contoso.Secrets`, which resolves *only* via the second feed. That's
the project that fails first if the second feed isn't reachable — a genuine split-feed
failure, not just "the one feed is down."

Before using it:

1. Edit `nuget-repro-repo/nuget.config` and replace the `REPLACE-ME` placeholder with your
   real Nexus URL (or ngrok tunnel URL, once you're testing the direct/Snyk-cloud path).
2. **Restore locally first, before pushing anywhere** (this exercises the same restore
   Snyk will run):

```bash
dotnet restore nuget-repro-repo/src/App/App.csproj
dotnet restore nuget-repro-repo/src/Lib/Lib.csproj
dotnet restore nuget-repro-repo/src/Internal/Internal.csproj
```

(Nexus's hosted repos default to anonymous read for `nuget.config` consumption in a fresh
install; if you enabled auth-required access, add a `packageSourceCredentials` block with
your Nexus username + the NuGet API key, same shape as before.)

`App.csproj` already has `UseAppHost` set to `false` for a reason worth knowing: building
an `Exe` normally pulls in `Microsoft.NETCore.App.Host.<rid>` from nuget.org for the native
launcher. With `<clear/>` in play, that resolves to nowhere and throws `NU1101` — a red
herring that masks the actual test. If you add more `Exe`-type projects to this repo later,
set `UseAppHost` to `false` on those too, or you'll hit the same thing.

3. **Before you `git add`/commit/push: make sure `.gitignore` is in place and `obj/`/`bin/`
   are not tracked.** This is the single easiest way to accidentally invalidate the whole
   exercise. `dotnet restore` writes the fully-resolved dependency graph to
   `obj/project.assets.json`. If that file gets committed and pushed, both `snyk test` and
   Snyk's SCM import can read the dependency tree straight off that file — no restore, no
   network call to your feed at all. You'll get a "clean" result that looks like success
   but has actually tested nothing about feed reachability. A `.gitignore` excluding
   `bin/`, `obj/`, `artifacts/`, and `*.nupkg` is already included in this scaffold — if
   you restored locally *before* adding it, check for leftovers before your first push:

```bash
git status --ignored          # should list obj/ and bin/ as ignored, not tracked
git ls-files | grep -E 'obj/|bin/|artifacts/'   # should print nothing
```

If that second command prints anything, those files were already committed. Untrack them
(this is the reliable version — feeding the exact file list to `git rm --cached` sidesteps
any shell/git glob-quoting issues):

```bash
git ls-files | grep -E 'obj/|bin/|artifacts/' | xargs git rm --cached
git commit -m "Stop tracking build output"
git push
git ls-files | grep -E 'obj/|bin/|artifacts/'   # confirm empty now
```

Note this only fixes what's tracked by *git* — it does **not** delete the physical files
on disk. `snyk test` run locally reads straight off the filesystem regardless of git
tracking status, so it'll keep finding old `obj/` output until you also `rm -rf` it. That's
fine and expected — local CLI tests can never demonstrate this failure anyway; see the note
at the end of this section.

Then re-trigger the Snyk import (delete the existing target and re-run **Add project**,
don't rely on it re-syncing on its own timeline) — a fresh clone won't have those cached
lockfiles, so it'll be forced to actually run its own restore against the feed this time.

4. Push this repo to a real GitHub/GitLab/Bitbucket repo you can connect to Snyk (Snyk SCM
   import needs a real remote, not a local-only folder).

All three should succeed locally — this is your baseline "local restore and Snyk CLI work
fine" state that matches the customer's report.

**Why local `snyk test` can never reproduce this failure, and that's fine:** the CLI runs
on your machine, on your network — the same place Nexus is running. There's no network
boundary between them, so of course it reaches `localhost:8081` fine, restore or no restore.
This matches the real customer's report too (their local CLI worked regardless of the SCM
import problem). **Only the SCM/web UI import runs in Snyk's actual cloud infrastructure**,
which is the only environment that's ever genuinely unable to reach your local feed. Don't
use CLI results as a signal for reachability testing — only the web import result counts.

---

## 3. Snyk config — DIRECT path (optional — skip if tunnels are blocked on your network)

Simpler than the Broker, but requires your Nexus instance to have a real
internet-reachable URL (ngrok tunnel, Cloudflare Tunnel, or a proper cloud VM — not bare
`localhost`). If tunneling tools get blocked on your network (common on
security-conscious/corporate networks), skip straight to **Section 4** — you don't need
this section to complete the repro, since the Broker path covers both the working and
broken states on its own.

1. **Organization Settings > Integrations > NuGet Repositories.**
2. Under **Your tokens**, add: **Username** (your Nexus username), **Personal access
   token** (the NuGet API key from step 1c), and the **repository URL** — the v3
   `index.json` URL for the main feed. Only HTTPS is supported, so this must be the
   ngrok/tunnel HTTPS URL, not plain `http://localhost:8081`.
3. Repeat for the second feed URL — the integration lets you register multiple private
   NuGet sources; Snyk tries all registered credentials as `dotnet nuget source add`
   entries before restoring.
4. Save.
5. Import the repo: **Add project > GitHub/GitLab/etc. > select `nuget-repro-repo`.**
6. Watch the import. It should complete and show all 3 projects (`App`, `Lib`, `Internal`)
   with dependencies resolved, including `Internal.Contoso.Secrets`.

This confirms the "feed reachable" happy path end-to-end through the direct integration.

Note: this configuration only applies to Snyk's Web UI / SCM import. The Snyk CLI already
resolves private NuGet sources automatically from your local `nuget.config` — that's why
the customer's local CLI worked regardless of this setting.

---

## 4. Snyk config — BROKERED path (Universal Broker)

This reproduces the customer's actual topology: the feed only reachable via a
broker/allowlist, not directly from Snyk's cloud. With Nexus, you get this "for free" —
just don't tunnel it publicly, and run the Broker on the same machine/network as Nexus so
it can reach `http://localhost:8081` (or the container's hostname) while Snyk's cloud
cannot.

### 4a. Install the Broker config CLI and create a connection

```bash
npm i -g snyk-broker-config
snyk-broker-config workflows connections create
```

Choose the **Nexus** connection type and provide the requested details (your Nexus base
URL, e.g. `http://localhost:8081`, and credentials as prompted — the CLI adapts its
questions to the connection type).

### 4b. Integrate the connection with your org

```bash
snyk-broker-config workflows connections integrate
```

Enter your Organization ID (valid UUID — find it under **Organization Settings >
General**) when prompted.

### 4c. Run the Broker client

Follow "Running your Universal Broker client" from the CLI output (Docker container or
Kubernetes/Helm). Requirements: outbound HTTPS (443) to `https://broker.snyk.io`, at least
1 CPU / 256 MB RAM, no inbound ports needed. Run it on the same host as your Nexus
container (or one that can reach it) so it can act as the tunnel.

### 4d. Enable Universal Broker for Open Source

**Settings > Products and features > Snyk Open Source >** under "Universal Broker for
Snyk Open Source," enable **Enable Universal Broker**.

### 4e. Configure the brokered NuGet registry

**Settings > Languages > .NET > Brokered package registries:**

1. Registry type: **Nexus**.
2. Registry URL: the same feed URL, e.g.
   `http://localhost:8081/repository/contoso-nuget-main/index.json` (from the Broker's
   point of view, `localhost`/the container network is fine — it's the Broker, not Snyk's
   cloud, that connects to it). It must end in `/index.json`. (If you ever switch to
   Artifactory instead, the required suffix is `/v3/{repository-name}/index.json` — a
   common copy-paste mistake between the two vendors.)
3. Add the second feed the same way for the `Internal.*`-mapped repo, if the UI in your
   Snyk version supports multiple brokered NuGet registries; otherwise proceed with the
   main feed for this pass and treat the second feed as an extension once the primary path
   works.

### 4f. A real gotcha to know about before you test

Support case history on this exact combination (First American Title, case
`500PU00000vOgDWYA0`, originally against Artifactory but the underlying behavior isn't
vendor-specific) shows NuGet is treated differently from other Broker-fronted ecosystems:
**Snyk resolves NuGet credentials/URLs from the org-level NuGet integration
(`Organization Settings > Integrations > NuGet Repositories`), not purely from the
Broker connection**, even when a Universal Broker connection exists and is healthy. In
that case the customer's Broker was fine, but imports still failed with "Unable to reach
Artifactory" until the org-level NuGet integration was also configured with the matching
feed URL and credentials.

Practical takeaway for your repro: configure **both** — the Broker connection/tunnel
(steps 4a–4e) **and** the org-level NuGet Repositories integration from Section 3, pointed
at the same feed URLs. If you want a "pure brokered, nothing direct" test to isolate
behavior, deliberately leave the org-level NuGet integration empty/wrong and see whether
the import fails the same way that customer's did — that's a second, useful variant of the
failure mode beyond the one the current customer reported.

There's also a second, related real case (`500PU00001AJCs7YAH`) worth being aware of:
when Snyk can't reach the private feed, it can silently fall back to public nuget.org
instead of failing outright, and resolve a different (often incompatible) package
version — surfacing as `NU1107` version-conflict errors rather than `NU1100`. Your
`<clear/>` + `packageSourceMapping` setup blocks that fallback entirely (nuget.org isn't
in the source list at all), which is exactly why it should reproduce a clean `NU1100`
instead of a confusing `NU1107`. Worth calling out if you're using this repro to explain
the difference to a customer whose config *doesn't* use `<clear/>`.

---

## 5. Reproduce the failure, then confirm the fix

### Break it

Pick whichever matches what you're trying to demonstrate:

- **Broker down:** stop the Broker container/pod (`docker stop <container>` or scale the
  Kubernetes deployment to 0). Reachability drops immediately; new imports using the
  brokered registry can't tunnel to Nexus.
- **Not allowlisted / unreachable:** stop or firewall the Nexus container itself
  (`docker stop nexus`), or kill the ngrok tunnel if you're testing the direct path. This is
  the simplest way to simulate "feed unreachable" without needing real IP-allowlisting
  infrastructure. (This is also the default starting state — see Section 0's confirmed
  finding: with nothing configured and `nuget.config` pointing at bare `localhost`, you're
  already in this state without doing anything extra.)
- **Wrong/removed integration:** temporarily clear the feed URL or credentials from
  either the org-level NuGet integration or the brokered registry setting.

Then trigger a fresh import of `nuget-repro-repo` (delete the existing target first and use
**Add project** again — don't rely on the automatic "Repository content sync" re-import,
since its timing isn't something you control and you want a clean before/after comparison).

### What you should see

One of two things, both valid:

- **Overt failure:** the import spinner runs, then times out or completes with 0 projects
  detected. Under the project/target's import history or the **Recent activity** log, look
  for a failed `dotnet restore` with `NU1100: Unable to resolve … PackageSourceMapping is
  enabled, the following source(s) were not considered: nuget.org` — this matches error
  `SNYK-OS-DOTNET-0005` in Snyk's error catalog.
- **Silent empty success (confirmed to occur in practice):** the import completes, shows
  "Project created" for everything, `0 C 0 H 0 M 0 L` issues — but the **Dependencies tab**
  on the project page shows **0**, not the expected `Contoso.Core`/`Internal.Contoso.Secrets`
  etc. This is just as valid a reproduction of the failure; it's just quieter. Always check
  Dependencies, not Issues, to tell the two states apart.

Because `Internal.Contoso.Secrets` only exists on the second feed, you can selectively
break just that feed and watch `App`/`Lib` still import (and resolve dependencies) fine
while `Internal` fails/comes back empty — a clean demonstration of the split-feed mapping
mattering, not just "is any feed up."

### Fix it and confirm

- Restart the Nexus container and/or the Broker container/pod, or restore the tunnel/feed
  URL and credentials.
- Delete the existing Snyk target and re-import fresh (again, don't rely on automatic
  content sync for timing).
- Confirm all 3 projects (`App`, `Lib`, `Internal`) now appear with resolved dependencies —
  check the **Dependencies tab count** on each, not just the issue counts — matching the
  state you got in Section 3/4's happy path.

---

## Appendix: quick reference

| Path | UI location | Feed URL format (Nexus) | Feed URL format (Artifactory, if you get access later) |
|---|---|---|---|
| Direct | Organization Settings > Integrations > NuGet Repositories | `{base}/repository/{repo}/index.json` | `{base}/artifactory/api/nuget/v3/{repo}/index.json` |
| Brokered | Settings > Languages > .NET > Brokered package registries, Registry type = Nexus/Artifactory | same as above, ends `/index.json` | same as above, ends `/v3/{repo}/index.json` |

Relevant Snyk docs:
- [Private NuGet repositories for .NET configuration](https://docs.snyk.io/scan-fix-and-prevent/scan-with-snyk/snyk-open-source/package-repository-integrations/private-nuget-repositories-for-.net-configuration)
- [Nexus repository manager for NuGet](https://docs.snyk.io/scan-fix-and-prevent/scan-with-snyk/snyk-open-source/package-repository-integrations/nexus-repository-manager-connection-setup/nexus-repository-manager-for-npm-1)
- [Artifactory repository manager for NuGet](https://docs.snyk.io/scan-fix-and-prevent/scan-with-snyk/snyk-open-source/package-repository-integrations/artifactory-package-repository-connection-setup/artifactory-repository-manager-for-nuget) (for later, if you get JFrog access)
- [Universal Broker](https://docs.snyk.io/platform-administration/snyk-broker/universal-broker)
- [Basic steps to install and configure Universal Broker](https://docs.snyk.io/platform-administration/snyk-broker/universal-broker/basic-steps-to-install-and-configure-universal-broker)
- [Error catalog](https://docs.snyk.io/scan-fix-and-prevent/prevent/error-catalog) (see `SNYK-OS-DOTNET-0005`, `-0012`, `-0013`)
- [Sonatype Nexus Repository OSS (Docker image)](https://hub.docker.com/r/sonatype/nexus3)
