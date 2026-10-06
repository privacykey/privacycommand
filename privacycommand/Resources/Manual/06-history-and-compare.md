# History and compare

## Saved runs

Every analysis and every monitored run is saved automatically to `~/Library/Application Support/privacycommand/runs/<id>/` as a JSON report. The empty main window lists the five most recent; the **History** tab lists them all.

- Click a run to load it back into the window.
- Right-click for **Reveal in Finder** or **Delete**.
- **Refresh** re-reads the folder.

Automatic saving can be turned off in Settings ▸ General ▸ Run history; a run is then only kept when you save a report from the File menu. The same section shows how many runs are saved and can delete them all; see [Settings](08-settings.md).

## Comparing two runs

Choose **Compare two runs** on the History tab. Pick a run for each side; the body lists, section by section, what was added and what was removed between them: entitlements, domains, SDKs, login items and findings, colour-cued. **Show only changes** hides everything the two reports have in common. Volatile build tokens that change with every build are collapsed into "modified" entries rather than shown as a removal and an addition.

Comparing the same app across versions is the quickest way to see what an update brought in.
