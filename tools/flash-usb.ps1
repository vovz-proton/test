param(
  [string]$File = 'build/Prof_KIP_v5.hex',
  [int]$SendTimeoutSec = 240,
  [int]$VerifySec = 30
)
# Compatibility entry point: BT now uses COM upload, not factory DFU.
& (Join-Path $PSScriptRoot 'upload-com.ps1') @PSBoundParameters