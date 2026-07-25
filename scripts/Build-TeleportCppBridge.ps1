[CmdletBinding()]
param([string]$OutputDirectory = "")

& (Join-Path $PSScriptRoot "Build-NativeComponent.ps1") `
    -Component TeleportCppBridge `
    -OutputDirectory $OutputDirectory

