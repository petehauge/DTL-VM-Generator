<#
.SYNOPSIS
This script will import VHDs an JSON files into a Shared Image Gallery

.EXAMPLE
.\Import-VHDsToSharedImageGallery.ps1 -StorageAccountName "" `
                                      -StorageAccountResourceGroup "" `
                                      -StorageContainerName "" `
                                      -SharedImageGalleryResourceGroupName "" `
                                      -SharedImageGalleryName "" `
                                      -SharedImageGalleryLocation

#>

#Requires -Version 3.0
#Requires -Module Az.Resources

param
(
    [ValidateNotNullOrEmpty()]
    [Parameter(Mandatory=$true, HelpMessage="The storage key for the storage account where custom images are stored")]
    [string] $StorageAccountName,

    [ValidateNotNullOrEmpty()]
    [Parameter(Mandatory=$true, HelpMessage="The resource group for the storage account")]
    [string] $StorageAccountResourceGroup,

    [ValidateNotNullOrEmpty()]
    [Parameter(Mandatory=$true, HelpMessage="The storage key for the storage account where custom images are stored")]
    [string] $StorageContainerName,

    [ValidateNotNullOrEmpty()]
    [Parameter(Mandatory=$true, HelpMessage="The resource group name for the Shared Image Gallery, only required if the SIG doesn't already exist")]
    [string] $SharedImageGalleryResourceGroupName,

    [ValidateNotNullOrEmpty()]
    [Parameter(Mandatory=$true, HelpMessage="The Name of the Shared Image Gallery where we will publish the VHDs & JSON information")]
    [string] $SharedImageGalleryName,

    [ValidateNotNullOrEmpty()]
    [Parameter(Mandatory=$false, HelpMessage="The location of the Shared Image Gallery, only required if the SIG doesn't already exist")]
    [string] $SharedImageGalleryLocation,

    [Parameter(Mandatory=$false, HelpMessage="Configuration File, see example in directory.  This is needed to define the replication count of images, +1 for each 5 labs.  If the parameter is missing, we assume 1.")]
    [ValidateNotNullOrEmpty()]
    [string] $ConfigFile = "config.csv"
)
$startTime = Get-Date

Write-Output "Start of script: $StartTime"

$ErrorActionPreference = 'Stop'

. "./Utils.ps1"
# Determine the image replication count
if ($ConfigFile) {
    $config = Import-ConfigFile -ConfigFile $ConfigFile      # Import all the lab settings from the config file
    # We need another image replica every 5 labs or so
    $replicationCount = $([System.Math]::Truncate(($config | Measure-Object).Count / 10) + 1 )
}
else {
    $replicationCount = 1
}

$importVhdToSharedImageGalleryScriptBlock = {
    param
    (
        [ValidateNotNullOrEmpty()]
        [Parameter(Mandatory=$true, HelpMessage="The Shared Image Gallery object")]
        [psobject] $SharedImageGallery,
    
        [ValidateNotNullOrEmpty()]
        [Parameter(Mandatory=$true, HelpMessage="All the image definitions in the Shared Image Gallery")]
        [psobject] $ImageDefinitions,
    
        [ValidateNotNullOrEmpty()]
        [Parameter(Mandatory=$true, HelpMessage="The details of the VHD to import into the Shared Image Gallery")]
        [psobject] $imageInfo,

        [ValidateNotNullOrEmpty()]
        [Parameter(Mandatory=$true, HelpMessage="The resource ID of the storage account where VHDs are stored")]
        [string] $StorageAccountResourceId,

        [ValidateNotNullOrEmpty()]
        [Parameter(Mandatory=$true, HelpMessage="The replication count, how many copies of the image we need")]
        [int] $replicationCount,

        [ValidateNotNullOrEmpty()]
        [Parameter(Mandatory=$true, HelpMessage="The tags describing the image version")]
        [psobject] $tagDetails
    )

    # See if we have an existing image
    $imageDef = $ImageDefinitions | Where-Object {$_.Name -eq $imageInfo.imageName}
    Write-Output "Begin import of image '$($imageInfo.imageName)'"
    if (-not $imageDef) {
        Write-Output "Creating Image Definition '$($imageInfo.imageName)'.."
        # Image definition doesn't exist, let's create one
        $imageDef = New-AzGalleryImageDefinition -GalleryName $SharedImageGallery.Name `
                                                 -ResourceGroupName $SharedImageGallery.ResourceGroupName `
                                                 -Location $SharedImageGallery.Location `
                                                 -Name $imageInfo.imageName `
                                                 -Description $imageInfo.description `
                                                 -Publisher $imageInfo.publisher `
                                                 -Offer $imageInfo.imageName `
                                                 -Sku $imageInfo.vhdFileName `
                                                 -OsState $imageInfo.osstate `
                                                 -OsType $imageInfo.osType `
                                                 -HyperVGeneration $imageInfo.hypervgeneration
    }

    # Remove any existing image versions
    Get-AzGalleryImageVersion -ResourceGroupName  $SharedImageGallery.ResourceGroupName `
                              -GalleryName $SharedImageGallery.Name `
                              -GalleryImageDefinitionName $imageDef.Name `
                              | Remove-AzGalleryImageVersion -Force | Out-Null

    $snapshotConfig = New-AzSnapshotConfig -AccountType "Standard_LRS" `
                                           -Location $SharedImageGallery.Location `
                                           -CreateOption Import `
                                           -OsType $imageInfo.osType `
                                           -HyperVGeneration $imageInfo.hypervgeneration `
                                           -SourceUri $imageinfo.sourceVhdUri `
                                           -StorageAccountId $StorageAccountResourceId
                                            

    Write-Output "   Importing VHD '$($imageInfo.vhdFileName)' as a snapshot..."
    $snapshot = New-AzSnapshot -Snapshot $snapshotConfig -ResourceGroupName $SharedImageGallery.ResourceGroupName -SnapshotName $imageInfo.imageName

    # We need to ensure the snapshot exists in Azure...  Sometimes we move on too quickly and get an error
    $snapshot = Get-AzSnapshot -ResourceGroupName $SharedImageGallery.ResourceGroupName -SnapshotName $imageInfo.imageName -ErrorAction SilentlyContinue
    $count = 10
    while (-not $snapshot -and $count -gt 0) {
        Write-Output "   Snapshot not found yet, retrying... $count remaining"
        $snapshot = Get-AzSnapshot -ResourceGroupName $SharedImageGallery.ResourceGroupName -SnapshotName $imageInfo.imageName -ErrorAction SilentlyContinue
        $count -= 1
    }

    Write-Output "   Creating a new image version for '$($imageInfo.imageName)'"

    # Let's create a new image version based on the existing image definition & upload the VHD
    # NOTE: we have no powershell support for this, so we have to do it by deploying a template
    $templateImageVersion = @"
{
    "`$schema": "http://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "resources": [
        {
            "apiVersion": "2019-07-01",
            "type": "Microsoft.Compute/galleries/images/versions",
            "name": "$($SharedImageGallery.Name)/$($imageDef.Name)/1.0.0",
            "location": "$($SharedImageGallery.Location)",
            "properties": {
                "publishingProfile": {
                    "replicaCount": "$($replicationCount)",
                    "targetRegions": [
                        {
                            "name": "$($SharedImageGallery.Location)",
                            "regionalReplicaCount": "$replicationCount",
                            "storageAccountType": "Standard_LRS"
                        }
                    ],
                    "excludeFromLatest": "false"
                },
                "storageProfile": {
                    "osDiskImage": {
                        "hostCaching": "None",
                        "source": {
                            "id": "$($snapshot.Id)"
                        }
                    }
                }
            },
            "tags": {
                $tagDetails
            }
        }
    ],
    "outputs": {}
}
"@

    $tmp = New-TemporaryFile
    Set-Content -Path $tmp.FullName -Value $templateImageVersion

    New-AzResourceGroupDeployment -Name "$($imageDef.Name)-$(Get-Random)" `
                                  -ResourceGroupName $SharedImageGallery.ResourceGroupName `
                                  -TemplateFile $tmp.FullName
   
    # Delete the managed image (we don't need it anymore), just a step to get into shared image gallery
    Write-Output "   Cleaning up managed image from '$($imageInfo.vhdFileName)'"
    Revoke-AzSnapshotAccess -ResourceGroupName $snapshot.ResourceGroupName -SnapshotName $snapshot.Name | Out-Null
    Remove-AzResource -ResourceId $snapshot.Id -Force | Out-Null
    Write-Output "Complete import of image '$($imageInfo.imageName)'"

}

# Check if the shared image gallery exists, if not we create it
$SharedImageGallery = Get-AzGallery | Where-Object {$_.Name -eq $SharedImageGalleryName -and $_.ResourceGroupName -eq $SharedImageGalleryResourceGroupName}

if (-not $SharedImageGallery) {
    # if the SIG doesn't exist, need to create it
    if (-not $SharedImageGalleryLocation) {
        Write-Error "Must provide SharedImageGalleryLocation parameter when the Shared Image Gallery provided does not exist.."
    }
    else {
        Write-Host "------------------------------------------------" -ForegroundColor Green
        Write-Host "Shared Image Gallery doesn't exist, creating it..." -ForegroundColor Green
        # Check if the resource group exists
        $SIGrg = Get-AzResourceGroup | Where-Object {$_.ResourceGroupName -eq $SharedImageGalleryResourceGroupName }
        if (-not $SIGrg) {
            $SIGrg = New-AzResourceGroup -Name $SharedImageGalleryResourceGroupName -Location $SharedImageGalleryLocation
        }

        $SharedImageGallery = New-AzGallery -GalleryName $SharedImageGalleryName -ResourceGroupName $SharedImageGalleryResourceGroupName -Location $SharedImageGalleryLocation
    }
} else {
    Write-Host "------------------------------------------------" -ForegroundColor Green
    Write-Output "Shared Image Gallery already exists, reusing it..."
}

# List of image definitions in the shared image gallery
$ImageDefinitions = Get-AzGalleryImageDefinition -GalleryName $SharedImageGallery.Name -ResourceGroupName $SharedImageGallery.ResourceGroupName
if (-not $ImageDefinitions) {
    # If the image definitions variable is null, we need to make it an empty list
    $ImageDefinitions = @()
}

# Get the Storage account (confirm it exists)
$StorageAcct = Get-AzstorageAccount -Name $StorageAccountName -ResourceGroupName $StorageAccountResourceGroup
if (-not $StorageAcct) {
    Write-Error "Unable to find storage account"
}

$StorageAccountResourceId = $StorageAcct.Id
$StorageAccountKey = (Get-AzstorageAccountKey -Name $StorageAccountName -ResourceGroupName $StorageAccountResourceGroup)[0].Value

# Get the list of JSON files in the storage account
$VmSettings = & "./Import-VmSetting" -StorageAccountName $StorageAccountName -StorageContainerName $StorageContainerName -StorageAccountKey $StorageAccountKey

# Let's scan through and make sure that all the VHD Filenames end in ".vhd", if not - write an error
$VmSettings | ForEach-Object {
    If (-not($_.vhdFileName -like "*.vhd")) {
        Write-Host "vhdFilename must end in .vhd in JSON configuration in storage account" -ForegroundColor Red
        Write-Error "vhdFilename must end in .vhd in JSON configuration in storage account"
    }
}

$jobs = @()

# For each JSON file, we create a image (if there isn't one already), or add a new image version
foreach ($imageInfo in $VmSettings) {
    Write-Output "Starting job to import $($imageInfo.imageName) image"
    $tagDetails = Split-Tags $imageInfo.psobject.properties
    $jobs += Start-RSJob -ScriptBlock $importVhdToSharedImageGalleryScriptBlock -ArgumentList $SharedImageGallery, $ImageDefinitions, $imageInfo, $StorageAccountResourceId, $replicationCount, $tagDetails -Throttle 25
    Start-Sleep -Seconds 15
}

# Wait for all the jobs to complete - but send some status to the UI
$runningJobs = ($jobs | Where-Object {$_.State -eq "Running"} | Measure-Object).Count
while ($runningJobs -gt 0){
    Write-Output "Waiting for remaining $($runningJobs) jobs to complete.."
    Start-Sleep -Seconds 60

    # We can write the output of any completed jobs
    foreach ($job in Get-RsJob -State Completed) {
        Write-Output "----------------------------------------------"
        $job.Output | Write-Output

        if ($job.HasErrors) {
            $job.Error | Write-Output
        }
        
        Remove-RSJob -Job $job
    }

    $runningJobs = ($jobs | Where-Object {$_.State -eq "Running"} | Measure-Object).Count
}

# Write the output of any remaining jobs
foreach ($job in Get-RsJob){
    Write-Output "----------------------------------------------"
    $job.Output | Write-Output
    Remove-RSJob -Job $job
}

Write-Output "----------------------------------------------"

Write-Output "End of script: $(Get-Date)"
Write-Output "Total script duration $(((Get-Date) - $StartTime).TotalSeconds) seconds"
