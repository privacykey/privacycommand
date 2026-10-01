# privacycommand build commands and provenance

Audited 2026-10-01 against `0fc43d4f` plus the provenance corrections in this branch.

`just info` previews the source identity: UTC build stamp, commit, branch, dirty-file count, tag-at-HEAD and channel. It does not reserve the stamp for a later build. `just archive` captures a fresh stamp, creates an Archive and verifies Organizer/app/extension metadata; exporting or uploading is a separate command. Product → Archive does the capture automatically through the shared scheme.

Dirty means tracked modifications or non-ignored untracked files. Ignored build products are excluded. A version tag (`vX.Y` or `vX.Y.Z`) at HEAD and dirty files are independent flags: both can be YES. A clean tagged source alone does not prove signing, export or App Store publication. A release-channel Archive may be untagged or dirty.

GitHub app builds automatically use the `ci` channel; explicit local/testflight/release choices take precedence. Archive defaults to `release` and redacts SHA/branch/describe/diff from binaries, while retaining dirty/tagged/timestamp/channel fields. CI source diagnostics remain in logs. Shared pipelines also report the checkout SHA, branch/detached state, dirty/tag flags and trigger in the job summary. PR jobs may build GitHub's synthetic merge commit; HEAD is reported accurately rather than replaced with the source branch's SHA.

Tag detection requires fetched tag refs. App build workflows and the updated shared pipelines fetch full history and tags. Shared pipeline consumers use an exact commit pin for these corrections; the moving v1 tag is unchanged.

Identification is consistent; clean-tree release enforcement is not universal. Do not infer a universal clean/tagged publishing gate from the presence of metadata.

SPM CI tests the package/CLI; shared App CI builds/tests the macOS Xcode app. just build/test cover the SPM targets, not the Xcode app. Shared Sparkle release uses the exact release tag and checks marketing version; local release-local has no clean-tree/tag gate.

## Available commands

```text
Available recipes:
    default                  # List available commands
    archive platform="macos" # Regenerate the project, Archive, and verify its app/extension build identity.
    info                     # Show the UTC build preview, commit, dirty files, tag-at-HEAD and channel.

    [dev]
    build                    # Build every SPM target (Core, auditctlKit, auditctl, guest agent, protocol)
    test                     # Run the full SPM test suite (same as CI)
    clean                    # Remove SPM build output

    [ship]
    release version          # Tag v<version> and push it to trigger the release workflow (tag must match MARKETING_VERSION)
    release-local            # Build, sign, notarize and package the DMG locally (needs Developer ID + notary env)
```

`release`, `beta`, `upload`, `deploy`, Worker secret/deploy commands and `stack-probe` have external effects. The audit listed them without running them. `release-local` signs/notarizes locally; `archive-export` exports but does not upload.
