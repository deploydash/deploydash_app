# Store Metadata Template

Fill this document before each store submission cycle.

## Shared Metadata

- Product name: `Deploy Dash`
- Canonical app ID / bundle ID: `com.deploydash.desktop`
- Support URL:
- Privacy policy URL:
- Marketing website URL:
- Contact email:

## Short Description

Use for storefront cards and package summaries.

```text
Deploy Dash is a local-first desktop control plane for managing your own
servers, databases, web app deploys, backups, and day-2 operations.
```

## Full Description

Include:

- local-first encrypted workspace
- GitHub-connected web app deploys
- PostgreSQL service management
- local AI Agent Access for read-only inspection and controlled redeploys
- one-off app commands inside managed app containers

## Screenshots Checklist

- Startup / unlock screen
- Home dashboard
- Server onboarding
- Web app deployment workspace
- Database workspace
- App Settings -> Agent Access

## Review Notes

Prepare concise notes that explain:

- Deploy Dash connects to user-owned infrastructure over SSH.
- The desktop app embeds a self-contained Python runtime as part of the local
  app bundle.
- OAuth returns through `deploydash://callback`.
- User-selected file imports/exports happen through OS file pickers.

## Channel Overrides

### Snap / Flathub

- Confinement / portal notes:

### Mac App Store

- Sandbox entitlement explanation:
- Embedded runtime explanation:

### Microsoft Store

- Product ID: `9P1GK6Z58B9T`
- Publisher subject: `CN=4DF691A0-E545-4698-A115-C49614B329C6`
- Publisher display name: `Tidy Technology`
- MSIX identity: `TidyTechnology.DeployDash`
- Package family name: `TidyTechnology.DeployDash_rf5wcg4kb0x8a`
- Architectures: one `x64` and one `arm64` package per submission
  (or per-arch submissions — record which)
- Minimum Windows version: `10.0.17763.0` (Windows 10 1809)
- Free listing confirmed: yes (date/initials)
- Initial audience: `Private audience`
- Update validation audience: package flight
- Accessibility declaration: leave unclaimed until the full audit is complete
