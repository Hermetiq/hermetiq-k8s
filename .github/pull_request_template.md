## Summary

<!-- What changes, why it is needed, and the user or operator impact. -->

## Related issue

<!-- Use "Closes #123" when merging this PR should close an issue. -->

## Scope

<!-- Check every area changed by this PR. -->

- [ ] `hermetiq` chart
- [ ] `buildbarn` chart
- [ ] `bb-worker-operator` chart
- [ ] Custom values or examples
- [ ] Documentation or repository tooling

## Testing

<!-- List exact commands and outcomes. Include representative non-default values when chart behavior changes. -->

```text
# command
# result
```

## Upgrade and compatibility impact

<!-- Describe changes to defaults, rendered resources, CRDs, RBAC, persistence, networking, or supported providers. Write "None" when not applicable. -->

## Contributor checklist

- [ ] The change is focused, documented, and does not include secrets or customer data.
- [ ] Changed charts pass `helm lint` and `helm template` with defaults and relevant override scenarios.
- [ ] New or changed chart behavior has automated coverage where practical.
- [ ] User-facing values and workflows are documented in the applicable chart README and examples.
- [ ] Backward compatibility and upgrade behavior have been considered.
- [ ] Security-sensitive changes use least-privilege RBAC and preserve the charts' pod/container hardening defaults.

## Release checklist

<!-- Required for releasable chart changes; mark items N/A for docs or repository-only changes. -->

- [ ] The chart `version` is bumped according to SemVer, or this is N/A.
- [ ] `appVersion` is updated when the deployed application version changes, or this is N/A.
- [ ] `artifacthub.io/changes` describes the user-visible change, or this is N/A.
- [ ] Dependency metadata and lock files are updated together, or this is N/A.
