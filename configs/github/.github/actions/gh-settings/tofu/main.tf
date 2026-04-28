# .github/actions/gh-settings/tofu/main.tf
#
# Consumes blueprint.auto.tfvars.json produced by merge.js and applies the
# merged GitHub configuration to a single repository. Org-level resources
# (github_organization_ruleset, etc.) are NOT managed here; they live in the
# central github-management repo's own OpenTofu root.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.3"
    }
  }
}

provider "github" {
  owner = var.repo.owner
}

locals {
  repo           = var.repo
  merge_controls = try(local.repo.merge_controls, {})
  security       = try(local.repo.security, {})
  labels         = try(local.repo.labels, {})
  rulesets       = try(local.repo.rulesets, {})
}

resource "github_repository" "this" {
  name                   = local.repo.name
  description            = try(local.repo.description, null)
  homepage_url           = try(local.repo.homepage_url, null)
  visibility             = try(local.repo.visibility, "private")
  topics                 = try(local.repo.topics, [])
  has_issues             = try(local.repo.has_issues, true)
  has_projects           = try(local.repo.has_projects, false)
  has_wiki               = try(local.repo.has_wiki, false)
  has_discussions        = try(local.repo.has_discussions, false)

  allow_squash_merge     = try(local.merge_controls.allow_squash_merge, true)
  allow_merge_commit     = try(local.merge_controls.allow_merge_commit, false)
  allow_rebase_merge     = try(local.merge_controls.allow_rebase_merge, false)
  allow_auto_merge       = try(local.merge_controls.allow_auto_merge, true)
  delete_branch_on_merge = try(local.merge_controls.delete_branch_on_merge, true)

  squash_merge_commit_title   = try(local.merge_controls.squash_merge_commit_title, "PR_TITLE")
  squash_merge_commit_message = try(local.merge_controls.squash_merge_commit_message, "PR_BODY")

  vulnerability_alerts = try(local.security.vulnerability_alerts, true)

  lifecycle {
    ignore_changes = [
      # Repo creation is out of scope for this action; we manage settings only.
      auto_init,
      license_template,
      gitignore_template,
    ]
  }
}

resource "github_repository_ruleset" "default_branch" {
  for_each = try(local.rulesets, {})

  repository  = github_repository.this.name
  name        = each.key
  target      = try(each.value.target, "branch")
  enforcement = try(each.value.enforcement, "active")

  conditions {
    ref_name {
      include = try(each.value.conditions.ref_name.include, ["~DEFAULT_BRANCH"])
      exclude = try(each.value.conditions.ref_name.exclude, [])
    }
  }

  dynamic "rules" {
    for_each = [each.value.rules]
    content {
      deletion         = try(rules.value.deletion, null)
      non_fast_forward = try(rules.value.non_fast_forward, null)

      dynamic "pull_request" {
        for_each = try([rules.value.pull_request], [])
        content {
          required_approving_review_count   = try(pull_request.value.required_approving_review_count, 1)
          dismiss_stale_reviews_on_push     = try(pull_request.value.dismiss_stale_reviews_on_push, true)
          require_code_owner_review         = try(pull_request.value.require_code_owner_review, false)
          required_review_thread_resolution = try(pull_request.value.required_review_thread_resolution, false)
        }
      }

      dynamic "required_status_checks" {
        for_each = try([rules.value.required_status_checks], [])
        content {
          strict_required_status_checks_policy = try(required_status_checks.value.strict_required_status_checks_policy, true)

          dynamic "required_check" {
            for_each = try(required_status_checks.value.required_checks, [])
            content {
              context = required_check.value.context
            }
          }
        }
      }
    }
  }
}

resource "github_issue_label" "this" {
  for_each   = try(local.labels, {})
  repository = github_repository.this.name
  name       = each.key
  color      = replace(each.value, "#", "")
}
