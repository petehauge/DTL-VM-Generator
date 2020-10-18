#region COMMON FUNCTIONS
# We are using strict mode for added safety
Set-StrictMode -Version Latest

# We require a relatively new version of Powershell
#requires -Version 3.0

# To understand the code below read here: https://docs.microsoft.com/en-us/powershell/azure/migrate-from-azurerm-to-az?view=azps-2.1.0
# Having both the Az and AzureRm Module installed is not supported, but it is probably common. The library should work in such case, but warn.
# Checking for the presence of the Az module, brings it into memory which causes an exception if AzureRm is present installed in the system. So checking for absence of AzureRm instead.
# If both are absent, then the user will get an error later on when trying to access it.
# If you have the AzureRm module, then everything works fine
# If you have the Az module, we need to enable the AzureRmAliases

$azureRm  = Get-InstalledModule -Name "AzureRM" -ErrorAction SilentlyContinue
$az       = Get-Module -Name "Az.Accounts" -ListAvailable
$justAz   = $az -and -not ($azureRm -and $azureRm.Version.Major -ge 6)
$justAzureRm = $azureRm -and (-not $az)

if($azureRm -and $az) {
  Write-Warning "You have both Az and AzureRm module installed. That is not officially supported. For more read here: https://docs.microsoft.com/en-us/powershell/azure/migrate-from-azurerm-to-az"
}

if($justAzureRm) {
  if ($azureRm.Version.Major -lt 6) {
    Write-Error "This module does not work correctly with version 5 or lower of AzureRM, please upgrade to a newer version of Azure PowerShell in order to use this module."
  } else {
    # This is not defaulted in older versions of AzureRM
    Enable-AzContextAutosave -Scope Process | Out-Null
    Write-Warning "You are using the deprecated AzureRM module. For more info, read https://docs.microsoft.com/en-us/powershell/azure/migrate-from-azurerm-to-az"
  }
}

if($justAz) {
  Enable-AzureRmAlias -Scope Local
  Enable-AzContextAutosave -Scope Process | Out-Null
}

# We want to track usage of library, so adding GUID to user-agent at loading and removig it at unloading
$libUserAgent = "pid-bd1d84d0-5ddb-4ab9-b951-393e656bb054"
[Microsoft.Azure.Common.Authentication.AzureSession]::ClientFactory.AddUserAgent($libUserAgent)

$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
  [Microsoft.Azure.Common.Authentication.AzureSession]::ClientFactory.RemoveUserAgent($libUserAgent)
}

# The reason for using the following function and managing errors as done in the cmdlets below is described
# at the link here: https://github.com/PoshCode/PowerShellPracticeAndStyle/issues/37#issuecomment-347257738
# The scheme permits writing the cmdlet code assuming the code after an error is not executed,
# and at the same time allows the caller to decide if the cmdlet *overall* should stop or continue for errors
# by using the standard ErrorAction syntax. It also mentions the correct cmdlet name in the text for the error
# without exposing the innards of the function. The price to pay is boilerplate code, reduced by BeginPreamble.
# You might think you might reduce boilerplate even more by creating a function that takes
# a scriptBlock and wrap it in the correct begig{} process {try{} catch{}} end {}
# but that ends up showing the source line of the error as such function, not the cmdlet.

# Import (with . syntax) this at the start of each begin block
function BeginPreamble {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseDeclaredVarsMoreThanAssignments", "", Scope="Function")]
  param()
    Get-CallerPreference -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState -Name ("ErrorActionPreference")
    $callerEA = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
}

function PrintHashtable {
  param($hash)

  return ($hash.Keys | ForEach-Object { "$_ $($hash[$_])" }) -join "|"
}

# Getting labs that don't exist shouldn't fail, but return empty for composibility
# Also I am forced to do client side query because when you add -ExpandProperty to Get-AzureRmResource it disables wildcard?????
# Also I know that treating each case separately is ugly looking, but there are various bugs that might be fixed in Get-AzureRmResource
# at which point more queries can be moved server side, so leave it as it is for now.
function MyGetResourceLab {
  param($Name, $ResourceGroupName)

  $ResourceType = "Microsoft.DevTestLab/labs"
  if($ResourceGroupName -and (-not $ResourceGroupName.Contains("*"))) { # Proper RG
    if($Name -and (-not $Name.Contains("*"))) { # Proper RG, Proper Name
      Get-AzureRmResource -ExpandProperties -resourcetype $ResourceType -ResourceGroupName $ResourceGroupName -ApiVersion "2018-10-15-preview" -Name $Name -EA SilentlyContinue
    } else { #Proper RG, wild name
      Get-AzureRmResource -ExpandProperties -resourcetype $ResourceType -ResourceGroupName $ResourceGroupName -ApiVersion "2018-10-15-preview" -EA SilentlyContinue | Where-Object { $_.ResourceId -like "*/labs/$Name"}
    }
  } else { # Wild RG forces client side query anyhow
    Get-AzureRmResource -ExpandProperties -resourcetype $ResourceType -EA SilentlyContinue | Where-Object { $_.ResourceId -like "*/resourcegroups/$ResourceGroupName/*/labs/$Name"}
  }
}

function MyGetResourceVm {
  param($Name, $LabName, $ResourceGroupName)

  $ResourceType = "Microsoft.DevTestLab/labs/virtualMachines"

  if($ResourceGroupName -and (-not $ResourceGroupName.Contains("*"))) { # Proper RG
    if($LabName -and (-not $LabName.Contains("*"))) { # Proper RG, Proper LabName
      if($Name -and (-not $Name.Contains("*"))) { # Proper RG, Proper LabName, Proper Name
        if($azureRm) {
          Get-AzureRmResource -ExpandProperties -resourcetype $ResourceType -ResourceGroupName $ResourceGroupName -Name "$LabName/$Name" -EA SilentlyContinue
        } else {
          Get-AzureRmResource -ExpandProperties -resourcetype $ResourceType -ResourceGroupName $ResourceGroupName -EA SilentlyContinue | Where-Object { $_.ResourceId -like "*/labs/$LabName/virtualmachines/$Name"}
        }
      } else { # Proper RG, Proper LabName, Improper Name
        Get-AzureRmResource -ExpandProperties -resourcetype $ResourceType -ResourceGroupName $ResourceGroupName -EA SilentlyContinue | Where-Object { $_.ResourceId -like "*/labs/$LabName/virtualmachines/$Name"}
      }
   } else { # Proper RG, Improper LabName
      Get-AzureRmResource -ExpandProperties -resourcetype $ResourceType -ResourceGroupName $ResourceGroupName -EA SilentlyContinue | Where-Object { $_.ResourceId -like "*/labs/$LabName/virtualmachines/$Name"}
   }
  } else { # Improper RG forces client side query anyhow
    Get-AzureRmResource -ExpandProperties -resourcetype $ResourceType -EA SilentlyContinue | Where-Object { $_.ResourceId -like "*/resourcegroups/$ResourceGroupName/*/labs/$LabName/virtualmachines/$Name"}
  }
}

function Get-AzureRmCachedAccessToken()
{
  $ErrorActionPreference = 'Stop'
  Set-StrictMode -Off

  if ($justAz) {
    if (-not (Get-Module -Name Az.Resources)) {
        Import-Module -Name Az.Resources
    }
    $azureRmProfileModuleVersion = (Get-Module Az.Resources).Version

  } else {
      if(-not (Get-Module -Name AzureRm.Profile)) {
        Import-Module -Name AzureRm.Profile
      }

      $azureRmProfileModuleVersion = (Get-Module AzureRm.Profile).Version
  }

  # refactoring performed in AzureRm.Profile v3.0 or later
  if($azureRmProfileModuleVersion.Major -ge 3 -or ($justAz -and $azureRmProfileModuleVersion.Major -ge 1)) {
    $azureRmProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
    if(-not $azureRmProfile.Accounts.Count) {
      Write-Error "Ensure you have logged in before calling this function."
    }
  } else {
    # AzureRm.Profile < v3.0
    $azureRmProfile = [Microsoft.WindowsAzure.Commands.Common.AzureRmProfileProvider]::Instance.Profile
    if(-not $azureRmProfile.Context.Account.Count) {
      Write-Error "Ensure you have logged in before calling this function."
    }
  }

  $currentAzureContext = Get-AzureRmContext
  $profileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($azureRmProfile)
  Write-Debug ("Getting access token for tenant" + $currentAzureContext.Subscription.TenantId)
  $token = $profileClient.AcquireAccessToken($currentAzureContext.Subscription.TenantId)
  $token.AccessToken
}

function GetHeaderWithAuthToken {

  $authToken = Get-AzureRmCachedAccessToken
  Write-Debug $authToken

  $header = @{
      'Content-Type' = 'application\json'
      "Authorization" = "Bearer " + $authToken
  }

  return $header
}
function Get-AzDtlLab {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$false,ValueFromPipelineByPropertyName = $true, ValueFromPipeline=$true, HelpMessage="Name of the lab(s) to retrieve.  This parameter supports wildcards at the beginning and/or end of the string.")]
    [ValidateNotNullOrEmpty()]
    [string]
    $Name = "*",

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Name of the resource group to get the lab from. It must be an existing one.")]
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName = '*'
  )

  begin {. BeginPreamble}
  process {
    try {
      Write-verbose "Retrieving lab $Name ..."
      MyGetResourceLab -Name $Name -ResourceGroupName $ResourceGroupName
      Write-verbose "Retrieved lab $Name."
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

function DeployLab {
  param (
    [parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [string]
    $arm,

    [parameter(Mandatory = $true)]
    $Lab,

    [parameter(Mandatory = $true)]
    $AsJob,

    [parameter(Mandatory = $true)]
    $Parameters,

    [parameter(mandatory = $false)]
    [switch]
    $IsNewLab = $false
  )
  Write-debug "DEPLOY ARM TEMPLATE`n$arm`nWITH PARAMS: $(PrintHashtable $Parameters)"

  $Name = $Lab.Name
  $ResourceGroupName = $Lab.ResourceGroupName
  $VmCreationSubnetPrefix = $null

  if (Get-Member -InputObject $Lab -Name VmCreationSubnetPrefix -MemberType Properties) {
    $VmCreationSubnetPrefix = $Lab.VmCreationSubnetPrefix
  }

  if ($Name.Length -gt 40) {
    $deploymentName = ("LabDeploy_" + $Name.Substring(0, 40))
  }
  else {
      $deploymentName = ("LabDeploy" + $Name)
  }
  Write-Verbose "Using deployment name $deploymentName with params`n $(PrintHashtable $Parameters)"

  if(-not $IsNewLab) {
    $existingLab = Get-AzureRmResource -Name $Name  -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue

    if (-not $existingLab) {
        throw "'$Name' Lab already exists. This action is supposed to be performed on an existing lab."
    }
  }
  $jsonPath = StringToFile($arm)

  $sb = {
    param($deploymentName, $Name, $ResourceGroupName, $VmCreationSubnetPrefix, $jsonPath, $Parameters, $workingDir, $justAz)

    if($justAz) {
      Enable-AzureRmAlias -Scope Local -Verbose:$false
      Enable-AzContextAutosave -Scope Process | Out-Null
    }

    # Import again the module
    if (-not (Get-Module -Name Az.DevTestLabs2)) {
        Import-Module "$workingDir\Az.DevTestLabs2.psm1"
    }

    $deployment = New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $ResourceGroupName -TemplateFile $jsonPath -TemplateParameterObject $Parameters
    Write-debug "Deployment succeded with deployment of `n$deployment"

    $lab = Get-AzureRmResource -Name $Name -ResourceGroupName $ResourceGroupName -ExpandProperties
    if ($VmCreationSubnetPrefix) {

      $labVnet = $lab | Get-AzDtlLabVirtualNetworks -ExpandedNetwork
      $labVnet.Subnets[0].AddressPrefix = $VmCreationSubnetPrefix
      $labVnet = Set-AzureRmVirtualNetwork -VirtualNetwork $labVnet

      $lab = Get-AzureRmResource -Name $Name -ResourceGroupName $ResourceGroupName -ExpandProperties
    }

    $lab
  }

  if($AsJob) {
    Start-Job      -ScriptBlock $sb -ArgumentList $deploymentName, $Name, $ResourceGroupName, $VmCreationSubnetPrefix, $jsonPath, $Parameters, $PWD, $justAz
  } else {
    Invoke-Command -ScriptBlock $sb -ArgumentList $deploymentName, $Name, $ResourceGroupName, $VmCreationSubnetPrefix, $jsonPath, $Parameters, $PWD, $justAz
  }
}

function DeployVm {
  param (
    [parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [string]
    $arm,

    [parameter(Mandatory = $true)]
    $vm,

    [parameter(Mandatory = $true)]
    $AsJob,

    [parameter(Mandatory = $true)]
    $Parameters,

    [parameter(mandatory = $false)]
    [switch]
    $IsNewVm = $false
  )
  Write-debug "DEPLOY ARM TEMPLATE`n$arm`nWITH PARAMS: $(PrintHashtable $Parameters)"

  $Name = $vm.ResourceId.Split('/')[10]
  $ResourceGroupName = $vm.ResourceGroupName

  if ($Name.Length -gt 40) {
    $deploymentName = "VMDeploy_" + $Name.Replace('/', '-').Substring(0, 40)
  }
  else {
      $deploymentName = "VMDeploy" + $Name.Replace('/', '-')
  }
  Write-Verbose "Using deployment name $deploymentName with params`n $(PrintHashtable $Parameters)."

  if(-not $IsNewVm) {
    $existingVM = Get-AzureRmResource -Name $Name  -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue

    if (-not $existingVM) {
        throw "'$Name' VM already exists. This action is supposed to be performed on an existing lab."
    }
  }
  $jsonPath = StringToFile($arm)

  $sb = {
    param($deploymentName, $Name, $ResourceGroupName, $jsonPath, $Parameters, $justAz)

    if($justAz) {
      Enable-AzContextAutosave -Scope Process | Out-Null
    }
    $deployment = New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $ResourceGroupName -TemplateFile $jsonPath -TemplateParameterObject $Parameters
    Write-debug "Deployment succeded with deployment of `n$deployment"

    Get-AzureRmResource -Name $Name -ResourceGroupName $ResourceGroupName -ExpandProperties
  }

  if($AsJob.IsPresent) {
    Start-Job      -ScriptBlock $sb -ArgumentList $deploymentName, $Name, $ResourceGroupName, $jsonPath, $Parameters, $justAz
  } else {
    Invoke-Command -ScriptBlock $sb -ArgumentList $deploymentName, $Name, $ResourceGroupName, $jsonPath, $Parameters, $justAz
  }
}

#TODO: reduce function below to just get ErrorActionPreference
# Taken from https://gallery.technet.microsoft.com/scriptcenter/Inherit-Preference-82343b9d
function Get-CallerPreference
{
    [CmdletBinding(DefaultParameterSetName = 'AllVariables')]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateScript({ $_.GetType().FullName -eq 'System.Management.Automation.PSScriptCmdlet' })]
        $Cmdlet,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.SessionState]
        $SessionState,

        [Parameter(ParameterSetName = 'Filtered', ValueFromPipeline = $true)]
        [string[]]
        $Name
    )

    begin
    {
        $filterHash = @{}
    }

    process
    {
        if ($null -ne $Name)
        {
            foreach ($string in $Name)
            {
                $filterHash[$string] = $true
            }
        }
    }

    end
    {
        # List of preference variables taken from the about_Preference_Variables help file in PowerShell version 4.0

        $vars = @{
            'ErrorView' = $null
            'FormatEnumerationLimit' = $null
            'LogCommandHealthEvent' = $null
            'LogCommandLifecycleEvent' = $null
            'LogEngineHealthEvent' = $null
            'LogEngineLifecycleEvent' = $null
            'LogProviderHealthEvent' = $null
            'LogProviderLifecycleEvent' = $null
            'MaximumAliasCount' = $null
            'MaximumDriveCount' = $null
            'MaximumErrorCount' = $null
            'MaximumFunctionCount' = $null
            'MaximumHistoryCount' = $null
            'MaximumVariableCount' = $null
            'OFS' = $null
            'OutputEncoding' = $null
            'ProgressPreference' = $null
            'PSDefaultParameterValues' = $null
            'PSEmailServer' = $null
            'PSModuleAutoLoadingPreference' = $null
            'PSSessionApplicationName' = $null
            'PSSessionConfigurationName' = $null
            'PSSessionOption' = $null

            'ErrorActionPreference' = 'ErrorAction'
            'DebugPreference' = 'Debug'
            'ConfirmPreference' = 'Confirm'
            'WhatIfPreference' = 'WhatIf'
            'VerbosePreference' = 'Verbose'
            'WarningPreference' = 'WarningAction'
        }


        foreach ($entry in $vars.GetEnumerator())
        {
            if (([string]::IsNullOrEmpty($entry.Value) -or -not $Cmdlet.MyInvocation.BoundParameters.ContainsKey($entry.Value)) -and
                ($PSCmdlet.ParameterSetName -eq 'AllVariables' -or $filterHash.ContainsKey($entry.Name)))
            {
                $variable = $Cmdlet.SessionState.PSVariable.Get($entry.Key)

                if ($null -ne $variable)
                {
                    if ($SessionState -eq $ExecutionContext.SessionState)
                    {
                        Set-Variable -Scope 1 -Name $variable.Name -Value $variable.Value -Force -Confirm:$false -WhatIf:$false
                    }
                    else
                    {
                        $SessionState.PSVariable.Set($variable.Name, $variable.Value)
                    }
                }
            }
        }

        if ($PSCmdlet.ParameterSetName -eq 'Filtered')
        {
            foreach ($varName in $filterHash.Keys)
            {
                if (-not $vars.ContainsKey($varName))
                {
                    $variable = $Cmdlet.SessionState.PSVariable.Get($varName)

                    if ($null -ne $variable)
                    {
                        if ($SessionState -eq $ExecutionContext.SessionState)
                        {
                            Set-Variable -Scope 1 -Name $variable.Name -Value $variable.Value -Force -Confirm:$false -WhatIf:$false
                        }
                        else
                        {
                            $SessionState.PSVariable.Set($variable.Name, $variable.Value)
                        }
                    }
                }
            }
        }

    } # end

} # function Get-CallerPreference

# Convert a string to a file so that it can be passed to functions that take a path. Assumes temporary files are deleted by the OS eventually.
function StringToFile([string] $text) {
  $tmp = New-TemporaryFile
  Set-Content -Path $tmp.FullName -Value $text
  return $tmp.FullName
}

function GetComputeVm($vm) {

  try {
    if ($vm.Properties.computeId) {
      # Instead of another round-trip to Azure, we parse the Compute ID to get the VM Name & Resource Group
      if ($vm.Properties.computeId -match "\/subscriptions\/(.*)\/resourceGroups\/(.*)\/providers\/Microsoft\.Compute\/virtualMachines\/(.*)$") {
        # For successful match, powershell stores the matches in "$Matches" array
        $vmResourceGroupName = $Matches[2]
        $vmName = $Matches[3]
      } else {
        # Unable to parse the resource Id, so let's do the additional round trip to Azure
        $vm = Get-AzureRmResource -ResourceId $vm.Properties.computeId
        $vmResourceGroupName = $vm.ResourceGroupName
        $vmName = $vm.Name
      }

      return Get-AzureRmVm -ResourceGroupName $vmResourceGroupName -Name $vmName -Status
    }
  }
  catch {
    Write-Information "DevTest Lab VM $($vm.Name) in RG $($vm.ResourceGroupName) has no associated compute VM"
  }

  # In this case, the ComputeId isn't set or doesn't resolve to a VM
  # this is a busted VM (compute VM was deleted out from under the DTL VM)
  return $null
}
#endregion

#region LAB ACTIONS

function New-AzDtlLab {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="Name of the lab to create.")]
    [ValidateLength(1,50)]
    [ValidateNotNullOrEmpty()]
    [string] $Name,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="Name of the resource group where to create the lab. It must already exist.")]
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName,

    [parameter(Mandatory=$false,HelpMessage="IP address prefix (CIDR notation) within 10.0.0.0/20 reserved for VMs creation. (e.g 10.0.0.0/21, 10.)")]
    [ValidateNotNullOrEmpty()]
    [string] $VmCreationSubnetPrefix,

    [parameter(Mandatory=$false,HelpMessage="Run the command in a separate job.")]
    [switch] $AsJob = $False
  )

  begin {. BeginPreamble}
  process {
    try {
      # We could create it, if it doesn't exist, but that would complicate matters as we'd need to take a location as well as parameter
      # Choose to keep it as simple as possible to start with.
      Get-AzureRmResourceGroup -Name $ResourceGroupName -ErrorAction Stop | Out-Null

      $CIDRIPv4Regex = "^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(3[0-2]|[1-2][0-9]|[0-9]))$"
      if ($VmCreationSubnetPrefix -and !($VmCreationSubnetPrefix -match $CIDRIPv4Regex)) {
        throw "Not a valid CIDR IPv4 address range"
      }

      $params = @{
        newLabName = $Name
      }

      # Need to create this as DeployLab takes a lab, which works better in all other cases
      $Lab = [pscustomobject] @{
        Name = $Name
        ResourceGroupName = $ResourceGroupName
      }

      if ($VmCreationSubnetPrefix) {
        $Lab | Add-member -Name 'VmCreationSubnetPrefix' -Value $VmCreationSubnetPrefix -MemberType NoteProperty
      }

# Taken from official sample here: https://github.com/Azure/azure-devtestlab/blob/master/Samples/101-dtl-create-lab/azuredeploy.json
@"
{
  "`$schema": "http://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "newLabName": {
      "type": "string",
      "metadata": {
        "description": "The name of the new lab instance to be created"
      }
    }
  },
  "variables": {
    "labVirtualNetworkName": "[concat('Dtl', parameters('newLabName'))]"
  },
  "resources": [
    {
      "apiVersion": "2018-10-15-preview",
      "type": "Microsoft.DevTestLab/labs",
      "name": "[parameters('newLabName')]",
      "location": "[resourceGroup().location]",
      "resources": [
        {
          "apiVersion": "2018-10-15-preview",
          "name": "[variables('labVirtualNetworkName')]",
          "type": "virtualNetworks",
          "dependsOn": [
            "[resourceId('Microsoft.DevTestLab/labs', parameters('newLabName'))]"
          ]
        },
        {
          "apiVersion": "2018-10-15-preview",
          "name": "Public Environment Repo",
          "type": "artifactSources",
          "location": "[resourceGroup().location]",
          "dependsOn": [
            "[resourceId('Microsoft.DevTestLab/labs', parameters('newLabName'))]"
          ],
          "properties": {
            "status": "Enabled"
          }
        }
      ]
    }
  ],
  "outputs": {
    "labId": {
      "type": "string",
      "value": "[resourceId('Microsoft.DevTestLab/labs', parameters('newLabName'))]"
    }
  }
}
"@ | DeployLab -Lab $Lab -AsJob $AsJob -IsNewLab -Parameters $Params
    }
    catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {
  }
}

function Remove-AzDtlLab {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="Lab object to remove.", ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$false,HelpMessage="Run the command in a separate job.")]
    [switch] $AsJob = $False
  )

  begin {. BeginPreamble}
  process {
    try {
      foreach($l in $Lab) {
        $resId = $l.ResourceId
        Write-Verbose "Started removal of lab $resId."
        if($AsJob.IsPresent) {
          Remove-AzureRmResource -ResourceId $resId -AsJob -Force
        } else {
          Remove-AzureRmResource -ResourceId $resId -Force
        }
        Write-Verbose "Removed lab $resId."
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

function Add-AzDtlLabTags {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline=$true, HelpMessage="Lab object to set Shared Image Gallery")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$true,HelpMessage="The tags to set on the lab and it's associated resources like this: @{'ProjectCode'='123456';'BillingCode'='654321'}")]
    [Hashtable] $tags,

    [Parameter(Mandatory=$false, HelpMessage="Also tag the lab's resource group?")]
    [bool] $tagLabsResourceGroup,

    [parameter(Mandatory = $false)]
    [switch] $AsJob
  )

  begin {. BeginPreamble}
  process {
    try{

        $StartJobIfNeeded = {
            param($Resource, $IsResourceGroup, $tags, $AsJob)

            $tagSb = {
                param($Resource, $IsResourceGroup, $newTags, $justAz)

                Enable-AzureRmAlias -Scope Local -Verbose:$false

                if ($IsResourceGroup) {
                    # Apply the unified tags back to Azure
                    Set-AzureRmResourceGroup -Id $Resource.ResourceId -Tag $newTags | Out-Null
                }
                else {
                    # Apply the unified tags back to Azure
                    Set-AzureRmResource -ResourceId $Resource.ResourceId -Tag $newTags -Force | Out-Null
                }
                return
            }

            function Unify-Tags {
                [CmdletBinding()]
                param(
                    [Parameter(Mandatory=$true)]
                    [AllowNull()]
                    [hashtable] $destinationTagList,

                    [Parameter(Mandatory=$true)]
                    [AllowNull()]
                    [hashtable] $sourceTagList
                )

                # if the destination doesn't have any tags, just apply the whole set of tags from the source
                if ($destinationTagList -eq $null) {
                    if ($sourceTagList -ne $null) {
                        $finalTagList = $sourceTagList.Clone()
                    }
                    else {
                        $finalTagList = $null
                    }
                }
                else {
                    # The destination list has tags, let's compare each one to make sure none are missing
                    $finalTagList = $destinationTagList.Clone()

                    # If the source list of tags isn't null, lets merge the tags in
                    if ($sourceTagList -ne $null) {
                        foreach ($sourceTag in $sourceTagList.GetEnumerator()) {
                            # Does the dest contain the Tag?
                            if ($finalTagList.Contains($sourceTag.Name)) {
                                # If there's a tag with the same name and the value is different we should fix it
                                if ($finalTagList[$sourceTag.Name] -ne $sourceTag.Value) {
                                    $finalTagList[$sourceTag.Name] = $sourceTag.Value
                                }
                            }
                            else {
                                # destination doesn't contain the tag, let's add it
                                $finalTagList.Add($sourceTag.Name, $sourceTag.Value)
                            }
                        }
                    }
                }
                $finalTagList
            }

            # From here: https://gist.github.com/dbroeglin/c6ce3e4639979fa250cf
            function Compare-Hashtable {
            [CmdletBinding()]
                param (
                    [Parameter(Mandatory = $true)]
                    [Hashtable]$Left,

                    [Parameter(Mandatory = $true)]
                    [Hashtable]$Right
	            )

	            function New-Result($Key, $LValue, $Side, $RValue) {
		            New-Object -Type PSObject -Property @{
					            key    = $Key
					            lvalue = $LValue
					            rvalue = $RValue
					            side   = $Side
			            }
	            }
	            [Object[]]$Results = $Left.Keys | % {
		            if ($Left.ContainsKey($_) -and !$Right.ContainsKey($_)) {
			            New-Result $_ $Left[$_] "<=" $Null
		            } else {
			            $LValue, $RValue = $Left[$_], $Right[$_]
			            if ($LValue -ne $RValue) {
				            New-Result $_ $LValue "!=" $RValue
			            }
		            }
	            }
	            $Results += $Right.Keys | % {
		            if (!$Left.ContainsKey($_) -and $Right.ContainsKey($_)) {
			            New-Result $_ $Null "=>" $Right[$_]
		            }
	            }
	            $Results
            }

            # If we have only the resource Id, let's get the full object
            if ($Resource.GetType().Name -eq "String" -and $IsResourceGroup -eq $true) {
                $Resource = Get-AzureRmResourceGroup -Id $Resource
            }
            if ($Resource.GetType().Name -eq "String" -and $IsResourceGroup -eq $false) {
                $Resource = Get-AzureRmResource -ResourceId $Resource
            }

            # Check to see if the resource already has all the tags
            $newTags = (Unify-Tags $Resource.Tags $tags)
            if ((-not $resource.Tags) -or (Compare-Hashtable -Left $Resource.Tags -Right $newTags)) {

                if($AsJob) {
                    Start-Job      -ScriptBlock $tagSb -ArgumentList $Resource, $IsResourceGroup, $newTags, $justAz
                } else {
                    Invoke-Command -ScriptBlock $tagSb -ArgumentList $Resource, $IsResourceGroup, $newTags, $justAz
                }
            }
            else {
                Write-Verbose "Tags are the same, can skip for ResourceId $($Resource.ResourceId)!"
            }
        }

        # Tag the resource group if the user wants
        if ($tagLabsResourceGroup) {
            $labrg = Get-AzureRmResourceGroup -Name $Lab.ResourceGroupName
            Invoke-Command -ScriptBlock $StartJobIfNeeded -ArgumentList $labrg, $true, $tags, $AsJob
        }

        # Get the lab resource and tag it
        $labObj = Get-AzureRmResource -Name $Lab.Name -ResourceGroupName $Lab.ResourceGroupName -ResourceType "Microsoft.DevTestLab/labs"
        Invoke-Command -ScriptBlock $StartJobIfNeeded -ArgumentList $labObj, $false, $tags, $AsJob

        # Get the DTL VMs and tag them
        Get-AzureRmResource -ResourceGroupName $Lab.ResourceGroupName -ResourceType "Microsoft.DevTestLab/labs/VirtualMachines" | Where-Object {
            $_.Name.StartsWith($Lab.Name + "/")
        } | ForEach-Object {
            Invoke-Command -ScriptBlock $StartJobIfNeeded -ArgumentList $_, $false, $tags, $AsJob
        }

        # Find all the resources associated with this lab (only proceed if we found the lab)
        if ($labObj.Properties.uniqueIdentifier) {
            Get-AzureRmResource -TagName hidden-DevTestLabs-LabUId -TagValue $labObj.Properties.uniqueIdentifier `
                  | ForEach-Object {

                      Invoke-Command -ScriptBlock $StartJobIfNeeded -ArgumentList $_, $false, $tags, $AsJob

                      if ($_.ResourceType -eq 'Microsoft.Compute/virtualMachines') {
                         # We need to get the disks on the VM and tag those - disks from specialized images don't have a hidden tag
                         # But the other resources (load balancer, network interface, public IPs, etc.) are all tagged above
                         $vm = Get-AzureRmResource -ResourceId $_.ResourceId

                         # Tag the compute's resource group assuming it's not the lab's RG
                         if ($vm.ResourceGroupName -ne $labObj.ResourceGroupName) {
                            $vmRg = Get-AzureRmResourceGroup -Name $vm.ResourceGroupName

                            Invoke-Command -ScriptBlock $StartJobIfNeeded -ArgumentList $vmRg, $true, $tags, $AsJob
                         }

                         # Add tags to the OS disk (VMs should always have an OS disk
                         Invoke-Command -ScriptBlock $StartJobIfNeeded -ArgumentList $vm.Properties.storageProfile.osDisk.managedDisk.id, $false, $tags, $AsJob

                         # Add Tags to the data disks
                         $vm.Properties.storageProfile.dataDisks | ForEach-Object {
                         Invoke-Command -ScriptBlock $StartJobIfNeeded -ArgumentList $_.managedDisk.id, $false, $tags, $AsJob
                      }
                  }
              }
        }
    }
    catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {
  }
}

function Set-AzDtlLabIpPolicy {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline=$true, HelpMessage="Lab to query for Shared Image Gallery")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$false, HelpMessage="Name of the subnet to update the properties.  If left out, all subnets are updated")]
    [string]
    $SubnetName,

    [parameter(Mandatory=$true, HelpMessage="Public=separate IP Address, Shared=load balancers optimizes IP Addresses, Private=No public IP address.")]
    [Validateset('Public','Private', 'Shared')]
    [string]
    $IpConfig = 'Shared'
  )

  begin {. BeginPreamble}
  process {
    try{

      $sharedIpConfig = @"
{
    "allowedPorts":  [
                        {
                            "transportProtocol" : "Tcp",
                            "backendPort" : "3389"
                        },
                        {
                            "transportProtocol" : "Tcp",
                            "backendPort" : "22"
                        }
                        ]
}
"@ | ConvertFrom-Json

      Write-verbose "Retrieving Virtual Network for lab $($Lab.Name) ..."
      $vnets = Get-AzResource -Name $Lab.Name -ResourceGroupName $Lab.ResourceGroupName -ResourceType 'Microsoft.DevTestLab/labs/virtualnetworks' -ODataQuery '$expand=Properties($expand=externalSubnets)' -ApiVersion 2018-10-15-preview

      # Iterate through the vnets for all the subnets
      foreach ($vnet in $vnets) {
        
        # There is a chance that subnet overrides doesn't exist.  This seems to happen if:
        #  1)  We get to the lab before DTL has fully populated the objects, or 
        #  2)  If the DTL VM object is created before the underlying VNet subnets are (ordering)
        #  If they're missing, let's generate the defaults for subnetOverrides
        if (-not ($vnet.Properties.PSObject.Properties.Name -match "subnetOverrides")) {

            $subnetOverrides = [array] ($vnet.Properties.externalSubnets | ForEach-Object {
                [PSCustomObject] @{
                    resourceId = $_.id
                    labSubnetName = $_.name
                    useInVmCreationPermission = "Allow"
                    usePublicIpAddressPermission = "Allow"
                }
            })
            
            Add-Member -InputObject $vnet.Properties -Name "subnetOverrides" -MemberType NoteProperty -Value $subnetOverrides

        }

        # Iterate through the subnets and set the properties appropriately
        foreach ($subnet in $vnet.Properties.subnetOverrides) {
            # Only update if it matches the subnet name/subnetname is missing AND if this is a VNet used for VM Creation
            if ((-not $SubnetName -or ($subnet.labSubnetName -like $SubnetName)) -and ($subnet.useInVmCreationPermission -eq "Allow")) {
                if ($IpConfig -eq 'Shared') {
                    if ($subnet.PSObject.Properties.Name -match "sharedPublicIpAddressConfiguration") {
                        $subnet.sharedPublicIpAddressConfiguration = $sharedIpConfig
                    }
                    else {
                        Add-Member -InputObject $subnet -MemberType NoteProperty -Name "sharedPublicIpAddressConfiguration" -Value $sharedIpConfig
                    }

                    $subnet.usePublicIpAddressPermission = $false
                }
                elseif ($IpConfig -eq 'Public') {
                    if ($subnet.PSObject.Properties.Name -match "sharedPublicIpAddressConfiguration") {
                        $subnet.PSObject.Properties.Remove("sharedPublicIpAddressConfiguration")
                    }

                    $subnet.usePublicIpAddressPermission = $true

                }
                elseif ($IpConfig -eq 'Private') {
                    if ($subnet.PSObject.Properties.Name -match "sharedPublicIpAddressConfiguration") {
                        $subnet.PSObject.Properties.Remove("sharedPublicIpAddressConfiguration")
                    }

                    $subnet.usePublicIpAddressPermission = $false
                }
            }
        }
        # Push this VNet back to Azure
        Set-AzResource -ResourceId $vnet.ResourceId -Properties $vnet.Properties -Force
      }

      # Return the lab to continue in the pipeline
      return $Lab
    }
    catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {
  }

}

function Get-AzDtlLabSharedImageGallery {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline=$true, HelpMessage="Lab to query for Shared Image Gallery")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$false,HelpMessage="Also return images")]
    [switch] $IncludeImages = $false
  )

  begin {. BeginPreamble}
  process {
    try{
        # Get the shared image gallery
        Write-Verbose "Checking for the shared image gallery resource for lab '$($lab.Name)'"
        $sig = Get-AzureRmResource -ResourceGroupName $Lab.ResourceGroupName -ResourceType 'Microsoft.DevTestLab/labs/sharedGalleries' -ResourceName $Lab.Name -ApiVersion 2018-10-15-preview

        # Get all the images too and return the whole thing - if $sig is null, we don't return anything (no pipeline object)
        if ($sig) {

          if ($IncludeImages) {
              # Get the images in the shared image gallery
              $sigImages = $sig | Get-AzDtlLabSharedImageGalleryImages

              # Add the images to the shared image gallery object
              $sig | Add-Member -MemberType NoteProperty -Name "Images" -Value $sigimages
          }

        return $sig
      }
    }
    catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {
  }
}

function Remove-AzDtlLabSharedImageGallery {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline=$true, HelpMessage="DevTest Labs Shared Image Gallery object to remove from the lab")]
    [ValidateNotNullOrEmpty()]
    $SharedImageGallery
  )

  begin {. BeginPreamble}
  process {
    try{
        Remove-AzureRmResource -ResourceId $SharedImageGallery.ResourceId -ApiVersion 2018-10-15-preview -Force
    }
    catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {
  }
}

function Set-AzDtlLabSharedImageGallery {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline=$true, HelpMessage="Lab object to set Shared Image Gallery")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$true,HelpMessage="The DevTest Labs name for the shared image gallery")]
    [string] $Name,

    [parameter(Mandatory=$true,HelpMessage="Full ResourceId of the Shared Image Gallery to attach to the lab")]
    [string] $ResourceId,

    [parameter(Mandatory=$false,HelpMessage="Set to true to allow all images to be used as VM bases, set to false to control image-by-image which ones are allowed")]
    [bool] $AllowAllImages = $true

  )

  begin {. BeginPreamble}
  process {
    try{

        if ($AllowAllImages) {
            $status = "Enabled"
        } else {
            $status = "Disabled"
        }


        $propertiesObject = @{
            GalleryId = $ResourceId
            allowAllImages = $status
        }

        # Add a shared image gallery
        $result = New-AzureRmResource -Location $Lab.Location `
                                      -ResourceGroupName $Lab.ResourceGroupName `
                                      -properties $propertiesObject `
                                      -ResourceType 'Microsoft.DevTestLab/labs/sharedGalleries' `
                                      -ResourceName ($Lab.Name + '/' + $Name) `
                                      -ApiVersion 2018-10-15-preview `
                                      -Force

        # following the pipeline pattern, return the shared image gallery object on the pipeline
        return ($Lab | Get-AzDtlLabSharedImageGallery)

    }
    catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {
  }
}

function Get-AzDtlLabSharedImageGalleryImages {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline=$true, HelpMessage="DevTest Labs Shared Image Gallery object to get images")]
    [ValidateNotNullOrEmpty()]
    $SharedImageGallery
  )

  begin {. BeginPreamble}
  process {
    try{

        $sigimages = Get-AzureRmResource -ResourceId ($SharedImageGallery.ResourceId + "/sharedimages") `
                                         -ApiVersion 2018-10-15-preview `
                                         | ForEach-Object {
                                            Add-Member -InputObject $_.Properties -MemberType NoteProperty -Name ResourceId -Value $_.ResourceId
                                            $_.Properties.PSObject.Properties.Remove('uniqueIdentifier')
                                            # Return properties on the pipeline
                                            $_.Properties
                                         }

        return $sigimages

    }
    catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {
  }
}

function UpdateSharedImageGalleryImage ($SigResourceId, $ImageName, $OsType, $ImageType, $Status) {

    $propertiesObject = @{
        definitionName = $ImageName
        enableState = $Status
        osType = $OsType
        ImageType = $ImageType
    }

    Set-AzureRmResource -ResourceId ($SigResourceId + "/sharedImages/" + $ImageName) `
                        -ApiVersion 2018-10-15-preview `
                        -Properties $propertiesObject `
                        -Force | Out-Null

 }

function Set-AzDtlLabSharedImageGalleryImages  {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ParameterSetName = "Default", ValueFromPipeline=$true, HelpMessage="Shared Image Gallery object with Images property populated")]
    [parameter(Mandatory=$true, ParameterSetName = "SingleImageChange", ValueFromPipeline=$true, HelpMessage="Shared Image Gallery object")]
    [ValidateNotNullOrEmpty()]
    $SharedImageGallery,

    [parameter(Mandatory=$true, ParameterSetName = "SingleImageChange", HelpMessage="Image Name for the image to change the enabled/disabled setting on")]
    [string] $ImageName,

    [parameter(Mandatory=$true, ParameterSetName = "SingleImageChange", HelpMessage="The type of OS for this particular image")]
    [ValidateSet('Windows','Linux')]
    [string] $OsType,

    [parameter(Mandatory=$true, ParameterSetName = "SingleImageChange", HelpMessage="Image Name for the image to change the enabled/disabled setting on")]
    [string] $ImageType,

    [parameter(Mandatory=$true, ParameterSetName = "SingleImageChange", HelpMessage="Should the image be enabled (true) or disabled (false)")]
    [bool] $Enabled
  )

  begin {. BeginPreamble}
  process {
    try{

        # If we're specifying a state for a specific image, we assume that the gallery should be
        # set with the "allowAllImages" property to false - let's fix if needed
        if ($SharedImageGallery.Properties.allowAllImages -eq "Enabled") {

            $propertiesObject = @{
                GalleryId = $SharedImageGallery.Properties.galleryId
                allowAllImages = "Disabled"
            }

            # Update the SIG using ResourceID
            $result = Set-AzureRmResource -ResourceId $SharedImageGallery.ResourceId `
                                          -Properties $propertiesObject `
                                          -ApiVersion 2018-10-15-preview `
                                          -Force
        }

        if ($ImageName) {
            # If we're looking at a single image, we handle it directly

            if ($Enabled) {
                $status = "Enabled"
            } else {
                $status = "Disabled"
            }

            UpdateSharedImageGalleryImage $SharedImageGallery.ResourceId $ImageName $OsType $ImageType $status

        } else {
            # First ensure the Images property is correctly set
            if ($SharedImageGallery.Images) {
                # Iterate through all the images and set each one
                foreach ($img in $SharedImageGallery.Images) {
                    UpdateSharedImageGalleryImage $SharedImageGallery.ResourceId $img.definitionName $img.osType $img.imageType $img.enableState
                }

            } else {
                Write-Error '$SharedImageGallery.Images property must be set or ImageName & Enabled must be set'
            }
        }

        # following the pipeline pattern, return the shared image gallery object on the pipeline
        return $SharedImageGallery

    }
    catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {
  }
}

#endregion

#region VM ACTIONS

function Get-AzDtlVm {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="Lab object to retrieve VM from.", ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$false,HelpMessage="Name of the VMs to retrieve.  This parameter supports wildcards at the beginning and/or end of the string.")]
    [ValidateNotNullOrEmpty()]
    [string]
    $Name = "*",

    [parameter(Mandatory=$false,HelpMessage="Status filter for the vms to retrieve.  This parameter supports wildcards at the beginning and/or end of the string.")]
    [ValidateSet('Starting', 'Running', 'Stopping', 'Stopped', 'Failed', 'Restarting', 'ApplyingArtifacts', 'UpgradingVmAgent', 'Creating', 'Deleting', 'Corrupted', 'Any')]
    [string]
    $Status = 'Any',

    [parameter(Mandatory=$false,HelpMessage="Check underlying compute for complete status")]
    [switch] $ExtendedStatus=$false
  )

  begin {. BeginPreamble}
  process {
    try {
      foreach($l in $Lab) {
        $ResourceGroupName = $l.ResourceGroupName
        $LabName = $l.Name
        Write-verbose "Retrieving $Name VMs for lab $LabName in $ResourceGroupName."
        # Need to query client side to support wildcard at start of name as well (but this is bad as potentially many vms are involved)
        # Also notice silently continue for errors to return empty set for composibility
        # TODO: is there a clever way to make this less expensive? I.E. prequery without -ExpandProperties and then use the result to query again.
        $vms = MyGetResourceVm -Name "$Name" -LabName $LabName -ResourceGroupName $ResourceGroupName

        if($vms -and ($Status -ne 'Any')) {
          return $vms | Where-Object { $Status -eq (Get-AzDtlVmStatus $_ -ExtendedStatus:$ExtendedStatus)}
        } else {
          if ($ExtendedStatus) {
            foreach($vm in $vms) {
                Add-Member -InputObject $vm.Properties -MemberType NoteProperty -Name "Status" -Value $(Get-AzDtlVmStatus $vm -ExtendedStatus:$ExtendedStatus)
            }
          }
          return $vms
        }
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

function Get-AzDtlVmStatus {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="VM to get status for.", ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    $Vm,

    [parameter(Mandatory=$false,HelpMessage="Check underlying compute for complete status")]
    [switch] $ExtendedStatus=$false
  )

  begin {. BeginPreamble}
  process {
    try {
      foreach($v in $Vm) {
        # If the DTL VM has provisioningState equal to "Succeeded", we need to check the compute VM state
        if ($v.Properties.provisioningState -eq "Succeeded") {
          if ($ExtendedStatus) {
            $computeVm = GetComputeVm($v)
            if ($computeVm) {
              $computeProvisioningStateObj = $computeVm.Statuses | Where-Object {$_.Code.Contains("ProvisioningState")} | Select-Object Code -First 1
              $computeProvisioningState = $null
              if ($computeProvisioningStateObj) {
                  $computeProvisioningState = $computeProvisioningStateObj.Code.Replace("ProvisioningState/", "")
              }
              $computePowerStateObj = $computeVm.Statuses | Where-Object {$_.Code.Contains("PowerState")} | Select-Object Code -First 1
              $computePowerState = $null
              if ($computePowerStateObj) {
                  $computePowerState = $computePowerStateObj.Code.Replace("PowerState/", "")
              }

              # if we have a powerstate, we return the pretty string for it.  This should match the DTL UI
              if ($computePowerState) {
                if ($computePowerState -eq "deallocating") {
                  return "Stopping"
                } elseif ($computePowerState -eq "deallocated") {
                    return "Stopped"
                } elseif ($computePowerState -eq "running") {
                    return "Running"
                } elseif ($computePowerState -eq "starting") {
                    return "Starting"
                } elseif ($computePowerState -eq "stopped") {
                    return "Stopped"
                } elseif ($computePowerState -eq "stopping") {
                    return "Stopping"
                } else {
                    # if we have a powerstate we don't recognize, let's return "Updating"
                    return "Updating"
                }
              } else {
                # No power state, we return the provisioning state
                if ($computeProvisioningState -eq "updating") {
                  return "Updating"
                } elseif ($computeProvisioningState -eq "failed") {
                  return "Failed"
                } elseif ($computeProvisioningState -eq "deleting") {
                  return "Deleting"
                } else {
                  return $computeProvisioningState
                }
              }
            } else {
              # Compute VM is null, means we have a failed VM
              return "Corrupted"
            }
          } else {
            return $v.Properties.lastKnownPowerState
          }
        } else {
            # ApplyingArtifacts, UpgradingVmAgent, Creating, Deleting, Failed
            return $v.Properties.provisioningState
        }
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

function Start-AzDtlVm {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="VM to start. Noop if already started.", ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    $Vm,

    [parameter(Mandatory=$false,HelpMessage="Run the command in a separate job.")]
    [switch] $AsJob = $False
  )

  begin {. BeginPreamble}
  process {
    try {

        $sb = {
          param($vm, $justAz)

          if($justAz) {
            Enable-AzContextAutosave -Scope Process | Out-Null
          }

          Invoke-AzureRmResourceAction -ResourceId $vm.ResourceId -Action "start" -Force | Out-Null
          Get-AzureRmResource -ResourceId $vm.ResourceId -ExpandProperties
        }

      foreach($v in $Vm) {

          if($AsJob.IsPresent) {
            Start-Job      -ScriptBlock $sb -ArgumentList $v, $justAz
          } else {
            Invoke-Command -ScriptBlock $sb -ArgumentList $v, $justAz
          }
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

function Stop-AzDtlVm {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="VM to stop. Noop if already stopped.", ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    $Vm,

    [parameter(Mandatory=$false,HelpMessage="Run the command in a separate job.")]
    [switch] $AsJob = $False
  )

  begin {. BeginPreamble}
  process {
    try {
        $sb = {
          param($vm, $justAz)

          if($justAz) {
            Enable-AzureRmAlias -Scope Local -Verbose:$false
            Enable-AzContextAutosave -Scope Process | Out-Null
          }

          Invoke-AzureRmResourceAction -ResourceId $vm.ResourceId -Action "stop" -Force | Out-Null
          Get-AzureRmResource -ResourceId $vm.ResourceId -ExpandProperties
        }

      foreach($v in $Vm) {

          if($AsJob.IsPresent) {
            Start-Job      -ScriptBlock $sb -ArgumentList $v, $justAz
          } else {
            Invoke-Command -ScriptBlock $sb -ArgumentList $v, $justAz
          }
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

function Remove-AzDtlVm {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="VM to remove. Noop if it doesn't exist.", ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    $Vm
  )

  begin {. BeginPreamble}
  process {
    try {
      foreach($v in $Vm) {
        Remove-AzureRmResource -ResourceId $v.ResourceId -Force
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

function Invoke-AzDtlVmClaim {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="VM to claim. Noop if already claimed.", ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    $Vm
  )

  begin {. BeginPreamble}
  process {
    try {
      foreach($v in $Vm) {
        Invoke-AzureRmResourceAction -ResourceId $v.ResourceId -Action "claim" -Force | Out-Null
        $v  | Get-AzDtlVm
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

function Invoke-AzDtlVmUnClaim {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="VM to unclaimed. Noop if already unclaimed.", ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    $Vm
  )

  begin {. BeginPreamble}
  process {
    try {
      foreach($v in $Vm) {
        Invoke-AzureRmResourceAction -ResourceId $v.ResourceId -Action "claim" -Force | Out-Null
        $v  | Get-AzDtlVm
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

function Set-AzDtlVmShutdownSchedule {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="Vm to apply policy to.", ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    $Vm,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="The time (relative to timeZoneId) at which the Lab VMs will be automatically shutdown (E.g. 17:30, 20:00, 09:00).")]
    [ValidateLength(4,5)]
    [string] $ShutdownTime,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="The Windows time zone id associated with labVmShutDownTime (E.g. UTC, Pacific Standard Time, Central Europe Standard Time).")]
    [ValidateLength(3,40)]
    [string] $TimeZoneId,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Set schedule status.")]
    [ValidateSet('Enabled', 'Disabled')]
    [string] $ScheduleStatus = 'Enabled',

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Set this notification status.")]
    [ValidateSet('Enabled', 'Disabled')]
    [string] $NotificationSettings = 'Disabled',

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Time in minutes..")]
    [ValidateRange(1, 60)] #TODO: validate this is right??
    [int] $TimeInIMinutes = 15,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Url to send notification to.")]
    [string] $ShutdownNotificationUrl = "https://mywebook.com",

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Email to send notification to.")]
    [string] $EmailRecipient = "someone@somewhere.com",

    [parameter(Mandatory=$false,HelpMessage="Run the command in a separate job.")]
    [switch] $AsJob = $False
  )

  begin {. BeginPreamble}
  process {
    try {
      foreach($v in $Vm) {
        $params = @{
          resourceName = $v.ResourceName
          labVmShutDownTime = $ShutdownTime
          timeZoneId = $TimeZoneId
          scheduleStatus = $ScheduleStatus
          notificationSettings = $NotificationSettings
          timeInMinutes = $TimeInIMinutes
          labVmShutDownURL = $ShutdownNotificationUrl
          emailRecipient = $EmailRecipient
        }
        Write-verbose "Set Shutdown with $(PrintHashtable $params)"
@"
{
  "`$schema": "http://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "resourceName": {
      "type": "string"
    },
    "labVmShutDownTime": {
      "type": "string",
      "minLength": 4,
      "maxLength": 5
    },
    "timeZoneId": {
      "type": "string",
      "minLength": 3
    },
    "scheduleStatus": {
      "type": "string"
    },
    "notificationSettings": {
      "type": "string"
    },
    "timeInMinutes": {
      "type": "int"
    },
    "labVmShutDownURL": {
        "type": "string"
    },
    "emailRecipient": {
        "type": "string"
    }
  },


  "resources": [
    {
      "apiVersion": "2016-05-15",
      "name": "[concat(parameters('resourceName'),'/LabVmsShutdown')]",
      "type": "microsoft.devtestlab/labs/virtualmachines/schedules",
      "location": "[resourceGroup().location]",

      "properties": {
        "status": "[trim(parameters('scheduleStatus'))]",
        "taskType": "LabVmsShutdownTask",
        "timeZoneId": "[string(parameters('timeZoneId'))]",
        "dailyRecurrence": {
          "time": "[string(parameters('labVmShutDownTime'))]"
        },
        "notificationSettings": {
            "status": "[trim(parameters('notificationSettings'))]",
            "timeInMinutes": "[parameters('timeInMinutes')]",
            "webHookUrl": "[trim(parameters('labVmShutDownURL'))]",
            "emailRecipient": "[trim(parameters('emailRecipient'))]"
        }
      }
    }
  ]
}
"@  | DeployVm -vm $v -AsJob $AsJob -Parameters $Params
     }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

#TODO: this returns a OK result resource created, but the UI doesn't show it. To investigate.
function Set-AzDtlShutdownPolicy {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="Lab to apply policy to.", ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true,HelpMessage="Set control level.")]
    [ValidateSet('NoControl', 'FullControl', 'OnlyControlTime')]
    [string]
    $ControlLevel
  )

  begin {. BeginPreamble}
  process {
    throw "this returns a OK result resource created, but the UI doesn't show it. Investigate if it works and remove throw."
    try {
      foreach($l in $lab) {

        Switch($ControlLevel) {
          'FullControl'       { $threshold = "['None','Modify','OptOut']"}
          'OnlyControlTime'   { $threshold = "['None','Modify']"}
          'NoControl'         { $threshold = "['None']"}
        }


        $req =
@"
{
  "properties": {
      "description": "",
      "status": "Enabled",
      "factName": "ScheduleEditPermission",
      "threshold":`"$threshold`",
      "evaluatorType": "AllowedValuesPolicy",
  }
}
"@
        Write-verbose "Using $threshold on $($l.ResourceId)"

        $authHeaders = GetHeaderWithAuthToken
        $jsonPath = StringToFile($req)
        $subscriptionId = (Get-AzureRmContext).Subscription.Id
        $ResourceGroupName = $l.ResourceGroupName
        $labName = $l.Name
        $url = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.DevTestLab/labs/$labName/policySets/default/policies/ScheduleEditPermission?api-version=2018-10-15-preview" | Out-Null
        Write-Verbose "Using url $url"

        Invoke-WebRequest -Headers $authHeaders -Uri $url -Method 'PUT' -InFile $jsonPath
        $l  | Get-AzDtlLab
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

# Get the Virtual Network of type Microsoft.DevTestLab/labs/virtualnetworks starting from the Id of the underlying Microsoft.Network resource
# TODO Maybe we should rename it to Get-AzDtlVirtualNetworkFromVirtualNetwork or similar?
function Convert-AzDtlVirtualNetwork {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline=$true, HelpMessage="Lab object to find the attached Virtual Network")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$true, HelpMessage="Id of type Microsoft.Network of the Lab Virtual Network")]
    [ValidateNotNullOrEmpty()]
    [string] $VirtualNetworkId
  )

  begin {. BeginPreamble}
  process {
    try {

      # Trying to pass through the LabUId tag is a dead end.
      # No way to get the name of the Lab from the UId..

      # $DtlLabUId = $VirtualNetwork.Tags.GetEnumerator() | `
      # Where-Object { $_.Key -eq "hidden-DevTestLabs-LabUId" } | `
      # Select-Object -ExpandProperty Value -First 1

      if ($VirtualNetworkId.Split("/")[6] -ine "Microsoft.Network") {
        throw "VirtualNetworkId is not of type Microsoft.Network"
      }

      $dtlVirtualNetworkId = $VirtualNetworkId.Replace("Microsoft.Network", "microsoft.devtestlab/labs/$($Lab.Name)")
      Get-AzureRmResource -ResourceId $dtlVirtualNetworkId

    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

# Get the Virtual Network/s attached to the Lab
function Get-AzDtlLabVirtualNetworks {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline=$true, HelpMessage="Lab object to find the attached Virtual Networks")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$false, HelpMessage="Id of type Microsoft.DevTestLab/labs/virtualnetworks of a Lab Virtual Network. If none, get all the attached Virtual Networks.")]
    [string] $LabVirtualNetworkId = "",

    [parameter(Mandatory=$false, HelpMessage="If set, get the underlying Microsoft.Network resource")]
    [Switch]
    $ExpandedNetwork
  )

  begin {. BeginPreamble}
  process {
    try {
      $Lab | ForEach-Object {

        if ($LabVirtualNetworkId) {

          if ($LabVirtualNetworkId.Split("/")[6] -ine "microsoft.devtestlab") {
            throw "VirtualNetworkId is not of type Microsoft.DevTestLab/labs/virtualnetworks"
          }

          if ($ExpandedNetwork) {

            $virtualNetworkId = $LabVirtualNetworkId -ireplace "microsoft.devtestlab/labs/$($Lab.Name)", "Microsoft.Network"
            Get-AzureRmVirtualNetwork -ResourceGroupName $virtualNetworkId.Split("/")[4] -Name $virtualNetworkId.Split("/")[8]

          } else {
            Get-AzureRmResource -ResourceId $LabVirtualNetworkId
          }

        }
        else {

          $labVirtualNetworks = Get-AzureRmResource `
            -ResourceGroupName $_.ResourceGroupName `
            -ResourceType Microsoft.DevTestLab/labs/virtualnetworks `
            -ResourceName $_.Name `
            -ApiVersion 2018-09-15

          if ($ExpandedNetwork) {
            $labVirtualNetworks | ForEach-Object {
              Get-AzureRmVirtualNetwork -ResourceGroupName $_.ResourceGroupName -Name $_.Name
            }
          }
          else {
            $labVirtualNetworks
          }
        }
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

# Get the Subnets of the attached Virtual Network
function Get-AzDtlLabVirtualNetworkSubnets {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline=$true, HelpMessage="Lab object to find the attached Virtual Network subnets")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$true, ValueFromPipeline=$false, HelpMessage="Id of type Microsoft.DevTestLab/labs/virtualnetworks of a Lab Virtual Network")]
    [ValidateNotNullOrEmpty()]
    [string] $LabVirtualNetworkId,

    [parameter(Mandatory=$false, ValueFromPipeline=$false, HelpMessage="Filter by type of DTL Subnet")]
    [ValidateSet('All','UsedInVmCreation','UsedInPublicIpAddress')]
    [string] $SubnetKind = 'All'
  )

  begin {. BeginPreamble}
  process {
    try {

        $LabVirtualNetwork = $Lab | Get-AzDtlLabVirtualNetworks -LabVirtualNetworkId $LabVirtualNetworkId
        $LabVirtualNetwork | Foreach-Object {
          $_.Properties.subnetOverrides | Foreach-Object {

            if ($SubnetKind -eq 'All') {
              Get-AzureRmResource -ResourceId $_.ResourceId
            }
            else {
              if ($SubnetKind -eq 'UsedInVmCreation' -and $_.useInVmCreationPermission -eq "Allow") {
                Get-AzureRmResource -ResourceId $_.ResourceId
              }
              elseif ($SubnetKind -eq 'UsedInPublicIpAddress' -and $_.usePublicIpAddressPermission -eq "Allow") {
                Get-AzureRmResource -ResourceId $_.ResourceId
              }
            }
          }
        }
    } catch {

      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

function Set-AzDtlLabBrowserConnect {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="Lab to remove the Bastion host from.", ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$false, ValueFromPipeline=$false, HelpMessage="Filter by type of DTL Subnet")]
    [ValidateSet('Enabled','Disabled')]
    [string] $BrowserConnect = 'Enabled'
  )

  begin {. BeginPreamble}
  process {
    try {

      $Lab = $Lab | Get-AzDtlLab

      if ($Lab.Properties.browserConnect -ne $BrowserConnect) {

        Write-Host "Updating Lab Browser Connect to '$BrowserConnect'"

        # Must use the Preview API
        $Lab.Properties.browserConnect = $BrowserConnect
        Set-AzureRmResource `
          -ResourceId $Lab.ResourceId `
          -ApiVersion 2018-10-15-preview `
          -Properties $Lab.Properties `
          -Force | Out-Null

        Write-Host "Lab Browser Connect successfully updated to '$BrowserConnect'"
        
        $Lab | Get-AzDtlLab
      } else {
        Write-Warning "Lab Browser Connect is already set to '$BrowserConnect'"
      }
    }
    catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

# LabVirtualNetwork =  DTL VNet type
# VirtualNetwork = Std VNet type
# Deploy an Azure Bastion host to Lab Virtual Network
function New-AzDtlBastion {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="Lab to deploy the Bastion host to.", ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$false,HelpMessage="Id of type Microsoft.DevTestLab/labs/virtualnetworks of the Lab Virtual Network used in VM creation. Defaults to the VNet with VMs creation enabled, if there is only one. If you are using an existing virtual network, make sure the existing virtual network has enough free address space to accommodate the Bastion subnet requirements.")]
    [string] $LabVirtualNetworkId = "",

    [parameter(Mandatory=$true,HelpMessage="IP address prefix (CIDR notation) where to deploy the Bastion host")]
    [ValidateNotNullOrEmpty()]
    [string] $BastionSubnetAddressPrefix,

    [parameter(Mandatory=$false,HelpMessage="Run the command in a separate job.")]
    [switch] $AsJob = $false
  )

  begin {. BeginPreamble}
  process {
    try {

      if ($LabVirtualNetworkId -and $LabVirtualNetworkId.Split("/")[6] -ine "microsoft.devtestlab") {
        throw "VirtualNetworkId is not of type Microsoft.DevTestLab/labs/virtualnetworks"
      }

      $CIDRIPv4Regex = "^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(3[0-2]|[1-2][0-9]|[0-9]))$"
      if (!($BastionSubnetAddressPrefix -match $CIDRIPv4Regex)) {
        throw "Not a valid CIDR IPv4 address range"
      }

      if ($BastionSubnetAddressPrefix.Split("/")[1] -gt 27) {
        throw "You must use a subnet of at least /27 or larger (26,25...)"
      }

      $sb = {
        param($Lab, $LabVirtualNetworkId, $BastionSubnetAddressPrefix, $workingDir, $justAz)

        if($justAz) {
          Enable-AzureRmAlias -Scope Local -Verbose:$false
          Enable-AzContextAutosave -Scope Process | Out-Null
        }

        # Import again the module
        if (-not (Get-Module -Name Az.DevTestLabs2)) {
          Import-Module "$workingDir\Az.DevTestLabs2.psm1"
        }

        # Get again the lab just in case the preview API was not used
        $Lab = $Lab | Get-AzDtlLab

        # If LabVirtualNetworkId is not set, we may find more than 1 VNet.
        # It is okay, provided that only 1 VNet has a subnet supporting VMs creations.
        # Otherwise can cause confusion for the caller on which one to pick during the VM creation step.
        # TODO As of now Bastion does not support peered VNets in hub-spoke topologies.
        # Once this is supported, we can deploy a Bastion to 1 VNet
        # and the other VNets will be able to host VMs enabled for browser connection
        # without furtherly creating their own Bastion subnet.
        Write-Host "Retrieving the attached Virtual Network where to deploy the Azure Bastion"
        $LabVirtualNetwork = $Lab | Get-AzDtlLabVirtualNetworks -LabVirtualNetworkId $LabVirtualNetworkId
        $LabVirtualNetworkId = $LabVirtualNetwork.ResourceId

        # In the Lab VNets, look for an underlying subnet supporting VMs creation.
        # If 0 or > 1 VNet is found, we don't deploy the Bastion (today)
        $LabVirtualNetwork = $LabVirtualNetwork | Where-Object {
          $subnets = $Lab | Get-AzDtlLabVirtualNetworkSubnets -LabVirtualNetworkId $_.ResourceId -SubnetKind 'UsedInVmCreation'
          if ($subnets) {
            return $_
          }
        }

        if ($null -eq $LabVirtualNetwork -or ($LabVirtualNetwork -is [array] -and $LabVirtualNetwork.Count -ne 1)) {
          throw "DTL library currently supports deploying a Bastion in a Lab with only 1 VNet enabled for VM creation"
        }

        # Make sure to get the underlying VNet for this Lab
        Write-Host "Retrieving the underlying attached Virtual Network used to deploy the Azure Bastion"
        $VirtualNetwork = $Lab | Get-AzDtlLabVirtualNetworks -LabVirtualNetworkId $LabVirtualNetwork.ResourceId -ExpandedNetwork

        # TODO Skip this step if there is already a subnet named 'AzureBastionSubnet'
        # Try to create a new subnet named 'AzureBastionSubnet' in this address range
        Write-Host "Adding a subnet 'AzureBastionSubnet' at $BastionSubnetAddressPrefix"
        $VirtualNetwork = Add-AzureRmVirtualNetworkSubnetConfig -VirtualNetwork $VirtualNetwork -Name "AzureBastionSubnet" -AddressPrefix $BastionSubnetAddressPrefix
        $VirtualNetwork = Set-AzureRmVirtualNetwork -VirtualNetwork $VirtualNetwork
        Write-Host "Subnet 'AzureBastionSubnet' successfully added to the Virtual Network"

        # IP must be in the same region of the Bastion
        Write-Host "Creating a Public IP address for the Bastion host"
        $bastionPublicIpAddress =
                New-AzureRmPublicIpAddress `
                    -ResourceGroupName $Lab.ResourceGroupName `
                    -Name "$($Lab.Name)BastionPublicIP" `
                    -Location $Lab.Location `
                    -AllocationMethod "Static" `
                    -Sku "Standard"
        Write-Host "Bastion Public IP address successfully created at $($bastionPublicIpAddress.IpAddress)"

        # Deploy the Bastion
        Write-Host "Creating the Bastion resource"
        New-AzBastion `
            -ResourceGroupName $Lab.ResourceGroupName `
            -Name "$($Lab.Name)Bastion" `
            -PublicIpAddressRgName $bastionPublicIpAddress.ResourceGroupName `
            -PublicIpAddressName $bastionPublicIpAddress.Name `
            -VirtualNetworkRgName $VirtualNetwork.ResourceGroupName `
            -VirtualNetworkName $VirtualNetwork.Name `

        Write-Host "Azure Bastion resource successfully created"

        $Lab = $Lab | Set-AzDtlLabBrowserConnect -BrowserConnect 'Enabled'

        # Return the newly created Bastion
        Write-Host "Returning the Bastion"
        $Lab | Get-AzDtlBastion -LabVirtualNetworkId $LabVirtualNetworkId
      }
      foreach($l in $Lab) {
        if($AsJob.IsPresent) {
          Start-Job      -ScriptBlock $sb -ArgumentList $l, $LabVirtualNetworkId, $BastionSubnetAddressPrefix, $PWD, $justAz
        } else {
          Invoke-Command -ScriptBlock $sb -ArgumentList $l, $LabVirtualNetworkId, $BastionSubnetAddressPrefix, $PWD, $justAz
        }
      }

      # Set-Location `$Using:PWD
    }
    catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

function Get-AzDtlBastion {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="Lab to get the Bastion host from.", ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$false,HelpMessage="Id of type Microsoft.DevTestLab/labs/virtualnetworks of the Lab Virtual Network used for Bastion. Deafults to the 1 and only VNet that has an Azure Bastion Subnet.")]
    [string] $LabVirtualNetworkId = ""
  )
  begin {. BeginPreamble}
  process {
    try {

      if ($LabVirtualNetworkId -and $LabVirtualNetworkId.Split("/")[6] -ine "microsoft.devtestlab") {
        throw "VirtualNetworkId is not of type Microsoft.DevTestLab/labs/virtualnetworks"
      }

      # Get again the lab just in case the preview API was not used
      $Lab = $Lab | Get-AzDtlLab

      Write-Host "Retrieving the attached Virtual Network where Azure Bastion is deployed"
      # Cannot retrieve AzureBastionSubnet from DTLVNet subnetOverrides property
      $VirtualNetwork = $Lab | Get-AzDtlLabVirtualNetworks -LabVirtualNetworkId $LabVirtualNetworkId -ExpandedNetwork

      # In the Lab VNets, look for an underlying subnet named AzureBastionSubnet.
      # If 0 or > 1 VNet is found, we don't remove the Bastion
      $VirtualNetwork = $VirtualNetwork | Where-Object {
        $bastionSubnet = [Array] $_.Subnets | Where-Object { $_.Name -eq "AzureBastionSubnet" } | Select-Object -First 1
        if ($bastionSubnet) {
          return $_
        }
      }

      if (-not $VirtualNetwork) {
        return $null
      }

      # Trace back the Bastion host from the assigned IPConfig
      # Look for an IP Configuration of type Microsoft.Network/bastionHosts
      $ipConfigBastions = [Array] $bastionSubnet.IpConfigurations | Where-Object {
        ("$($_.Id.Split("/")[6])/$($_.Id.Split("/")[7])" -eq "Microsoft.Network/bastionHosts")
      }

      if (($ipConfigBastions | Measure-Object).Count -eq 0) {
        throw "No bastion associated to this IPConfig"
      }
      if (($ipConfigBastions | Measure-Object).Count -gt 1) {
        throw "More than 1 bastion associated to this IPConfig"
      }

      $bastionResourceGroupName = $ipConfigBastions.Id.Split("/")[4]
      $bastionName = $ipConfigBastions.Id.Split("/")[8]
      
      Get-AzBastion `
            -ResourceGroupName $bastionResourceGroupName `
            -Name $bastionName
    }
    catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

function Remove-AzDtlBastion {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="Lab to remove the Bastion host from.", ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$false,HelpMessage="Id of type Microsoft.DevTestLab/labs/virtualnetworks of the Lab Virtual Network used for Bastion. If there is only 1 VNet with an AzureBastionSubnet, it defaults to this one.")]
    [string] $LabVirtualNetworkId = "",

    [parameter(Mandatory=$false,HelpMessage="Run the command in a separate job.")]
    [switch] $AsJob = $false
  )

  begin {. BeginPreamble}
  process {
    try {

      if ($LabVirtualNetworkId -and $LabVirtualNetworkId.Split("/")[6] -ine "microsoft.devtestlab") {
        throw "VirtualNetworkId is not of type Microsoft.DevTestLab/labs/virtualnetworks"
      }

      $sb = {
        param($Lab, $LabVirtualNetworkId, $workingDir, $justAz)

        if($justAz) {
          Enable-AzureRmAlias -Scope Local -Verbose:$false
          Enable-AzContextAutosave -Scope Process | Out-Null
        }

        # Import again the module
        if (-not (Get-Module -Name Az.DevTestLabs2)) {
          Import-Module "$workingDir\Az.DevTestLabs2.psm1"
        }

        $Lab = $Lab | Get-AzDtlLab
        $bastion = $Lab | Get-AzDtlBastion -LabVirtualNetworkId $LabVirtualNetworkId
  
        if ($bastion) {

          Write-Host "Removing the bastion '$($bastion.Name)'."
          $bastion | Remove-AzBastion -Force

          $VirtualNetwork = $Lab | Get-AzDtlLabVirtualNetworks -LabVirtualNetworkId $LabVirtualNetworkId -ExpandedNetwork

          $bastion.IpConfigurations | ForEach-Object {
    
            if ($_.PublicIpAddress) {
              Write-Host "Removing the Public Ip Address assigned to the Azure Bastion 'AzureBastionSubnet'."
              Remove-AzureRmResource -ResourceId $_.PublicIpAddress.Id -Force
            }
    
            if ($_.Subnet) {
              Write-Host "Removing the subnet 'AzureBastionSubnet'."
              $bastionSubnet = Get-AzureRmResource -ResourceId $_.Subnet.Id
              Remove-AzureRmVirtualNetworkSubnetConfig -Name $bastionSubnet.Name -VirtualNetwork $VirtualNetwork
              $VirtualNetwork | Set-AzureRmVirtualNetwork
            }
          }
        }

        $Lab | Set-AzDtlLabBrowserConnect -BrowserConnect 'Disabled' | Out-Null
      }

      foreach($l in $Lab) {
        if($AsJob.IsPresent) {
          Start-Job      -ScriptBlock $sb -ArgumentList $l, $LabVirtualNetworkId, $PWD, $justAz
        } else {
          Invoke-Command -ScriptBlock $sb -ArgumentList $l, $LabVirtualNetworkId, $PWD, $justAz
        }
      }
    }
    catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

function Set-AzDtlMandatoryArtifacts {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline=$true, HelpMessage="Lab object to set Shared Image Gallery")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$false,HelpMessage="The names of mandatory artifacts for Windows-based OS")]
    [array] $WindowsArtifactNames,

    [parameter(Mandatory=$false,HelpMessage="The names of mandatory artifacts for Linux-based OS")]
    [array] $LinuxArtifactNames

  )

  begin {. BeginPreamble}
  process {
    try{

        # NOTE: It's OK if both windows/linux artifacts are null - that means clear out both lists
        # NOTE2: There is some code duplication, powershell mucks with parameters, didn't work when moving common code to a function

        # First we need to get the current state of the lab
        $labObj = MyGetResourceLab $Lab.Name $Lab.ResourceGroupName

        # Pre-process the $WindowsArtifactNames variable
        if ($WindowsArtifactNames) {
            # If the user passed in a string, convert it to an array
            if ($WindowsArtifactNames -and $WindowsArtifactNames.GetType().Name -eq "String") {
                $WindowsArtifactNames = @($WindowsArtifactNames)
            }

            # If the user didn't pass full IDs, we need to convert them
            for ($i = 0; $i -lt $WindowsArtifactNames.Count; $i ++) {
                if (-not $WindowsArtifactNames[$i].contains('/')) {
                    $WindowsArtifactNames.Item($i) = "$($labObj.ResourceId)/artifactSources/public repo/artifacts/$($WindowsArtifactNames[$i])"
                }
            }
        }

        $labObj.Properties.mandatoryArtifactsResourceIdsWindows = $WindowsArtifactNames

        # Pre-process the $LinuxArtifactNames variable
        if ($LinuxArtifactNames) {
            # If the user passed in a string, convert it to an array
            if ($LinuxArtifactNames -and $LinuxArtifactNames.GetType().Name -eq "String") {
                $LinuxArtifactNames = @($LinuxArtifactNames)
            }

            # If the user didn't pass full IDs, we need to convert them
            for ($i = 0; $i -lt $LinuxArtifactNames.Count; $i ++) {
                if (-not $LinuxArtifactNames[$i].contains('/')) {
                    $LinuxArtifactNames.Item($i) = "$($labObj.ResourceId)/artifactSources/public repo/artifacts/$($LinuxArtifactNames[$i])"
                }
            }
        }

        $labObj.Properties.mandatoryArtifactsResourceIdsLinux = $LinuxArtifactNames

        Set-AzureRmResource -Name $labObj.Name -ResourceGroupName $labObj.ResourceGroupName -ResourceType "Microsoft.DevTestLab/labs" -Properties $labObj.Properties -ApiVersion 2018-10-15-preview -Force

    }
    catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {
  }
}

function Get-AzDtlVmArtifact {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="Vm to get artifacts from.", ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    $Vm
  )

  begin {. BeginPreamble}
  process {
    throw "There is a AzureRM 6.0 bug breaking this code."
    try {
      foreach($v in $Vm) {
        return (Get-AzureRmResource -ResourceId $v.ResourceId -ApiVersion 2016-05-15 -ODataQuery '$expand=Properties($expand=Artifacts)').Properties.Artifacts
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}
function Set-AzDtlVmArtifact {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="Vm to apply artifacts to.", ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    $Vm,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true,HelpMessage="Name of the repository to get artifact from.")]
    [ValidateNotNullOrEmpty()]
    [string]
    $RepositoryName,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true,HelpMessage="Name of the artifact to apply.")]
    [ValidateNotNullOrEmpty()]
    [string]
    $ArtifactName,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true,HelpMessage="Parameters for artifact. An array of hashtable, each one as @{name = xxx; value = yyy}.")]
    [ValidateNotNullOrEmpty()]
    [array]
    $ArtifactParameters = @(),

    [parameter(Mandatory=$false,HelpMessage="Run the command in a separate job.")]
    [switch] $AsJob = $False
  )

  begin {. BeginPreamble}
  process {
    try {

        $sb = {
            param(
                $v,
                [string] $RepositoryName,
                [string] $ArtifactName,
                [array] $ArtifactParameters = @(),
                $justAz
            )

            if($justAz) {
                Enable-AzureRmAlias -Scope Local -Verbose:$false
                Enable-AzContextAutosave -Scope Process | Out-Null
            }

            $ResourceGroupName = $v.ResourceGroupName

            #TODO: is there a better way? It doesn't seem to be in Expanded props of VM ...
            $LabName = $v.ResourceId.Split('/')[8]
            if(-not $LabName) {
              throw "VM Name for $v is not in the format 'RGName/VMName. Why?"
            }

            # Get internal repo name
            $repository = Get-AzureRmResource -ResourceGroupName $resourceGroupName `
              -ResourceType 'Microsoft.DevTestLab/labs/artifactsources' `
              -ResourceName $LabName -ApiVersion 2016-05-15 `
              | Where-Object { $RepositoryName -in ($_.Name, $_.Properties.displayName) } `
              | Select-Object -First 1

            if(-not $repository) {
              throw "Unable to find repository $RepositoryName in lab $LabName."
            }
            Write-verbose "Repository found is $($repository.Name)"

            # Get internal artifact name
            $template = Get-AzureRmResource -ResourceGroupName $ResourceGroupName `
              -ResourceType "Microsoft.DevTestLab/labs/artifactSources/artifacts" `
              -ResourceName "$LabName/$($repository.Name)" `
              -ApiVersion 2016-05-15 `
              | Where-Object { $ArtifactName -in ($_.Name, $_.Properties.title) } `
              | Select-Object -First 1

            if(-not $template) {
              throw "Unable to find template $ArtifactName in lab $LabName."
            }
            Write-verbose "Template artifact found is $($template.Name)"

            #TODO: is there a better way to construct this?
            $SubscriptionID = (Get-AzureRmContext).Subscription.Id
            $FullArtifactId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.DevTestLab/labs/$LabName/artifactSources/$($repository.Name)/artifacts/$($template.Name)"
            Write-verbose "Using artifact id $FullArtifactId"

            $prop = @{
              artifacts = @(
                @{
                  artifactId = $FullArtifactId
                  parameters = $ArtifactParameters
                }
              )
            }

            Write-debug "Apply:`n $($prop | ConvertTo-Json)`n to $($v.ResourceId)."
            Write-verbose "Using $FullArtifactId on $($v.ResourceId)"
            Invoke-AzureRmResourceAction -Parameters $prop -ResourceId $v.ResourceId -Action "applyArtifacts" -ApiVersion 2016-05-15 -Force | Out-Null
            Get-AzureRmResource -ResourceId $v.ResourceId -ExpandProperties
        }

      foreach($v in $Vm) {
          if($AsJob.IsPresent) {
            Start-Job      -ScriptBlock $sb -ArgumentList $v, $RepositoryName, $ArtifactName, $artifactParameters, $justAz
          } else {
            Invoke-Command -ScriptBlock $sb -ArgumentList $v, $RepositoryName, $ArtifactName, $artifactParameters, $justAz
          }
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

function Set-AzDtlVmAutoStart {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="Vm to apply autostart to.", ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    $Vm,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true,HelpMessage="Set autostart status.")]
    [bool]
    $AutoStartStatus = $true
  )

  begin {. BeginPreamble}
  process {
    try {
      foreach($v in $Vm) {
        Write-Verbose "Set AutoStart for $($v.ResourceId) to $AutoStartStatus"
        Set-AzureRmResource -ResourceId $v.ResourceId -Tag @{AutoStartOn = $AutoStartStatus} -Force | Out-Null
        $v  | Get-AzDtlVm
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

$templateVmCreation = @"
{
  "`$schema": "http://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "newVMName": {
      "type": "string"
    },
    "existingLabName": {
      "type": "string"
    }
  },
  "variables": {
    "labSubnetName": "[concat(variables('labVirtualNetworkName'), 'Subnet')]",
    "labVirtualNetworkId": "[resourceId('Microsoft.DevTestLab/labs/virtualnetworks', parameters('existingLabName'), variables('labVirtualNetworkName'))]",
    "labVirtualNetworkName": "[concat('Dtl', parameters('existingLabName'))]",
    "resourceName": "[concat(parameters('existingLabName'), '/', parameters('newVMName'))]",
    "resourceType": "Microsoft.DevTestLab/labs/virtualMachines"
  },
  "resources": [
    {
      "apiVersion": "2018-10-15-preview",
      "type": "Microsoft.DevTestLab/labs/virtualMachines",
      "name": "[variables('resourceName')]",
      "location": "[resourceGroup().location]",
      "properties": {
        "labVirtualNetworkId": "[variables('labVirtualNetworkId')]",
        "labSubnetName": "[variables('labSubnetName')]"
      }
    }
  ],
  "outputs": {
    "vmId": {
      "type": "string",
      "value": "[resourceId(variables('resourceType'), parameters('existingLabName'), parameters('newVMName'))]"
    }
  }
}
"@

# TODO: Consider adding parameters Name and ResourceGroupName tied to the pipeline by property
# to enable easier pipeline for csv files in the form [Name, ResourceGroupName, VMName, ...]
function New-AzDtlVm {
  [CmdletBinding()]
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingPlainTextForPassword", "", Scope="Function")]
  param(
    [parameter(Mandatory=$false, ValueFromPipeline=$true, HelpMessage="Lab object to create Vm into. This is not used if you specify Name/ResourceGroupName.")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Name of Lab object to create Vm into.")]
    [ValidateNotNullOrEmpty()]
    $Name,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Name of Resource Group where lab lives.")]
    [ValidateNotNullOrEmpty()]
    $ResourceGroupName,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="Name of VM to create.")]
    [ValidateNotNullOrEmpty()]
    [string]
    $VmName,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="Size of VM to create.")]
    [ValidateNotNullOrEmpty()]
    [string]
    $Size,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Storage type to use for virtual machine (i.e. Standard, StandardSSD, Premium).")]
    [Validateset('Standard', 'StandardSSD', 'Premium')]
    [string]
    $StorageType,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="The notes of the virtual machine.")]
    [string]
    $Notes = "",

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="This is a claimable VM.")]
    [Switch]
    $Claimable,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Public=separate IP Address, Shared=load balancers optimizes IP Addresses, Private=No public IP address.")]
    [Validateset('Public','Private', 'Shared')]
    [string]
    $IpConfig = 'Shared',

    # We need to know the OS even in the custom image case to know which NAT rules to add in the shared IP scenario
    # TODO: perhaps the OS for a custom image can be retrieved. Then the user can not pass this, but we pay the price with one more network trip.
    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Which OS")]
    [Validateset('Windows','Linux')]
    [string]
    $OsType = 'Windows',

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Virtual Network id (defaults to id of virtual network name).")]
    [ValidateNotNullOrEmpty()]
    [string]
    $LabVirtualNetworkId = "",

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Virtual Network id (defaults to [VirtualNetworkName]Subnet).")]
    [ValidateNotNullOrEmpty()]
    [string]
    $LabSubnetName = "",

    [parameter(Mandatory=$true,HelpMessage="User Name.", ValueFromPipelineByPropertyName = $true, ParameterSetName ='SSHCustom')]
    [parameter(Mandatory=$true,HelpMessage="User Name.", ValueFromPipelineByPropertyName = $true, ParameterSetName ='SSHSIG')]
    [parameter(Mandatory=$true,HelpMessage="User Name.", ValueFromPipelineByPropertyName = $true, ParameterSetName ='SSHGallery')]
    [parameter(Mandatory=$false,HelpMessage="User Name.", ValueFromPipelineByPropertyName = $true, ParameterSetName ='PasswordCustom')]
    [parameter(Mandatory=$false,HelpMessage="User Name.", ValueFromPipelineByPropertyName = $true, ParameterSetName ='PasswordSIG')]
    [parameter(Mandatory=$true,HelpMessage="User Name.", ValueFromPipelineByPropertyName = $true, ParameterSetName ='PasswordGallery')]
    [ValidateNotNullOrEmpty()]
    [string]
    $UserName = $null,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true,HelpMessage="Password.", ParameterSetName ='PasswordCustom')]
    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true,HelpMessage="Password.", ParameterSetName ='PasswordSIG')]
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true,HelpMessage="Password.", ParameterSetName ='PasswordGallery')]
    [ValidateNotNullOrEmpty()]
    [string] # We should support key vault retrival at some point
    $Password = $null,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true,HelpMessage="SSH Key.", ParameterSetName ='SSHCustom')]
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true,HelpMessage="SSH Key.", ParameterSetName ='SSHSIG')]
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true,HelpMessage="SSH Key.", ParameterSetName ='SSHGallery')]
    [ValidateNotNullOrEmpty()]
    [string]
    $SshKey,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true,HelpMessage="Name of custom image to use or customImage object.", ParameterSetName ='SSHCustom')]
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true,HelpMessage="Name of custom image to use or customImage object.", ParameterSetName ='PasswordCustom')]
    [ValidateNotNullOrEmpty()]
    [Object]
    $CustomImage,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true,HelpMessage="Name of custom image to use or customImage object.", ParameterSetName ='SSHSIG')]
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true,HelpMessage="Name of custom image to use or customImage object.", ParameterSetName ='PasswordSIG')]
    [ValidateNotNullOrEmpty()]
    [Object]
    $SharedImageGalleryImage,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true,HelpMessage="Name of Sku.", ParameterSetName ='SSHGallery')]
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true,HelpMessage="Name of Sku.", ParameterSetName ='PasswordGallery')]
    [ValidateNotNullOrEmpty()]
    [string]
    $Sku,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true,HelpMessage="Publisher name.", ParameterSetName ='SSHGallery')]
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true,HelpMessage="Publisher name.", ParameterSetName ='PasswordGallery')]
    [ValidateNotNullOrEmpty()]
    [string]
    $Publisher, # Is this mandatory?

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true,HelpMessage="Version.", ParameterSetName ='SSHGallery')]
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true,HelpMessage="Version.", ParameterSetName ='PasswordGallery')]
    [ValidateNotNullOrEmpty()]
    [string]
    $Offer,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true,HelpMessage="Version.", ParameterSetName ='SSHGallery')]
    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true,HelpMessage="Version.", ParameterSetName ='PasswordGallery')]
    [ValidateNotNullOrEmpty()]
    [string]
    $Version = 'latest',

    [parameter(Mandatory=$false,HelpMessage="Run the command in a separate job.")]
    [switch] $AsJob = $False
  )

  begin {. BeginPreamble}
  process {
    try {

      if((-not $lab) -and (-not ($Name -and $ResourceGroupName))) {
        throw "You need to specify either a Lab parameter or Name and ResourceGroupName parameters."
      }

      if(($Name -and (-not $ResourceGroupName)) -or ($ResourceGroupName -and (-not $Name))) {
        throw "You need to speficy both a Name and ResourceName parameter. You can't specify just one of them."
      }

      # Name and ResourceGroupName take precedence over the Lab parameter.
      if($Name) {
        $theLab = [pscustomobject] @{ Name = $Name; ResourceGroupName = $ResourceGroupName}
      } else {
        $theLab = $Lab
      }
      Write-debug "Lab is $theLab"

      # As pipeline goes, we are creating the same vm in multiple labs. It is unclear if that's the most common scenario
      # compared to create multiple identical vms in same lab. We could also consider a more complex pipeline binding to properties of
      # pipeline object, but it gets a bit complicated as $Lab is not a primitive type
      foreach($l in $theLab) {
        # We assume parameterset has ferreted out the set of correct parameters so we don't need to validate here
        # Also, we could consider a table based implementation, but $PSBoundParameters doesn't return default values
        # and alternatives to get *all* parameters are tricky, so going for simple 'if' statements here.
        # Also, for json translation they need to be Objects, not PSObjects, and not hashtable, which kind of forses the ugly Add-Member syntax

        $ResourceGroupName = $l.ResourceGroupName
        $Name = $l.Name

        $t = ConvertFrom-Json $templateVmCreation

        $p = $t.resources.properties
        $p | Add-Member -Name 'size' -Value $Size -MemberType NoteProperty

        if($StorageType) {$p | Add-Member -Name 'storageType' -Value $StorageType -MemberType NoteProperty}

        if($Notes) {$p | Add-Member -Name 'notes' -Value $Notes -MemberType NoteProperty}

        if($Claimable) {$p | Add-Member -Name 'allowClaim' -Value $True -MemberType NoteProperty}

        # In the next two -force is needed because the property already exist in json with a different value
        if($LabVirtualNetworkId) { $p | Add-Member -Name 'labVirtualNetworkId' -Value $LabVirtualNetworkId -MemberType NoteProperty -Force}
        if($LabSubnetName) { $p | Add-Member -Name 'labSubnetName' -Value $LabSubnetName -MemberType NoteProperty -Force}
        if($UserName) { $p | Add-Member -Name 'userName' -Value $UserName -MemberType NoteProperty }
        if($Password) { $p | Add-Member -Name 'password' -Value $Password -MemberType NoteProperty }

        if($SshKey) {
          $p | Add-Member -Name 'isAuthenticationWithSshKey' -Value $true -MemberType NoteProperty
          $p | Add-Member -Name 'sshKey' -Value $SshKey -MemberType NoteProperty
        } else {
          $p | Add-Member -Name 'isAuthenticationWithSshKey' -Value $false -MemberType NoteProperty
        }

        if($IpConfig -eq 'Shared') {
          $p | Add-Member -Name 'disallowPublicIpAddress' -Value $True -MemberType NoteProperty
          if($OsType -eq 'Windows') { $port = 3389} else { $port = 22}
          $inboundNatRules = New-Object Object
          $inboundNatRules | Add-Member -Name 'transportProtocol' -Value 'tcp' -MemberType NoteProperty
          $inboundNatRules | Add-Member -Name 'backendPort' -Value $port -MemberType NoteProperty
          $sharedPublicIpAddressConfiguration = New-Object Object
          $sharedPublicIpAddressConfiguration | Add-Member -Name 'inboundNatRules' -Value @($inboundNatRules) -MemberType NoteProperty
          $networkInterface = New-Object Object
          $networkInterface | Add-Member -Name 'sharedPublicIpAddressConfiguration' -Value $sharedPublicIpAddressConfiguration -MemberType NoteProperty
          $p | Add-Member -Name 'networkInterface' -Value $networkInterface -MemberType NoteProperty
        }
        elseif($IpConfig -eq 'Public') {
          $p | Add-Member -Name 'disallowPublicIpAddress' -Value $False -MemberType NoteProperty
        } else {
          $p | Add-Member -Name 'disallowPublicIpAddress' -Value $True -MemberType NoteProperty
        }

        if($CustomImage) {
          if($CustomImage -is [string]) {
            $SubscriptionID = (Get-AzureRmContext).Subscription.Id
            $imageId = "/subscriptions/$SubscriptionID/ResourceGroups/$ResourceGroupName/providers/Microsoft.DevTestLab/labs/$Name/customImages/$CustomImage"
            Write-Verbose "Using custom image (string) $CustomImage with resource id $imageId"
          } elseif($CustomImage.ResourceId) {
            $imageId = $CustomImage.ResourceId
            Write-Verbose "Using custom image (object) $CustomImage with resource id $imageId"
          } else {
            throw "CustomImage $CustomImage is not a string and not an object with a ResourceId property."
          }
          $p | Add-Member -Name 'customImageId' -Value $imageId -MemberType NoteProperty
        }

        if ($SharedImageGalleryImage) {
            if ($SharedImageGalleryImage -is [string]) {
                $SigImageString = $SharedImageGalleryImage
            }
            elseif ($SharedImageGalleryImage.Id) {
                $SigImageString = $SharedImageGalleryImage.Id
            }
            else {
                throw "SharedImageGalleryImage is not a string and not an object with an Id property."
            }

            # The image name MUST have at least 1 slash (contains the SIG Gallery & Image definition name)
            if (-not $SigImageString.Contains("/")) {
                throw "SharedImageGalleryImage must have at least one '/' in the format SharedImageGallery/ImageDefinitionName"
            }

            # We could have a variety of formats, we basically need the image name
            # If the string ends in a version, take the string right before, otherwise the name is the last string
            $b = $null
            if ([System.Version]::TryParse(($SigImageString.Split("/") | Select -Last 1), [ref]$b)) {
                # Ends in a version number, let's check the string before
                if (($SigImageString.Split("/") | Select -Last 2 | Select -First 1) -eq "versions") {
                    # We have a full resource id, let's get the name & Shared Image Gallery name
                    $SigImageName = $SigImageString.Split("/") | Select -Last 3 | Select -First 1
                    $SigGalleryName = $SigImageString.Split("/") | Select -Last 5 | Select -First 1
                }
                else {
                    # we have the gallery & name & version, but not a full resource Id
                    $SigImageName = $SigImageString.Split("/") | Select -Last 2 | Select -First 1
                    $SigGalleryName = $SigImageString.Split("/") | Select -Last 3 | Select -First 1
                }
            }
            else {
                # Doesn't end in a version number - this is an image definition
                if (($SigImageString.Split("/") | Select -Last 2 | Select -First 1) -eq "images") {
                    # We have a full resource id, let's get the name & Shared Image Gallery name
                    $SigImageName = $SigImageString.Split("/") | Select -Last 1
                    $SigGalleryName = $SigImageString.Split("/") | Select -Last 3 | Select -First 1
                }
                else {
                    # we have the gallery & name, but not a full resource Id
                    $SigImageName = $SigImageString.Split("/") | Select -Last 1
                    $SigGalleryName = $SigImageString.Split("/") | Select -Last 2 | Select -First 1
                }

            }

            $SubscriptionID = (Get-AzureRmContext).Subscription.Id
            $imageId = "/subscriptions/$SubscriptionID/ResourceGroups/$ResourceGroupName/providers/Microsoft.DevTestLab/labs/$Name/sharedgalleries/$SigGalleryName/sharedimages/$SigImageName"
            Write-Verbose "Using Shared Image Gallery $SigGalleryName/$SigImageName with resource id $imageId"

            $p | Add-Member -Name 'sharedImageId' -Value $imageId -MemberType NoteProperty

        }

        if($Sku -or $Publisher -or $Offer) {
          $g = New-Object Object
          $g | Add-member -Name 'Sku' -Value $Sku -MemberType NoteProperty
          $g | Add-member -Name 'OsType' -Value $OsType -MemberType NoteProperty
          $g | Add-member -Name 'Publisher' -Value $Publisher -MemberType NoteProperty
          $g | Add-member -Name 'Version' -Value $Version -MemberType NoteProperty
          $g | Add-member -Name 'Offer' -Value $Offer -MemberType NoteProperty

          $p | Add-member -Name 'galleryImageReference' -Value $g -MemberType NoteProperty
        }

        $jsonToDeploy = ConvertTo-Json $t -Depth 6 # Depth defaults to 2, so it wouldn't print out the GalleryImageReference Property. Why oh why ...
        $deploymentName = "$Name-$VmName"
        Write-debug "JSON ABOUT TO BE DEPLOYED AS $deploymentName `n$jsonToDeploy"

        $jsonPath = StringToFile($jsonToDeploy)

        Write-Verbose "Starting deployment $deploymentName of $VmName in $Name"

        $sb = {
          param($deploymentName, $Name, $ResourceGroupName, $VmName, $jsonPath, $justAz)

          if($justAz) {
            Enable-AzureRmAlias -Scope Local -Verbose:$false
            Enable-AzContextAutosave -Scope Process | Out-Null
          }
          $deployment = New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $ResourceGroupName -TemplateFile $jsonPath -existingLabName $Name -newVmName $VmName
          Write-debug "Deployment succeded with deployment of `n$deployment"

          Get-AzureRmResource -Name "$Name/$VmName" -ResourceGroupName $ResourceGroupName -ExpandProperties
        }

        if($AsJob.IsPresent) {
          Start-Job      -ScriptBlock $sb -ArgumentList $deploymentName, $Name, $ResourceGroupName, $vmName, $jsonPath, $justAz
        } else {
          Invoke-Command -ScriptBlock $sb -ArgumentList $deploymentName, $Name, $ResourceGroupName, $vmName, $jsonPath, $justAz
        }
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

function Get-AzDtlVmRdpFileContents {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="Virtual Machine to get an RDP file from", ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    $Vm
  )

  begin {. BeginPreamble}
  process {
    try {
      foreach($v in $Vm) {
        $rdpFile = Invoke-RestMethod -Method Post `
                  -Uri "https://management.azure.com$($v.ResourceId)/getRdpFileContents?api-version=2018-09-15" `
                  -Headers $(GetHeaderWithAuthToken)
        # Put the contents in the pipeline
        $rdpFile.contents
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

## Not strictly DTL related, but often used in a DTL context if unused RGs are left around by broken DTL remove operations.
function Get-UnusedRgInSubscription {
  [CmdletBinding()]
  param()

  <#
  There are multiple RG that can be created by DTL:

  DTL lab: {labname}{13 random digits}
  VM/ENV: {vmname/envname}{6 random digits}

  Resource: {baseName}-{postFix}{count}
  Where postfix = IP/OSdisk/Vms/VMss/lb/nsg/nic/as
  Count= incrementing ordinal value

  This script uses the first two rules. It doesn't dwelve into resources.
  #>

  $rgs = Get-AzureRmResourceGroup
  $dtlNames = Get-AzureRmResource -ResourceType 'Microsoft.DevTestLab/labs' | Select-Object -ExpandProperty Name
  $vmNames = Get-AzureRmVM | Select-Object -ExpandProperty Name

  $toDelete = @()
  foreach ($r in $rgs) {
    if($r.ResourceGroupName -match '(.+)(\d{13})') {
      $dtlName = $matches[1]
      if($dtlNames -contains $dtlName) {
        Write-Verbose "$($r.ResourceGroupName) is for $dtlName"
      } else {
        Write-Verbose "$dtlName is not an existing lab"
        $toDelete += $r
      }
    } elseif ($r.ResourceGroupName -match '(.+)(\d{6})') {
      $vmName = $matches[1]
      if($vmNames -contains $vmName) {
        Write-Verbose "$($r.ResourceGroupName) is for $vmName"
      } else {
        Write-Verbose "$vmName is not an existing VM"
        $toDelete += $r
      }
    }
  }

  $toDelete | Select-Object -ExpandProperty ResourceGroupName
}

function Get-AzureRmDtlNetorkCard { [CmdletBinding()] param($vm)}
function Get-AzDtlVmDisks { [CmdletBinding()] param($vm)}
function Import-AzureRmDtlVm { [CmdletBinding()] param($Name, $ResourceGroupName, $ImportParams)}

#endregion

#region ENVIRONMENT ACTIONS
function New-AzDtlLabEnvironment{
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Name of Lab to create environment into.")]
    [ValidateNotNullOrEmpty()]
    $Name,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Name of Resource Group where lab lives.")]
    [ValidateNotNullOrEmpty()]
    $ResourceGroupName,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true, HelpMessage="Repository that contains base template name.")]
    [ValidateNotNullOrEmpty()]
    [string] $ArtifactRepositoryDisplayName,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true, HelpMessage="Environment base template name.")]
    [ValidateNotNullOrEmpty()]
    [string] $TemplateName,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true, HelpMessage="Environment instance name.")]
    [ValidateNotNullOrEmpty()]
    [string] $EnvironmentInstanceName,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName=$true, HelpMessage="User Id for the instance.")]
    [ValidateNotNullOrEmpty()]
    [string]$UserId,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName=$true, HelpMessage="Environment base template parameters.")]
    [array]
    $EnvironmentParameterSet = @()
  )

  begin {. BeginPreamble}
  process {
    try{

      # Get Lab using Name and ResourceGroupName

      if ((-not $Name) -or (-not $ResourceGroupName)) { throw "Missing Name or ResourceGroupName parameters."}
      $Lab = Get-AzDtlLab -Name $Name -ResourceGroupName $ResourceGroupName

      if (-not $Lab) {throw "Unable to find lab $Name with Resource Group $ResourceGroupName."}

      # Get User Id
      if (-not $UserId) {
        $UserId = $((Get-AzureRmADUser -UserPrincipalName (Get-AzureRmContext).Account).Id.Guid)
        if (-not $UserId) {throw "Unable to get User Id."}
      }

      # Get the DevTest lab internal repository identifier
      $repository = Get-AzureRmResource -ResourceGroupName $Lab.ResourceGroupName `
        -ResourceType 'Microsoft.DevTestLab/labs/artifactsources' `
        -ResourceName $Lab.Name `
        -ApiVersion 2016-05-15 `
        | Where-Object { $ArtifactRepositoryDisplayName -in ($_.Name, $_.Properties.displayName) } `
        | Select-Object -First 1

      if (-not $repository) { throw "Unable to find repository $ArtifactRepositoryDisplayName in lab $($Lab.Name)." }

      # Get the internal environment template name
      $template = Get-AzureRmResource -ResourceGroupName $Lab.ResourceGroupName `
        -ResourceType "Microsoft.DevTestLab/labs/artifactSources/armTemplates" `
        -ResourceName "$($Lab.Name)/$($repository.Name)" `
        -ApiVersion 2016-05-15 `
        | Where-Object { $TemplateName -in ($_.Name, $_.Properties.displayName) } `
        | Select-Object -First 1

      if (-not $template) { throw "Unable to find template $TemplateName in lab $($Lab.Name)." }

      $templateProperties = @{ "deploymentProperties" = @{ "armTemplateId" = "$($template.ResourceId)"; "parameters" = $EnvironmentParameterSet }; }

      # Create the environment
      $deployment = New-AzureRmResource -Location $Lab.Location `
        -ResourceGroupName $Lab.ResourceGroupName `
        -Properties $templateProperties `
        -ResourceType 'Microsoft.DevTestLab/labs/users/environments' `
        -ResourceName "$($Lab.Name)/$UserId/$EnvironmentInstanceName" `
        -ApiVersion '2016-05-15' -Force

      Write-debug "Deployment succeded with deployment of `n$deployment"

      return $Lab
    }
    catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {
  }
 }

function Get-AzDtlLabEnvironment{
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline=$true, HelpMessage="Lab object to get environments from.")]
    [ValidateNotNullOrEmpty()]
    $Lab
  )

  begin {. BeginPreamble}
  process {
    try{

     #Get LabId
     $labId = Get-AzDtlLab -Name $Lab.Name -ResourceGroupName $Lab.ResourceGroupName

     if (-not $labId) { throw "Unable to find lab $($Lab.Name) with resource group $($Lab.ResourceGroupName)." }

     #Get all environments
     $environs = Get-AzureRmResource -ResourceGroupName $Lab.ResourceGroupName `
       -ResourceType 'Microsoft.DevTestLab/labs/users/environments' `
       -ResourceName "$($Lab.Name)/@all" `
       -ApiVersion '2016-05-15'

     $labId | Add-Member -NotePropertyName 'environments' -NotePropertyValue $environs

     return $labId

    }
    catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {
  }
}

#endregion

#region LAB PROPERTIES MANIPULATION

function Add-AzDtlLabUser {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline=$true, HelpMessage="Lab to add users to.")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="User emails to add.")]
    [ValidateNotNullOrEmpty()]
    [string]
    $UserEmail,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Role to add user emails to (defaults to dtl user).")]
    [ValidateNotNullOrEmpty()]
    [string]
    $Role = 'DevTest Labs User'
  )

  begin {. BeginPreamble}
  process {
    try {
      foreach($l in $Lab) {
        $ResourceGroupName = $l.ResourceGroupName
        $DevTestLabName = $l.Name
        Write-Verbose "Adding $UserEmail as $Role in $DevTestLabName."
        # We discard the return type because we want to return a Lab to continue the pipeline and the type doesn't seem to contain much useful
        New-AzureRmRoleAssignment -SignInName $UserEmail -RoleDefinitionName $Role `
          -ResourceGroupName $ResourceGroupName -ResourceName $DevTestLabName -ResourceType 'Microsoft.DevTestLab/labs' | Out-Null
        Write-Verbose "Added $UserEmail as $Role in $DevTestLabName."
        return $Lab
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }
  end {}
}

function Add-AzDtlLabArtifactRepository {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline = $true, HelpMessage="Lab to add artifact repository to.")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Artifact repository display name.")]
    [ValidateNotNullOrEmpty()]
    [string] $ArtifactRepositoryDisplayName = "Team Repository",

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="Artifact repo URI.")]
    [ValidateNotNullOrEmpty()]
    [string] $ArtifactRepoUri,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Branch to use for the artifact repo.")]
    [ValidateNotNullOrEmpty()]
    [string] $ArtifactRepoBranch = "master",

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Folder for artifacts")]
    [ValidateNotNullOrEmpty()]
    [string] $ArtifactRepoFolder = "Artifacts/",

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Type of artifact repo")]
    [ValidateSet("VsoGit", "GitHub")]
    [string] $ArtifactRepoType = "GitHub",

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="PAT token for the artifact repo")]
    [ValidateNotNullOrEmpty()]
    [string] $ArtifactRepoSecurityToken,

    [parameter(Mandatory=$false,HelpMessage="Run the command in a separate job.")]
    [switch] $AsJob = $False
  )

  begin {. BeginPreamble}
  process {
    try {
      foreach($l in $Lab) {
        $params = @{
          labName = $l.Name
          artifactRepositoryDisplayName = $ArtifactRepositoryDisplayName
          artifactRepoUri               = $ArtifactRepoUri
          artifactRepoBranch            = $ArtifactRepoBranch
          artifactRepoFolder            = $ArtifactRepoFolder
          artifactRepoType              = $ArtifactRepoType
          artifactRepoSecurityToken     = $ArtifactRepoSecurityToken
        }
        Write-verbose "Set Artifact repo with $(PrintHashtable $params)"

@"
{
  "`$schema": "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "labName": {
      "type": "string"
    },
    "artifactRepositoryDisplayName": {
      "type": "string"
    },
    "artifactRepoUri": {
      "type": "string"
    },
    "artifactRepoBranch": {
      "type": "string"
    },
    "artifactRepoFolder": {
      "type": "string"
    },
    "artifactRepoType": {
      "type": "string",
      "allowedValues": [ "VsoGit", "GitHub" ]
    },
    "artifactRepoSecurityToken": {
      "type": "securestring"
    }
  },
  "variables": {
    "artifactRepositoryName": "[concat('Repo-', uniqueString(subscription().subscriptionId))]"
  },
  "resources": [
    {
      "apiVersion": "2018-10-15-preview",
      "type": "Microsoft.DevTestLab/labs/artifactSources",
      "name": "[concat(parameters('labName'), '/', variables('artifactRepositoryName'))]",
      "location": "[resourceGroup().location]",
      "properties": {
        "uri": "[parameters('artifactRepoUri')]",
        "folderPath": "[parameters('artifactRepoFolder')]",
        "branchRef": "[parameters('artifactRepoBranch')]",
        "displayName": "[parameters('artifactRepositoryDisplayName')]",
        "securityToken": "[parameters('artifactRepoSecurityToken')]",
        "sourceType": "[parameters('artifactRepoType')]",
        "status": "Enabled"
      }
    }
  ],
  "outputs": {
    "labId": {
      "type": "string",
      "value": "[resourceId('Microsoft.DevTestLab/labs', parameters('labName'))]"
    }
  }
}
"@ | DeployLab -Lab $l -AsJob $AsJob -Parameters $Params
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }

  end {}
}

function Set-AzDtlLabAnnouncement {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline = $true, HelpMessage="Lab to add announcement to.")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="Title of announcement.")]
    [ValidateNotNullOrEmpty()]
    [string] $Title,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="Markdown of announcement.")]
    [ValidateNotNullOrEmpty()]
    [string] $AnnouncementMarkdown,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Expiration of announcement (format '2100-01-01T17:00:00+00:00').")]
    [ValidateNotNullOrEmpty()]
    [string] $Expiration = "2100-01-01T17:00:00+00:00",

    [parameter(Mandatory=$false,HelpMessage="Run the command in a separate job.")]
    [switch] $AsJob = $False
  )

  begin {. BeginPreamble}
  process {
    try {
      foreach($l in $Lab) {
        $params = @{
          newLabName = $l.Name
          announcementTitle = $Title
          announcementMarkdown = $AnnouncementMarkdown
          announcementExpiration = $Expiration
          labTags = $l.Tags
        }
        Write-verbose "Set Lab Announcement with $(PrintHashtable $params)"

@"
      {
        "`$schema": "http://schema.management.azure.com/schemas/2014-04-01-preview/deploymentTemplate.json#",
        "contentVersion": "1.0.0.0",
        "parameters": {
            "newLabName": {
                "type": "string"
            },
            "announcementTitle": {
                "type": "string"
            },
            "announcementMarkdown": {
                "type": "string"
            },
            "announcementExpiration":{
                "type": "string"
            },
            "labTags": {
                "type": "object"
            }
        },
        "resources": [
            {
                "apiVersion": "2018-10-15-preview",
                "name": "[parameters('newLabName')]",
                "type": "Microsoft.DevTestLab/labs",
                "tags": "[parameters('labTags')]",
                "location": "[resourceGroup().location]",
                "properties": {
                    "labStorageType": "Premium",
                    "announcement":
                    {
                        "enabled": "Enabled",
                        "expired": "False",
                        "expirationDate": "[parameters('announcementExpiration')]",
                        "markdown": "[parameters('announcementMarkdown')]",
                        "title": "[parameters('announcementTitle')]"
                    }
                }
            }
        ],
        "outputs": {
          "labId": {
            "type": "string",
            "value": "[resourceId('Microsoft.DevTestLab/labs', parameters('newLabName'))]"
          }
        }
    }
"@ | DeployLab -Lab $l -AsJob $AsJob -Parameters $Params
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }

  end {}
}

function Set-AzDtlLabSupport {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline = $true, HelpMessage="Lab to add support message to.")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="Markdown of support message.")]
    [ValidateNotNullOrEmpty()]
    [string] $SupportMarkdown,

    [parameter(Mandatory=$false,HelpMessage="Run the command in a separate job")]
    [switch] $AsJob = $False
  )

  begin {. BeginPreamble}
  process {
    try {
      foreach($l in $Lab) {
        $params = @{
          newLabName = $l.Name
          supportMessageMarkdown = $SupportMarkdown
          labTags = $l.Tags
        }
        Write-verbose "Set Lab Support with $(PrintHashtable $params)"

@"
{
  "`$schema": "http://schema.management.azure.com/schemas/2014-04-01-preview/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
      "newLabName": {
          "type": "string"
      },
      "supportMessageMarkdown": {
          "type": "string"
      },
      "labTags": {
          "type": "object"
      }
  },
  "resources": [
      {
          "apiVersion": "2018-10-15-preview",
          "name": "[parameters('newLabName')]",
          "type": "Microsoft.DevTestLab/labs",
          "tags": "[parameters('labTags')]",
          "location": "[resourceGroup().location]",
          "properties": {
              "labStorageType": "Premium",
              "support":
              {
                  "enabled": "Enabled",
                  "markdown": "[parameters('supportMessageMarkdown')]"
              }
          }
      }
  ],
    "outputs": {
      "labId": {
        "type": "string",
        "value": "[resourceId('Microsoft.DevTestLab/labs', parameters('newLabName'))]"
      }
    }
  }
"@ | DeployLab -Lab $l -AsJob $AsJob -Parameters $Params
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }

  end {}
}

function Set-AzDtlLabRdpSettings {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline = $true, HelpMessage="Lab to add RDP settings to.")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="Experience level RDP connection.")]
    [ValidateRange(1,7)]
    [int] $ExperienceLevel,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="URL of Gateway for RDP.")]
    [ValidateNotNullOrEmpty()]
    [string] $GatewayUrl,

    [parameter(Mandatory=$false,HelpMessage="Run the command in a separate job.")]
    [switch] $AsJob = $False
  )

  begin {. BeginPreamble}
  process {
    try {
      foreach($l in $Lab) {
        $params = @{
          newLabName = $l.Name
          experienceLevel = $ExperienceLevel
          gatewayUrl = $GatewayUrl
          labTags = $l.Tags
        }
        Write-verbose "Set Rdp Settings with $(PrintHashtable $params)"
@"
{
  "`$schema": "http://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "newLabName": {
      "type": "string",
      "metadata": {
        "description": "The name of the new lab instance to be created."
      }
    },
    "experienceLevel": {
      "type": "int",
      "minValue": 1,
      "maxValue": 7
    },
    "gatewayUrl": {
      "type": "string"
    },
    "labTags": {
      "type": "object"
    }
  },
  "resources": [
    {
      "apiVersion": "2018-10-15-preview",
      "type": "Microsoft.DevTestLab/labs",
      "name": "[parameters('newLabName')]",
      "tags": "[parameters('labTags')]",
      "location": "[resourceGroup().location]",
      "properties":{
        "extendedProperties":{
          "RdpConnectionType": "[parameters('experienceLevel')]",
          "RdpGateway":"[parameters('gatewayUrl')]"
        }
      }
    }
  ],
  "outputs": {
    "labId": {
      "type": "string",
      "value": "[resourceId('Microsoft.DevTestLab/labs', parameters('newLabName'))]"
    }
  }
}
"@ | DeployLab -Lab $l -AsJob $AsJob -Parameters $Params
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }

  end {}
}

function Set-AzDtlLabShutdown {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline = $true, HelpMessage="Lab to operate on.")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="The time (relative to timeZoneId) at which the Lab VMs will be automatically shutdown (E.g. 17:30, 20:00, 09:00).")]
    [ValidateLength(4,5)]
    [string] $ShutdownTime,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="The Windows time zone id associated with labVmShutDownTime (E.g. UTC, Pacific Standard Time, Central Europe Standard Time).")]
    [ValidateLength(3,40)]
    [string] $TimeZoneId,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Set schedule status.")]
    [ValidateSet('Enabled', 'Disabled')]
    [string] $ScheduleStatus = 'Enabled',

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Set notification setting.")]
    [ValidateSet('Enabled', 'Disabled')]
    [string] $NotificationSettings = 'Disabled',

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Minutes.")]
    [ValidateRange(1, 60)] #TODO: validate this is right??
    [int] $TimeInIMinutes = 15,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="URL to send notification to.")]
    [string] $ShutdownNotificationUrl = "https://mywebook.com",

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Email to send notification to.")]
    [string] $EmailRecipient = "someone@somewhere.com",

    [parameter(Mandatory=$false,HelpMessage="Run the command in a separate job.")]
    [switch] $AsJob = $False
  )

  begin {. BeginPreamble}
  process {
    try {
      foreach($l in $Lab) {
        $params = @{
          newLabName = $l.Name
          labVmShutDownTime = $ShutdownTime
          timeZoneId = $TimeZoneId
          scheduleStatus = $ScheduleStatus
          notificationSettings = $NotificationSettings
          timeInMinutes = $TimeInIMinutes
          labVmShutDownURL = $ShutdownNotificationUrl
          emailRecipient = $EmailRecipient
        }
        Write-verbose "Set Shutdown with $(PrintHashtable $params)"
@"
{
  "`$schema": "http://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "newLabName": {
      "type": "string"
    },
    "labVmShutDownTime": {
      "type": "string",
      "minLength": 4,
      "maxLength": 5
    },
    "timeZoneId": {
      "type": "string",
      "minLength": 3
    },
    "scheduleStatus": {
      "type": "string"
    },
    "notificationSettings": {
      "type": "string"
    },
    "timeInMinutes": {
      "type": "int"
    },
    "labVmShutDownURL": {
        "type": "string"
    },
    "emailRecipient": {
        "type": "string"
    }
  },

  "resources": [
    {
      "apiVersion": "2018-10-15-preview",
      "type": "Microsoft.DevTestLab/labs/schedules",
      "name": "[concat(trim(parameters('newLabName')), '/LabVmsShutdown')]",
	  "properties": {
		"status": "[trim(parameters('scheduleStatus'))]",
		"taskType": "LabVmsShutdownTask",
		"timeZoneId": "[string(parameters('timeZoneId'))]",
		"dailyRecurrence": {
		  "time": "[string(parameters('labVmShutDownTime'))]"
		},
		"notificationSettings": {
			"status": "[trim(parameters('notificationSettings'))]",
			"timeInMinutes": "[parameters('timeInMinutes')]"
		}
	  }
    },
	{
      "apiVersion": "2018-10-15-preview",
      "type": "Microsoft.DevTestLab/labs/notificationChannels",
      "name": "[concat(trim(parameters('newLabName')), '/AutoShutdown')]",
	  "properties": {
		"events": [
			{
				"eventName": "Autoshutdown"
			}
		],
		"webHookUrl": "[trim(parameters('labVmShutDownURL'))]",
		"emailRecipient": "[trim(parameters('emailRecipient'))]"
	  },
    }
  ],
  "outputs": {
    "labId": {
      "type": "string",
      "value": "[resourceId('Microsoft.DevTestLab/labs', parameters('newLabName'))]"
    }
  }
}
"@ | DeployLab -Lab $l -AsJob $AsJob -Parameters $Params
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }

  end {}
}

function Set-AzDtlLabStartupSchedule {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline = $true, HelpMessage="Lab to operate on.")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="The time (relative to timeZoneId) at which the Lab VMs will be automatically shutdown (E.g. 17:30, 20:00, 09:00).")]
    [ValidateLength(4,5)]
    [string] $StartupTime,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="The Windows time zone id associated with labVmStartup (E.g. UTC, Pacific Standard Time, Central Europe Standard Time).")]
    [ValidateLength(3,40)]
    [string] $TimeZoneId,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Days when to start the VM.")]
    [Array] $WeekDays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'),

    [parameter(Mandatory=$false,HelpMessage="Run the command in a separate job.")]
    [switch] $AsJob = $False
  )

  begin {. BeginPreamble}
  process {
    try {
      foreach($l in $Lab) {
        $params = @{
          labName = $l.Name
          labVmStartupTime = $StartupTime
          timeZoneId = $TimeZoneId
          weekDays = $WeekDays
        }
        Write-verbose "Set Startup with $(PrintHashtable $params)"
@"
{
  "`$schema": "http://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "labName": {
      "type": "string"
    },
    "labVmStartupTime": {
      "type": "string",
      "minLength": 4,
      "maxLength": 5
    },
    "timeZoneId": {
      "type": "string",
      "minLength": 3
    },
    "weekDays": {
      "type": "array"
    }
  },

  "resources": [
    {
      "apiVersion": "2018-10-15-preview",
      "type": "microsoft.devtestlab/labs/schedules",
      "name": "[concat(parameters('labName'), '/', 'LabVmAutoStart')]",
      "location": "[resourceGroup().location]",
      "properties": {
        "status": "Enabled",
        "timeZoneId": "[string(parameters('timeZoneId'))]",
        "weeklyRecurrence": {
          "time": "[string(parameters('labVmStartupTime'))]",
          "weekdays": "[parameters('weekDays')]"
        },
        "taskType": "LabVmsStartupTask",
        "notificationSettings": {
          "status": "Disabled",
          "timeInMinutes": 15
        }
      }
    }
  ],
  "outputs": {
    "labId": {
      "type": "string",
      "value": "[resourceId('Microsoft.DevTestLab/labs', parameters('labName'))]"
    }
  }
}
"@ | DeployLab -Lab $l -AsJob $AsJob -Parameters $Params
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }

  end {}
}

function Get-AzDtlLabSchedule {
  Param(
    [parameter(Mandatory=$true, ValueFromPipeline = $true, HelpMessage="Lab to operate on.")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="Which schedule to get.")]
    [ValidateSet('AutoStart', 'AutoShutdown')]
    $ScheduleType
  )
  begin {. BeginPreamble}
  process {
    try {
      foreach($l in $Lab) {
        if($ScheduleType -eq 'AutoStart') {
          $ResourceName = "$($l.Name)/LabVmAutoStart"
        } else {
          $ResourceName = "$($l.Name)/LabVmsShutdown"
        }

        try {
          # Why oh why Silentlycontinue does not work here
          Get-AzureRmResource -Name $ResourceName -ResourceType "Microsoft.DevTestLab/labs/schedules" -ResourceGroupName $l.ResourceGroupName -ApiVersion 2016-05-15 -ea silentlycontinue
        } catch {
          return @() # Do we need compositionality here or should we just let the exception goes through?
        }
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }

  end {}
}

function BuildVmSizeThresholdString {
  param(
    [Array] $AllowedVmSizes,

    [parameter(Mandatory=$false)]
    [Array] $ExistingVmSizes
  )

    # First strip quotes start/end of the string in case they're present
    $AllowedVmSizes = $AllowedVmSizes | ForEach-Object {$_ -match '[^\"].+[^\"]'} | ForEach{$Matches[0]}

    # Add the arrays together and remove duplicates
    if ($ExistingVmSizes) {
    $vmSizes = ($AllowedVmSizes + $ExistingVmSizes) | Select -Unique
    } else {
    $vmSizes = $AllowedVmSizes
    }

    # Process the incoming allowed sizes, need to convert to the special string
    $thresholdString = ($vmSizes | ForEach-Object {
        $finalSize = $_

        # Add starting & ending string if missing
        if (-not $_.StartsWith('"')) {
            $finalSize = '"' + $finalSize
        }
        if (-not $_.EndsWith('"')) {
            $finalSize = $finalSize + '"'
        }

        # return the final string to the pipeline
        $finalSize
        }) -join ","

    return $thresholdString
}

function Set-AzDtlLabAllowedVmSizePolicy {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true, ValueFromPipeline = $true, HelpMessage="Lab to operate on.")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$true, ParameterSetName="AllowedVmSizes", HelpMessage="The allowed Virtual Machine Sizes to set in the lab.  For example:  'Standard_A4', 'Standard_DS3_v2'.")]
    [Array] $AllowedVmSizes,

    [parameter(Mandatory=$true, ParameterSetName="EnableAllSizes", HelpMessage="Turn off the policy and enable ALL VM sizes in the lab")]
    [switch] $EnableAllSizes = $false,

    [parameter(Mandatory=$false, ParameterSetName="AllowedVmSizes", HelpMessage="Overwrite the existing list instead of merging in new sizes")]
    [switch] $Overwrite = $False,

    [parameter(Mandatory=$false,HelpMessage="Run the command in a separate job.")]
    [switch] $AsJob = $False
  )

  begin {. BeginPreamble}
  process {
    try {

        foreach($l in $Lab) {

            if ($EnableAllSizes) {
                $status = "Disabled"
                $thresholdString = ""
            } else {
                if ($Overwrite) {
                    $thresholdString = BuildVmSizeThresholdString -AllowedVmSizes $AllowedVmSizes
                } else {
                    $thresholdString = BuildVmSizeThresholdString -AllowedVmSizes $AllowedVmSizes -ExistingVmSizes (Get-AzDtlLabAllowedVmSizePolicy -Lab $l).AllowedSizes
                }

                $status = "Enabled"
            }

            $params = @{
                labName = $l.Name
                threshold = $thresholdString
                status = $status
            }
            Write-verbose "Set AllowedVMSize with $(PrintHashtable $params)"
@"
{
  "`$schema": "http://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "labName": {
      "type": "string"
    },
    "threshold": {
      "type": "string",
    },
    "status": {
      "type": "string",
    }
  },

  "resources": [
    {
      "apiVersion": "2018-10-15-preview",
      "type": "microsoft.devtestlab/labs/policySets/policies",
      "name": "[concat(parameters('labName'), '/default/AllowedVmSizesInLab')]",
      "location": "[resourceGroup().location]",
      "properties": {
        "status": "[parameters('status')]",
        "factName": "LabVmSize",
        "threshold": "[concat('[', parameters('threshold'), ']')]",
        "evaluatorType": "AllowedValuesPolicy"
      }
    }
  ],
  "outputs": {
    "labId": {
      "type": "string",
      "value": "[resourceId('Microsoft.DevTestLab/labs', parameters('labName'))]"
    }
  }
}
"@ | DeployLab -Lab $l -AsJob $AsJob -Parameters $Params
        }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }


  end {}
}

function Get-AzDtlLabAllowedVmSizePolicy {
  Param(
    [parameter(Mandatory=$true, ValueFromPipeline = $true, HelpMessage="Lab to operate on.")]
    [ValidateNotNullOrEmpty()]
    $Lab
  )
  begin {. BeginPreamble}
  process {
    try {
      foreach($l in $Lab) {
        try {
          $policy = (Get-AzureRmResource -ResourceType 'Microsoft.DevTestLab/labs/policySets/policies' -ResourceName ($l.Name + "/default") -ResourceGroupName $l.ResourceGroupName -ApiVersion 2018-09-15) | Where-Object {$_.Name -eq 'AllowedVmSizesInLab'}
          if ($policy) {
            $threshold = $policy.Properties.threshold
            # Regular expression to remove [] at beginning and end, then split by commas, then remove the extra quotes
            # Returns a string array of sizes that are enabled in the lab
            if ($threshold -match "[^\[].+[^\]]") {
                $sizes = $Matches[0].Split(',',[System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object {$_ -match '[^\"].+[^\"]'} | ForEach{$Matches[0]}
            } else {
                $sizes = $null
            }

            [pscustomobject] @{
                Status = $policy.Properties.Status
                AllowedSizes = $sizes
            }
          } else {

            # return an object, status="disabled"
            [pscustomobject] @{
                Status = "Disabled"
                AllowedSizes = $null
            }
          }

        } catch {
          return @() # Do we need compositionality here or should we just let the exception goes through?
        }
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }

  end {}
}

function Get-AzureRmDtlNetwork { [CmdletBinding()] param($Name, $ResourceGroupName)}
function Get-AzureRmDtlLoadBalancers { [CmdletBinding()] param($Name, $ResourceGroupName)}
function Get-AzureRmDtlCosts { [CmdletBinding()] param($Name, $ResourceGroupName)}
function Get-AzDtlLabAnnouncement { [CmdletBinding()] param($Name, $ResourceGroupName)}
function Get-AzureRmDtlInternalSupport { [CmdletBinding()] param($Name, $ResourceGroupName)}
function Get-AzureRmDtlRepositories { [CmdletBinding()] param($Name, $ResourceGroupName)}
function Get-AzureRmDtlMarketplaceImages { [CmdletBinding()] param($Name, $ResourceGroupName)}
function Get-AzureRmDtlRdpSettings { [CmdletBinding()] param($Name, $ResourceGroupName)}

function Set-AzureRmDtlMarketplaceImages { [CmdletBinding()] param($Name, $ResourceGroupName, $ImagesParams)}
#endregion

#region CUSTOM IMAGE MANIPULATION
function New-AzDtlCustomImageFromVm {
  [CmdletBinding()]
  param(

    [parameter(Mandatory=$true, ValueFromPipeline = $true, HelpMessage="VM to get custom image from.")]
    [ValidateNotNullOrEmpty()]
    $Vm,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="State of Windows OS.")]
    [ValidateSet('NonSysprepped', 'SysprepRequested', 'SysprepApplied')]
    [string] $WindowsOsState = 'NonSysprepped',

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="Name of image.")]
    [ValidateNotNullOrEmpty()]
    [string] $ImageName,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="Description of image.")]
    [ValidateNotNullOrEmpty()]
    [string] $ImageDescription,

    [parameter(Mandatory=$false,HelpMessage="Run the command in a separate job.")]
    [switch] $AsJob = $False
  )

  begin {. BeginPreamble}
  process {
    try {
      foreach($v in $Vm) {
        $labName = $Vm.ResourceId.Split('/')[8]
        Write-Verbose "Creating it in lab $labName"
        $l = Get-AzDtlLab -Name $LabName -ResourceGroupName $vm.ResourceGroupName

        $params = @{
          existingLabName = $labName
          existingVMResourceId = $v.ResourceId
          windowsOsState = $WindowsOsState
          imageName = $ImageName
          imageDescription = $ImageDescription
        }
        Write-verbose "Set Startup with $(PrintHashtable $params)"
@"
{
  "`$schema": "http://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "existingLabName": {
      "type": "string",
      "metadata": {
        "description": "Name of an existing lab where the custom image will be created."
      }
    },
    "existingVMResourceId": {
      "type": "string",
      "metadata": {
        "description": "Resource ID of an existing VM from which the custom image will be created."
      }
    },
      "windowsOsState": {
      "type": "string",
      "allowedValues": [
        "NonSysprepped",
        "SysprepRequested",
        "SysprepApplied"
        ],
      "defaultValue": "NonSysprepped",
      "metadata": {
        "description": "State of Windows on the machine. It can be one of three values NonSysprepped, SysprepRequested, and SysprepApplied"
      }
    },
    "imageName": {
      "type": "string",
      "metadata": {
        "description": "Name of the custom image being created or updated."
      }
    },
    "imageDescription": {
      "type": "string",
      "defaultValue": "",
      "metadata": {
        "description": "Details about the custom image being created or updated."
      }
    }
  },
  "variables": {
    "resourceName": "[concat(parameters('existingLabName'), '/', parameters('imageName'))]",
    "resourceType": "Microsoft.DevTestLab/labs/customimages"
  },
  "resources": [
    {
      "apiVersion": "2018-10-15-preview",
      "name": "[variables('resourceName')]",
      "type": "Microsoft.DevTestLab/labs/customimages",
      "properties": {
        "description": "[parameters('imageDescription')]",
        "vm": {
          "sourceVmId": "[parameters('existingVMResourceId')]",
          "windowsOsInfo": {
            "windowsOsState": "[parameters('windowsOsState')]"
          }
        }
      }
    }
  ],
  "outputs": {
    "customImageId": {
      "type": "string",
      "value": "[resourceId(variables('resourceType'), parameters('existingLabName'), parameters('imageName'))]"
    }
  }
}
"@ | DeployLab -Lab $l -AsJob $AsJob -Parameters $Params | Out-Null

        $l | Get-AzDtlCustomImage | Where-Object {$_.Name -eq $ImageName}
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }

  end {}
}

function Import-AzDtlCustomImageFromUri {
  Param(
    [parameter(Mandatory=$true, ValueFromPipeline = $true, HelpMessage="Lab to operate on.")]
    [ValidateNotNullOrEmpty()]
    $Lab,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="Uri to get VHD from.")]
    [ValidateNotNullOrEmpty()]
    [string]
    $Uri,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="Operating system on image.")]
    [ValidateSet('Linux', 'Windows')]
    [string]
    $ImageOsType,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Sysprep status.")]
    [bool]
    $IsVhdSysPrepped = $false,

    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName = $true, HelpMessage="Name of image.")]
    [ValidateNotNullOrEmpty()]
    [string]
    $ImageName,

    [parameter(Mandatory=$false, ValueFromPipelineByPropertyName = $true, HelpMessage="Description of image.")]
    [ValidateNotNullOrEmpty()]
    [string]
    $ImageDescription = "",

    [parameter(Mandatory=$false,HelpMessage="Run the command in a separate job.")]
    [switch] $AsJob = $False
  )
  begin {. BeginPreamble}
  process {
    try {
      foreach($l in $Lab) {

        $sb = {
          param($l, $Uri, $ImageOsType, $IsVhdSysPrepped, $ImageName, $ImageDescription, $justAz)

          if($justAz) {
            Enable-AzureRmAlias -Scope Local -Verbose:$false
            Enable-AzContextAutosave -Scope Process | Out-Null
          }
          
          # Get storage account for the lab
          $labRgName= $l.ResourceGroupName
          $sourceLab = $l
          $DestStorageAccountResourceId = $sourceLab.Properties.artifactsStorageAccount
          $DestStorageAcctName = $DestStorageAccountResourceId.Substring($DestStorageAccountResourceId.LastIndexOf('/') + 1)
          $storageAcct = (Get-AzureRMStorageAccountKey  -StorageAccountName $DestStorageAcctName -ResourceGroupName $labRgName)
          $DestStorageAcctKey = $storageAcct.Value[0]
          $DestStorageContext = New-AzureStorageContext -StorageAccountName $DestStorageAcctName -StorageAccountKey $DestStorageAcctKey
          New-AzureStorageContainer -Context $DestStorageContext -Name 'uploads' -EA SilentlyContinue

          # Determine if the file is *already* in the lab's storage account in the right place
          # Only copy if it isn't already present
          $vhdFIlename = $Uri.Split('/') | Select -Last 1
          $destUri = $DestStorageContext.BlobEndPoint + "uploads/" + $vhdFIlename
          if ($destUri -ine $Uri) {

              # Copy vhd at uri to storage account
              # TODO: it probably uses one more thread than needed.
              $handle = Start-AzureStorageBlobCopy -srcUri $Uri -DestContainer 'uploads' -DestBlob $vhdFIlename -DestContext $DestStorageContext -Force
              Write-Verbose "Started copying $ImageName from $Uri ..."
              $copyStatus = $handle | Get-AzureStorageBlobCopyState

              while (($copyStatus | Where-Object {$_.Status -eq "Pending"}) -ne $null) {
                  $copyStatus | Where-Object {$_.Status -eq "Pending"} | ForEach-Object {
                      [int]$perComplete = ($_.BytesCopied/$_.TotalBytes)*100
                      Write-Verbose ("    Copying " + $($_.Source.Segments[$_.Source.Segments.Count - 1]) + " to " + $DestStorageAcctName + " - $perComplete% complete" )
                  }
                  Start-Sleep -Seconds 60
                  $copyStatus = $handle | Get-AzureStorageBlobCopyState
              }

              $copyStatus | Where-Object {$_.Status -ne "Success"} | ForEach-Object {
                throw "    Error copying image $($_.Source.Segments[$_.Source.Segments.Count - 1]), $($_.StatusDescription)."
              }

              $copyStatus | Where-Object {$_.Status -eq "Success"} | ForEach-Object {
                Write-Verbose "    Completed copying image $($_.Source.Segments[$_.Source.Segments.Count - 1]) to $DestStorageAcctName - 100% complete"
              }
          }

          # Create custom images
          $params = @{
            existingLabName = $l.Name
            existingVhdUri = $destUri
            imageOsType = $ImageOsType
            isVhdSysPrepped = $IsVhdSysPrepped
            imageName = $ImageName
            imageDescription = $ImageDescription
          }
          Write-verbose "New custom image with $(PrintHashtable $params)"

@"
{
    "`$schema": "http://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
      "existingLabName": {
        "type": "string"
      },
      "existingVhdUri": {
        "type": "string"
      },
      "imageOsType": {
        "type": "string",
        "defaultValue": "Windows",
        "allowedValues": [
          "Linux",
          "Windows"
        ]
      },
      "isVhdSysPrepped": {
        "type": "bool",
        "defaultValue": false
      },
      "imageName": {
        "type": "string"
      },
      "imageDescription": {
        "type": "string",
        "defaultValue": ""
      }
    },
    "variables": {
      "resourceName": "[concat(parameters('existingLabName'), '/', parameters('imageName'))]",
      "resourceType": "Microsoft.DevTestLab/labs/customimages"
    },
    "resources": [
      {
        "apiVersion": "2016-05-15",
        "name": "[variables('resourceName')]",
        "type": "Microsoft.DevTestLab/labs/customimages",
        "properties": {
          "author": "None",
          "vhd": {
            "imageName": "[parameters('existingVhdUri')]",
            "sysPrep": "[parameters('isVhdSysPrepped')]",
            "osType": "[parameters('imageOsType')]"
          },
          "description": "[parameters('imageDescription')]"
        }
      }
    ],
    "outputs": {
      "customImageId": {
        "type": "string",
        "value": "[resourceId(variables('resourceType'), parameters('existingLabName'), parameters('imageName'))]"
      }
    }
  }
"@ | DeployLab -Lab $l -AsJob $false -Parameters $Params | Out-Null

          # Now that we have created the custom image we can remove the vhd, but only if we did a copy
          if ($destUri -ine $Uri) {
              Remove-AzureStorageBlob -Context $DestStorageContext -Container 'uploads' -Blob $ImageName | Out-Null
          }

          $l | Get-AzDtlCustomImage | Where-Object {$_.Name -eq "$ImageName"}
        }

        if($AsJob.IsPresent) {
          Start-Job      -ScriptBlock $sb -ArgumentList $l, $Uri, $ImageOsType, $IsVhdSysPrepped, $ImageName, $ImageDescription, $justAz
        } else {
          Invoke-Command -ScriptBlock $sb -ArgumentList $l, $Uri, $ImageOsType, $IsVhdSysPrepped, $ImageName, $ImageDescription, $justAz
        }
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }

  end {}
}

function Get-AzDtlCustomImage {
  Param(
    [parameter(Mandatory=$true, ValueFromPipeline = $true, HelpMessage="Lab to operate on")]
    [ValidateNotNullOrEmpty()]
    $Lab
  )
  begin {. BeginPreamble}
  process {
    try {
      foreach($l in $Lab) {
        Get-AzureRmResource -ResourceType 'Microsoft.DevTestLab/labs/customImages' -ResourceName $l.Name -ResourceGroupName $l.ResourceGroupName  -ApiVersion '2016-05-15'
      }
    } catch {
      Write-Error -ErrorRecord $_ -EA $callerEA
    }
  }

  end {}
}
#endregion

#region EXPORTS
New-Alias -Name 'Dtl-NewLab'              -Value New-AzDtlLab
New-Alias -Name 'Dtl-RemoveLab'           -Value Remove-AzDtlLab
New-Alias -Name 'Dtl-GetLab'              -Value Get-AzDtlLab
New-Alias -Name 'Dtl-AddLabTags'          -value Add-AzDtlLabTags
New-Alias -Name 'Dtl-GetVm'               -Value Get-AzDtlVm
New-Alias -Name 'Dtl-StartVm'             -Value Start-AzDtlVm
New-Alias -Name 'Dtl-StopVm'              -Value Stop-AzDtlVm
New-Alias -Name 'Dtl-ClaimVm'             -Value Invoke-AzDtlVmClaim
New-Alias -Name 'Dtl-UnClaimVm'           -Value Invoke-AzDtlVmUnClaim
New-Alias -Name 'Dtl-RemoveVm'            -Value Remove-AzDtlVm
New-Alias -Name 'Dtl-NewVm'               -Value New-AzDtlVm
New-Alias -Name 'Dtl-GetVmRdpFile'        -Value Get-AzDtlVmRdpFileContents
New-Alias -Name 'Dtl-AddUser'             -Value Add-AzDtlLabUser
New-Alias -Name 'Dtl-SetLabAnnouncement'  -Value Set-AzDtlLabAnnouncement
New-Alias -Name 'Dtl-SetLabSupport'       -Value Set-AzDtlLabSupport
New-Alias -Name 'Dtl-SetLabRdp'           -Value Set-AzDtlLabRdpSettings
New-Alias -Name 'Dtl-AddLabRepo'          -Value Add-AzDtlLabArtifactRepository
New-Alias -Name 'Dtl-ApplyArtifact'       -Value Set-AzDtlVmArtifact
New-Alias -Name 'Dtl-GetLabSchedule'      -Value Get-AzDtlLabSchedule
New-Alias -Name 'Dtl-SetLabShutdown'      -Value Set-AzDtlLabShutdown
New-Alias -Name 'Dtl-SetLabStartup'       -Value Set-AzDtlLabStartupSchedule
New-Alias -Name 'Dtl-SetLabIpPolicy'      -Value Set-AzDtlLabIpPolicy
New-Alias -Name 'Dtl-SetLabShutPolicy'    -Value Set-AzDtlShutdownPolicy
New-Alias -Name 'Dtl-SetMandatoryArtifacts' -value Set-AzDtlMandatoryArtifacts
New-Alias -Name 'Dtl-GetLabAllowedVmSizePolicy' -Value Get-AzDtlLabAllowedVmSizePolicy
New-Alias -Name 'Dtl-SetLabAllowedVmSizePolicy' -Value Set-AzDtlLabAllowedVmSizePolicy
New-Alias -Name 'Dtl-GetSharedImageGallery' -Value Get-AzDtlLabSharedImageGallery
New-Alias -Name 'Dtl-SetSharedImageGallery' -Value Set-AzDtlLabSharedImageGallery
New-Alias -Name 'Dtl-RemoveSharedImageGallery' -Value Remove-AzDtlLabSharedImageGallery
New-Alias -Name 'Dtl-GetSharedImageGalleryImages' -Value Get-AzDtlLabSharedImageGalleryImages
New-Alias -Name 'Dtl-SetSharedImageGalleryImages' -Value Set-AzDtlLabSharedImageGalleryImages
New-Alias -Name 'Dtl-SetAutoStart'        -Value Set-AzDtlVmAutoStart
New-Alias -Name 'Dtl-SetVmShutdown'       -Value Set-AzDtlVmShutdownSchedule
New-Alias -Name 'Dtl-GetVmStatus'         -Value Get-AzDtlVmStatus
New-Alias -Name 'Dtl-GetVmArtifact'       -Value Get-AzDtlVmArtifact
New-Alias -Name 'Dtl-ImportCustomImage'   -Value Import-AzDtlCustomImageFromUri
New-Alias -Name 'Dtl-GetCustomImage'      -Value Get-AzDtlCustomImage
New-Alias -Name 'Dtl-NewCustomImage'      -Value New-AzDtlCustomImageFromVm

New-Alias -Name 'Claim-AzureRmDtlVm'      -Value Invoke-AzDtlVmClaim
New-Alias -Name 'UnClaim-AzureRmDtlVm'    -Value Invoke-AzDtlVmUnClaim

New-Alias -Name 'Dtl-NewEnvironment'      -Value New-AzDtlLabEnvironment
New-Alias -Name 'Dtl-GetEnvironment'      -Value Get-AzDtlLabEnvironment

New-Alias -Name 'Dtl-ConvertVirtualNetwork'     -Value Convert-AzDtlVirtualNetwork
New-Alias -Name 'Dtl-GetVirtualNetworks'        -Value Get-AzDtlLabVirtualNetworks
New-Alias -Name 'Dtl-GetVirtualNetworkSubnets'  -Value Get-AzDtlLabVirtualNetworkSubnets

New-Alias -Name 'Dtl-SetLabBrowserConnect'  -Value Set-AzDtlLabBrowserConnect
New-Alias -Name 'Dtl-NewBastion'            -Value New-AzDtlBastion
New-Alias -Name 'Dtl-GetBastion'            -Value Get-AzDtlBastion
New-Alias -Name 'Dtl-RemoveBastion'         -Value Remove-AzDtlBastion

Export-ModuleMember -Function New-AzDtlLab,
                              Remove-AzDtlLab,
                              Get-AzDtlLab,
                              Add-AzDtlLabTags,
                              Get-AzDtlVm,
                              Start-AzDtlVm,
                              Stop-AzDtlVm,
                              Invoke-AzDtlVmClaim,
                              Invoke-AzDtlVmUnClaim,
                              New-AzDtlVm,
                              Get-UnusedRgInSubscription,
                              Remove-AzDtlVm,
                              Add-AzDtlLabUser,
                              Set-AzDtlLabAnnouncement,
                              Set-AzDtlLabSupport,
                              Set-AzDtlLabRdpSettings,
                              Add-AzDtlLabArtifactRepository,
                              Set-AzDtlVmArtifact,
                              Get-AzDtlVmRdpFileContents,
                              Get-AzDtlLabSchedule,
                              Set-AzDtlLabShutdown,
                              Set-AzDtlLabStartupSchedule,
                              Set-AzDtlMandatoryArtifacts,
                              New-AzDtlLabEnvironment,
                              Get-AzDtlLabEnvironment,
                              Set-AzDtlShutdownPolicy,
                              Set-AzDtlLabBrowserConnect, 
                              Set-AzDtlVmAutoStart,
                              Set-AzDtlVmShutdownSchedule,
                              Set-AzDtlLabIpPolicy,
                              Get-AzDtlLabAllowedVmSizePolicy,
                              Set-AzDtlLabAllowedVmSizePolicy,
                              Get-AzDtlLabSharedImageGallery,
                              Set-AzDtlLabSharedImageGallery,
                              Remove-AzDtlLabSharedImageGallery,
                              Get-AzDtlLabSharedImageGalleryImages,
                              Set-AzDtlLabSharedImageGalleryImages,
                              Get-AzDtlVmStatus,
                              Get-AzDtlVmArtifact,
                              Import-AzDtlCustomImageFromUri,
                              Get-AzDtlCustomImage,
                              New-AzDtlCustomImageFromVm,
                              Convert-AzDtlVirtualNetwork,
                              Get-AzDtlLabVirtualNetworks,
                              Get-AzDtlLabVirtualNetworkSubnets,
                              Set-AzDtlLabBrowserConnect,
                              New-AzDtlBastion,
                              Get-AzDtlBastion,
                              Remove-AzDtlBastion

Export-ModuleMember -Alias *
#endregion
