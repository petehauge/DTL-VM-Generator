
# This is included at the top of each script
# You would be tempted to include generic useful actions here
# i.e. setting ErrorPreference or checking that you are in the right folder
# but those won't be executed if you are executing the script from the wrong folder
# Instead setting $ActionPreference = "Stop" at the start of each script
# and the script won't start if it executed from wrong folder as it can't import this file.

Set-StrictMode -Version Latest

# Import a patched up version of this module because the standard release
# doesn't propagate Write-host messages to console
# see https://github.com/proxb/PoshRSJob/pull/158/commits/b64ad9f5fbe6fa85f860311f81ec0d6392d5fc01
if (Get-Module | Where-Object {$_.Name -eq "PoshRSJob"}) {
} else {
  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
  Import-Module "$PSScriptRoot\PoshRSJob\PoshRSJob.psm1"
}

# DTL Module dependency
$AzDtlModuleName = "Az.DevTestLabs2"
$AzDtlModuleSource = "https://raw.githubusercontent.com/Azure/azure-devtestlab/master/samples/DevTestLabs/Modules/Library/Az.DevTestLabs2.psm1"

# To be passed as 'ModulesToImport' param when starting a RSJob
$global:AzDtlModulePath = Join-Path -Path (Resolve-Path ./) -ChildPath "$AzDtlModuleName.psm1"

# PSipcalc script dependency
$PSipcalcSource = "https://raw.githubusercontent.com/EliteLoser/PSipcalc/master/PSipcalc.ps1"
$PSipcalcName = "PSipcalc"
$PSipcalcScriptPath = Join-Path -Path (Resolve-Path ./) -ChildPath "$PSipcalcName.ps1"
$PSipcalcAliasName = "Invoke-PSipcalc"

function Import-RemoteModule {
  param(
    [ValidateNotNullOrEmpty()]
    [string] $Source,
    [ValidateNotNullOrEmpty()]
    [string] $ModuleName
  )

  $modulePath = Join-Path -Path (Resolve-Path ./) -ChildPath $ModuleName

  # WORKAROUND: Use a checked-in version of the library temporarily
  if (Test-Path -Path $modulePath) {
    # if the file exists, delete it - just in case there's a newer version, we always download the latest
    # Remove-Item -Path $modulePath
  }

  # $WebClient = New-Object System.Net.WebClient
  # $WebClient.DownloadFile($Source, $modulePath)

  Import-Module $modulePath -Force
}

function Import-RemoteScript {
  param(
      [parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "Web source of the psm1 file")]
      [ValidateNotNullOrEmpty()]
      [string] $Source,

      [parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "Web source of the psm1 file")]
      [ValidateNotNullOrEmpty()]
      [string] $ScriptName,
      
      [parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "Name of the module")]
      [ValidateNotNullOrEmpty()]
      [string] $AliasName
  )

  $scriptPath = Join-Path -Path (Resolve-Path ./) -ChildPath $ScriptName

  if (Test-Path -Path $scriptPath) {
      Remove-Item -Path $scriptPath | Out-Null
  }

  $WebClient = New-Object System.Net.WebClient
  $WebClient.DownloadFile($Source, $scriptPath)

  New-Alias -Name $AliasName -Scope Script -Value $scriptPath -Force
}
function Import-AzDtlModule {
   Import-RemoteModule -Source $AzDtlModuleSource -ModuleName "$AzDtlModuleName.psm1"
}
function Remove-AzDtlModule {
   Remove-Module -Name $AzDtlModuleName -ErrorAction SilentlyContinue
}
function Import-PsipcalcScript {
  Import-RemoteScript -Source $PSipcalcSource -ScriptName "$PSipcalcName.ps1" -AliasName $PSipcalcAliasName 
}
function Remove-PsipcalcScript {
  Remove-Item -Path $PSipcalcScriptPath
}

function Remove-AzDtlModule {
  Remove-Module -Name "Az.DevTesTLabs2" -ErrorAction SilentlyContinue
}

function Set-LabAccessControl {
  param(
    $DevTestLabName,
    $ResourceGroupName,
    $customRole,
    [string[]] $ownAr,
    [string[]] $userAr
  )

  foreach ($owneremail in $ownAr) {
    # First see if the role assignment already exists, if so, just log it
    $ra = Get-AzRoleAssignment -SignInName $owneremail -RoleDefinitionName 'Owner' -ResourceGroupName $ResourceGroupName -ResourceName $DevTestLabName -ResourceType 'Microsoft.DevTestLab/labs' -ErrorAction SilentlyContinue
    if ($ra) {
        Write-Output "   Role assignment for owner $owneremail already exists in lab $DevTestLabName, skipping... "
    }
    else {
        $ra = New-AzRoleAssignment -SignInName $owneremail -RoleDefinitionName 'Owner' -ResourceGroupName $ResourceGroupName -ResourceName $DevTestLabName -ResourceType 'Microsoft.DevTestLab/labs' -ErrorAction SilentlyContinue

        # if we couldn't apply the role assignment, it's likely because we couldn't find the user
        # instead let's search aad for them, this only works if we have the AzureAd module installed
        if (-not $ra) {
            $user = Get-AzureADUser -Filter "Mail eq '$owneremail'" -ErrorAction SilentlyContinue
            if ($user) {
                $ra = Get-AzRoleAssignment -ObjectId $user.ObjectId -RoleDefinitionName 'Owner' -ResourceGroupName $ResourceGroupName -ResourceName $DevTestLabName -ResourceType 'Microsoft.DevTestLab/labs' -ErrorAction SilentlyContinue
                if ($ra) {
                    Write-Output "   Role assignment for owner $owneremail already exists in lab $DevTestLabName, skipping... "
                }
                else {
                    $ra = New-AzRoleAssignment -ObjectId $user.ObjectId -RoleDefinitionName 'Owner' -ResourceGroupName $ResourceGroupName -ResourceName $DevTestLabName -ResourceType 'Microsoft.DevTestLab/labs' -ErrorAction SilentlyContinue
                }
            }
        }

        if ($ra) {
            Write-Output "   $owneremail added as Owner in Lab '$DevTestLabName'"
        }
        else {
            Write-Output "   Unable to add $owneremail as Owner in Lab '$DevTestLabName', cannot find the user in AAD OR the Custom Role doesn't exist." -ForegroundColor Yellow
        }
    }
  }

  foreach ($useremail in $userAr) {
    # First see if the role assignment already exists, if so just log it
    $ra = Get-AzRoleAssignment -SignInName $useremail -RoleDefinitionName $customRole -ResourceGroupName $ResourceGroupName -ResourceName $DevTestLabName -ResourceType 'Microsoft.DevTestLab/labs' -ErrorAction SilentlyContinue

    if ($ra) {
        Write-Output "   Role assignment for user $useremail already exists in lab $DevTestLabName, skipping... "
    }
    else {
        $ra = New-AzRoleAssignment -SignInName $useremail -RoleDefinitionName $customRole -ResourceGroupName $ResourceGroupName -ResourceName $DevTestLabName -ResourceType 'Microsoft.DevTestLab/labs' -ErrorAction SilentlyContinue

        # if we couldn't apply the role assignment, it's likely because we couldn't find the user
        # instead let's search aad for them, this only works if we have the AzureAd module installed
        if (-not $ra) {
            $user = Get-AzureADUser -Filter "Mail eq '$useremail'" -ErrorAction SilentlyContinue
            if ($user) {
                $ra = Get-AzRoleAssignment -ObjectId $user.ObjectId -RoleDefinitionName $customRole -ResourceGroupName $ResourceGroupName -ResourceName $DevTestLabName -ResourceType 'Microsoft.DevTestLab/labs' -ErrorAction SilentlyContinue
                if ($ra) {
                    Write-Output "   Role assignment for user $useremail already exists in lab $DevTestLabName, skipping... "
                }
                else {
                    $ra = New-AzRoleAssignment -ObjectId $user.ObjectId -RoleDefinitionName $customRole -ResourceGroupName $ResourceGroupName -ResourceName $DevTestLabName -ResourceType 'Microsoft.DevTestLab/labs' -ErrorAction SilentlyContinue
                }
            }
        }

        if ($ra) {
            Write-Output "   $useremail added as $customRole in Lab '$DevTestLabName'"
        }
        else {
            Write-Output "   Unable to add $useremail as $customRole in Lab '$DevTestLabName', cannot find the user in AAD OR the Custom Role doesn't exist." -ForegroundColor Yellow
        }
    }
  }
}

filter Convert-IPToDecimal {
  $IP = $_.Trim()
  $IPv4Regex = "^((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])(\.(?!$)|$)){4}$"
  if ($IP -match $IPv4Regex) {
      try {
          $str = ($IP.Split('.') | ForEach-Object { [System.Convert]::ToString([byte] $_, 2).PadLeft(8, '0') }) -join ''
          return [Convert]::ToInt64($str, 2)
      }
      catch {
          Write-Warning -Message "Error converting '$IP' to a decimal: $_"
          return $null
      }
  }
  else {
      Write-Warning -Message "Invalid IP detected: '$IP'."
      return $null
  }
}

filter Convert-DecimalToIP {
  "$($_ -shr 24).$(($_ -shr 16) -band 255).$(($_ -shr 8) -band 255).$($_ -band 255)"
}

function Convert-IPRangeToCIDRNotation {
  [CmdletBinding()]
  param(    
    [parameter(Mandatory=$true,HelpMessage="Start IPv4 in the address range")]
    [ValidateNotNullOrEmpty()]
    [string] $Start,

    [parameter(Mandatory=$true,HelpMessage="End IPv4 in the address range")]
    [ValidateNotNullOrEmpty()]
    [string] $End
  )

  # Implementation based on https://stackoverflow.com/questions/13508231/how-can-i-convert-ip-range-to-cidr-in-c

  $startDecimal = $Start | Convert-IPToDecimal
  $endDecimal = $End | Convert-IPToDecimal

  # Determine all bits that are different between the two IPs
  $diffs = $startDecimal -bxor $endDecimal
  $bits = 32
  $mask = 0

  while ($diffs -ne 0) {
    #We keep shifting diffs right until it's zero (i.e. we've shifted all the non-zero bits off)
    $diffs = $diffs -shr 1;

    # Every time we shift, that's one fewer consecutive zero bits in the prefix
    $bits--;

    # Accumulate a mask which will have zeros in the consecutive zeros of the prefix and ones elsewhere
    $mask = ($mask -shl 1) -bor 1;
  }

  # Construct the root of the range by inverting the mask and ANDing it with the start address
  $root = $startDecimal -band (-bnot $mask);

  return "$($root -shr 24).$(($root -shr 16) -band 255).$(($root -shr 8) -band 255).$($root -band 255)/$bits"
}


# Get the first available unallocated address space which is large enough to host a new subnet of at least /$Length
function Get-VirtualNetworkUnallocatedSpace {
  [CmdletBinding()]
  param(
    [parameter(Mandatory=$true,HelpMessage="Virtual Network to get the unassigned space from")]
    [ValidateNotNullOrEmpty()]
    $VirtualNetwork,

    [parameter(Mandatory=$true,HelpMessage="Length of the required address space")]
    [ValidateNotNullOrEmpty()]
    [int] $Length
  )

  try {

    # Using Psipcal
    Import-PsipcalcScript
    
    # Solution:
    # Build a hashtable of starting and ending address ranges, ordered by start of address range
    # On a second pass calculate the delta between i_end and i+1_start. If it is large enough, that is the range to return
    
    # [[10.0.0.0, 10.0.0.0], [10.0.4.0, 10.0.6.0], [10.0.7.0, 10.0.8.0], [10.0.8.0, 10.0.9.0], [10.1.0.0, 10.1.0.0]]
    # TO ->
    # [[10.0.0.0, 10.0.0.4], [10.0.6.0, 10.0.7.0], [10.0.9.0, 10.1.0.0]]

    # Edge cases.
    # Start entry: [start_range, start_range] = [10.0.0.0, 10.0.0.0]
    # End entry: [end_range, end_range] = [10.1.0.0, 10.1.0.0]
    
    # n log n runtime. Okay if it requires getting the first bottom slot available...
    # n space. We can also break earlier without building the unallocated spaces table.
    #          Leaving it here for other possible implementations.

    # Ordered Hashtable for all the allocated subnet ranges
    $allocatedSubnetRanges = @{}

    # A VNet can have multiple address spaces assigned, even not contiguous
    # E.g. 2 ranges: 10.0.0.0/24 | 10.0.8.0/24
    $addressRanges = $VirtualNetwork.AddressSpace.AddressPrefixes | Sort-Object -Property AddressPrefix
    $addressRanges | ForEach-Object {

      $vnetAddressRangeInfo = Invoke-PSipcalc -NetworkAddress $_
      $vnetAddressRangeLength = $vnetAddressRangeInfo.NetworkLength
      if ($vnetAddressRangeLength -gt $Length) {
        throw "You must use a Vnet of at least /$($Length+1) or larger"
      }
  
      $vnetAddressRangeStart = $vnetAddressRangeInfo.NetworkAddress
      $nextVnetAddressRangeStart = (($vnetAddressRangeInfo.Broadcast | Convert-IPToDecimal) + 1) | Convert-DecimalToIp 
  
      $allocatedSubnetRanges.Add($vnetAddressRangeStart, $vnetAddressRangeStart)
      $allocatedSubnetRanges.Add($nextVnetAddressRangeStart, $nextVnetAddressRangeStart)
  
      $vnetSubnets = $VirtualNetwork.Subnets  | `
                      Sort-Object -Property AddressPrefix
      $vnetSubnets | Foreach-Object {
  
        $vnetSubnet = $_
        $subnetAddressRangeInfo = Invoke-PSipcalc -NetworkAddress $vnetSubnet.AddressPrefix
        $subnetAddressRangeLength = $subnetAddressRangeInfo.NetworkLength
        
        if ($subnetAddressRangeLength -gt $Length) {
          # This subnet is not large enough to host a new subnet
          continue
        }
  
        $subnetAddressRangeStart = $subnetAddressRangeInfo.NetworkAddress
        $nextsubnetAddressRangeStart = (($subnetAddressRangeInfo.Broadcast | Convert-IPToDecimal) + 1) | Convert-DecimalToIp
  
        if ($allocatedSubnetRanges[$subnetAddressRangeStart]) {
          # Replace existing with the new range
          $allocatedSubnetRanges[$subnetAddressRangeStart] = $nextsubnetAddressRangeStart
        }
        else {
          $allocatedSubnetRanges.Add($subnetAddressRangeStart, $nextsubnetAddressRangeStart)
        }
      }
    }

    # Ordered Array of unallocated ranges (CIDR notation) calculated as a complement to the above table
    $unallocatedSubnetRanges = [System.Collections.ArrayList]@()

    $allocatedSubnetStarts = [array]($allocatedSubnetRanges.Keys | Sort-Object)
    $allocatedSubnetStarts | ForEach-Object {

      $index = $allocatedSubnetStarts.IndexOf($_)
      $nextsubnetAddressRangeStart = $allocatedSubnetRanges[$_]
      if ($index+1 -lt $allocatedSubnetRanges.Count) {

        $nextNextsubnetAddressRangeStart = $allocatedSubnetStarts[$index+1]
        if ($nextsubnetAddressRangeStart -ne $nextNextsubnetAddressRangeStart) {
          
          # Calculate the end IP of the allocated range
          $nextsubnetAddressRangeEnd = (($nextNextsubnetAddressRangeStart | Convert-IPToDecimal) - 1) | Convert-DecimalToIp 
          
          $unallocatedAddressRange = Convert-IPRangeToCIDRNotation -Start $nextsubnetAddressRangeStart -End $nextsubnetAddressRangeEnd 
          $unallocatedSubnetRanges.Add($unallocatedAddressRange) | Out-Null

        } # else contiguous subnet
      }
    }
    
    # TODO deciding on the smallest (bottom) or shortest subnet
    $unallocatedSubnetRanges | Select-Object -First 1
  }
  catch {
    Write-Error -ErrorRecord $_
  }
  finally {
    Remove-PsipcalcScript
  }
}

# Get the first available subnet with a unassigned address space large enough to host a new subnet of at least /$Length
# Note: Resizing a Subnet with existing IP Configurations is not currently supported.
# You must first move the IP configurations to another temporary VNet or subnet.
# https://docs.microsoft.com/bs-latn-ba/azure/virtual-network/virtual-network-manage-subnet#change-subnet-settings
function Get-VirtualNetworkUnassignedSpace {
  [CmdletBinding()]
  param(    
    [parameter(Mandatory=$true,HelpMessage="Virtual Network to get the unassigned space from")]
    [ValidateNotNullOrEmpty()]
    $VirtualNetwork,

    [parameter(Mandatory=$true,HelpMessage="Length of the required address space")]
    [ValidateNotNullOrEmpty()]
    [int] $Length
  )

  try {

    # Using Psipcal
    Import-PsipcalcScript

    # Get Highest address prefix length
    $networkLengths = $VirtualNetwork.AddressSpace.AddressPrefixes | Select-Object -Property @{Name = 'NetworkLength'; Expression = {$_.Split("/")[1]}} | Select-Object -ExpandProperty NetworkLength
    $highestNetworkLength = [Linq.Enumerable]::Min([int[]] $networkLengths)
    if ($highestNetworkLength -ge $Length) {
      throw "You must use a Vnet of at least /$($Length+1) or larger"
    }

    # Make sure to get the 'subnets/ipConfigurations' of the underlying VNet
    $VirtualNetwork = Get-AzVirtualNetwork -ResourceGroupName $VirtualNetwork.ResourceGroupName -Name $VirtualNetwork.Name -ExpandResource 'subnets/ipConfigurations'

    # Using foreach instead of Foreach-Object to break execution of the loop without exiting the function
    foreach ($_ in $VirtualNetwork.Subnets  | `
                    Sort-Object -Property AddressPrefix) {

      $vnetSubnet = $_
      $subnetAddressRangeInfo = Invoke-PSipcalc -NetworkAddress $vnetSubnet.AddressPrefix
      $subnetAddressRangeLength = $subnetAddressRangeInfo.NetworkLength
      
      if ($subnetAddressRangeLength -ge $Length) {
        # This subnet is not large enough to host a new subnet
        continue
      }

      $subnetAddressRangeStart = $subnetAddressRangeInfo.NetworkAddress

      # Init the lower and upper bounds to subnetAddressRangeStart
      $lowestAssignedIp = $highestAssignedIp = $subnetAddressRangeStart

      $assignedIPs = $vnetSubnet.IpConfigurations | Select-Object -ExpandProperty PrivateIpAddress
      if ($assignedIPs) {
        $lowestAssignedIpDecimal = [Linq.Enumerable]::Min([string[]] $assignedIPs, [Func[string,int]] { param ($ip); $ip | Convert-IPToDecimal })
        $highestAssignedIpDecimal = [Linq.Enumerable]::Max([string[]] $assignedIPs, [Func[string,int]] { param ($ip); $ip | Convert-IPToDecimal })
      
        $lowestAssignedIp = $lowestAssignedIpDecimal | Convert-DecimalToIP
        $highestAssignedIp = $highestAssignedIpDecimal | Convert-DecimalToIP
      }

      # TODO we can also consider getting the minimum address length large enough instead than halving the space in /Length+1
     
      $lowerHalfSubnetSpace = "$subnetAddressRangeStart/$($subnetAddressRangeLength+1)"
      $upperHalfSubnetSpace = "$((($subnetAddressRangeStart | Convert-IPToDecimal) + [System.Math]::Pow(2, 32 - $subnetAddressRangeLength-1)) | Convert-DecimalToIp)/$($subnetAddressRangeLength+1)"
      
      if ((Invoke-PSipcalc $lowerHalfSubnetSpace -Contains $lowestAssignedIp) -and `
          (Invoke-PSipcalc $lowerHalfSubnetSpace -Contains $highestAssignedIp)) {
          
        # Range is contained in the lower half of the address space
        $assignedSubnetSpace = $lowerHalfSubnetSpace
        $unassignedSubnetSpace = $upperHalfSubnetSpace

        break
      }
      
      if ((Invoke-PSipcalc $upperHalfSubnetSpace -Contains $lowestAssignedIp) -and `
          (Invoke-PSipcalc $upperHalfSubnetSpace -Contains $highestAssignedIp)) { # range in upperhalf
          
        # Range is contained in the upper half of the address space
        $assignedSubnetSpace = $upperHalfSubnetSpace
        $unassignedSubnetSpace = $lowerHalfSubnetSpace

        break
      }
    }

    if ($null -eq $unassignedSubnetSpace -and $null -eq $assignedSubnetSpace) {
      Write-Warning -Message "No subnet found with length of /$Length or larger"
      return $null
    }

    $result = New-Object Object
    $result | Add-member -Name 'VirtualNetworkSubnet' -Value $vnetSubnet -MemberType NoteProperty
    $result | Add-member -Name 'UnassignedSubnetSpace' -Value $unassignedSubnetSpace -MemberType NoteProperty
    $result | Add-member -Name 'AssignedSubnetSpace' -Value $assignedSubnetSpace -MemberType NoteProperty
    
    $result
  }
  catch {
    Write-Error -ErrorRecord $_
  }
  finally {
    Remove-PsipcalcScript
  }
}

function Select-VmSettings {
  param (
    $sourceImageInfos,

    [Parameter(HelpMessage="Example:  'ID-*,CSW2-SRV' , a string containing comma delimitated list of patterns. The script will (re)create just the VMs matching one of the patterns. The empty string (default) recreates all labs as well.")]
    [string] $ImagePattern = ""
  )

  if($ImagePattern) {
    $imgAr = $ImagePattern.Split(",").Trim()

    # Severely in need of a linq query to do this ...
    $newSources = @()
    foreach($source in $sourceImageInfos) {
      foreach($cond in $imgAr) {
        if($source.imageName -like $cond) {
          $newSources += $source
          break
        }
      }
    }

    if(-not $newSources) {
      throw "No source images selected by the image pattern chosen: $ImagePattern"
    }

    return $newSources
  }

  return $sourceImageInfos
}

function Select-Vms {
  param (
    $vms,

    [Parameter(HelpMessage="Example:  'ID-*,CSW2-SRV' , a string containing comma delimitated list of patterns. The script will (re)create just the VMs matching one of the patterns. The empty string (default) recreates all labs as well.")]
    [string] $ImagePattern = ""
  )

  if($ImagePattern) {
    $patterns = $ImagePattern.Split(",").Trim()

    # Severely in need of a linq query to do this ...
    $newVms = @()
    foreach($vm in $vms) {
      foreach($cond in $patterns) {
        if($vm.Name -like $cond) {
          $newVms += $vm
          break
        }
      }
    }
    if(-not $newVms) {
      Write-Error "No vm selected by the ImagePattern chosen in $DevTestLabName"
    }

    return $newVms
  }

  return $vms # No ImagePattern passed
}

function ManageExistingVM {
  param($ResourceGroupName, $DevTestLabName, $VmSettings, $IfExist)

  $newSettings = @()

  $VmSettings | ForEach-Object {
    $vmName = $_.imageName
    $existingVms = Get-AzResource -ResourceType "Microsoft.DevTestLab/labs/virtualMachines" -ResourceGroupName $ResourceGroupName | Where-Object { $_.Name -eq "$DevTestLabName/$vmName"}

    if($existingVms) {
      Write-Host "Found an existing VM $vmName in $DevTestLabName"
      if($IfExist -eq "Delete") {
        Write-Host "Deleting VM $vmName in $DevTestLabName"
        $vmToDelete = $existingVms[0]
        Remove-AzResource -ResourceId $vmToDelete.ResourceId -Force | Out-Null
        $newSettings += $_
      } elseif ($IfExist -eq "Leave") {
        Write-Host "Leaving VM $vmName  in $DevTestLabName be, not moving forward ..."
      } elseif ($IfExist -eq "Error") {
        throw "Found VM $vmName in $DevTestLabName. Error because passed the 'Error' parameter"
      } else {
        throw "Shouldn't get here in New-Vm. Parameter passed is $IfExist"
      }
    } else { # It is not an existing VM, we should continue creating it
      Write-Host "$vmName doesn't exist in $DevTestLabName"
      $newSettings += $_
    }
  }
  return $newSettings
}

function Wait-JobWithProgress {
  param(
    [ValidateNotNullOrEmpty()]
    $jobs,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    $secTimeout
    )

  Write-Host "Waiting for $(($jobs | Measure-Object).Count) job results at most $secTimeout seconds, or $( [math]::Round($secTimeout / 60,1)) minutes, or $( [math]::Round($secTimeout / 60 / 60,1)) hours ..."

  if(-not $jobs) {
    Write-Host "No jobs to wait for"
    return
  }

  # Control how often we show output and print out time passed info
  # Change here to make it go faster or slower
  $RetryIntervalSec = 7
  $MaxPrintInterval = 7
  $PrintInterval = 1

  $timer = [Diagnostics.Stopwatch]::StartNew()

  $runningJobs = $jobs | Where-Object { $_ -and ($_.State -eq "Running") }
  while(($runningJobs) -and ($timer.Elapsed.TotalSeconds -lt $secTimeout)) {

    $output = $runningJobs | Receive-Job -Keep -ErrorAction Continue
    # Only output something if we have something new to show
    if ($output -and $output.ToString().Trim()) {
      $output | Out-String | Write-Host
    }

    $runningJobs | Wait-Job -Timeout $RetryIntervalSec

    if($PrintInterval -ge $MaxPrintInterval) {
      $totalSecs = [math]::Round($timer.Elapsed.TotalSeconds,0)
      Write-Host "Remaining running Jobs $(($runningJobs | Measure-Object).Count): Time Passed: $totalSecs seconds, or $( [math]::Round($totalSecs / 60,1)) minutes, or $( [math]::Round($totalSecs / 60 / 60,1)) hours ..." -ForegroundColor Yellow
      $PrintInterval = 1
    } else {
      $PrintInterval += 1
    }

    $runningJobs = $jobs | Where-Object { $_ -and ($_.State -eq "Running") }
  }

  $timer.Stop()
  $lasted = $timer.Elapsed.TotalSeconds

  Write-Host ""
  Write-Host "JOBS STATUS"
  Write-Host "-------------------"
  $jobs | Format-Table                            # Show overall status of all jobs
  Write-Host ""
  Write-Host "JOBS OUTPUT"
  Write-Host "-------------------"
  
  $output = $jobs | Receive-Job -ErrorAction Continue

  # If the output has resource types, format it like a table, otherwise just write it out
  if ($output -and (Get-Member -InputObject $output[0] -Name ResourceType -MemberType Properties)) {
    $output | Select-Object Name, `
                            ResourceGroupName, `
                            ResourceType, `
                            @{Name="ProvisioningState";Expression={$_.Properties.provisioningState}}`
            | Out-String | Write-Host
  }
  else {
    $output | Out-String | Write-Host
  }

  $jobs | Remove-job -Force                       # -Force removes also the ones still running ...

  if ($lasted -gt $secTimeout) {
    throw "Jobs did not complete before timeout period. It lasted $lasted secs."
  } else {
    Write-Host "Jobs completed before timeout period. It lasted $lasted secs."
  }
}

function Import-ConfigFile {
  param
  (
    [parameter(ValueFromPipeline)]
    [string] $ConfigFile = "config.csv"
  )

  $config = Import-Csv $ConfigFile

  $config | ForEach-Object {
    $lab = $_

    # Confirm that the IpConfig is one of 3 options:
    if ($lab.IpConfig -ne "Public" -and $lab.IpConfig -ne "Shared" -and $lab.Ipconfig -ne "Private") {
        Write-Error "IpConfig either missing or incorrect for lab $($lab.DevTestLabName).  Must be 'Public', 'Private', or 'Shared'"
    }

    # Convert BastionEnabled to a boolean. If BastionEnabled property is not set, defaults to $false 
    if ($lab.BastionEnabled) {
      $lab.BastionEnabled = [System.Convert]::ToBoolean($lab.BastionEnabled)
    } else {
      $lab.BastionEnabled = $false
    }

    # If Vm ResourceGroupName is set to 'default'
    if ($lab.VmCreationResourceGroupName -ieq "default") {
      $lab.VmCreationResourceGroupName = $null
    }

    # Also add "Name" since that's used by the DTL Library for DevTestLabName
    Add-Member -InputObject $lab -MemberType NoteProperty -Name "Name" -Value $lab.DevTestLabName

    # We are getting a string from the csv file, so we need to split it
    if($lab.LabOwners) {
        $lab.LabOwners = $lab.LabOwners.Split(",").Trim()
    } else {
        $lab.LabOwners = @()
    }
    if($lab.LabUsers) {
        $lab.LabUsers = $lab.LabUsers.Split(",").Trim()
    } else {
        $lab.LabUsers = @()
    }

    $lab
  }
}
function Show-JobProgress {
  [CmdletBinding()]
  param(
      [Parameter(Mandatory,ValueFromPipeline)]
      [ValidateNotNullOrEmpty()]
      [System.Management.Automation.Job[]]
      $Job
  )

  Process {
      $Job.ChildJobs | ForEach-Object {
          if (-not $_.Progress) {
              return
          }

          $_.Progress |Select-Object -Last 1 | ForEach-Object {
              $ProgressParams = @{}
              if ($_.Activity          -and $null -ne $_.Activity) { $ProgressParams.Add('Activity',         $_.Activity) }
              if ($_.StatusDescription -and $null -ne $_.StatusDescription) { $ProgressParams.Add('Status',           $_.StatusDescription) }
              if ($_.CurrentOperation  -and $null -ne $_.CurrentOperation) { $ProgressParams.Add('CurrentOperation', $_.CurrentOperation) }
              if ($_.ActivityId        -and $_.ActivityId        -gt -1)    { $ProgressParams.Add('Id',               $_.ActivityId) }
              if ($_.ParentActivityId  -and $_.ParentActivityId  -gt -1)    { $ProgressParams.Add('ParentId',         $_.ParentActivityId) }
              if ($_.PercentComplete   -and $_.PercentComplete   -gt -1)    { $ProgressParams.Add('PercentComplete',  $_.PercentComplete) }
              if ($_.SecondsRemaining  -and $_.SecondsRemaining  -gt -1)    { $ProgressParams.Add('SecondsRemaining', $_.SecondsRemaining) }

              Write-Progress @ProgressParams
          }
      }
  }
}

function Wait-RSJobWithProgress {
  param(
    [ValidateNotNullOrEmpty()]
    $jobs,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    $secTimeout
    )

  Write-Host "Waiting for results at most $secTimeout seconds, or $( [math]::Round($secTimeout / 60,1)) minutes, or $( [math]::Round($secTimeout / 60 / 60,1)) hours ..."

  if(-not $jobs) {
    Write-Host "No jobs to wait for"
    return
  }

  $timer = [Diagnostics.Stopwatch]::StartNew()

  $jobs | Wait-RSJob -ShowProgress -Timeout $secTimeout | Out-Null

  $timer.Stop()
  $lasted = $timer.Elapsed.TotalSeconds

  Write-Host ""
  Write-Host "JOBS STATUS"
  Write-Host "-------------------"
  $jobs | Format-Table | Out-Host

  $allJobs = $jobs | Select-Object -ExpandProperty 'Name'
  $failedJobs = $jobs | Where-Object {$_.State -eq 'Failed'} | Select-Object -ExpandProperty 'Name'
  $runningJobs = $jobs | Where-Object {$_.State -eq 'Running'} | Select-Object -ExpandProperty 'Name'
  $completedJobs = $jobs | Where-Object {$_.State -eq 'Completed'} | Select-Object -ExpandProperty 'Name'

  Write-Output "OUTPUT for ($allJobs)"
  # These go to output to show errors and correct results
  $jobs | Receive-RSJob -ErrorAction Continue
  $jobs | Remove-RSjob -Force | Out-Null

  $errorString =  ""
  if($failedJobs -or $runningJobs) {
    $errorString += "Failed jobs: $failedJobs, Running jobs: $runningJobs. "
  }

  if ($lasted -gt $secTimeout) {
    $errorString += "Jobs did not complete before timeout period. It lasted for $lasted secs."
  }

  if($errorString) {
    throw "ERROR: $errorString"
  }

  Write-Output "These jobs ($completedJobs) completed before timeout period. They lasted for $lasted secs."
}

function Invoke-RSForEachLab {
  param
  (
    [parameter(ValueFromPipeline)]
    [string] $script,
    [string] $ConfigFile = "config.csv",
    [int] $SecondsBetweenLoops =  10,
    [string] $customRole = "No VM Creation User",
    [string] $ImagePattern = "",
    [string] $IfExist = "Leave",
    [int] $SecTimeout = 5 * 60 * 60,
    [string[]] $ModulesToImport
  )

  $config = Import-Csv $ConfigFile

  $jobs = @()

  $config | ForEach-Object {
    $lab = $_
    Write-Host "Starting operating on $($lab.DevTestLabName) ..."

    # We are getting a string from the csv file, so we need to split it
    if($lab.LabOwners) {
        $ownAr = $lab.LabOwners.Split(",").Trim()
    } else {
        $ownAr = @()
    }
    if($lab.LabUsers) {
        $userAr = $lab.LabUsers.Split(",").Trim()
    } else {
        $userAr = @()
    }

    # Convert BastionEnabled to a boolean. If BastionEnabled property is not set, defaults to $false 
    if ($lab.BastionEnabled) {
      $lab.BastionEnabled = [System.Convert]::ToBoolean($lab.BastionEnabled)
    } else {
      $lab.BastionEnabled = $false
    }

    # The scripts that operate over a single lab need to have an uniform number of parameters so that they can be invoked by Invoke-ForeachLab.
    # The argumentList of star-job just allows passing arguments positionally, so it can't be used if the scripts have arguments in different positions.
    # To workaround that, a string gets generated that embed the script as text and passes the parameters by name instead
    # Also, a valueFromRemainingArguments=$true parameter needs to be added to the single lab script
    # So we achieve the goal of reusing the Invoke-Foreach function for everything, while still keeping the single lab scripts clean for the caller
    # The price we pay for the above is the crazy code below, which is likely quite bug prone ...
    $formatOwners = $ownAr | ForEach-Object { "'$_'"}
    $ownStr = $formatOwners -join ","
    $formatUsers = $userAr | ForEach-Object { "'$_'"}
    $userStr = $formatUsers -join ","

    $params = "@{
      DevTestLabName='$($lab.DevTestLabName)';
      ResourceGroupName='$($lab.ResourceGroupName)';
      SharedImageGalleryName='$($lab.SharedImageGalleryName)';
      ShutDownTime='$($lab.ShutDownTime)';
      TimezoneId='$($lab.TimezoneId)';
      LabRegion='$($lab.LabRegion)';
      LabOwners= @($ownStr);
      LabUsers= @($userStr);
      LabIpConfig='$($lab.IpConfig)';
      LabBastionEnabled=`$$($lab.BastionEnabled);
      CustomRole='$($customRole)';
      ImagePattern='$($ImagePattern)';
      IfExist='$($IfExist)';
    }"

    $sb = [scriptblock]::create(
    @"
    `Set-Location `$Using:PWD
    `$params=$params
    .{$(get-content $script -Raw)} @params
"@)

    $jobs += Start-RSJob -Name "$($lab.DevTestLabName)-JobId$(Get-Random)" -ScriptBlock $sb -ModulesToImport $ModulesToImport
    Start-Sleep -Seconds $SecondsBetweenLoops
  }

  Wait-RSJobWithProgress -secTimeout $secTimeout -jobs $jobs
}

function Get-RandomString {
  param(
    [Parameter(Mandatory)]
    #Joining together a..z and A..Z we have exactly 52 characters to choose from
    [ValidateRange(0, 52)]
    [byte]$length
  )
  #Set ASCII boundaries for letter generation
  $lowercaseA = 65
  $lowercaseZ = 90
  $uppercaseA = 97
  $uppercaseZ = 122
  return -join (($lowercaseA..$lowercaseZ) + ($uppercaseA..$uppercaseZ) `
    | Get-Random -Count $length `
    | ForEach-Object { [char]$_ })
}

# Generate password lifted from this location: https://blogs.technet.microsoft.com/heyscriptingguy/2015/11/05/generate-random-letters-with-powershell/
Function Get-NewPassword() {
    Param(
        [int]$length=40
    )
    # NOTE: this excludes commas and some other special characters
    return (-join ((48..57) + (65..90) + (97..122) | Get-Random -Count $length | % {[char]$_}))
}

function Split-Tags {
  param
  (
    [Parameter(Mandatory)]
    [psobject]$tags
  )
  $TAG_VALUE_MAX_LENGTH = 256
  $MAX_TAG_PARTS_ALLOWED = 10
  $tagFormatter = '"{0}":"{1}",'

  $formattedTags = $tags | ForEach-Object {
    # Azure max tag value length is 256. To circumvent this, a longer tag is splitted up
    $tagValue = $_.Value.ToString()
    $partsCounts = [int][Math]::Ceiling($tagValue.Length / $TAG_VALUE_MAX_LENGTH)
    # Tag List to upload to the Image Version
    $tagList = ""

    #Extreme case : a tag longer than 2560 characters isn't allowed. 
    # This can be easily extended by adding a new digit to the part numbering
    # But that's just plain overkill at this point
    if ($partsCounts -gt $MAX_TAG_PARTS_ALLOWED){
      $maxCharactersAllowed = $MAX_TAG_PARTS_ALLOWED * $TAG_VALUE_MAX_LENGTH
      throw "The tag $tagValue is longer than the max allowed tag length $maxCharactersAllowed character"
    }
    # Tag shorter than the limit, just add it to the list 
    if ($partsCounts -le 1) {
      $tagList = $tagFormatter -f $_.Name, $tagValue
    }else{
      #Tag longer than the limit, splitting it up into parts "key_$i : $PartialValue"
      for ($i = 0; $i -lt $partsCounts; $i++) {
        $partialKeyName = $_.Name + "_$i"
        $cutIndex = $i * $TAG_VALUE_MAX_LENGTH
        # Number of characters to cut
        $chunkSize = [Math]::Min($TAG_VALUE_MAX_LENGTH, $tagValue.Length - $cutIndex)
        $tagList += $tagFormatter -f $partialKeyName, $tagValue.Substring($cutIndex, $chunkSize) + "`n"
      }
    }
    #Remove trailing newlines or spaces if any
    $tagList.Trim()
  } | Out-String
  #Remove trailing comma
  $formattedTags.Trim() -replace ".$"
}

function Join-Tags{
  param
  (
    [Parameter(Mandatory)]
    $tags
  )
  # Iterate on sorted "_X" properties parts, removing them while reassembling the property value
  # The properties that weren't previously splitted are left untouched.
  # Properties such as "YYY_0" and "YYY_1" will be reassembled as just "YYY", concatenating their values.
  $numeralMatcher = "_\d+$"
  $tags.PSobject.Properties.name -match $numeralMatcher | Sort-Object | ForEach-Object {
    $propertyName = $_ -replace $numeralMatcher
    # Create the property "YYY"
    if (-not ($tags | Get-Member -Name "$propertyName")) {
      $tags | Add-Member -MemberType "NoteProperty" -Name "$propertyName" -Value ""
    }
    # Concatenate the value of "YYY_X" to "YYY"
    $tags.$propertyName += $tags.$_
    # Remove the old "YYY_X" property
    $tags.PSObject.Properties.Remove($_)
  }
  $tags
}
