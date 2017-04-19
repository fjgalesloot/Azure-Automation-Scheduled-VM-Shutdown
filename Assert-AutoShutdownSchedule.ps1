<#
    .SYNOPSIS
        This Azure Automation runbook automates the scheduled shutdown and startup of resources in an Azure subscription. 

    .DESCRIPTION
        The runbook implements a solution for scheduled power management of Azure resources in combination with tags
        on resources or resource groups which define a shutdown schedule. Each time it runs, the runbook looks for all
        supported resources or resource groups with a tag named "AutoShutdownSchedule" having a value defining the schedule, 
        e.g. "10PM -> 6AM". It then checks the current time against each schedule entry, ensuring that resourcess with tags or in tagged groups 
        are deallocated/shut down or started to conform to the defined schedule.

        This is a PowerShell runbook, as opposed to a PowerShell Workflow runbook.

        This script requires the "AzureRM.Resources" modules which are present by default in Azure Automation accounts.
        For detailed documentation and instructions, see: 
        
        CREDITS: Initial version credits goes to automys from which this script started :
        https://automys.com/library/asset/scheduled-virtual-machine-shutdown-startup-microsoft-azure

    .PARAMETER AzureCredentialName
        The name of the PowerShell credential asset in the Automation account that contains username and password
        for the account used to connect to target Azure subscription. This user must be configured as owner
        of the subscription for best functionality. 

        By default, the runbook will use the credential with name "Default Automation Credential"

        For for details on credential configuration, see:
        http://azure.microsoft.com/blog/2014/08/27/azure-automation-authenticating-to-azure-using-azure-active-directory/
    
    .PARAMETER AzureSubscriptionName
        The name or ID of Azure subscription in which the resources will be created. By default, the runbook will use 
        the value defined in the Variable setting named "Default Azure Subscription"
    
    .PARAMETER Simulate
        If $true, the runbook will not perform any power actions and will only simulate evaluating the tagged schedules. Use this
        to test your runbook to see what it will do when run normally (Simulate = $false).

    .PARAMETER DefaultScheduleIfNotPresent
        If provided, will set the default schedule to apply on all resources that don't have any scheduled tag value defined or inherited.

        Description | Tag value
        Shut down from 10PM to 6 AM UTC every day | 10pm -> 6am
        Shut down from 10PM to 6 AM UTC every day (different format, same result as above) | 22:00 -> 06:00
        Shut down from 8PM to 12AM and from 2AM to 7AM UTC every day (bringing online from 12-2AM for maintenance in between) | 8PM -> 12AM, 2AM -> 7AM
        Shut down all day Saturday and Sunday (midnight to midnight) | Saturday, Sunday
        Shut down from 2AM to 7AM UTC every day and all day on weekends | 2:00 -> 7:00, Saturday, Sunday
        Shut down on Christmas Day and New Year’s Day | December 25, January 1
        Shut down from 2AM to 7AM UTC every day, and all day on weekends, and on Christmas Day | 2:00 -> 7:00, Saturday, Sunday, December 25
        Shut down always – I don’t want this VM online, ever | 0:00 -> 23:59:59
        
    
    .PARAMETER TimeZone
        Defines the Timezone used when running the runbook. "GMT Standard Time" by default.
        Microsoft Time Zone Index Values:
        https://msdn.microsoft.com/en-us/library/ms912391(v=winembedded.11).aspx

    .EXAMPLE
        For testing examples, see the documentation at:

        https://automys.com/library/asset/scheduled-virtual-machine-shutdown-startup-microsoft-azure
    
    .INPUTS
        None.

    .OUTPUTS
        Human-readable informational and error messages produced during the job. Not intended to be consumed by another runbook.
#>
[CmdletBinding()]
param(
    [parameter(Mandatory=$false)]
    [String] $AzureCredentialName = "Use *Default Automation Credential* Asset",
    [parameter(Mandatory=$false)]
    [String] $AzureSubscriptionName = "Use *Default Azure Subscription* Variable Value",
    [parameter(Mandatory=$false)]
    [bool]$Simulate = $false,
    [parameter(Mandatory=$false)]
    [string]$DefaultScheduleIfNotPresent,
    [parameter(Mandatory=$false)]
    [String] $Timezone = "W. Europe Standard Time"
)

$VERSION = '3.3.0'
$autoShutdownTagName = 'AutoShutdownSchedule'
$autoShutdownOrderTagName = 'ProcessingOrder'
$defaultOrder = 1000

$ResourceProcessors = @(
  @{
    ResourceType = 'Microsoft.ClassicCompute/virtualMachines'
    PowerStateAction = { param([object]$Resource, [string]$DesiredState) (Get-AzureRmResource -ResourceId $Resource.ResourceId).Properties.InstanceView.PowerState }
    StartAction = { param([string]$ResourceId) Invoke-AzureRmResourceAction -ResourceId $ResourceId -Action 'start' -Force } 
    DeallocateAction = { param([string]$ResourceId) Invoke-AzureRmResourceAction -ResourceId $ResourceId -Action 'shutdown' -Force } 
  },
  @{
    ResourceType = 'Microsoft.Compute/virtualMachines'
    PowerStateAction = { 
      param([object]$Resource, [string]$DesiredState)
      
      $vm = Get-AzureRmVM -ResourceGroupName $Resource.ResourceGroupName -Name $Resource.Name -Status
      $currentStatus = $vm.Statuses | Where-Object Code -like 'PowerState*' 
      $currentStatus.Code -replace 'PowerState/',''
    }
    StartAction = { param([string]$ResourceId) Invoke-AzureRmResourceAction -ResourceId $ResourceId -Action 'start' -Force } 
    DeallocateAction = { param([string]$ResourceId) Invoke-AzureRmResourceAction -ResourceId $ResourceId -Action 'deallocate' -Force } 
  },
  @{
    ResourceType = 'Microsoft.Compute/virtualMachineScaleSets'
    #since there is no way to get the status of a VMSS, we assume it is in the inverse state to force the action on the whole VMSS
    PowerStateAction = { param([object]$Resource, [string]$DesiredState) if($DesiredState -eq 'StoppedDeallocated') { 'Started' } else { 'StoppedDeallocated' } }
    StartAction = { param([string]$ResourceId) Invoke-AzureRmResourceAction -ResourceId $ResourceId -Action 'start' -Parameters @{ instanceIds = @('*') } -Force } 
    DeallocateAction = { param([string]$ResourceId) Invoke-AzureRmResourceAction -ResourceId $ResourceId -Action 'deallocate' -Parameters @{ instanceIds = @('*') } -Force } 
  }
)

# Define function to get current date using the TimeZone Paremeter
function GetCurrentDate
{
    return [system.timezoneinfo]::ConvertTime($(Get-Date),$([system.timezoneinfo]::GetSystemTimeZones() | ? id -eq $Timezone))
}

# Define function to check current time against specified range
function Test-ScheduleEntry ([string]$TimeRange)
{	
	# Initialize variables
	$rangeStart, $rangeEnd, $parsedDay = $null
	$currentTime = GetCurrentDate
    $midnight = $currentTime.AddDays(1).Date	        

	try
	{
	    # Parse as range if contains '->'
	    if($TimeRange -like '*->*')
	    {
	        $timeRangeComponents = $TimeRange -split '->' | foreach {$_.Trim()}
	        if($timeRangeComponents.Count -eq 2)
	        {
	            $rangeStart = Get-Date $timeRangeComponents[0]
	            $rangeEnd = Get-Date $timeRangeComponents[1]
	
	            # Check for crossing midnight
	            if($rangeStart -gt $rangeEnd)
	            {
                    # If current time is between the start of range and midnight tonight, interpret start time as earlier today and end time as tomorrow
                    if($currentTime -ge $rangeStart -and $currentTime -lt $midnight)
                    {
                        $rangeEnd = $rangeEnd.AddDays(1)
                    }
                    # Otherwise interpret start time as yesterday and end time as today   
                    else
                    {
                        $rangeStart = $rangeStart.AddDays(-1)
                    }
	            }
	        }
	        else
	        {
	            Write-Output "`tWARNING: Invalid time range format. Expects valid .Net DateTime-formatted start time and end time separated by '->'" 
	        }
	    }
	    # Otherwise attempt to parse as a full day entry, e.g. 'Monday' or 'December 25' 
	    else
	    {
	        # If specified as day of week, check if today
	        if([System.DayOfWeek].GetEnumValues() -contains $TimeRange)
	        {
	            if($TimeRange -eq (Get-Date).DayOfWeek)
	            {
	                $parsedDay = Get-Date '00:00'
	            }
	            else
	            {
	                # Skip detected day of week that isn't today
	            }
	        }
	        # Otherwise attempt to parse as a date, e.g. 'December 25'
	        else
	        {
	            $parsedDay = Get-Date $TimeRange
	        }
	    
	        if($parsedDay -ne $null)
	        {
	            $rangeStart = $parsedDay # Defaults to midnight
	            $rangeEnd = $parsedDay.AddHours(23).AddMinutes(59).AddSeconds(59) # End of the same day
	        }
	    }
	}
	catch
	{
	    # Record any errors and return false by default
	    Write-Output "`tWARNING: Exception encountered while parsing time range. Details: $($_.Exception.Message). Check the syntax of entry, e.g. '<StartTime> -> <EndTime>', or days/dates like 'Sunday' and 'December 25'"
	    return $false
	}
	
	# Check if current time falls within range
	if($currentTime -ge $rangeStart -and $currentTime -le $rangeEnd)
	{
	    return $true
	}
	else
	{
	    return $false
	}
	
} # End function Test-ScheduleEntry


# Function to handle power state assertion for resources
function Assert-ResourcePowerState
{
    param(
        [Parameter(Mandatory=$true)]
        [object]$Resource,
        [Parameter(Mandatory=$true)]
        [string]$DesiredState,
        [bool]$Simulate
    )

  $processor = $ResourceProcessors | Where-Object ResourceType -eq $Resource.ResourceType
  if(-not $processor) {
    throw ('Unable to find a resource processor for type ''{0}''. Resource: {1}' -f $Resource.ResourceType, ($Resource | ConvertTo-Json -Depth 5000))
  }
  # If should be started and isn't, start resource
  $currentPowerState = & $processor.PowerStateAction -Resource $Resource -DesiredState $DesiredState
	if($DesiredState -eq 'Started' -and $currentPowerState -notmatch 'Started|Starting|running')
	{
		if($Simulate)
        {
            Write-Output "[$($Resource.Name) `- P$($Resource.ProcessingOrder)]: SIMULATION -- Would have started resource. (No action taken)"
        }
        else
        {
            Write-Output "[$($Resource.Name) `- P$($Resource.ProcessingOrder)]: Starting resource"
            & $processor.StartAction -ResourceId $Resource.ResourceId
        }
	}
		
	# If should be stopped and isn't, stop resource
	elseif($DesiredState -eq 'StoppedDeallocated' -and $currentPowerState -notmatch 'Stopped|deallocated')
	{
        if($Simulate)
        {
            Write-Output "[$($Resource.Name) `- P$($Resource.ProcessingOrder)]: SIMULATION -- Would have stopped resource. (No action taken)"
        }
        else
        {
            Write-Output "[$($Resource.Name) `- P$($Resource.ProcessingOrder)]: Stopping resource"
            & $processor.DeallocateAction -ResourceId $Resource.ResourceId
        }
	}

    # Otherwise, current power state is correct
    else
    {
        Write-Output "[$($Resource.Name) `- P$($Resource.ProcessingOrder)]: Current power state [$($currentPowerState)] is correct."
    }
}

# Main runbook content
try
{
    $currentTime = GetCurrentDate
    Write-Output "Runbook started. Version: $VERSION"
    if($Simulate)
    {
        Write-Output '*** Running in SIMULATE mode. No power actions will be taken. ***'
    }
    else
    {
        Write-Output '*** Running in LIVE mode. Schedules will be enforced. ***'
    }
    Write-Output "Current UTC/GMT time [$($currentTime.ToString('dddd, yyyy MMM dd HH:mm:ss'))] will be checked against schedules"
	
    # Retrieve subscription name from variable asset if not specified
    if($AzureSubscriptionName -eq 'Use *Default Azure Subscription* Variable Value')
    {
        $AzureSubscriptionName = Get-AutomationVariable -Name 'Default Azure Subscription'
        if($AzureSubscriptionName.length -gt 0)
        {
            Write-Output "Specified subscription name/ID: [$AzureSubscriptionName]"
        }
        else
        {
            throw "No subscription name was specified, and no variable asset with name 'Default Azure Subscription' was found. Either specify an Azure subscription name or define the default using a variable setting"
        }
    }

    # Retrieve credential
    write-output "Specified credential asset name: [$AzureCredentialName]"
    if($AzureCredentialName -eq 'Use *Default Automation Credential* asset')
    {
        # By default, look for "Default Automation Credential" asset
        $azureCredential = Get-AutomationPSCredential -Name 'Default Automation Credential'
        if($azureCredential -ne $null)
        {
		    Write-Output "Attempting to authenticate as: [$($azureCredential.UserName)]"
        }
        else
        {
            throw "No automation credential name was specified, and no credential asset with name 'Default Automation Credential' was found. Either specify a stored credential name or define the default using a credential asset"
        }
    }
    else
    {
        # A different credential name was specified, attempt to load it
        $azureCredential = Get-AutomationPSCredential -Name $AzureCredentialName
        if($azureCredential -eq $null)
        {
            throw "Failed to get credential with name [$AzureCredentialName]"
        }
    }

    # Connect via Azure Resource Manager 
    $resourceManagerContext = Add-AzureRmAccount -Credential $azureCredential -ErrorAction SilentlyContinue
    if($resourceManagerContext)
    {
        Write-Output "Successfully authenticated as user: [$($azureCredential.UserName)]"
    }
    else
    {
        throw "Authentication failed for credential [$($azureCredential.UserName)]. Ensure a valid Azure Active Directory user account is specified which is configured as a subscription owner (modern portal) on the target subscription. Verify you can log into the Azure portal using these credentials."
    }


    # Validate subscription
    $subscriptions = @(Get-AzureRmSubscription | Where-Object {$_.SubscriptionName -eq $AzureSubscriptionName -or $_.SubscriptionId -eq $AzureSubscriptionName})
    if($subscriptions.Count -eq 1)
    {
        # Set working subscription
        $targetSubscription = $subscriptions | Select-Object -First 1
        Set-AzureRmContext -SubscriptionId $targetSubscription.SubscriptionId

        $currentSubscription = (Get-AzureRmContext).Subscription
        Write-Output "Working against subscription: $($currentSubscription.SubscriptionName) ($($currentSubscription.SubscriptionId))"
    }
    else
    {
        if($subscription.Count -eq 0)
        {
            throw "No accessible subscription found with name or ID [$AzureSubscriptionName]. Check the runbook parameters and ensure user has proper rights on the target subscription."
        }
        elseif($subscriptions.Count -gt 1)
        {
            throw "More than one accessible subscription found with name or ID [$AzureSubscriptionName]. Please ensure your subscription names are unique, or specify the ID instead"
        }
    }

    $resourceList = @()
    # Get a list of all supported resources in subscription
    $ResourceProcessors | % {
      Write-Output ('Looking for resources of type {0}' -f $_.ResourceType)
      $resourceList += @(Find-AzureRmResource -ResourceType $_.ResourceType)
    }

    $ResourceList | % {     
      if($_.Tags -and $_.Tags.Name -contains $autoShutdownOrderTagName ) {
        $order = $_.Tags | % { if($_.Name -eq $autoShutdownOrderTagName) { $_.Value } }
      } else {
        $order = $defaultOrder
      }
      Add-Member -InputObject $_ -Name ProcessingOrder -MemberType NoteProperty -TypeName Integer -Value $order
    }


    # Get resource groups that are tagged for automatic shutdown of resources
    $resourceGroups = @(Get-AzureRmResourceGroup)
    $taggedResourceGroupNames = @($resourceGroups | Where-Object {$_.Tags.Count -gt 0 -and $_.Tags.Name -contains $autoShutdownTagName} | Select-Object -ExpandProperty ResourceGroupName)
    Write-Output "Found [$($taggedResourceGroupNames.Count)] schedule-tagged resource groups in subscription"	
    if($DefaultScheduleIfNotPresent) {
      Write-Output "Default schedule was specified, all non tagged resources will inherit this schedule: $DefaultScheduleIfNotPresent"
    }

    # For each resource, determine
    #  - Is it directly tagged for shutdown or member of a tagged resource group
    #  - Is the current time within the tagged schedule 
    # Then assert its correct power state based on the assigned schedule (if present)
    Write-Output "Processing [$($resourceList.Count)] resources found in subscription"
    foreach($resource in $resourceList)
    {
        $schedule = $null

        # Check for direct tag or group-inherited tag
        if($resource.Tags -and $resource.Tags.Name -contains $autoShutdownTagName)
        {
            # Resource has direct tag (possible for resource manager deployment model resources). Prefer this tag schedule.
            $schedule = ($resource.Tags | Where-Object Name -eq $autoShutdownTagName)['Value']
            Write-Output "[$($resource.Name)]: Found direct resource schedule tag with value: $schedule"
        }
        elseif($taggedResourceGroupNames -contains $resource.ResourceGroupName)
        {
            # resource belongs to a tagged resource group. Use the group tag
            $parentGroup = $resourceGroups | Where-Object ResourceGroupName -eq $resource.ResourceGroupName
            $schedule = ($parentGroup.Tags | Where-Object Name -eq $autoShutdownTagName)['Value']
            Write-Output "[$($resource.Name)]: Found parent resource group schedule tag with value: $schedule"
        }
        elseif($DefaultScheduleIfNotPresent)
        {
          $schedule = $DefaultScheduleIfNotPresent
          Write-Output "[$($resource.Name)]: Using default schedule: $schedule"
        }
        else
        {
            # No direct or inherited tag. Skip this resource.
            Write-Output "[$($resource.Name)]: Not tagged for shutdown directly or via membership in a tagged resource group. Skipping this resource."
            continue
        }

        # Check that tag value was succesfully obtained
        if($schedule -eq $null)
        {
            Write-Output "[$($resource.Name) `- $($resource.ProcessingOrder)]: Failed to get tagged schedule for resource. Skipping this resource."
            continue
        }

		    # Parse the ranges in the Tag value. Expects a string of comma-separated time ranges, or a single time range
		    $timeRangeList = @($schedule -split ',' | foreach {$_.Trim()})
	    
		    # Check each range against the current time to see if any schedule is matched
		    $scheduleMatched = $false
		    $matchedSchedule = $null
        foreach($entry in $timeRangeList)
		    {
		        if((Test-ScheduleEntry -TimeRange $entry) -eq $true)
		        {
		            $scheduleMatched = $true
                $matchedSchedule = $entry
		            break
		        }
		    }
        Add-Member -InputObject $resource -Name ScheduleMatched -MemberType NoteProperty -TypeName Boolean -Value $scheduleMatched
        Add-Member -InputObject $resource -Name MatchedSchedule -MemberType NoteProperty -TypeName Boolean -Value $matchedSchedule
    }
    
    foreach($resource in $resourceList | Group-Object ScheduleMatched) {
      if($resource.Name -eq '') {continue}
      $sortedResourceList = @()
      if($resource.Name -eq $false) {
        # meaning we start resources, lower to higher
        $sortedResourceList += @($resource.Group | Sort ProcessingOrder)
      } else { 
        $sortedResourceList += @($resource.Group | Sort ProcessingOrder -Descending)
      }

      foreach($resource in $sortedResourceList)
      {		
            # Enforce desired state for group resources based on result. 
		    if($resource.ScheduleMatched)
		    {
          # Schedule is matched. Shut down the resource if it is running. 
		      Write-Output "[$($resource.Name) `- P$($resource.ProcessingOrder)]: Current time [$currentTime] falls within the scheduled shutdown range [$($resource.MatchedSchedule)]"
		      Add-Member -InputObject $resource -Name DesiredState -MemberType NoteProperty -TypeName String -Value 'StoppedDeallocated'

		    }
		    else
		    {
          # Schedule not matched. Start resource if stopped.
		      Write-Output "[$($resource.Name) `- P$($resource.ProcessingOrder)]: Current time falls outside of all scheduled shutdown ranges."
		      Add-Member -InputObject $resource -Name DesiredState -MemberType NoteProperty -TypeName Boolean -Value 'Started'
		    }	    
		    Assert-ResourcePowerState -Resource $resource -DesiredState $resource.DesiredState -Simulate $Simulate
      }
    }

    Write-Output 'Finished processing resource schedules'
}
catch
{
    $errorMessage = $_.Exception.Message
    throw "Unexpected exception: $errorMessage"
}
finally
{
    Write-Output "Runbook finished (Duration: $(('{0:hh\:mm\:ss}' -f ((GetCurrentDate) - $currentTime))))"
}