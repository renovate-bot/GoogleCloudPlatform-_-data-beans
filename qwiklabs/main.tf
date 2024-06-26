####################################################################################
# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     https://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
####################################################################################

####################################################################################
# README
# Changes for Qwiklabs
# 1 - moved files to this directory
# 2 - change the path ../terraform-modules to ./terraform-modules
# 3 - added variables
# 4 - added data for project number 
# 5 - changed var.project_number to data.google_project.project.number
# 6 - added runtime.yaml
# 7 - hard coded org id = 0
####################################################################################


terraform {
  required_providers {
    google = {
      source                = "hashicorp/google-beta"
      version               = ">= 4.52, < 6"
      configuration_aliases = [google.service_principal_impersonation]
    }
  }
}


####################################################################################
# Providers
# Multiple providers: https://www.terraform.io/language/providers/configuration
# The first is the default (who is logged in) and creates the project and service principal that provisions the resources
# The second is the service account created by the first and is used to create the resources
####################################################################################
# Default provider (uses the logged in user to create the project and service principal for deployment)
provider "google" {
  project = local.local_project_id
}


####################################################################################
# Provider that uses service account impersonation (best practice - no exported secret keys to local computers)
####################################################################################
provider "google" {
  alias                       = "service_principal_impersonation"
  impersonate_service_account = "${local.local_project_id}@${local.local_project_id}.iam.gserviceaccount.com"
  project                     = local.local_project_id
  region                      = var.default_region
  zone                        = var.default_zone
}


####################################################################################
# Create the project and grants access to the current user
####################################################################################
module "project" {
  # Run this as the currently logged in user or the service account (assuming DevOps)
  count           = data.google_project.project.number == "" ? 1 : 0
  source          = "./terraform-modules/project"
  project_id      = local.local_project_id
  org_id          = var.org_id
  billing_account = var.billing_account
}

data "google_project" "project" {
  project_id = var.gcp_project_id
}

####################################################################################
# Creates a service account that will be used to deploy the subsequent artifacts
####################################################################################
module "service-account" {
  # This creates a service account to run portions of the following deploy by impersonating this account
  source                = "./terraform-modules/service-account"
  project_id            = local.local_project_id
  org_id                = var.org_id
  impersonation_account = local.local_impersonation_account 
  gcp_account_name      = "${var.gcp_account_name}@qwiklabs.net"
  environment           = var.environment

  depends_on = [
    module.project
  ]
}


####################################################################################
# Enable all the cloud APIs that will be used by using Batch Mode
# Batch mode is enabled on the provider (by default)
####################################################################################
module "apis-batch-enable" {
  source = "./terraform-modules/apis-batch-enable"

  project_id       = local.local_project_id
  project_number   = data.google_project.project.number == "" ? module.project[0].output-project-number : data.google_project.project.number

  depends_on = [
    module.project,
    module.service-account
  ]
}

resource "time_sleep" "service_account_api_activation_time_delay" {
  create_duration = "120s"
  depends_on = [
    module.project,
    module.service-account,
    module.apis-batch-enable
  ]  
}


####################################################################################
# Turns off certain Org Policies required for deployment
# They will be re-enabled by a second call to Terraform
# This step is Skipped when deploying into an existing project (it is assumed a person disabled by hand)
####################################################################################
module "org-policies" {
  count  = var.environment == "GITHUB_ENVIRONMENT" && var.org_id != "0" ? 1 : 0
  source = "./terraform-modules/org-policies"

  # Use Service Account Impersonation for this step. 
  # NOTE: This step must be done using a service account (a user account cannot change these policies)
  # providers = { google = google.service_principal_impersonation }

  project_id = local.local_project_id

  depends_on = [
    module.project,
    module.service-account,
    module.apis-batch-enable,
    time_sleep.service_account_api_activation_time_delay
  ]
}


####################################################################################
# This deploy the majority of the Google Cloud Infrastructure
####################################################################################
module "resources" {
  source = "./terraform-modules/resources"

  # Use Service Account Impersonation for this step. 
  # providers = { google = google.service_principal_impersonation }

  gcp_account_name                    = "${var.gcp_account_name}@qwiklabs.net"
  project_id                          = local.local_project_id

  dataplex_region                     = var.dataplex_region
  multi_region                        = var.multi_region
  bigquery_non_multi_region           = var.bigquery_non_multi_region
  vertex_ai_region                    = var.vertex_ai_region
  data_catalog_region                 = var.data_catalog_region
  appengine_region                    = var.appengine_region
  colab_enterprise_region             = var.colab_enterprise_region

  random_extension                    = random_string.project_random.result
  project_number                      = data.google_project.project.number == "" ? module.project[0].output-project-number : data.google_project.project.number
  deployment_service_account_name     = var.deployment_service_account_name

  terraform_service_account           = "" # module.service-account.deployment_service_account

  bigquery_data_beans_curated_dataset = var.bigquery_data_beans_curated_dataset
  data_beans_curated_bucket           = local.data_beans_curated_bucket
  data_beans_code_bucket              = local.code_bucket
  data_beans_analytics_hub            = var.data_beans_analytics_hub

  depends_on = [
    module.project,
    module.service-account,
    module.apis-batch-enable,
    time_sleep.service_account_api_activation_time_delay,
    module.org-policies,
  ]
}


####################################################################################
# Deploy BigQuery stored procedures / sql scripts
###################################################################################
module "sql-scripts" {
  source = "./terraform-modules/sql-scripts"

  # Use Service Account Impersonation for this step. 
  # providers = { google = google.service_principal_impersonation }

  gcp_account_name                    = "${var.gcp_account_name}@qwiklabs.net"
  project_id                          = local.local_project_id

  dataplex_region                     = var.dataplex_region
  multi_region                     = var.multi_region
  bigquery_non_multi_region           = var.bigquery_non_multi_region
  vertex_ai_region                    = var.vertex_ai_region
  data_catalog_region                 = var.data_catalog_region
  appengine_region                    = var.appengine_region
  colab_enterprise_region             = var.colab_enterprise_region

  random_extension                    = random_string.project_random.result
  project_number                      = data.google_project.project.number == "" ? module.project[0].output-project-number : data.google_project.project.number
  deployment_service_account_name     = var.deployment_service_account_name

  terraform_service_account           = "" # module.service-account.deployment_service_account

  bigquery_data_beans_curated_dataset = var.bigquery_data_beans_curated_dataset
  data_beans_curated_bucket           = local.data_beans_curated_bucket
  data_beans_code_bucket              = local.code_bucket
  data_beans_analytics_hub            = var.data_beans_analytics_hub


  depends_on = [
    module.project,
    module.service-account,
    module.apis-batch-enable,
    time_sleep.service_account_api_activation_time_delay,
    module.org-policies,
    module.resources
  ]
}


####################################################################################
# Deploy supporting files to GCS
####################################################################################
module "deploy-files-module" {
  source = "./terraform-modules/deploy-files"

  # Use Service Account Impersonation for this step. 
  # providers = { google = google.service_principal_impersonation }

  gcp_account_name                    = "${var.gcp_account_name}@qwiklabs.net"
  project_id                          = local.local_project_id

  dataplex_region                     = var.dataplex_region
  multi_region                     = var.multi_region
  bigquery_non_multi_region           = var.bigquery_non_multi_region
  vertex_ai_region                    = var.vertex_ai_region
  data_catalog_region                 = var.data_catalog_region
  appengine_region                    = var.appengine_region
  colab_enterprise_region             = var.colab_enterprise_region

  random_extension                    = random_string.project_random.result
  project_number                      = data.google_project.project.number == "" ? module.project[0].output-project-number : data.google_project.project.number
  deployment_service_account_name     = var.deployment_service_account_name

  terraform_service_account           = "" # module.service-account.deployment_service_account

  bigquery_data_beans_curated_dataset = var.bigquery_data_beans_curated_dataset
  data_beans_curated_bucket           = local.data_beans_curated_bucket
  data_beans_code_bucket              = local.code_bucket
  data_beans_analytics_hub            = var.data_beans_analytics_hub

  depends_on = [
    module.project,
    module.service-account,
    module.apis-batch-enable,
    time_sleep.service_account_api_activation_time_delay,
    module.org-policies,
    module.resources
  ]
}



####################################################################################
# Deploy notebooks to Colab (Dataform)
####################################################################################
module "deploy-notebooks-module" {
  source = "./terraform-modules/colab-deployment/terraform-module"

  # Use Service Account Impersonation for this step. 
  # providers = { google = google.service_principal_impersonation }

  project_id                          = local.local_project_id
  vertex_ai_region                    = var.vertex_ai_region
  bigquery_data_beans_curated_dataset = var.bigquery_data_beans_curated_dataset
  data_beans_curated_bucket           = local.data_beans_curated_bucket
  data_beans_code_bucket              = local.code_bucket
  dataform_region                     = "us-central1"
  cloud_function_region               = "us-central1"
  workflow_region                     = "us-central1"
  random_extension                    = random_string.project_random.result
  gcp_account_name                    = "${var.gcp_account_name}@qwiklabs.net"

  depends_on = [
    module.project,
    module.service-account,
    module.apis-batch-enable,
    time_sleep.service_account_api_activation_time_delay,
    module.org-policies,
    module.resources
  ]
}



####################################################################################
# Outputs (Gather from sub-modules)
# Not really needed, but are outputted for viewing
####################################################################################
output "gcp_account_name" {
  value = "${var.gcp_account_name}@qwiklabs.net"
}

output "project_id" {
  value = local.local_project_id
}

output "project_number" {
  value = data.google_project.project.number == "" ? module.project[0].output-project-number : data.google_project.project.number
}

output "deployment_service_account_name" {
  value = var.deployment_service_account_name
}

output "org_id" {
  value = var.org_id
}

output "billing_account" {
  value = var.billing_account
}

output "region" {
  value = var.default_region
}

output "zone" {
  value = var.default_zone
}

output "dataplex_region" {
  value = var.dataplex_region
}

output "multi_region" {
  value = var.multi_region
}

output "bigquery_non_multi_region" {
  value = var.bigquery_non_multi_region
}

output "vertex_ai_region" {
  value = var.vertex_ai_region
}

output "data_catalog_region" {
  value = var.data_catalog_region
}

output "appengine_region" {
  value = var.appengine_region
}

output "shared_demo_project_id" {
  value = var.shared_demo_project_id
}

output "aws_omni_biglake_dataset_region" {
  value = var.aws_omni_biglake_dataset_region
}

output "aws_omni_biglake_dataset_name" {
  value = var.aws_omni_biglake_dataset_name
}

output "aws_omni_biglake_connection" {
  value = var.aws_omni_biglake_connection
}

output "aws_omni_biglake_s3_bucket" {
  value = var.aws_omni_biglake_s3_bucket
}

output "azure_omni_biglake_adls_name" {
  value = var.azure_omni_biglake_adls_name
}

output "azure_omni_biglake_dataset_name" {
  value = var.azure_omni_biglake_dataset_name
}

output "azure_omni_biglake_dataset_region" {
  value = var.azure_omni_biglake_dataset_region
}

output "random_string" {
  value = random_string.project_random.result
}

output "local_impersonation_account" {
  value = local.local_impersonation_account
}

output "local_azure_omni_biglake_connection" {
  value = local.local_azure_omni_biglake_connection
}


# Tells the deploy.sh where to upload the "terraform" output json file
# A file named "tf-output.json" will be places at gs://${terraform-output-bucket}/terraform/output
output "terraform-output-bucket" {
  value = local.code_bucket
}
