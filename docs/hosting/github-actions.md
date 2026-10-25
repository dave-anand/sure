# GitHub Actions on this fork

Automatic checks remain available after Actions is enabled on the fork:

| Workflow | Automatic trigger |
| --- | --- |
| Pull Request | Opened, updated and reopened PRs, except chart-only changes |
| Pipelock Security Scan | PRs targeting `main` |
| Chart CI | Relevant chart/version changes on PRs and `main` |
| Mobile CI | Relevant mobile changes on PRs and `main` |

The Pull Request workflow calls the shared CI workflow for Rails unit/integration
and browser tests, explicit-key encryption tests, Ruby/Biome lint and security
scans. Its manual trigger remains available for troubleshooting.

Publishing and external-service entrypoints are manual-only:

- Publish Docker image
- Mobile Release and iOS TestFlight
- Chart Release
- Sync Maybe mirror
- Update Docs
- LLM Evals

Pushing to `main`, creating a version tag or waiting for a schedule does not
start these workflows. Reusable build/upload workflows run only when called by
a parent workflow; Mobile CI can still build test artifacts without publishing
to an app store. Existing upstream repository guards on mirror sync and docs
updates remain in place, so those jobs skip on this fork until deliberately
configured. The LLM evaluation workflow can use a paid external API when run
manually with credentials.

Use **Actions → workflow → Run workflow** to start a manual workflow. The Docker
publisher defaults `push` to false: it builds and validates without registry
login, image/cache uploads, manifest publishing or associated release jobs.
Checking `push` enables publishing and the existing tag-dependent release
helpers. Configure and review credentials and destinations before using those
publishing paths. This change does not configure App Store, Google Play, Render,
Helm hosting or mirror destinations for this fork.

Enable Actions only after these trigger restrictions are on the default branch.
GitHub also has per-workflow enabled/disabled states: manual-only workflows
should be enabled once their automatic triggers are removed, so **Run workflow**
remains available. Administration commands for this fork include:

```sh
gh api --method PUT repos/dave-anand/sure/actions/permissions -F enabled=true
gh workflow enable pr.yml --repo dave-anand/sure
```

Workflow trigger and publishing changes can be checked with Actionlint, YAML
policy assertions and `git diff --check`, without triggering a publisher. Follow
the repository's development guide for the required application and CI checks;
this configuration change does not alter the test policy.
