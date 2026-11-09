<#
.SYNOPSIS
    Builds and deploys the sale-processor Azure Function (Python 3.11, Linux).

.DESCRIPTION
    1. Installs dependencies as prebuilt *Linux* wheels for Python 3.11, even on Windows
       (pyodbc won't compile locally without the C++ build tools, and a Windows build
       wouldn't run on the Linux Function host anyway).
    2. Checks the function code for syntax errors before shipping it.
    3. Zips with tar, because Windows PowerShell 5.1's Compress-Archive writes
       backslash paths that the Linux host can't read as folders.
    4. Zip-deploys and lists the functions the host discovered.

.EXAMPLE
    .\scripts\deploy_function.ps1 -Name jeremiah
#>
param(
    [Parameter(Mandatory)] [string] $Name,
    [string] $PythonVersion = "3.11"
)

$ErrorActionPreference = "Stop"
$root  = Split-Path -Parent $PSScriptRoot
$app   = Join-Path $root "function_app"
$zip   = Join-Path $root "function_deploy.zip"
$rg    = "rg-inventory-$Name"
$func  = "func-inventory-$Name"

Push-Location $app
try {
    Write-Host "==> Installing Linux wheels for Python $PythonVersion" -ForegroundColor Cyan
    Remove-Item -Recurse -Force .python_packages -ErrorAction SilentlyContinue
    pip install -r requirements.txt `
        --target .python_packages\lib\site-packages `
        --platform manylinux2014_x86_64 `
        --only-binary=:all: `
        --python-version $PythonVersion
    if ($LASTEXITCODE -ne 0) { throw "pip install failed" }

    Write-Host "==> Syntax check" -ForegroundColor Cyan
    python -m py_compile process_sale\process_sale.py
    if ($LASTEXITCODE -ne 0) { throw "process_sale.py has a syntax error" }

    Write-Host "==> Packaging $zip" -ForegroundColor Cyan
    Remove-Item $zip -ErrorAction SilentlyContinue
    tar -a -c -f $zip host.json requirements.txt process_sale .python_packages
    if ($LASTEXITCODE -ne 0) { throw "tar failed" }
}
finally {
    Pop-Location
}

Write-Host "==> Deploying to $func" -ForegroundColor Cyan
az functionapp deployment source config-zip --resource-group $rg --name $func --src $zip --output none
if ($LASTEXITCODE -ne 0) { throw "Deployment failed" }

Write-Host "==> Functions discovered by the host:" -ForegroundColor Cyan
az functionapp function list -g $rg -n $func --query "[].name" -o tsv
