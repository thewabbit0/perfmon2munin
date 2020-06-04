# Description
a Powershell wrapper to evaluate Perfmon-recorded CSV-data and turn it into Munin-readable 
multigraph / supersampling format.

# Features
- high sampling rate 
  - one data point every 15 seconds with the defaults
  - configurable down to the minimum 1-second-interval supported by Munin
  - configurable for Munin collection intervals of longer than once per 5 minutes, retaining the high data resolution
- multiple datalines in one graph
- configurable scaling
- pre-defined collection templates

Get high-resolution data into Munin now!

| perfmon2munin collected disk performance data | vs | Munin Node for Windows native disk performance plugin |
|-------|-------|
| ![perfmon2munin collected disk performance data](img/munin-perfmon.png =400x) | | ![perfmon2munin collected disk performance data](img/munin-disktime.png =400x) |

# Requirements
Requires a configured recent version of _Munin Node for Windows_ 

# Installation
Running `install.bat` with administrative privileges will 
- copy the plugin scripts and configuration files to `C:\Program Files\Munin-Node-Plugins\perfmon2munin`
- register the external plugin _"perfmon2munin"_ in _munin-node.ini_
- use the sample data collector sets from the _Perfmon-Templates_ directory to set up 
  data collection for a number of services (if present on the machine)


# Configuration
The plugin uses two additional configuration files to draw definitions from:

## perfmon2munin-viewscale.conf
contains a single JSON key:value hashtable where 
"key" is the perfmon value name to define a viewscale for and "value" is the
unit multiplier to use for Munin data display.

Example:

    {
           "PhysicalDisk(_Total)\\Disk Bytes/sec":  "1e-6"
    }
would configure a CDEF multiplying the values provided with 10^-6, effectively 
showing them as Megabytes in Munin graphs. Note that the transmitted data itself
is unaffected by this definition - it still would contain the raw byte value.

"Nice" SI metric prefix names (like "milliunits" or "Teraunits") are defined for a number of scale definitions and appended to the
counter descriptions in Munin.

## perfmon2munin-gauges.conf
contains a JSON array with a number of string
entries defining whether counters should be interpreted as point-in-time GAUGEs instead of
as ever-incremented COUNTERs, where delta values between measurements are calculated 
and normalized by the time passed inbetween measurements. The default is to 
return all data as COUNTERs, except for those counter names regex-matched by one 
of the entries in the $regexGaugePath file.

# Author
Denis Jedig

on behalf of: Cologne University of Applied Sciences (TH Köln), Germany

2017-02-20
