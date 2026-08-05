# E1 v01 synthetic evaluation candidate

This immutable revision contains 150 synthetic cases and no production or user-derived records. It is an initial_hypothesis evaluation corpus, not evidence of production quality.

The physical split is baseline (100), recent (25), and holdout (25), using the baseline_recent_holdout_nonoverlap policy. Every case has one stable ID and occurs in exactly one file. Thirty boundary cases (20%) seed the BadCase workflow; they are hypotheses pending evaluation, not observed failures.

source.json freezes source, license, sensitivity, retention, and deletion policy. review.json keeps Product and Security approval pending_external and disables formal publication. split.json freezes split counts. The P10-005 evidence manifest records POSIX paths, raw byte SHA-256 and size, RFC8785_JCS identity, and the dataset Git tree OID.

Change control is append-only: publish a new version directory rather than overwriting v01. Rollback returns evaluation to the immutable P04 E0 manifest; it never edits failing fixtures to hide a regression.
