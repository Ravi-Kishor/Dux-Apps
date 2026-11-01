# Dux Apps

Dux Apps is a release automation repository for packaging and publishing the upstream Dux projects as combined GitHub releases.

This repository does not contain the core application source for each app. Instead, it clones the latest upstream HEAD for the following components, builds them in a controlled environment, stages the install payload under `/usr`, and publishes release artifacts as tar.gz archives:

- Dux Calendar
- Dux GOP
- Dux Files
- Dux Greeter

## What this repository does

The workflow in `.github/workflows/build.yml` runs on:

- manual dispatch via GitHub Actions
- a scheduled cron job every 6 hours

It:

1. boots an Arch Linux container on `ubuntu-latest`
2. installs the build dependencies needed for Go-based tooling
3. clones the upstream repositories recursively, including submodules
4. builds each project
5. stages the built files under a temporary filesystem layout
6. creates release archives for each component
7. publishes a single combined GitHub Release containing all four assets

## Release artifacts

Each release includes:

- `dux-calendar-x86_64.tar.gz`
- `dux-gop-x86_64.tar.gz`
- `dux-files-x86_64.tar.gz`
- `dux-greeter-x86_64.tar.gz`

The release notes also include component version information, upstream commit SHAs, and SHA-256 checksums for the generated archives.

## Repository structure

```text
.
├── .github/
│   └── workflows/
│       └── build.yml
└── README.md
```

## Notes

- The repository is focused on packaging and artifact publishing rather than authoring the apps themselves.
- Each archive is meant to be extracted at the filesystem root so its staged `/usr` content is installed correctly.
- The combined release tag is generated from the upstream commit SHAs of the four repositories.

## License and source

The upstream application repositories are maintained by the Dux project ecosystem. This repository packages their built outputs into distributable release assets for convenience.
