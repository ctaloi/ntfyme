# Release, deployment, and push runbook

This is the operator document for the next agent (or future you). It is the
one place that explains how NtfyMe ships, what a push does, how the website is
deployed, how Sparkle updates are cut, and what is safe to commit.

## Current shape

- **Repo:** `github.com/ctaloi/ntfyme`
- **Visibility:** public
- **License:** MIT (`LICENSE`)
- **Website:** `https://ntfyme.aloi.dev`
- **GitHub homepage / About:** set manually (one `gh repo edit` command; see below)
- **Website deploy:** GitHub Pages via `.github/workflows/pages.yml`
- **DNS:** Cloudflare zone `aloi.dev`, record `ntfyme.aloi.dev -> ctaloi.github.io` (`DNS only`)
- **App updates:** Sparkle 2, appcast at repo root `appcast.xml`

## What a push to `main` does

### Always
- `.github/workflows/ci.yml`
  - selects newest Xcode on `macos-26`
  - `swift build -v`
  - `swift test -v`

- `.github/workflows/pages.yml`
  - redeploys `site/` to GitHub Pages on **every push to `main`**

That means the website does not need a special deploy step once the commit is
on `main`.

**Repo About metadata is not automated**: GitHub rejected the secretless workflow
for updating repository description/homepage on push. The settings are already
correct, and changes stay a one-line manual `gh repo edit` so the repo can
remain public without adding a privileged PAT secret.

## Website hosting

The landing page lives in `site/`:

- `site/index.html`
- `site/assets/*`
- `site/CNAME` → `ntfyme.aloi.dev`
- `site/PRODUCT.md`
- `site/DESIGN.md`

GitHub Pages is configured for **GitHub Actions**. The repo has already been
switched to public, which is required on the current GitHub plan for Pages.

### Cloudflare DNS (already created)

- Zone: `aloi.dev`
- Zone ID: `01a8cd81d494e0203d35cbbb328307bf`
- Record:

```text
CNAME  ntfyme  ctaloi.github.io   proxied: false
```

Keep it **DNS only** unless there is a specific reason to proxy it.

## Sparkle auto-update setup

### Public vs private key

- **Public key**: committed in `Scripts/config.sh`
  - safe to commit
  - used by the app to verify updates
- **Private key**: stored in the macOS Keychain on the release machine
  - must never be committed
  - used only by `sign_update`

### One-time setup on a new machine

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build                    # resolves Sparkle and the package graph
cd .build/checkouts/Sparkle
xcodebuild -project Sparkle.xcodeproj -scheme generate_keys -configuration Release -derivedDataPath /tmp/sparkle-tools build
xcodebuild -project Sparkle.xcodeproj -scheme sign_update  -configuration Release -derivedDataPath /tmp/sparkle-tools build
cp /tmp/sparkle-tools/Build/Products/Release/sign_update .build/checkouts/Sparkle/bin/
/tmp/sparkle-tools/Build/Products/Release/generate_keys      # writes keypair into Keychain
/tmp/sparkle-tools/Build/Products/Release/generate_keys -p   # prints PUBLIC key
```

If the printed public key is different from the one in `Scripts/config.sh`, it
means you generated a new update keypair. **Do not rotate casually** — old
clients trust the old public key. A key rotation is a deliberate migration.

## Cutting a release

```bash
Scripts/release.sh 0.2.0
```

What it does:
1. bumps `MARKETING_VERSION` and `BUILD_VERSION` in `Scripts/config.sh`
2. runs `Scripts/build-app.sh`
3. assembles `build/NtfyMe.app`
4. zips it as `build/NtfyMe-<version>.zip`
5. signs the zip for Sparkle using `sign_update`
6. updates `appcast.xml` newest-first
7. prints the `gh release create` command to run

### After `release.sh`
Run the printed command, then commit and push:

```bash
gh release create v0.2.0 build/NtfyMe-0.2.0.zip --title "NtfyMe 0.2.0" --generate-notes
git add appcast.xml Scripts/config.sh
git commit -m "Release 0.2.0"
git push
```

The push updates:
- the website (Pages workflow)
- the repo About metadata (repo-about workflow)
- the appcast in the public repo

## Local build / app bundle

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
Scripts/build-app.sh
open build/NtfyMe.app
```

`build-app.sh` now also:
- embeds `Sparkle.framework`
- signs it
- signs the app bundle
- writes `SUFeedURL` and `SUPublicEDKey` into `Info.plist`

## Public-repo safety

The repo has been scrubbed for public release.

### Safe to commit
- app code
- screenshots in `site/assets`
- Sparkle **public** key in `Scripts/config.sh`
- appcast.xml
- workflow files
- release/build scripts

### Must never be committed
- `Scripts/local.sh` (gitignored)
- macOS signing identity hashes if they are local-only convenience values
- Sparkle **private** key
- any Cloudflare token, GitHub token, or `.env` secrets
- any real ntfy topic names if those topics live on the public `ntfy.sh` service

### Already cleaned
- leaked-looking test topic names (`vaspian-*`, `aloi-home-*`, `aloi-wan-*`) were removed
- no private keys or API tokens were found in tracked files
- repo visibility was changed to public only after that pass

## GitHub repo metadata

Current desired state:
- **Description:** `Native macOS client for ntfy — real notifications, searchable archive, compose. Download: ntfyme.aloi.dev`
- **Homepage:** `https://ntfyme.aloi.dev`
- **Topics:** `macos`, `swift`, `ntfy`, `notifications`, `menubar`, `sparkle`

Description/homepage are currently set correctly. If you need to change them:

```bash
gh repo edit ctaloi/ntfyme \
  --description "Native macOS client for ntfy — real notifications, searchable archive, compose. Download: ntfyme.aloi.dev" \
  --homepage "https://ntfyme.aloi.dev"
```

## If Pages is not live yet

Check:
1. the commit with `site/` and `.github/workflows/pages.yml` is on `main`
2. Actions → **Deploy site** has run successfully
3. GitHub Pages is enabled for **workflow** builds
4. the Cloudflare CNAME still points at `ctaloi.github.io`
5. proxy is still off (`DNS only`)

## If Sparkle release signing fails

Usually one of these:
- `SPARKLE_ED_PUBLIC_KEY` missing or wrong
- private key not present in the release machine's Keychain
- `sign_update` binary not built yet on this machine
- `swift build` not run, so the Sparkle checkout/artifacts do not exist

## If the next agent needs a short version

- push to `main` → tests + Pages deploy + repo-about update
- `site/` is the landing page
- `Scripts/release.sh <version>` is the release flow
- appcast is in repo root
- public key is in `Scripts/config.sh`
- private update key is only in Keychain
- DNS is already in Cloudflare for `ntfyme.aloi.dev`
