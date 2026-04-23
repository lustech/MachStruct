# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest release | Yes |
| Older releases | No |

## Reporting a Vulnerability

If you discover a security vulnerability in MachStruct, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, please use [GitHub Security Advisories](https://github.com/lustech/MachStruct/security/advisories/new) to report the issue privately. This allows us to assess and address the vulnerability before it becomes public.

You can expect:
- An acknowledgement within 48 hours
- A status update within 7 days
- A fix or mitigation plan for confirmed vulnerabilities

## Scope

MachStruct is a local document viewer/editor. Its primary attack surface is malicious input files (JSON, XML, YAML, CSV). If you find a way to cause code execution, memory corruption, or sandbox escape via a crafted file, that qualifies as a security issue.
