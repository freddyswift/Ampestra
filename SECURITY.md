# Security Policy

## Supported versions

Security fixes are provided for the latest published release and the current
`main` branch. Older releases may be asked to update before a fix is evaluated.

## Security model

Ampestra is designed for speakers on a trusted local network. Compatible KEF
speakers expose a local, unencrypted HTTP control API; Ampestra cannot add
authentication or transport encryption that the speaker does not support. The
app rejects public manual addresses, avoids speaker-controlled HTTP redirects,
and does not intentionally expose a listening network service.

The optional macOS media-key feature requests Input Monitoring and
Accessibility access. Those permissions are used only to receive and suppress
volume media-key events. The iPhone physical-button feature observes system
output-volume changes only while its capture mode is active.

## Reporting a vulnerability

Please do not report suspected vulnerabilities in a public issue. Use
[GitHub private vulnerability reporting](https://github.com/freddyswift/Ampestra/security/advisories/new)
so the report and any supporting details remain private while they are
investigated.

Include the affected Ampestra version, platform and OS version, speaker model,
reproduction steps, and the impact you observed. Do not include network
captures, private addresses, MAC addresses, now-playing data, or other personal
information unless essential; redact them whenever possible.

Use public issues for ordinary bugs, unsupported speakers, and feature
requests. Private vulnerability reporting is appropriate when an issue could
cross the local-network boundary, disclose private data, bypass a permission or
trust decision, execute unintended code, or materially control a speaker
without the user's action.

Ampestra does not currently operate a paid bug-bounty program. Test only on
devices and networks you own or are authorised to use, avoid disrupting normal
speaker operation, and give maintainers a reasonable opportunity to investigate
before publishing vulnerability details.

Ampestra is an unofficial, independent project and is not affiliated with or
endorsed by KEF.
