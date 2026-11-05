# better-actions

Reusable GitHub Actions workflows and composite actions for Flutter packages and apps, shared across my repositories.

Consumers keep a small caller workflow and the logic lives here, so a CI fix is made once.

## Workflows

| Workflow | Purpose |
| --- | --- |
| [`ci.yml`](.github/workflows/ci.yml) | Analyze, test, validate the package, and run integration tests (platforms chosen via the required `platforms` input) |
| [`create-release.yml`](.github/workflows/create-release.yml) | Validate, run the integration tests for the required `platforms` input, then create a tag and GitHub release derived from `pubspec.yaml`, and dispatch the publish workflow |
| [`publish.yml`](.github/workflows/publish.yml) | Publish to pub.dev via OIDC |
| [`deploy-demo.yml`](.github/workflows/deploy-demo.yml) | Build the example app and deploy it to GitHub Pages |

## Usage

```yaml
# .github/workflows/ci.yml in the consuming repo
name: CI
on:
  pull_request:
    branches: [main]

permissions:
  contents: read

jobs:
  ci:
    uses: Tkko/better-actions/.github/workflows/ci.yml@v1
    with:
      platforms: web,linux
      integration-test-working-directory: example
```

Pin to a major tag (`@v1`) for convenience, or a full commit SHA for stricter supply-chain control. Avoid `@main`.

### Publishing to pub.dev

pub.dev validates the **calling** repository and workflow file. Keep a `publish.yml` in each package repo that calls the reusable one, and configure its tag pattern in the package's Admin tab on pub.dev. The caller must grant the permissions the reusable workflow needs:

```yaml
jobs:
  publish:
    permissions:
      contents: read
      id-token: write
    uses: Tkko/better-actions/.github/workflows/publish.yml@v1
```

### Inputs

Each workflow's inputs are listed under `workflow_call` in its file. Inputs are treated as a public API: names and defaults only change in a new major version.

## Composite actions

Step-level building blocks used by the workflows, under [`.github/actions`](.github/actions): `setup-flutter`, `validate-package`, `release-metadata`, `create-release`, `publish-package`, `build-pages-demo`, `deploy-pages-demo`, and `integration-{android,ios,linux,desktop,web}`.

Each reusable workflow checks this repository out at `job.workflow_sha`, so the actions always match the workflow version the caller pinned.

## Versioning

Semantic versioning with moving major tags. `v1` always points to the latest `v1.x.y`. Breaking changes to inputs, outputs, or required permissions go in a new major version.

## Security

- No secrets live in this repository; secrets stay in each consuming repo. Publishing uses OIDC.
- Workflows default to `contents: read`, with elevated permissions granted per job.
- Third-party actions are pinned to full commit SHAs.
- See [SECURITY.md](SECURITY.md) to report a vulnerability.

## License

[MIT](LICENSE). New package READMEs start from [`templates/PACKAGE_README.md`](templates/PACKAGE_README.md).

---

<div align="center">

Made by [Tornike](https://www.linkedin.com/in/thornike/) · [Discord](https://rebrand.ly/qwc3s0d) · [Ko-fi](https://ko-fi.com/flutterman) · [Buy Me a Coffee](https://www.buymeacoffee.com/fman)

</div>
