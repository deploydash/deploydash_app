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
- where the vulnerability can be observed and its type
  (for example: "command injection in the one-off command runner"),
- steps to reproduce as a benign, non-destructive proof of concept,
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

- Acknowledgement within 5 working days and triage within
  10 working days (best effort; this is a small team).
- Severity assessment and a fix timeline after reproduction.
- If you want a status update, please ask no more than once every
  14 days so we can focus on the fix.
- We will notify you when the vulnerability is remediated and may
  ask you to confirm the fix covers it.
- Coordinated disclosure: a fix and release first, public details
  after users have had a reasonable window to update — please
  coordinate the release timing with us.
- Credit in the release notes if you want it (just say so).

There is no paid bug-bounty programme.

## Ground rules

When researching vulnerabilities in our products and services:

- Do not break any applicable law.
- Do not access unnecessary amounts of data, and do not share or
  redistribute anything you retrieve; securely delete it as soon as
  it is no longer needed.
- Do not modify data, disrupt services, or use high-intensity,
  destructive, or denial-of-service techniques.
- Do not demand payment for disclosure.
- Please avoid reports on non-exploitable issues or generic
  best-practice deviations (missing security headers, TLS cipher
  preferences) rather than concrete vulnerabilities.

This policy does not authorise any activity that is inconsistent
with the law or that would put us or our partners in breach of
legal obligations.
