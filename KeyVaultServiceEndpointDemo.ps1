<####################################################################################
Name: KeyVaultServiceEndpointDemo.ps1
Version: 1.0
Author: Josh Kewley
Company: Blue Chip Consulting Group
Description:
    This script will deploy
        - a resource group
        - a vnet and subnet
        - a key vault with a secret
        - a storage account
        - an app service plan (Premium!) and function app with managed identity
        - a service endpoint for the function app to connect to the key vault
    The intent of this script is to demonstrate how to connect to the key vault from the function app
    while hiding the key vault from the public Internet

    Note that this creates a set of subfolders below the script execution path so the function assets can be deployed

History:
1.0 intial file creation and documentation
####################################################################################>

$ErrorActionPreference = "Stop"

########### CHANGE THESE VALUES ###########
$yourUniquePrefix = ""                             # used to create uniquely named assets to avoid naming collisions
$storageName = "testpaasstorage"                   # storage account name. append prefix manually due to storage naming constraints (lowercase, alpha, max 24)
$subscriptionName = "YOUR SUBSCRIPTION NAME"       # the name value from 'az account list' for the subscription where you want to deploy the demo
########### /CHANGE THESE VALUES ###########

$rgName = $yourUniquePrefix + "TestPaaSSecurity"    # resource group name
$vnetName = $yourUniquePrefix + "TestPaaSVNet"      # virtual network name
$subnetName = $yourUniquePrefix + "TestPaaSSubnet"  # subnet name
$aspName = $yourUniquePrefix + "TestPaaSAppSvc"     # app service plan name
$funcName = $yourUniquePrefix + "TestPaaSFunc"      # function app name
$kvName = $yourUniquePrefix + "testpaaskv"          # key vault name

$location = "eastus2"                               # premium V2 app service plans are only available in certain regions at the time this was written : az appservice list-locations --sku P1V2
$vnetprefix = "10.20.0.0/16"                        # vnet address prefix
$subnetprefix = "10.20.0.0/27"                      # vnet address prefix
$testSecretName = "KVSecret"                        # key vault secret name
$testSecretValue = "KV secret value"                # key vault secret value

$myip = (Invoke-WebRequest -uri "http://ifconfig.me/ip").Content # your local IP address which will be added and removed from the ky vault firewall during the demo

# set default subscription
az account set -s $subscriptionName 

# create the RG
Write-Host "Creating resource group" -ForegroundColor Yellow
az group create --location $location --name $rgName

# create the vnet and subnet
Write-Host "Creating network infrastructure" -ForegroundColor Yellow
az network vnet create --name $vnetName --address-prefix $vnetprefix --subnet-name $subnetName --subnet-prefix $subnetprefix --resource-group $rgName --location $location

# add service endpoint policy for storage and key vault
az network vnet subnet update --resource-group $rgName --vnet-name $vnetName --name $subnetName --service-endpoints Microsoft.Storage Microsoft.KeyVault


############# STORAGE ACCOUNT CONFIGURATION #############
Write-Host "Creating storage" -ForegroundColor Yellow

# create the storage account
az storage account create --name $storageName --kind StorageV2 --sku Standard_ZRS --resource-group $rgName --location $location

# If you configure a virtual network service endpoint on the storage account you're using for your function app, that will break your app - https://docs.microsoft.com/en-us/azure/azure-functions/functions-networking-options#connecting-to-service-endpoint-secured-resources
# connect storage to vnet
#az storage account network-rule add --vnet-name $vnetname --subnet $subnetName --account-name $storageName
# deny all traffic by default
# az storage account update --name $storageName --default-action Deny --resource-group $rgName


############# KEY VAULT CONFIGURATION #############
#create the key vault
Write-Host "Creating key vault" -ForegroundColor Yellow
az keyvault create --name $kvName --enabled-for-deployment true --enabled-for-template-deployment true --resource-group $rgName --location $location

#connect key vault to vnet
az keyvault network-rule add --vnet-name $vnetname --subnet $subnetName --name $kvName

# https://docs.microsoft.com/en-us/azure/azure-functions/functions-networking-options#connecting-to-service-endpoint-secured-resources
# For now, it may take up to 12 hours for new service endpoints to become available to your function app after you configure access restrictions on the downstream resource. During this time the resource will be completely unavailable to your app.

# allow azure services to access the KV
az keyvault update --resource-group $rgName --name $kvName --bypass AzureServices

# deny all traffic by default
az keyvault update --resource-group $rgName --name $kvName --default-action Deny

# add your IP back in for this deployment so we can add secrets later in the script
az keyvault network-rule add --name $kvName --ip-address $myip


############# APP SVC / FUNCTION CONFIGURATION #############
Write-Host "Creating app service and function" -ForegroundColor Yellow

# create app service plan *with v2 SKU* to ensure the hardware we allocate can support regional vnet integration
az appservice plan create --sku P1V2 --name $aspName --resource-group $rgName --location $location

# now scale it back to standard
az appservice plan update --sku S1 --name $aspName --resource-group $rgName

# create the function app
az functionapp create --plan $aspName -n $funcName --storage-account $storageName --resource-group $rgName

# tell the function app it'll be running powershell
az webapp config appsettings set -n $funcName  --resource-group $rgName --settings FUNCTIONS_WORKER_RUNTIME=powershell 

# add the function app to the vnet
az functionapp vnet-integration add -g $rgName -n $funcName --vnet $vnetname --subnet $subnetName

Write-Host "Assigning msi" -ForegroundColor Yellow
# assign a managed identity to the func and capture the resulting payload
$identityPayload = (az webapp identity assign -n $funcName --resource-group $rgName)
$principal = ($identityPayload | ConvertFrom-Json).principalId

Write-Host "grant kv access to func" -ForegroundColor Yellow
# give MSI service principal kv read rights to secrets
az keyvault set-policy --name $kvName --object-id $principal --secret-permissions get


############# SET UP SECRETS #############
Write-Host "Adding secret" -ForegroundColor Yellow

# create the secrets we want to capture
$secret="$(az keyvault secret set --name $testSecretName --vault-name $kvName --value $testSecretValue)"
$secretUri = ($secret | ConvertFrom-Json).id

# fully qualified setting value https://docs.microsoft.com/en-us/azure/app-service/app-service-key-vault-references
$appSettingSecretRef="@Microsoft.KeyVault(SecretUri=$secretUri)"

# KEY VAULT REFERENCES DON'T WORK WITH VNETS YET. Leaving this in for when this feature is included
#   https://feedback.azure.com/forums/355860-azure-functions/suggestions/38817385-allow-key-vault-references-to-access-secrets-behin
# add the keyvault secret reference to the function app setting
Write-Host "Add secret ref to function app config" -ForegroundColor Yellow
# note the odd escaping of the value https://github.com/Azure/azure-cli/issues/8506
az webapp config appsettings set -n $funcName  --resource-group $rgName --settings "NotYetSupported=""$appSettingSecretRef""" 


############# PUBLISH THE FUNCTION #############
Write-Host "Creating function supporting files" -ForegroundColor Yellow

$secret="$(az keyvault secret show --name $testSecretName --vault-name $kvName)"
$secretUri = ($secret | ConvertFrom-Json).id

Remove-Item functionapp -Recurse -ErrorAction Ignore
mkdir functionapp
cd functionapp
mkdir Function1
$hostfile = @"
{
  "bindings": [
    {
      "authLevel": "function",
      "type": "httpTrigger",
      "direction": "in",
      "name": "Request",
      "methods": [
        "get",
        "post"
      ]
    },
    {
     "type": "http",
      "direction": "out",
      "name": "Response"
    }
  ]
}
"@
# write json to function.json
$hostfile > Function1/function.json

$functioncode = @"
using namespace System.Net

# Input bindings are passed in via param block.
param(`$Request, `$TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# getting access token using MSI
`$tokenAuthURI = `$Env:MSI_ENDPOINT +"?resource=https://vault.azure.net&api-version=2017-09-01"
`$tokenResponse = Invoke-RestMethod -Method Get -Headers @{"Secret"="`$env:MSI_SECRET"} -Uri `$tokenAuthURI
`$accessToken = `$tokenResponse.access_token
# get secret value
`$headers = @{ 'Authorization' = "Bearer `$accessToken" }
`$queryUrl = "$secretUri" + "?api-version=7.0"

`$keyResponse = Invoke-RestMethod -Method GET -Uri `$queryUrl -Headers `$headers
`$secretValue = `$keyResponse.value

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    #Body = "Hello `$(`$env:NotYetSupported)"
    Body = "Hello `$(`$secretValue)"
})
"@
# write script to powershell file
$functioncode > Function1/run.ps1

#Zip the folder to upload the Azure Function
Write-Host "Publishing function" -ForegroundColor Yellow
Compress-Archive -Path * -DestinationPath Function1.zip
az functionapp deployment source config-zip -n $funcName -g $rgName --src ./Function1.zip

cd ..


# Show that the key vault firewall exception allows direct access to the data plane from the Internet
Write-Host "Get secret directly with firewall rule permitting your internet IP address" -ForegroundColor Yellow
az keyvault secret show --name $testSecretName --vault-name $kvName

# Show that the function can access the key vault with the firewall exception in place
Write-Host "Invoking function with firewall rule permitting your internet IP address" -ForegroundColor Yellow
# POST to ARM to get the host invocation key for the new function
$subscriptionId = (az account show | ConvertFrom-Json).id
$accessToken = az account get-access-token --query accessToken -o tsv
$listFunctionKeysUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.Web/sites/$funcName/functions/Function1/listKeys?api-version=2018-02-01"
$functionKey = (az rest --method post --uri $listFunctionKeysUrl | ConvertFrom-Json).default

# now call the function to see the secret
$uri = "https://$funcName.azurewebsites.net/api/Function1?code=$functionKey"
Write-Host "Invoking function at $uri" -ForegroundColor Yellow
(Invoke-WebRequest -Uri $uri).Content

# Remove the firewall exception to prove no access from the Internet without it
Write-Host "Removing key vault firewall rule permitting your internet IP address" -ForegroundColor Yellow
az keyvault network-rule remove --name $kvName --ip-address $myip/32

Write-Host "Get secret directly *without* firewall rule permitting your internet IP address" -ForegroundColor Yellow
az keyvault secret show --name $testSecretName --vault-name $kvName

# Show that the function can still access the key vault without the firewall exception in place
Write-Host "Invoking function *without* firewall rule permitting your internet IP address" -ForegroundColor Yellow
(Invoke-WebRequest -Uri $uri).Content

Write-Host "Demo complete. Hit enter to continue" -ForegroundColor Green
Read-Host


# run this to clean up the resource group after you're done
# az group delete --name $rgName --yes

#reference articles
#http://vgaltes.com/post/using-key-vault-secret-in-appsettings/
#https://tomssl.com/2019/10/31/setting-keyvault-secrets-through-the-azure-cli/
#https://markheath.net/post/deploying-azure-functions-with-azure-cli
#https://docs.microsoft.com/en-us/aspnet/core/security/app-secrets?view=aspnetcore-3.1&tabs=windows
