# cal-diy-lt

Builds a container image of [calcom/cal.diy](https://github.com/calcom/cal.diy) with Lithuanian (`lt`) registered as a locale.

- `UPSTREAM_REF` — pinned upstream commit. Bump it to update; the workflow rebuilds on push.
- `overlay/` — files copied over the upstream tree (`packages/i18n/locales/lt/common.json`: visitor-facing subset; other keys fall back to English).
- `scripts/apply-overlay.py` — adds `lt` to `i18n.json` and copies the overlay; fails the build if either step did not happen.

Image: `ghcr.io/tobalt-dev/cal-diy-lt:<upstream-sha12>`. Runtime secrets are provided by the deployment, never at build time.
- `patches/*.patch` — small upstream source patches, applied with `git apply` after the overlay; a patch that no longer applies fails the build.
  - `office365-invite-attendee-language.patch`: Outlook/Teams invite body uses the booking page (attendee) language instead of the organizer's profile locale.
