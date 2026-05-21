# nsfw_detect eval harness

A small command-line harness that runs a labelled image set through the
plugin's one-shot `scanFile` API, then reports precision / recall / F1 per
NSFW category per model. Lives under `tools/eval/` rather than as a separate
package so it can import the plugin's internal types directly.

## Dataset format

A JSON array of `{path, truth, notes?}` objects. Paths are resolved against
the dataset file's directory. Truth labels must be one of the
`NsfwCategory` enum names: `safe`, `suggestive`, `nudity`, `explicitNudity`,
`unknown`.

```json
[
  {"path": "safe/cat.png", "truth": "safe"},
  {"path": "nsfw/example.png", "truth": "nudity", "notes": "edge case"}
]
```

## Running the harness

The harness depends on the plugin's native binary, so it must run from a
context where `scanFile` works end-to-end:

```sh
# from the plugin root, with example app's pods installed
dart run tools/eval/bin/run.dart path/to/dataset.json \
    --model opennsfw2_coreml \
    --out report.md
```

Output formats:

- `--format md` (default) — Markdown table for CI logs / PR comments.
- `--format json` — machine-readable, with full confusion matrix.

## Smoke fixture

`tools/eval/fixtures/smoke_dataset.json` is the tiny canonical set checked
into the repo. It points at solid-colour PNGs intentionally — those round-
trip safely as `safe` for any classifier, so the harness can be smoke-tested
on a developer machine without bundling real-world content. Replace with
your own labelled set for actual model evaluation.

## CI integration

See `.github/workflows/eval.yml` (when configured) for the smoke-only PR job;
it gates against a > 10% drop in macro-F1 on the canonical fixture so
gross regressions in the inference path get caught at PR time.
