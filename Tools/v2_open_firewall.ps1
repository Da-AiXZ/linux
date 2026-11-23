# v2 device loop -- one-time firewall opening.
#
# The workstation's Wi-Fi is classified "Public" by Windows, and the Public
# profile blocks every inbound connection by default.  That is why the app
# could not upload: it never reached this machine, not even discovery.
#
# Run this once, as administrator (right-click -> Run with PowerShell, or the
# assistant launches it with a UAC prompt).  It only opens the three ports the
# device loop uses, for every profile, and nothing else.
#
#   TCP 8765  log upload / command poll
#   UDP 8766  discovery ("V2DISCOVER" -> "V2LOG <port> <addresses>")
#   UDP 8767  beacon (server announces itself every 2 s)

$ErrorActionPreference = "Stop"

$rules = @(
    @{ Name = "v2 log tcp"; Protocol = "TCP"; Ports = "8765" },
    @{ Name = "v2 log udp"; Protocol = "UDP"; Ports = "8766,8767" }
)

foreach ($rule in $rules) {
    Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $rule.Name `
        -Direction Inbound `
        -Protocol $rule.Protocol `
        -LocalPort $rule.Ports `
        -Action Allow `
        -Profile Any | Out-Null
    Write-Host ("added: {0} {1}/{2}" -f $rule.Name, $rule.Protocol, $rule.Ports)
}

Write-Host ""
Write-Host "listening check:"
Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue |
    Select-Object LocalAddress, LocalPort, OwningProcess |
    Format-Table -AutoSize | Out-String | Write-Host
Write-Host "done -- the device can reach this workstation now."
