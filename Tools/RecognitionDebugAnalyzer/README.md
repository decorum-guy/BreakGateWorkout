# Recognition Debug Analyzer

Offline analyzer for BreakGateWorkout `Recognition Debug` exports.

It reads either:

- an export folder containing `metadata.json`, `pose-samples.jsonl`, `exercise-reviews.json`, and optional `video.mp4`
- or a `.zip` export produced by Recognition Debug

## Run

From the repo root:

```bash
python3 Tools/RecognitionDebugAnalyzer/analyze_debug_export.py /path/to/debug-export-folder --out /path/to/report-folder
```

Or with a zip:

```bash
python3 Tools/RecognitionDebugAnalyzer/analyze_debug_export.py /path/to/debug-export.zip --out /path/to/report-folder
```

Open the report:

```bash
open /path/to/report-folder/index.html
```

## Manual labels

The analyzer always creates:

- `manual-labels-template.csv`

Fill it in and re-run with:

```bash
python3 Tools/RecognitionDebugAnalyzer/analyze_debug_export.py /path/to/debug-export-folder --out /path/to/report-folder --labels /path/to/manual-labels.csv
```

Then the report will also include:

- `labels-summary.json`

## Output

The report folder contains:

- `index.html`
- `summary.json`
- `session-summary.csv`
- `events.csv`
- `segments.csv`
- `suspicious-moments.csv`
- `missed-candidates.csv`
- `manual-labels-template.csv`
- `failure-reasons.json`
- `frames/`
- `plots/`

`frames/` contains pose-based skeleton snapshots even if no `video.mp4` exists.

## Video support

Video is optional.

If `video.mp4` exists and `ffprobe` / `ffmpeg` are installed, the analyzer can:

- inspect basic stream info
- extract still frames around suspicious rep events

If those tools are missing, the analyzer still produces the full pose-based report.

## Optional dependencies

Current implementation is Python stdlib first.

Optional external tools:

- `ffprobe` for video metadata
- `ffmpeg` for frame extraction

No extra Python packages are required for the base report.

## What it analyzes

- session metadata and camera conditions
- exercise review summary
- full pose sample timeline
- rep increment events
- suspicious rep events
- missed movement candidates based on motion without rep progress
- failure reason aggregation
- pose-only skeleton visualizations

## Notes

- Vision coordinates are rendered with bottom-left origin preserved correctly.
- The analyzer does not modify app logic.
- Generated reports should not be committed unless explicitly requested.
