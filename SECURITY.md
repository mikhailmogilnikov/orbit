# Security

Orbit runs agent CLIs, language servers and shell commands with your user's
permissions (it isn't sandboxed), and it updates itself through Sparkle, so
security problems matter.

## Reporting a vulnerability

Please don't open a public issue. Report it privately through
[GitHub's security advisories](https://github.com/mikhailmogilnikov/orbit/security/advisories/new),
or by email to mikhail.mogilnikov02@gmail.com.

Include what's affected, how to reproduce it and what an attacker could do
with it. You'll get an answer within a week; fixes ship in the next release,
and you'll be credited unless you'd rather not be.

## Supported versions

Only the latest release gets fixes. Orbit updates itself, so that's the one
to test against.

## Out of scope

What an agent does with the permissions you gave it is up to the agent and
your choices in its permission prompts; problems in the agents, language
servers or extensions themselves belong to their own projects.
