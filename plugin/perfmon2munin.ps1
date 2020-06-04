<#
.SYNOPSIS
Perfmon2munin.ps1 - a Powershell wrapper to evaluate Perfmon-recorded CSV-data from
$perfCollectionsDir and turn it into Munin-readable Multigraph Supersampling
format.

.DETAIL
Every Perfmon Data Collector set will yield a single graph in the Munin "perfmon"
graph category. The value labels are derived from counter names, the graph labels
will be derived from the Perfmon Data Collector set's directory name. If you want 
beautiful names, take care to name your directories accordingly.

The wrapper uses two additional configuration files to draw definitions from:

The first, $viewScalePath contains a single JSON key:value hashtable where 
"key" is the perfmon value name to define a viewscale for and "value" is the
unit multiplier to use for Munin data display. Example:
{
       "PhysicalDisk(_Total)\\Disk Bytes/sec":  "1e-6"
}
would configure a CDEF multiplying the values provided with 10^-6, effectively 
showing them as Megabytes in Munin graphs. Note that the transmitted data itself
is unaffected by this definition - it still would contain the raw byte value.
The function BeautifyCounterScale() below contains a table for "nice" SI metric
prefix names for a number of scale definitions.
#
The second, $regexGaugePath, contains a JSON array with a number of string
entries defining whether counters should be interpreted as point-in-time GAUGEs or 
as ever-incremented COUNTERs, where delta values between measurements are calculated 
and normalized by the time passed inbetween measurements. The default is to 
return all data as COUNTERs, except for those counter names regex-matched by one 
of the entries in the $regexGaugePath file.

.COPYRIGHT
Author: Denis Jedig
on behalf of: Cologne University of Applied Sciences (TH Köln), Germany
2017-02-20
#>


param(
    # The Munin plugin action to execute (fetch, config, name)
    [String]$PluginAction="fetch",
    # Process the last $LinesToFetch lines in the perfmon log file.
    # The default of 50 amounts to 750 seconds of data assuming a sampling interval 
    # of 15 seconds which is enough to avoid data gaps considering the Munin fetch 
    # interval of 5 minutes
    [int]$LinesToFetch=50
) 

# Constants

$perfCollectionsDir = "C:\PerfLogs\Admin\"                            # Directory where perfmon is writing logs to
$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition   # Filesystem Path of this script
$viewScalePath = "$scriptPath\\perfmon2munin-viewscale.conf"          # path for the perfmon2munin-viewscale.conf definition file
$regexGaugePath = "$scriptPath\\perfmon2munin-gauges.conf"            # path for the perfmon2munin-gauges.conf definition file


function printMuninConfig ($filename, $graphTitle){
# Generates the Munin "config" output using the supplied $filename perfmon collection CSV
# as the data fields definition and processes the perfmon2munin-viewscale.conf JSON definition
# to CDEF the values into reasonable scale

# common headers
@"

multigraph perfmon_$($graphTitle -replace "[^a-zA-Z0-9]+","_")

graph_title Perfmon $graphTitle
graph_category perfmon
graph_args -l 0 -r
"@

    # Load data from files
    $viewScale = Get-Content -Raw $viewScalePath | ConvertFrom-Json
    $regexGauge = (Get-Content -Raw $regexGaugePath) -replace "//.*", "" | ConvertFrom-Json
    $perfData=Import-Csv -Path $filename

    # we need the en-US culture info as this is what the Perfmon time format will be in 
    # for an international English system. It not necessarily will be the current culture 
    # of the Powershell environment, so date conversion functions will need to have en-US specified.
    $culture_en_US = New-Object system.globalization.cultureinfo("en-US")

    # Iterate through $perfData, generate a synthetic value name based on the original name string's hash, 
    # determine (guess) the value type, use a cleared-up version of the original name as the Munin label and
    # set it into scale using CDEF (and the viewscale definitions)
    $perfData[1].psObject.Properties | ForEach-Object { 
        if (-not ($_.Name -match "\(PDH-CSV 4.0\).*")) {
            $counterName ="hash_$([Convert]::ToString($_.Name.GetHashCode(),16))"
            $counterType = guessValueType (shortenNameString($_.Name)) $regexGauge
            # find the counter name in $viewScale, return first corresponding value of the match as $counterScale
            $counterOrigName=$_.Name
            Try {
                $counterScale = ($viewScale.psObject.Properties | Where-Object { $counterOrigName -like "*$($_.Name)" })[0].Value
            } Catch { $counterScale = $null }   # $counterScale is $null if no match has been found

            # construct the Munin field label from the counter name and the scale
            If ($counterScale -ne $null) {
                "$counterName.cdef $($counterName),$counterScale,*"
                $counterLabel = "$(shortenNameString($_.Name)) $(BeautifyCounterScale($counterScale))"
             } Else { $counterLabel = shortenNameString($_.Name) }
            "$counterName.label $counterLabel"
            "$counterName.type $counterType"

        } Else { $counterTimestamp = $_.Name }         # This is to determine the (possibly varying) name of the timestamp column
    }
    Try {
        # Look at the first two $perfData entries to determine the sampling period for the data and use it as the Munin update rate
        $muninUpdateRate = [int](New-TimeSpan -Start ([datetime]::Parse($perfData[1].psObject.Properties.Item($counterTimestamp).Value, $culture_en_US)) `
                                            -End ([datetime]::Parse($perfData[2].psObject.Properties.Item($counterTimestamp).Value, $culture_en_US)) ).TotalSeconds
    } Catch {
        # Assume a default data update rate of once per 15 seconds if the detection using the perfdata file has failed with an exception.
        $muninUpdateRate = 15
    }

    "update_rate $muninUpdateRate"
    "graph_data_size custom 1t, 1m for 3t, 5m for 1y"
}

function printMuninValues ($filename, $graphTitle){
    $unixEpoch = Get-Date -Date "01/01/1970"
    [int]$timeOffset = -9999
    [String]$timeZone = ""

    # we need the en-US culture info as this is what the Perfmon time format will be in 
    # for an international English system. It not necessarily will be the current culture 
    # of the Powershell environment, so date conversion functions will need to have en-US specified.
    $culture_en_US = New-Object system.globalization.cultureinfo("en-US")


    "multigraph perfmon_$($graphTitle -replace "[^a-zA-Z0-9]+","_")"
    
    # Import-Csv will create an array of objects - one instance per line
    # The CSV column data will be exposed as object properties, so we need to 
    # iterate through property enumerations to get at the data
    Import-Csv -Path $filename | Select -Last $linesToFetch | ForEach-Object {
        $_.psObject.Properties | ForEach-Object { 
            if ($_.Name -match "\(PDH-CSV 4.0\).*") {
               # Treat the timestamp column by extracting the timezone and calculating the offset 
               # (only if not done already previously)
               # and converting the DateTime into Linux Epoch (seconds since 1/1/1970)
                If ($timeOffset -eq -9999) {
                    $timeZone=$_.Name -replace "\(PDH-CSV 4.0\) \([^\)]*\)", ""
                    $timeOffset=Invoke-Expression "$timeZone * 60"
                }
                $counterTimestamp = [int](New-TimeSpan -Start $unixEpoch -End ([datetime]::Parse($_.Value, $culture_en_US))).TotalSeconds + [int]$timeOffset
            } Else {
                # Print data in munin-compatible supersampling format
                # <counter>.value <timestamp>:<value>. The Munin field name is generated as a hash from the perfmon counter name
                $counterName = "hash_$([Convert]::ToString($_.Name.GetHashCode(),16))"
                # Do try not print empty values,
                # cut off precision after the 6th digit as Munin might not react well to very long numbers
                if (($_.Value).Trim() -ne "") {
                    "$counterName.value $($counterTimestamp):$([math]::Round($_.Value,6))"
                }
            } # if ($_.Name -match "\(PDH-CSV 4.0\).*") 
        } # $_.psObject.Properties | ForEach-Object
    } | Sort-Object # Import-Csv -Path $filename | Select -Last 50 | ForEach-Object
}

function getCounterScale($counterName, $viewScale){
# find $countername in $viewScale, return first corresponding value
    ($viewScale.psObject.Properties | Where-Object { $counterName -like $_.Name })[0].Value
}

function BeautifyCounterScale($counterScale) {
# replace the numeric multiplier as used in $viewScale by SI metric prefixes
    switch ([float]$counterScale)
    {
        1e18 { "(attounits\)"; return }
        1e15 { "(femtounits\)"; return }
        1e12 { "(picounits)"; return }
        1e9 { "(nanounits)"; return }
        1e6 { "(microunits)"; return }
        1e3 { "(milliunits)"; return }
        1 { ""; return }
        1e-3 { "(Kilounits)"; return }
        1e-6 { "(Megaunits)"; return }
        1e-9 { "(Gigaunits)"; return }
        1e-12 { "(Teraunits)"; return }
        1e-15 { "(Petaunits)"; return }
        1e-18 { "(Exaunits)"; return }
    }

    # Invert the operator so the label tells the viewer what *she* needs to do to get to the original value 
    # instead of telling what has been done to get it
    If ([float]$counterScale -gt 1) {
        "(/$([float]$counterScale))"
    } Else {
        "(x$([int](1/[float]$counterScale)))"
    }
}


function shortenNameString ($nameString)
# cleans up and shortens labels of the type "\\CIT-WSS-02\PhysicalDisk(_Total)\Disk Bytes/sec" 
{
    # remove computer name
    $nameString = $nameString -replace "\\\\[^\\]+\\", ""
    # remove (_Total) 
    $nameString = $nameString -replace "\(_Total\)", ""
    # remove parenthesis
    $nameString = $nameString -replace "\(([^\)]+)\)", ' $1'
    $nameString
}

function guessValueType ($nameString, $regexGauge)
# Guess the type of the value (GAUGE vs COUNTER) by looking for matches from $regexGauge in $nameString
{
    $regexGauge | ForEach-Object {
        If ($nameString -match ($_ -replace '\\', '\\')) {
            $result = "GAUGE"
            return 
        } # If ($nameString -match[...]
    } # $regexGauge | ForEach-Object

    # As a default, assume COUNTER
    If ($result -ne $null) { $result } Else { "COUNTER" }
}


Get-ChildItem -Path $perfCollectionsDir | Foreach-Object {
    $perfCollectionItem = $_
    $LatestDir = (Get-ChildItem -Path $perfCollectionItem.PSPath | Sort-Object LastAccessTime -Descending | Select-Object -First 1).PSPath
    $perfmonFile = (Get-ChildItem -Path $LatestDir | Sort-Object LastAccessTime -Descending | Select-Object -First 1).PSPath

    switch ($PluginAction) {
        "name" { [Console]::Out.Write("perfmon2munin") }
        "config" { printMuninConfig $perfmonFile $perfCollectionItem.Name  }
        default { printMuninValues $perfmonFile $perfCollectionItem.Name  }
    }
}

"."