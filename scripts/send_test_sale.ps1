<#
.SYNOPSIS
    Simulates a point-of-sale system by publishing a sale event to the Service Bus queue.

.DESCRIPTION
    The Azure CLI can manage Service Bus but cannot send messages, so this script calls the
    Service Bus REST API directly with a short-lived SAS token. The POS side never talks to
    the database; it only drops an event on the queue. That decoupling is the point of the design.

.EXAMPLE
    .\scripts\send_test_sale.ps1 -Name jeremiah -ProductId 1 -Quantity 2
#>
param(
    [Parameter(Mandatory)] [string] $Name,
    [int]    $ProductId = 1,
    [int]    $Quantity  = 1,
    [string] $SaleId    = ("POS-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
)

$ErrorActionPreference = "Stop"
$rg      = "rg-inventory-$Name"
$ns      = "sbns-inventory-$Name"
$queue   = "sale-events"
$keyName = "RootManageSharedAccessKey"

$key = az servicebus namespace authorization-rule keys list -g $rg --namespace-name $ns -n $keyName --query primaryKey -o tsv
if (-not $key) { throw "Could not read the Service Bus key. Are you logged in with az login?" }

# Build a SAS token valid for 10 minutes
$uri    = "https://$ns.servicebus.windows.net/$queue"
$encUri = [uri]::EscapeDataString($uri)
$expiry = [DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeSeconds()
$hmac   = New-Object System.Security.Cryptography.HMACSHA256
$hmac.Key = [Text.Encoding]::UTF8.GetBytes($key)
$sig    = [uri]::EscapeDataString([Convert]::ToBase64String(
            $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("$encUri`n$expiry"))))
$token  = "SharedAccessSignature sr=$encUri&sig=$sig&se=$expiry&skn=$keyName"

$body = @{ sale_id = $SaleId; product_id = $ProductId; quantity = $Quantity } | ConvertTo-Json -Compress

Invoke-RestMethod -Method Post -Uri "$uri/messages" `
    -Headers @{ Authorization = $token } `
    -ContentType "application/json" `
    -Body $body | Out-Null

Write-Host "Sent sale event to ${queue}: $body" -ForegroundColor Green
