terragrunt = {
  terraform {
    source = "git::git@github.com:gruntwork-io/modules-example.git//consul?ref=v0.0.2"
  }

  include {
    path = "${find_in_parent_folders()}"
  }
}
