# NtfyMe — product context

> Written 2026-09-03 by the assistant from the user's brief and the README,
> with assumptions labeled. Owner: correct anything wrong; this file is the
> durable truth every design task reads.

## What it is

NtfyMe is a native macOS app for [ntfy](https://ntfy.sh): it
watches your ntfy subscriptions and delivers them as **real macOS
notifications**, keeps a searchable local archive of every message, and can
publish back to any topic from a proper compose window. Open source (MIT),
distributed as a signed binary from GitHub Releases, auto-updating via
Sparkle.

## Who it is for

People who already run (or subscribe to) ntfy topics — homelab alerts, CI
notifications, self-hosted services — and want them on the Mac properly,
not in a browser tab. Assumption (labeled): they value native behavior,
privacy (credentials in the Keychain), and quiet reliability over flash.

## What this surface must do

A one-page landing site at **ntfyme.aloi.dev**:

- **Mode: Persuade.** The visitor decides to download and acts.
- The visitor should understand, within seconds: what it is, that it is
  native and trustworthy (signed, auto-updating, open source), and where
  the download button is.
- Content: the app's real screenshots (rendered from the app's own test
  fixtures — synthetic data, no private servers), a short plain description,
  a Download link (GitHub Releases latest), a link to the GitHub repo,
  and the honest security note (topic names on ntfy.sh are like passwords).
- **Explicit brief constraints:** simple; not "AI slop"; no invented
  commercial claims; links to the GitHub repo; hosted at ntfyme.aloi.dev.

## Voice

Plain and concrete, the project README's voice. No superlatives, no
marketing puffery, no exclamation marks. The strongest sentences are the
concrete ones: "searchable archive of every message it has seen".
