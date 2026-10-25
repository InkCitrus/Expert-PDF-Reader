# Security Policy

## Supported versions

Only the latest release gets security fixes. Before reporting, please check that the problem still happens with the newest version from [Releases](https://github.com/InkCitrus/Expert-PDF-Reader/releases).

## Reporting a vulnerability

Please report security problems privately rather than in a public issue: open the repository's **Security** tab and choose **Report a vulnerability** ([direct link](https://github.com/InkCitrus/Expert-PDF-Reader/security/advisories/new)).

It helps to include:

- the app version (**Expert PDF Reader › About Expert PDF Reader**) and your macOS version;
- what happens, and the steps to reproduce it;
- if a particular PDF triggers it, the file or a way to make one.

This is a spare-time project, so expect a first reply within a week. Once a fix is released, the advisory is published, with credit to you if you'd like.

## Scope

Expert PDF Reader shows local PDF files with Apple's PDFKit and makes no network requests of its own. The app's code, its build scripts and its release workflow are in scope. Bugs in PDFKit or macOS itself are best reported to Apple through [Apple Security Research](https://security.apple.com).
