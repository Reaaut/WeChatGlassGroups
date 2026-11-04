# WCTheme development

This directory is reserved for the standalone WCTheme Rootless project.

## Source baseline
The working source baseline supplied by the maintainer is WCTheme 1.8.5. A first local revision has been prepared as WCTheme 1.8.6-dev1:
- Dock default width now uses the available host width instead of a hard-coded 305pt cap.
- The independent 52pt avatar and 8pt separation are preserved.
- Fixed-width preference mode remains available.

The source archive is not yet committed to this repository. The CI workflow will only produce a DEB after the complete source tree (Makefile, tweak sources, prefs, layout and resources) is present here.

## Build
The GitHub Actions workflow in .github/workflows/build.yml builds a Rootless package using Theos on iOS 15+ and uploads the resulting DEB as a workflow artifact.

Do not install a package until the workflow has completed successfully and the artifact has been checked.
