# Simple IaC Pipeline Guide

This repository contains a simple Terraform IaC pipeline for learning purposes. It deploys an S3 bucket to AWS using GitHub Actions.

## Step 1: Deploy the Backend Infrastructure
Terraform needs an S3 bucket and a DynamoDB table to store its state and manage locking. We use AWS CloudFormation for this initial setup.

1. Open the [AWS CloudFormation Console](https://console.aws.amazon.com/cloudformation).
2. Create a new stack using the provided `terraform-backend.yaml` file.
3. Once the stack is complete, check the **Outputs** tab for:
    * `StateBucketName`
    * `DynamoDBTableName`

## Step 2: Configure GitHub Secrets
For GitHub Actions to communicate with AWS, you need to store your AWS credentials securely.

1. Go to your GitHub repository: **Settings** > **Secrets and variables** > **Actions**.
2. Create a new Secrets Environment named "TEST"
3. Create the following secrets:
    * `AWS_ACCESS_KEY_ID`: Your AWS IAM Access Key.
    * `AWS_SECRET_ACCESS_KEY`: Your AWS IAM Secret Key.
    * `TF_BACKEND_BUCKET`: The name of the S3 bucket from CloudFormation.
    * `TF_BACKEND_DYNAMODB_TABLE`: The name of the DynamoDB table from CloudFormation.
    * `TF_BACKEND_REGION`: The AWS region where your CloudFormation stack was deployed (e.g., `us-east-1`).
## Step 3: Configure GitHub Actions Permissions: 
GitHub Actions Workflows by default can read from your repository, however they cannot write. The GitHub Action defined in the /.github/workflows/terraform.yml leverage yor to apply tags. Yor tags allow Cortex Cloud to trace IaC to deployed cloud assets. You can read more about yor here: https://yor.io/ 

In order for yor tagging to work in GitHub Actions, we'll need to enable write permissions in the repository: 
1. On GitHub, navigate to the main page of your repository.
2. Under your repository name, click Settings.
3. In the left sidebar, click Actions, then select General.
4. Scroll down to the "Workflow permissions" section.
5. Select the Read and write permissions option.
6. Click Save to apply the changes 

## Step 4: Configuring Destination Region (Optional)
While the GitHub Actions Secret `TF_BACKEND_REGION` should be set to the same region where you set up the CloudFormation backend, the actual region where you deploy the S3 bucket defined in the main.tf file is independnent of the backend region. If you wish to update the region where the S3 bucket will be deployed, then update the region defined in the variables.tf file. By default it is in us-east-1. 

## Step 5: The CI/CD Workflow
The pipeline in `.github/workflows/terraform.yml` performs the following on every pull request:
1. `terraform init`: Initializes the backend using the secrets provided.
2. `terraform fmt`: Checks for proper code formatting.
3. `terraform plan`: Generates a preview of the changes.

When you merge into the **main** branch:
5. `terraform apply`: Deploys the S3 bucket to your AWS account automatically.

## Files Overview
* `terraform-backend.yaml`: CloudFormation template for the state backend.
* `provider.tf`: Configures the AWS provider.
* `backend.tf`: Configures the remote state storage (filled at runtime via GitHub Secrets).
* `main.tf`: Defines the S3 bucket resource to be deployed.
* `variables.tf`: Contains the AWS region variable.
* `.github/workflows/terraform.yml`: The GitHub Actions pipeline definition.

## Step 6: Configure the GitHub Integration in Cortex Cloud
Now that you have a basic IaC pipeline, configure the GitHub SaaS integration in Cortex Cloud. This will enable multiple types of scans on your GitHub repository: 
1. Branch Periodic Scanning of the repository
2. Pull Request Scanning to PRs to the main branch (and others if configured)
3. CI/CD Risk scanning of the GitHub and GitHub Actions configuration itself 

Go to Data Sources and Integrations > Add New > Search for "GitHub SaaS" and follow the steps to onboard the repository. Note that afterwards you'll need to add an egress path for GitHub SaaS with your GitHub username as the value. https://docs-cortex.paloaltonetworks.com/r/Cortex/Cortex-Gateway-Administrator-Guide/Egress-configurations 

You can read more at: https://docs-cortex.paloaltonetworks.com/r/Cortex-CLOUD/Cortex-Cloud-Runtime-Security-Documentation/GitHub-Cloud 

Once set up, Cortex Cloud will run an initial scan of your repositories and will initiate PR scans for the main branch. 

## Step 7: Configure a Business Application and AppSec Policy in Cortex Cloud
Now that you have GitHub integrated, you can create a business application to contain the code and cloud assets that relate to the pipeline. Try creating a business application manually, based on your github repository used in this lab. 

To create a business application, go to Modules > Application Security > Business Applications > and select "create application" then "New Application". Enter in the values, such as the business criticality and the owner (yourself) and use the GitHub repository as the criteria for your application. 

Note that once created, Business Applications may take several hours to fully populate all assets from code to cloud. 
You can read more at: https://docs-cortex.paloaltonetworks.com/r/Cortex-Cloud-Posture-Management/Cortex-Cloud-Application-Security/Defining-Business-Applications 

## Step 8: Create an AppSec Policy 
Once your business application is created, try creating an AppSec Policy that disallows certain IaC misconfigurations for assets involved with your business application. 

Go to Modules > Application Security > AppSec Policies and hit "Add Policy". Use a "Code Scanner" policy, that selects for "IaC Misconfigurations" as the finding type, that matches for Business Application Names that matches the name of your business applicaiton in the scope, and set it to block PR scan for the trigger and action. 

You can read more here: https://docs-cortex.paloaltonetworks.com/r/Cortex-Cloud-Posture-Management/Code-Security/Create-Cortex-Cloud-Application-Security-policies 
