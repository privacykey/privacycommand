# Archive and build identity

The portfolio uses `YYYY.MMDD.HHMM` in UTC for build numbers. The marketing
version lives in `Config/Shared.xcconfig`; repository provenance is separate.
See the [canonical agreement](https://github.com/AdamXweb/AdamXweb/blob/main/docs/VERSIONING.md).

Open the shared app scheme, select a device or Any Mac, then choose
**Product → Archive**. Each build captures a fresh identity automatically;
the app and its extensions share it. Generated projects must be regenerated
after pulling project changes.

`just archive` generates the project when needed, archives, and checks the
Organizer, app and extension versions. Supported platforms are listed in
`Config/ArchiveTargets.json`; pass one with `just archive PLATFORM`.
For compile and metadata verification without certificates, run
`python3 scripts/archive-app.py --unsigned`. Add `--plan` to inspect commands.

Normal archives use the project's signing setup and your Apple account.
Set `APPLE_TEAM_ID` when a team override is needed. Export and upload remain
separate. Release archives omit repository identifiers. Marketing versions
are unchanged by archiving.

The format has minute precision: wait for the next UTC minute before
uploading a second build of the same version. An existing App Store version
with a larger legacy integer build may need a marketing version bump before
the first timestamp build can be uploaded.
