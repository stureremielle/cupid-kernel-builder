# Prints the kernel release suffix of the connected phone.
# Use the value with:  ./build.sh --localversion '<suffix>'
#
# Run from Windows PowerShell (WSL2 usually cannot see the phone over USB
# unless usbipd-win is configured).

$ErrorActionPreference = "Stop"

$rel = (& adb shell uname -r 2>$null | Out-String).Trim()
if (-not $rel) {
    Write-Error "Could not read 'uname -r'. Is the phone connected and authorized? (adb devices)"
}

$suffix = $rel -replace '^\d+\.\d+\.\d+', ''
Write-Host "Phone kernel release : $rel"
Write-Host "Use with the builder : --localversion '$suffix'"
Write-Host "Expected in dist     : $rel"
