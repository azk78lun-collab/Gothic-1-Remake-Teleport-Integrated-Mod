[CmdletBinding()]
param([string]$OutputDirectory = "")

$ErrorActionPreference = "Stop"

foreach ($component in @("TeleportCppBridge", "PlayerEditCppBridge", "TeleportUiNative")) {
    & (Join-Path $PSScriptRoot "Build-NativeComponent.ps1") `
        -Component $component `
        -OutputDirectory $OutputDirectory
}

