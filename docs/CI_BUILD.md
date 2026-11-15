# RD03v2 GitHub Actions validation

This workflow separates cheap source/configuration checks from a full signed firmware build.

## Automatic static checks

A push to `work/rd03v2-dualwan-mwan3-baseline` and a pull request targeting `main` run:

- `git diff --check` and branch ancestry check;
- Bash syntax checks for shell scripts;
- Python bytecode compilation for `tools/`;
- RD03v2 target, NSS profile, mwan3 package and image manifest assertions;
- check that no `private-key.pem` is tracked.

These checks do **not** compile OpenWrt, do not validate downloaded feeds, do not build ECM, and do not prove that an image boots.

## Full build

The full build job runs only on a push whose commit message contains `[full-build]`.

Before requesting such a run:

1. Open repository Settings → Secrets and variables → Actions.
2. Add a repository secret named `RD03V2_PRIVATE_KEY_PEM`.
3. Its value must be the PEM contents of the private EC signing key corresponding exactly to the committed `keys/public-key.pem`.
4. Never put the private key in the repository, issue, chat, workflow file or build artifact.
5. Make a deliberate commit with `[full-build]` in its message.

The workflow creates the key only in the runner's temporary workspace, validates it against the public key and uses the project's normal `build.sh` and `verify-v2.sh` path. It uploads logs only and does not publish firmware binaries or a package repository.

The build is stamped with an `example.invalid` package-repository URL. This deliberately makes the CI image unsuitable for installation as a user-facing release until a real package repository URL and release process are configured.

## Resource caveat

The workflow uses the standard GitHub-hosted Ubuntu runner with two build jobs. The project requires at least 4 GiB of available RAM during the final build. Disk capacity and run duration may still be limiting; a failed runner build must be classified by its actual log, not silently treated as a source-code failure.

## Current state

Adding this workflow does not mean a build has run. A green static-check job is not a firmware compilation result. Report separately:

- STATIC PASS/FAIL;
- PREPARE_ONLY PASS/FAIL;
- FULL BUILD PASS/FAIL;
- `verify-v2.sh` PASS/FAIL;
- hardware validation PASS/FAIL/NOT TESTED.
