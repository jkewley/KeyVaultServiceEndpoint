## Architecture
The Powershell script will produce the following architecture:

![Key vault architecture](https://thepracticaldev.s3.amazonaws.com/i/6dnywio9lzwtnls22i50.png)

## Script settings

The script has a few variables which you'll want to update

```
# used to create uniquely named assets to avoid naming collisions
$yourUniquePrefix = "myPrefix"          

# storage account name. append prefix manually due to storage naming constraints (lowercase, alpha, max 24)
$storageName = "myprefixtestpaasstorage"   

# the name value from 'az account list' for the subscription where you want to deploy the demo
$subscriptionName = "YOUR SUBSCRIPTION NAME"
```

The scipt leverages the [latest Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest) (version 2.0.77) which introduced support for `az functionapp vnet-integration add`. 

## What the script does

This script will deploys the following assets in order in the East US2 region:
 * a resource group
 * a vnet and subnet
 * a key vault
 * a storage account
 * an app service plan (Premium!) and function app with a managed identity
 * a deployed Powershell function app which retrieves and returns the key vault secret

It connects the app service plan to the vnet and sets up a service endpoint for the subnet. Finally, it provides the function app's identity 'get' rights to the key vault's secrets.

The function uses Powershell and the local managed identity endpoint to demonstrate that it is able to retrieve the secrets. As of the time that this was written, [key vault configuration references are not supported with service endpoints](https://github.com/Azure/azure-webjobs-sdk/issues/746).

The script walks through four validation tests.
 * First it shows that it can read the secret using the Azure CLI with a firewall rule in place which allows the caller's IP address. 
 * Next it invokes the function, which returns the secret in the Http response payload
 * It then removes the firewall rule and demonstrates that it can no longer read the secret
 * It makes a final call to the function app to show that it is still able to access the vault through the subnet's service endpoint

[The code is heavily commented to make it easy to follow along](https://github.com/jkewley/KeyVaultServiceEndpoint). Enjoy!
