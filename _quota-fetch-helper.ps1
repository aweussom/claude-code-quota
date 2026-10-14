#
# _quota-fetch-helper.ps1 — Background fetch worker for quota-lib.ps1
#
# This script is launched by Invoke-QuotaGet via Start-Process when the cache
# is stale.  It must NOT be run directly.
#
# It dot-sources quota-lib.ps1 (from the same directory), calls
# Invoke-QuotaFetchOnce, then removes the lock file.

#Requires -Version 7.0

$libPath = Join-Path $PSScriptRoot "quota-lib.ps1"
if (Test-Path $libPath -PathType Leaf) {
    . $libPath
} else {
    exit 1
}

Invoke-QuotaFetchOnce

# Not the hardcoded Anthropic path: Invoke-QuotaFetchOnce points $_QL_Lock at
# the provider this session spends, and an Ollama session locks a different file.
Remove-Item $script:_QL_Lock -ErrorAction SilentlyContinue
