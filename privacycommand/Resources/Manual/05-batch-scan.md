# Batch scan

Batch scan analyses many apps at once and triages them in one table, using the same static analyser as the single-app flow.

## Opening it

Choose **File ▸ Scan Installed Apps…** (⇧⌘B). The Scan Apps window opens on its own, so you can keep a report open in the main window.

## Scanning

- **Scan** (⌘R) analyses everything in `/Applications` and `~/Applications`.
- Hold ⇧ while clicking Scan, or click **Choose Folder…**, to scan a folder of your choosing.
- **Include system apps** adds `/System/Applications`: Apple's own apps, all notarised and usually low signal.
- **Stop** cancels a scan in progress. Apps already analysed stay in the table.

## Triage

Each row is one app with its risk tier, warning count and headline signals. Sort by any column and use the filter bar to narrow the table to, for example, unsigned apps, apps shipping tracking SDKs, apps without sandboxing, or apps with embedded launch items. The filter field matches on name, bundle identifier and path.

Select a row and choose **Analyze in Main Window** to hand that app to the main window for the full report, a monitored run, or an export.
