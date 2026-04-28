# moon-raa

Manage review apps and artifacts (RAA) for a Moon monorepo. Creates GitHub Deployments, runs per-project build/teardown tasks, and produces a manifest of artifacts.

## Usage

```yaml
- uses: ./.github/actions/moon-raa
  with:
    command: run # or rm
    pr-number: ${{ inputs.pr-number }}
    github-token: ${{ secrets.GITHUB_TOKEN }}
```

## Inputs

| Input          | Required | Default | Description                                               |
| -------------- | -------- | ------- | --------------------------------------------------------- |
| `command`      | yes      |         | `run` to build review artifacts, `rm` to tear down        |
| `pr-number`    | yes      |         | PR number                                                 |
| `prefix`       | no       | `raa`   | Environment name prefix (produces `<prefix>-pr-<number>`) |
| `github-token` | yes      |         | `GITHUB_TOKEN` for deployment API calls                   |

## Outputs

| Output          | Command | Description                                   |
| --------------- | ------- | --------------------------------------------- |
| `deployment-id` | run     | GitHub Deployment ID                          |
| `environment`   | both    | Environment name (e.g. `raa-pr-42`)           |
| `project-count` | both    | Number of projects processed                  |
| `summary`       | both    | Markdown summary for `GITHUB_STEP_SUMMARY`    |
| `manifest`      | run     | Full payload as JSON                          |
| `clean`         | rm      | `true` if teardown completed without warnings |

## Project Configuration

The action discovers affected projects via `moon query projects --affected` and filters to those with `raa` metadata in their `moon.yml`.

Both `run` and `rm` fields are required. Projects missing either field are skipped with a warning.

```yaml
# plugins/my-plugin/moon.yml
project:
  metadata:
    raa:
      run: review # task to run for review build
      rm: review-rm # task to run for teardown
```

The action executes `moon run <project-id>:<raa.run>` during `command: run` and `moon run <project-id>:<raa.rm>` during `command: rm`.

## Workflow Integration

RAA is dispatched from `pr.yml` via `raa.yml`:

1. PR push triggers `pr.yml`, which runs full CI.
2. After the gate passes, if the `review-app` label is present, `pr.yml` dispatches `raa.yml` with `command: run`.
3. On PR close, `pr.yml` dispatches `raa.yml` with `command: rm`.
4. `raa.yml` can also be triggered manually from the Actions tab.

## How It Works

**`run` command:**

1. Discovers affected projects with valid `raa` metadata.
2. Deactivates any existing deployments for the environment.
3. Creates a new GitHub Deployment.
4. Runs each project's `raa.run` task sequentially.
5. Sets deployment status to `success` or `failure`.

**`rm` command:**

1. Reads the deployment manifest to find projects.
2. Runs each project's `raa.rm` task.
3. Deactivates and deletes the deployment.
4. Deletes the GitHub environment.
