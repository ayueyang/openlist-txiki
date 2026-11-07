# Unseal the signing passphrase from a DPAPI (CurrentUser) blob into a file.
# Never prints the secret and never prints a hash of the secret.
# Usage:
#   powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File signing-unseal.ps1 `
#     -Blob <path to pass.dpapi> -Out <path to temp passphrase file>
# Then:
#   openssl rsa -in openlist-txiki.rsa -passin file:<temp file> -check -noout
# Delete the temp file right after use.
param(
  [Parameter(Mandatory=$true)][string]$Blob,
  [Parameter(Mandatory=$true)][string]$Out
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$enc = [System.IO.File]::ReadAllBytes($Blob)
$plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
  $enc, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
if ($null -eq $plain -or $plain.Length -eq 0) { throw 'UNSEAL_EMPTY' }
[System.IO.File]::WriteAllBytes($Out, $plain)

$acl = Get-Acl $Out
$acl.SetAccessRuleProtection($true, $false)
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
  $me, 'FullControl', 'Allow')
$acl.SetAccessRule($rule)
Set-Acl -Path $Out -AclObject $acl

Write-Output ("UNSEAL out={0} bytes={1}" -f $Out, $plain.Length)
[Array]::Clear($plain, 0, $plain.Length)
$plain = $null; $enc = $null
