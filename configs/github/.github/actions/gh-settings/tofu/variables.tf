# .github/actions/gh-settings/tofu/variables.tf
variable "repo" {
  description = "Merged repository blueprint produced by merge.js"
  type        = any
}
