# Releasing Soft Bun's Oven

Publish completed SBO changes to GitHub by default. Run `python3 build.py` to test and rebuild the release. Commit the source changes, `Oven.mpackage`, and `VERSION` together, then push to `origin/main` and verify the release is available. The package updater reads `VERSION` and `Oven.mpackage` from that branch.
