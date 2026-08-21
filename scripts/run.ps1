<#
  Reverts the test VM to a clean checkpoint, boots it, and runs the playbook.
  Run from the Hyper-V host.
    .\run.ps1
    .\run.ps1 -Tags detect
    .\run.ps1 -Profile profiles/nvidia-desktop-v4.json
#>
param(
  [string]$VMName     = "NyxOS-Test",
  [string]$Checkpoint = "base-install",
  [string]$SshTarget  = "nyx@nyxos-test",
  [string]$Tags       = "",
  [string]$Profile    = ""
)

$ErrorActionPreference = "Stop"

Write-Host "==> reverting $VMName to '$Checkpoint'" -ForegroundColor Cyan
Restore-VMCheckpoint -VMName $VMName -Name $Checkpoint -Confirm:$false
Start-VM -Name $VMName

Write-Host "==> waiting for sshd" -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes(3)
do {
  Start-Sleep -Seconds 5
  $up = Test-NetConnection -ComputerName ($SshTarget -split '@')[1] `
        -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
} until ($up -or (Get-Date) -gt $deadline)
if (-not $up) { throw "VM never came up on port 22" }

$args = @()
if ($Tags)    { $args += "--tags $Tags" }
if ($Profile) { $args += "-e @$Profile" }

$cmd = "cd ~/nyxos-installer && git pull --ff-only && " +
       "ansible-playbook site.yml $($args -join ' ') --ask-become-pass"

Write-Host "==> $cmd" -ForegroundColor Cyan
ssh -t $SshTarget $cmd
