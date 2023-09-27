#!/bin/bash

# This script automates the deployment of an Azure Red Hat OpenShift (ARO) cluster
# using Terraform on Microsoft Azure.

# Print the menu
echo "================================================="
echo "Install ARO Cluster. Choose an option (1-5): "
echo "================================================="
options=(
  "Terraform Init"
  "Terraform Validate"
  "Terraform Plan"
  "Terraform Apply"
  "Quit"
)

# Select an option
COLUMNS=0
select opt in "${options[@]}"; do
  case $opt in
  "Terraform Init")
    terraform init
    exit
    ;;
  "Terraform Validate")
    terraform validate
    exit
    ;;
  "Terraform Plan")
    op="plan"
    break
    ;;
  "Terraform Apply")
    op="apply"
    break
    ;;
  "Quit")
    exit
    ;;
  *) echo "Invalid option $REPLY" ;;
  esac
done

# Azure Resource Naming Prefix
resourcePrefix="<azure-resources-name-prefix>"
aroDomain="${resourcePrefix,,}"
aroClusterServicePrincipalDisplayName="${resourcePrefix,,}-aro-sp-${RANDOM}"
pullSecret=$(cat pull-secret.txt)

# Name and location of the resource group for the ARO cluster
aroResourceGroupName="${resourcePrefix}RG"
location="northeurope"

# Subscription information
subscriptionId=$(az account show --query id --output tsv)
subscriptionName=$(az account show --query name --output tsv)
tenantId=$(az account show --query tenantId --output tsv)

# Register necessary Azure resource providers
az provider register --namespace 'Microsoft.RedHatOpenShift' --wait
az provider register --namespace 'Microsoft.Compute' --wait
az provider register --namespace 'Microsoft.Storage' --wait
az provider register --namespace 'Microsoft.Authorization' --wait

# Check if the resource group already exists
echo "Checking if [$aroResourceGroupName] resource group exists in the [$subscriptionName] subscription..."

az group show --name $aroResourceGroupName &>/dev/null

if [[ $? != 0 ]]; then
  echo "No [$aroResourceGroupName] resource group found. Creating..."

  # Create the resource group
  az group create --name $aroResourceGroupName --location $location 1>/dev/null

  if [[ $? == 0 ]]; then
    echo "[$aroResourceGroupName] resource group successfully created."
  else
    echo "Failed to create [$aroResourceGroupName] resource group."
    exit
  fi
else
  echo "[$aroResourceGroupName] resource group already exists."
fi

# Create the service principal for the ARO cluster
echo "Creating service principal with [$aroClusterServicePrincipalDisplayName] display name in the [$tenantId] tenant..."
az ad sp create-for-rbac \
  --name $aroClusterServicePrincipalDisplayName >app-service-principal.json

aroClusterServicePrincipalClientId=$(jq -r '.appId' app-service-principal.json)
aroClusterServicePrincipalClientSecret=$(jq -r '.password' app-service-principal.json)
aroClusterServicePrincipalObjectId=$(az ad sp show --id $aroClusterServicePrincipalClientId | jq -r '.id')

# Assign the User Access Administrator role to the new service principal with resource group scope
roleName='User Access Administrator'
az role assignment create \
  --role "$roleName" \
  --assignee-object-id $aroClusterServicePrincipalObjectId \
  --resource-group $aroResourceGroupName \
  --assignee-principal-type 'ServicePrincipal' >/dev/null

if [[ $? == 0 ]]; then
  echo "[$aroClusterServicePrincipalDisplayName] service principal successfully assigned [$roleName] with [$aroResourceGroupName] resource group scope"
else
  echo "Failed to assign [$roleName] role with [$aroResourceGroupName] resource group scope to the [$aroClusterServicePrincipalDisplayName] service principal"
  exit
fi

# Assign the Contributor role to the new service principal with resource group scope
roleName='Contributor'
az role assignment create \
  --role "$roleName" \
  --assignee-object-id $aroClusterServicePrincipalObjectId \
  --resource-group $aroResourceGroupName \
  --assignee-principal-type 'ServicePrincipal' >/dev/null

if [[ $? == 0 ]]; then
  echo "[$aroClusterServicePrincipalDisplayName] service principal successfully assigned [$roleName] with [$aroResourceGroupName] resource group scope"
else
  echo "Failed to assign [$roleName] role with [$aroResourceGroupName] resource group scope to the [$aroClusterServicePrincipalDisplayName] service principal"
  exit
fi

# Get the service principal object ID for the OpenShift resource provider
aroResourceProviderServicePrincipalObjectId=$(az ad sp list --display-name "Azure Red Hat OpenShift RP" --query [0].id -o tsv)

# Terraform Operations
if [[ $op == 'plan' ]]; then
  # Generate Terraform plan
  terraform plan \
    -compact-warnings \
    -out main.tfplan \
    -var "resource_prefix=$resourcePrefix" \
    -var "location=$location" \
    -var "domain=$aroDomain" \
    -var "pull_secret=$pullSecret" \
    -var "aro_cluster_aad_sp_client_id=$aroClusterServicePrincipalClientId" \
    -var "aro_cluster_aad_sp_client_secret=$aroClusterServicePrincipalClientSecret" \
    -var "aro_cluster_aad_sp_object_id=$aroClusterServicePrincipalObjectId" \
    -var "aro_rp_aad_sp_object_id=$aroResourceProviderServicePrincipalObjectId"
else
  if [[ -f "main.tfplan" ]]; then
    # Apply Terraform plan if it exists
    terraform apply \
      -compact-warnings \
      -auto-approve \
      main.tfplan \
      -var "resource_prefix=$resourcePrefix" \
      -var "resource_group_name=$aroResourceGroupName" \
      -var "location=$location" \
      -var "domain=$aroDomain" \
      -var "pull_secret=$pullSecret" \
      -var "aro_cluster_aad_sp_client_id=$aroClusterServicePrincipalClientId" \
      -var "aro_cluster_aad_sp_client_secret=$aroClusterServicePrincipalClientSecret" \
      -var "aro_cluster_aad_sp_object_id=$aroClusterServicePrincipalObjectId" \
      -var "aro_rp_aad_sp_object_id=$aroResourceProviderServicePrincipalObjectId"
  else
    # Apply Terraform configuration directly
    terraform apply \
      -compact-warnings \
      -auto-approve \
      -var "resource_prefix=$resourcePrefix" \
      -var "resource_group_name=$aroResourceGroupName" \
      -var "location=$location" \
      -var "domain=$aroDomain" \
      -var "pull_secret=$pullSecret" \
      -var "aro_cluster_aad_sp_client_id=$aroClusterServicePrincipalClientId" \
      -var "aro_cluster_aad_sp_client_secret=$aroClusterServicePrincipalClientSecret" \
      -var "aro_cluster_aad_sp_object_id=$aroClusterServicePrincipalObjectId" \
      -var "aro_rp_aad_sp_object_id=$aroResourceProviderServicePrincipalObjectId"
  fi
fi
