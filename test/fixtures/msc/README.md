# Frozen MSC comparison inputs

These are the saved August 2026 Obex, Osero and Grove reports used by the Tally
examples. They are not a new execution of the MSC process. `manifest.json` names
the source checkout commit and SHA-256 of each input; report generation verifies
these checksums before using the packaged baseline.

The Grove configuration is reduced to venue ID and chain, the only fields used
by the coverage report. The manifest records the original configuration hash
and that transformation. Provenance and summary files are preserved byte for
byte, including their known disagreements. Grove E12 and E22 discrepancies and
the SDE double-subtraction issue are exposed in the generated comparison.

The source revision identifies the checkout from which files were copied; each
report also records its own generation timestamp and MSC version. It does not
prove that this checkout was used to generate those older saved reports.

To refresh, deliberately select and review a new MSC snapshot, replace the input
files, recompute the manifest, and regenerate all comparisons and tests. Do not
change fixtures merely to make an unexplained accounting difference disappear.
Use `--pipeline` for exploratory comparisons against a different MSC checkout.
