# amplify_common

Shared Ballerina library for `amplify-api` and `amplify-jobs` (ADR-020).

Modules: `types`, `events`, `linkedin`, `googlechat`, `crypto`, `resilience`.
Bounded contexts and repositories live in `amplify_domain` (ADR-021).

Publish to the local repository before building a consumer:

```sh
bal pack && bal push --repository=local
```
