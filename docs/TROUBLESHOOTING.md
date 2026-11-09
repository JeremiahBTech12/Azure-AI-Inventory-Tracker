# Deployment Troubleshooting Log

These are the real issues I hit while building the **AI Inventory Tracker**, in the order they happened, with the root cause and fix for each. They fall into four groups:

- **Platform limits (1–5):** region restrictions, quotas and eventual consistency in Azure Resource Manager.
- **Access and packaging (6–8):** the SQL firewall, cross-platform Python packages, and a CLI command that doesn't exist.
- **Runtime debugging (9–10):** a dead-lettered message traced to its cause once observability was added.
- **Integration (11–13):** wiring the Logic App to Azure OpenAI and email.

| # | Error | Resource | Root cause | Fix |
|---|-------|----------|------------|-----|
| 1 | `ProvisioningDisabled` | `azurerm_mssql_server.main` | Azure SQL can't be provisioned in **East US** for this subscription | Moved the deployment to **West US 3** |
| 2 | `Requested features 'Dynamic SKU, Linux Worker' not available in resource group` | `azurerm_service_plan.functions` | The resource group's App Service servers don't support Linux Consumption (Y1) plans | Removed the Y1 plan and ran the Function App on the existing B1 plan |
| 3 | `Operation cannot be completed without additional quota ... Current Limit (B1 VMs): 0` | `azurerm_service_plan.main` | App Service quota is set **per region**, and the chosen region had a B1 limit of 0 | Tested regions with a script and deployed to one where B1 and SQL both worked |
| 4 | `retrieving Storage Account ... 404 Not Found` | `azurerm_storage_account.functions` | Timing: Terraform read the account before Azure made it visible | Ran `terraform apply` again |
| 5 | `checking the parent namespace Queue ... 404 Not Found` | `azurerm_servicebus_queue.sale_events` | Timing: the queue was created before the new Service Bus namespace was visible | Ran `terraform apply` again |
| 6 | Client IP address not allowed (Query editor login) | `azurerm_mssql_server.main` | The SQL firewall only allowed Azure services, not your own computer | Added a firewall rule for your public IP |
| 7 | `Microsoft Visual C++ 14.0 or greater is required` (pyodbc) | Local `pip install` | pip tried to compile pyodbc for Windows / Python 3.14 | Downloaded prebuilt Linux / Python 3.11 wheels |
| 8 | `'message' is misspelled or not recognized` | `az servicebus message send` | The Azure CLI has no command for sending messages | Sent the test message with Service Bus Explorer in the portal, or through the REST API from PowerShell |
| 9 | Test sale dead-lettered (`MaxDeliveryCountExceeded`), stock unchanged | Function `process_sale` | `IndentationError` in `process_sale.py`, hidden because there was no Application Insights | Added Application Insights to see the error, fixed the indentation, and redeployed |
| 10 | `Login failed for user ''. (18456)` | `azurerm_key_vault_secret.db_connection` | The connection string used .NET keywords (`User ID`, `Password`), which the ODBC driver ignores | Changed to ODBC keywords `UID` / `PWD`, then applied and restarted the Function App |
| 11 | Logic App HTTP step: `404 Resource not found` | Logic App → HTTP action (Azure OpenAI) | The hand-typed OpenAI URI was malformed | Built the URI from the real endpoint in PowerShell, tested it, and pasted it into the Logic App |
| 12 | Every step green, but no email arrived | Logic App → Send an email (V2) | The Outlook connector was signed in with a Microsoft account that has no Outlook mailbox | Sent from a dedicated Outlook.com mailbox to a personal Yahoo inbox |
| 13 | Email body was the literal text `body('HTTP')?[...]` | Logic App → Send an email (V2) | The expression was typed as plain text, not inserted as an expression | Inserted it through the **fx** expression editor, so it shows as a token |

---

## 1. Azure SQL: `ProvisioningDisabled`

**Error**

```text
Error: creating Server ... Server Name: "sql-inventory-<name>"
Status: "ProvisioningDisabled"
Message: "Provisioning is restricted in this region. Please choose a different region..."
  with azurerm_mssql_server.main
```

**Cause**

East US is a high-demand region, and Azure often blocks new SQL servers there for some subscriptions. No change to the code fixes this. The only options are a different region or a support request.

**Fix**

Changed `location` in `terraform.tfvars` to **West US 3**. See issue 3 for how the region was chosen.

```hcl
location = "West US 3"
```

Changing the region forces every resource to be replaced, so the old partial deployment was removed first with `terraform destroy`.

---

## 2. Function App plan: `Dynamic SKU, Linux Worker not available`

**Error**

```text
Error: creating App Service Plan ... Server Farm Name: "asp-fn-inventory-<name>"
"Requested features 'Dynamic SKU, Linux Worker' not available in resource group rg-inventory-<name>.
 Please try using a different resource group or create a new one."
  with azurerm_service_plan.functions
```

**Cause**

When Azure creates the first App Service plan in a resource group, it places the group on a set of servers in that region. Here the B1 web app plan was created first, and its servers couldn't host a **Linux Consumption (Y1)** plan. Microsoft is also retiring Linux Consumption, which makes it less reliable to create.

**Fix**

Removed the separate Y1 plan and ran the Function App on the existing B1 plan. The B1 plan is already paid for, so this adds no cost.

- Deleted the `azurerm_service_plan.functions` resource.
- Pointed the Function App at the shared plan and turned on `always_on`. A dedicated (non-Consumption) plan needs `always_on` so the Service Bus trigger keeps listening.
- Removed app settings that the provider already sets or that conflicted with zip deployment.

```hcl
resource "azurerm_linux_function_app" "sale_processor" {
  # ...
  service_plan_id = azurerm_service_plan.main.id   # shared B1 plan

  site_config {
    always_on = true
    application_stack {
      python_version = "3.11"
    }
  }

  app_settings = {
    "SqlConnectionString"  = "@Microsoft.KeyVault(VaultName=kv-inventory-${var.yourname};SecretName=SqlConnectionString)"
    "ServiceBusConnection" = azurerm_servicebus_namespace.main.default_primary_connection_string
  }
  # ...
}
```

| Removed setting | Why |
|-----------------|-----|
| `FUNCTIONS_WORKER_RUNTIME` | The `application_stack` block already sets it |
| `AzureWebJobsStorage` | `storage_account_name` and `storage_account_access_key` already set it |
| `WEBSITE_RUN_FROM_PACKAGE = "1"` | Conflicts with the `az functionapp deployment source config-zip` deploy step |

**Related change: purge soft-deleted OpenAI accounts on destroy**

Azure keeps deleted Azure OpenAI (Cognitive Services) accounts in a soft-deleted state, and that blocks creating a new account with the same name. Because the region change meant destroying and recreating everything, this was added to the provider block:

```hcl
provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
    cognitive_account {
      purge_soft_delete_on_destroy = true
    }
  }
}
```

---

## 3. App Service plan: B1 quota is 0

**Error**

```text
Error: creating App Service Plan ... Server Farm Name: "asp-inventory-<name>"
unexpected status 401 (401 Unauthorized)
"Operation cannot be completed without additional quota.
 Current Limit (B1 VMs): 0  Current Usage: 0  Amount required for this deployment (B1 VMs): 1"
  with azurerm_service_plan.main
```

**What was checked**

1. **Subscription:** The account has more than one subscription (Pay-As-You-Go and a free tier). `az account list --output table` confirmed Terraform was already using Pay-As-You-Go, so the wrong subscription wasn't the cause.
2. **Quota page:** **Portal → Quotas → App Service** showed `0 of 30` B1 used, which seemed to contradict the error.

**Cause**

App Service quotas are set **per region**. The quota page showed a region with room, but the region in `terraform.tfvars` had a B1 limit of 0. On Pay-As-You-Go, Azure can set the limit to 0 in busy regions even when other regions have plenty of capacity.

**Fix**

Tested several regions for **both** B1 plans and SQL Server, using a temporary resource group that is deleted at the end. The B1 plans exist only for seconds, so they cost a fraction of a cent. An empty SQL server is free.

```powershell
$regions = "eastus2","centralus","westus2","westus3","northcentralus","southcentralus","canadacentral"
$pw = "Tst!" + [guid]::NewGuid().ToString("N").Substring(0,16)
az group create -n rg-region-test -l centralus --output none
foreach ($r in $regions) {
  az appservice plan create -g rg-region-test -n "asp-test-$r" --sku B1 --is-linux -l $r --output none 2>$null
  $b1 = if ($LASTEXITCODE -eq 0) { "OK" } else { "FAIL" }
  az sql server create -g rg-region-test -n "sqltest-$((Get-Random -Max 99999))-$r" -l $r -u sqladmin -p $pw --output none 2>$null
  $sql = if ($LASTEXITCODE -eq 0) { "OK" } else { "FAIL" }
  "{0,-16} B1: {1,-5} SQL: {2}" -f $r, $b1, $sql
}
az group delete -n rg-region-test --yes --no-wait
```

After that, `location` in `terraform.tfvars` was set to **West US 3**, which passed both checks, and the project was redeployed with `terraform destroy` followed by `terraform apply`.

**If every region fails:** use **Request increase** on the B1 row of **Portal → Quotas → App Service** for the region you want.

---

## 4. Storage account: `404 Not Found` while retrieving

**Error**

```text
Error: retrieving Storage Account ... Storage Account Name: "stfninventory<name>":
unexpected status 404 (404 Not Found) with error: ResourceNotFound
  with azurerm_storage_account.functions
```

**Cause**

A timing issue. Azure accepted the create request, but the account wasn't readable yet when Terraform checked for it.

**Fix**

Ran `terraform apply` again. If that instead reports that the account **already exists**, it was created but Terraform lost track of it, so import it into the state:

```bash
terraform import azurerm_storage_account.functions /subscriptions/<subscription-id>/resourceGroups/rg-inventory-<name>/providers/Microsoft.Storage/storageAccounts/stfninventory<name>
```

---

## 5. Service Bus queue: parent namespace `404 Not Found`

**Error**

```text
Error: checking the parent namespace Queue ... Namespace Name: "sbns-inventory-<name>" Queue Name: "sale-events":
unexpected status 404 (404 Not Found) with error: ResourceNotFound
  with azurerm_servicebus_queue.sale_events
```

**Cause**

A timing issue. Terraform created the queue right after the namespace, but a new Service Bus namespace can take a minute or two to become visible.

**Fix**

Waited a minute and ran `terraform apply` again, which worked.

If the error keeps coming back, check whether the namespace actually exists:

```bash
az servicebus namespace show -g rg-inventory-<name> -n sbns-inventory-<name> --query "{name:name, status:status}" -o table
```

| Result | Action |
|--------|--------|
| `Active` | Timing issue. Run `terraform apply` again |
| `Activating` / `Creating` | Wait until it says `Active`, then apply |
| Not found | The state is out of date. Run `terraform state rm azurerm_servicebus_namespace.main`, then `terraform apply` |

---

## 6. SQL Query editor: client IP address not allowed

**Error**

When logging in to **InventoryDB → Query editor** (Step 7), the portal said the client's IP address isn't allowed to access the server.

**Cause**

The Terraform config has only one firewall rule, `AllowAzureServices` (`0.0.0.0`). That rule lets Azure services such as the Function App and Logic App connect. The portal Query editor connects from **your own public IP**, which wasn't allowed.

**Fix (quick, in the portal)**

Use either method:

- On the Query editor login screen, click **Allowlist IP x.x.x.x on server**.
- Or go to **SQL server → Security → Networking → Add your client IPv4 address → Save**.

Wait 1–2 minutes for the rule to take effect, then log in.

**Fix (managed by Terraform)**

Add a rule for your IP to `main.tf`:

```hcl
variable "my_ip" {
  description = "Your public IP, for SQL Query editor access."
  type        = string
}

resource "azurerm_mssql_firewall_rule" "my_ip" {
  name             = "AllowMyIP"
  server_id        = azurerm_mssql_server.main.id
  start_ip_address = var.my_ip
  end_ip_address   = var.my_ip
}
```

Get your public IP and add it to `terraform.tfvars`:

```powershell
Invoke-RestMethod https://api.ipify.org
```

```hcl
my_ip = "<your public IP>"
```

**Gotcha: forgetting to declare the variable**

The first time, `my_ip` was added to `terraform.tfvars` but not to `main.tf`. Terraform printed this warning and planned no changes:

```text
Warning: Value for undeclared variable
The root module does not declare a variable named "my_ip" but a value was found in file "terraform.tfvars".
```

A value in `terraform.tfvars` does nothing unless a matching `variable` block exists. Adding the `variable` and `azurerm_mssql_firewall_rule` blocks above to `main.tf` (and saving the file) fixed it.

**Recurring issue: the IP changed the next day**

The next day the Query editor blocked logins again. Most home internet providers change your public IP from time to time, so the `AllowMyIP` rule pointed at the old address. Updating `my_ip` and running `terraform apply` again fixed it.

To skip editing `terraform.tfvars`, look up the current IP and pass it in one command:

```powershell
terraform apply -var "my_ip=$(Invoke-RestMethod https://api.ipify.org)"
```

A value passed with `-var` overrides the one in `terraform.tfvars`. Run this before every demo so a changed IP doesn't block you mid-walkthrough.

> The Query editor's **Allowlist IP** link is faster, but Terraform doesn't track the rules it creates, so old IPs pile up on the server. The Terraform rule replaces the old IP instead.

---

## 7. pip: pyodbc fails to build (`Microsoft Visual C++ 14.0 or greater is required`)

**Error**

```text
Building wheel for pyodbc (pyproject.toml) ... error
error: Microsoft Visual C++ 14.0 or greater is required.
ERROR: Failed building wheel for pyodbc
```

**Cause**

`pip install` downloads packages for the computer it runs on. Here that was Windows with Python 3.14. pyodbc 4.0.39 has no prebuilt package (wheel) for Python 3.14, so pip tried to compile it from source, which needs the C++ build tools. A Windows build wouldn't have worked anyway, because the Function App runs on **Linux with Python 3.11**.

**Fix**

Downloaded prebuilt Linux packages for the Function App's Python version instead:

```powershell
Remove-Item -Recurse -Force .python_packages -ErrorAction SilentlyContinue
pip install -r requirements.txt `
  --target .python_packages\lib\site-packages `
  --platform manylinux2014_x86_64 `
  --only-binary=:all: `
  --python-version 3.11
```

`--python-version` must match `python_version` in the Function App's `application_stack`.

---

## 8. Sending a test message: `'message' is misspelled or not recognized`

**Error**

```text
PS> az servicebus message send --resource-group ... --queue-name sale-events --body '{...}'
'message' is misspelled or not recognized by the system.
```

**Cause**

The guide's Step 9 uses `az servicebus message send`, which doesn't exist. The Azure CLI can manage Service Bus namespaces and queues, but it can't send messages to them.

**Fix (portal)**

1. Go to **Service Bus namespace → Queues → sale-events → Service Bus Explorer**.
2. Click **Send messages** and set **Content type** to `application/json`.
3. Paste `{"sale_id":"TEST-001","product_id":1,"quantity":2}` as the body and click **Send**.

**Fix (PowerShell, using the Service Bus REST API)**

```powershell
$rg = "rg-inventory-<name>"; $ns = "sbns-inventory-<name>"; $q = "sale-events"
$keyName = "RootManageSharedAccessKey"
$key = az servicebus namespace authorization-rule keys list -g $rg --namespace-name $ns -n $keyName --query primaryKey -o tsv

$uri    = "https://$ns.servicebus.windows.net/$q"
$encUri = [uri]::EscapeDataString($uri)
$expiry = [DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeSeconds()
$hmac   = New-Object System.Security.Cryptography.HMACSHA256
$hmac.Key = [Text.Encoding]::UTF8.GetBytes($key)
$sig    = [uri]::EscapeDataString([Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("$encUri`n$expiry"))))
$token  = "SharedAccessSignature sr=$encUri&sig=$sig&se=$expiry&skn=$keyName"

Invoke-RestMethod -Method Post -Uri "$uri/messages" `
  -Headers @{ Authorization = $token } `
  -ContentType "application/json" `
  -Body '{"sale_id":"TEST-001","product_id":1,"quantity":2}'
```

If nothing prints, the message was sent (Service Bus answers with `201 Created` and an empty body).

---

## 9. Test sale dead-lettered: `MaxDeliveryCountExceeded`

**Symptom**

After the Step 9 test message was sent, Laptop stock stayed at 15. The `sale-events` queue showed **Dead-letter = 1**, and the dead-lettered message's `DeadLetterReason` was `MaxDeliveryCountExceeded`.

**What that means**

The Function received the message but failed on all 3 tries (`max_delivery_count = 3`), so Service Bus moved the message to the dead-letter queue. The reason only says *that* it failed, not *why*. Nothing was lost: dead-lettering is the safety net working as designed.

**Diagnosis steps**

1. **Checked the Key Vault reference.** Under **Function App → Settings → Environment variables**, `SqlConnectionString` showed a green check, so the Function could read the secret.
2. **Restarted the Function App.** Key Vault references are cached for up to 24 hours. After the secret changes (here, adding `Driver=`), a restart makes the Function fetch the new value:
   ```bash
   az functionapp restart -g rg-inventory-<name> -n func-inventory-<name>
   ```
3. **Added Application Insights.** The original Terraform had no Application Insights, so the Function's errors weren't recorded anywhere and **Monitor → Invocations** was empty:
   ```hcl
   resource "azurerm_application_insights" "main" {
     name                = "appi-inventory-${var.yourname}"
     location            = var.location
     resource_group_name = azurerm_resource_group.main.name
     workspace_id        = azurerm_log_analytics_workspace.main.id
     application_type    = "web"
     tags                = var.tags
   }
   ```
   And in the Function App's `site_config`:
   ```hcl
   application_insights_connection_string = azurerm_application_insights.main.connection_string
   ```

**Actual error (found in Monitor → Invocations)**

```text
Exception: IndentationError: unexpected indent (process_sale.py, line 38)
  File "/home/site/wwwroot/process_sale/process_sale.py", line 38
    cursor.execute ("""
```

**Cause**

When the code was copied from the guide, the indentation got broken, most likely a mix of tabs and spaces. Python couldn't load the file, so every message failed before any database code ran.

**Fix**

1. Replaced `process_sale.py` with a correctly indented copy, using 4 spaces per level and no tabs.
2. Checked the syntax locally **before** deploying:
   ```powershell
   python -m py_compile function_app\process_sale\process_sale.py
   ```
   No output means the file compiles.
3. Rebuilt the zip, redeployed, and sent a new test message.

**Lesson:** run `python -m py_compile` before every deploy. It catches syntax errors in seconds, instead of after a deploy, three retries and a dead-lettered message.

---

## 10. Function: `Login failed for user ''`

**Error (from Function App → process_sale → Monitor)**

```text
pyodbc.InterfaceError: ('28000', "[28000] [Microsoft][ODBC Driver 18 for SQL Server][SQL Server]
Login failed for user ''. (18456) (SQLDriverConnect)")
  File "/home/site/wwwroot/process_sale/process_sale.py", line 22, in main
    conn = pyodbc.connect(conn_str)
```

**Cause**

The user name in the error is **empty** (`''`). The guide's connection string uses .NET-style keywords (`User ID=...;Password=...`), but `pyodbc` passes the string to the **ODBC** driver, which expects `UID=` and `PWD=`. The driver silently ignored the keywords it didn't recognize and tried to log in with no user name.

This error was also useful progress. It showed that the Key Vault reference, ODBC Driver 18, the network and the SQL firewall all worked, and that only the login details were wrong.

**Fix**

Changed the Key Vault secret value in `main.tf` to use ODBC keywords. The password is wrapped in `{}` so special characters like `;` can't break the string:

```hcl
resource "azurerm_key_vault_secret" "db_connection" {
  name         = "SqlConnectionString"
  key_vault_id = azurerm_key_vault.main.id
  value        = "Driver={ODBC Driver 18 for SQL Server};Server=tcp:sql-inventory-${var.yourname}.database.windows.net,1433;Database=InventoryDB;UID=${var.sql_admin_login};PWD={${var.sql_admin_password}};Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"

  depends_on = [azurerm_role_assignment.kv_admin_self]
}
```

Then applied the change and restarted the Function App so it stopped using its cached copy of the Key Vault secret:

```powershell
terraform apply -var "my_ip=$(Invoke-RestMethod https://api.ipify.org)"
az functionapp restart -g rg-inventory-<name> -n func-inventory-<name>
```

| .NET / ADO.NET keyword | ODBC keyword |
|---|---|
| `User ID` | `UID` |
| `Password` | `PWD` |
| `Encrypt=True` | `Encrypt=yes` |
| *(none, built in)* | `Driver={ODBC Driver 18 for SQL Server}` |

**Result**

Test message `TEST-005` was processed on the first try, and Laptop stock dropped from **15 to 13**. The end-to-end flow (Service Bus → Function → Azure SQL) works.

> The earlier failed test messages (`TEST-001` to `TEST-004`) stay in the dead-letter queue as a record of the failures. Don't resubmit them. Each one would subtract another 2 laptops.

---

## 11. Logic App → Azure OpenAI: `404 Resource not found`

**Error (HTTP step output in Run history)**

```json
{
  "statusCode": 404,
  "body": { "error": { "code": "404", "message": "Resource not found" } }
}
```

**Cause**

The request reached Azure OpenAI, so the API key was accepted (a bad key returns `401`). But the URI didn't match any route. Azure OpenAI's two kinds of 404 mean different things:

| Message | Meaning |
|---|---|
| `DeploymentNotFound` | The URI is well formed, but the deployment name doesn't exist |
| `Resource not found` | The URI itself is malformed: a wrong endpoint, a double slash, a missing `/openai/`, a typo in `chat/completions`, or a missing or wrong `api-version` |

Turning on **Secure outputs** on the HTTP step hides the response body. Turn it off temporarily while debugging.

**Fix**

Built the URI from the account's real endpoint and tested it outside the Logic App:

```powershell
$ep  = az cognitiveservices account show -g rg-inventory-<name> -n oai-inventory-<name> --query properties.endpoint -o tsv
$key = az cognitiveservices account keys list -g rg-inventory-<name> -n oai-inventory-<name> --query key1 -o tsv
$uri = "${ep}openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-10-21"
$uri
Invoke-RestMethod -Method Post -Uri $uri -Headers @{ "api-key" = $key } -ContentType "application/json" `
  -Body '{"messages":[{"role":"user","content":"Say hello"}]}' | Select-Object -ExpandProperty choices
```

The test returned a reply, so the printed `$uri` was copied into the Logic App's HTTP **URI** field exactly as printed.

**Lesson:** test an API call with a small script before wiring it into a workflow. If the script works and the workflow doesn't, you know the problem is in how the workflow was set up.

---

## 12. Logic App email: all steps green, but no email received

**Symptom**

Every step in Run history showed a green check, including **Send an email (V2)**, but nothing arrived in the inbox, Spam or Promotions.

**Cause**

The **Outlook.com** and **Office 365 Outlook** connectors send *from* an Outlook mailbox. The connection was signed in with a Microsoft account registered under a Gmail address, which has no Outlook mailbox behind it.

**Fix**

1. Created a free Outlook.com address used only for sending alerts, and signed in once to complete verification.
2. In the email step, used **Change connection → Add new** and signed in with the new Outlook account.
3. Set **To** to a personal Yahoo (ymail) address. The connector can send *to* any provider; only the *sending* account has to be an Outlook mailbox.

**Why not the Gmail connector?** Google restricts personal Gmail accounts in Logic Apps. The Gmail connector can only be used in workflows whose other steps are Google-approved services or certain built-in actions. This workflow uses the **SQL Server** connector, so a Gmail step would be blocked.

---

## 13. Logic App email body shows the expression text

**Symptom**

The email arrived, but its body was literally:

```text
body('HTTP')?['choices']?[0]?['message']?['content']
```

**Cause**

The expression was typed into the Body field as plain text, so Logic Apps sent it word for word instead of running it.

**Fix**

Deleted the text, opened the expression editor (the **fx** icon, or type `/` → **Insert expression**), pasted the expression there, and clicked **Add**. The Body then showed a colored **token** instead of text. Another way that works is to paste `@{body('HTTP')?['choices']?[0]?['message']?['content']}`; the `@{ }` tells Logic Apps to evaluate it.

**Result**

The workflow ran end to end: Recurrence → SQL query → Azure OpenAI → email. The AI's restock recommendations arrived in the Yahoo inbox.

---

## Lessons learned

- **Don't assume East US works.** It's the most restricted region for new SQL and App Service deployments. Check that the services you need are available before choosing a region.
- **Quotas are per region.** A quota page showing room in one region says nothing about another.
- **`404` right after a create is usually a timing issue.** Run `terraform apply` again before you start debugging.
- **Check `az account show`** before deploying when the account has more than one subscription.
- **Add Application Insights from day one.** Without it, Function failures only show up as dead-lettered messages with no error details.
- **Compile Python before you deploy** with `python -m py_compile`.
- **A green check doesn't mean it worked as intended.** Check a step's actual inputs and outputs in Run history, not just its status.
- **Home IPs change.** Re-apply the SQL firewall rule with your current IP before each session or demo.
- **Changing the region replaces everything.** Run `terraform destroy` first, and make sure soft-delete purge is turned on for Key Vault and Cognitive Services so names can be reused.

## Notes

- `azure-functions` is intentionally **not** in `function_app/requirements.txt`. The Functions host provides it, and bundling your own copy can conflict with the host's version.
- The Function build-and-deploy steps from issues 7 and 9 are automated in [`scripts/deploy_function.ps1`](../scripts/deploy_function.ps1). The test message from issue 8 is automated in [`scripts/send_test_sale.ps1`](../scripts/send_test_sale.ps1).
