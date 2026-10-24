# Security policy

Deploy Dash manages its users' production servers, so vulnerability
reports get priority attention. Thank you for reporting responsibly.

## Supported versions

| Version | Supported          |
| ------- | ------------------ |
| 1.1.x   | Yes                |
| < 1.1   | Best effort only   |

Only the latest minor release receives security fixes. Older releases
are updated only when a fix backports cleanly; otherwise, upgrade.

## Reporting a vulnerability

**Do not open a public issue for a suspected vulnerability.** Use one
of these private channels:

1. Preferred: the repository's **Security** tab →
   **Report a vulnerability** (GitHub private vulnerability reporting).
2. Fallback: email `info@deploydash.com` with `[SECURITY]` in the
   subject line.

Include:

- the Deploy Dash version and platform (Windows/macOS, Store/DMG),
- what you expected vs what happened,
- steps to reproduce (proof-of-concept preferred),
- your assessment of the impact (who is affected and how).

## Scope

In scope:

- first-party code in this repository (desktop app, backend engine),
- pinned dependencies as shipped in a release (tell us when a pin
  needs moving, even if the fix itself belongs upstream),
- the release, signing, and update pipeline defined in this repository.

Out of scope:

- vulnerabilities in upstream projects themselves (Flutter, Python,
  Pyinfra, …) — please report those to the upstream project,
- the operating system and packages on a managed server outside what
  Deploy Dash configures,
- attacks that require an already-compromised workstation or server,
- social engineering, physical attacks, and denial of service.

## What to expect

- Acknowledgement within 7 days (best effort; this is a small team).
- Severity assessment and a fix timeline after reproduction.
- Coordinated disclosure: a fix and release first, public details
  after users have had a reasonable window to update.
- Credit in the release notes if you want it (just say so).

There is no paid bug-bounty programme.
