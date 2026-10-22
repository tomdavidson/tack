# Seeded by tack (configs/tofu/tflint.copy.hcl) with overwrite: false.
# Add cloud provider plugins (aws, azurerm, google, etc.) per repository.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

rule "terraform_naming_convention" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}
