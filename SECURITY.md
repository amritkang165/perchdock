# Security Policy

PerchDock asks for Accessibility and Screen Recording permissions, so security issues matter. Thanks for reporting them responsibly.

## Supported versions

Only the [latest release](https://github.com/slynck/perchdock/releases/latest) gets security fixes.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately with [GitHub's security advisory form](https://github.com/slynck/perchdock/security/advisories/new) and include:

- What an attacker could do, and what they'd need (local access, a malicious app, a crafted file and so on).
- Steps to reproduce, and the PerchDock and macOS versions you tested.

You'll get an acknowledgement within 72 hours. Once a fix is released you'll be credited in the release notes, unless you'd rather stay anonymous.

## Verifying downloads

Every release includes a `.sha256` file next to the DMG. Check your download with:

```bash
shasum -a 256 PerchDock-<version>.dmg
```
