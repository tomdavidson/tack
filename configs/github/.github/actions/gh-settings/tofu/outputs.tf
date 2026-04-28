# .github/actions/gh-settings/tofu/outputs.tf
output "repo_full_name" {
  value = github_repository.this.full_name
}

output "ruleset_ids" {
  value = { for k, r in github_repository_ruleset.default_branch : k => r.id }
}
