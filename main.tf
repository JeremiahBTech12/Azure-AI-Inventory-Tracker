terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
    # Azure OpenAI accounts are soft-deleted on destroy; purge so the name can be reused.
    cognitive_account {
      purge_soft_delete_on_destroy = true
    }
  }
}

data "azurerm_client_config" "current" {}

# ---------------------------------------------------------------------------
# Resource group
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "main" {
  name     = "rg-inventory-${var.yourname}"
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Key Vault (RBAC mode) - holds the SQL, Service Bus and OpenAI secrets
# ---------------------------------------------------------------------------
resource "azurerm_key_vault" "main" {
  name                       = "kv-inventory-${var.yourname}"
  location                   = var.location
  resource_group_name        = azurerm_resource_group.main.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  soft_delete_retention_days = 7
}

# Lets the identity running Terraform write secrets.
resource "azurerm_role_assignment" "kv_admin_self" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ---------------------------------------------------------------------------
# Azure SQL - InventoryDB (Products, Suppliers, StockMovements)
# ---------------------------------------------------------------------------
resource "azurerm_mssql_server" "main" {
  name                         = "sql-inventory-${var.yourname}"
  resource_group_name          = azurerm_resource_group.main.name
  location                     = var.location
  version                      = "12.0"
  administrator_login          = var.sql_admin_login
  administrator_login_password = var.sql_admin_password
  minimum_tls_version          = "1.2"
  tags                         = var.tags
}

# 0.0.0.0 is Azure's special value for "allow Azure services" (Function App, Logic App).
resource "azurerm_mssql_firewall_rule" "allow_azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Your workstation's public IP, for the portal Query editor. Refresh with:
#   terraform apply -var "my_ip=$(Invoke-RestMethod https://api.ipify.org)"
resource "azurerm_mssql_firewall_rule" "my_ip" {
  name             = "AllowMyIP"
  server_id        = azurerm_mssql_server.main.id
  start_ip_address = var.my_ip
  end_ip_address   = var.my_ip
}

resource "azurerm_mssql_database" "inventory" {
  name      = "InventoryDB"
  server_id = azurerm_mssql_server.main.id
  sku_name  = "Basic"
  tags      = var.tags
}

# ODBC-style connection string (UID/PWD, not .NET's User ID/Password) because the
# Function connects with pyodbc. Password is wrapped in {} so special characters are safe.
resource "azurerm_key_vault_secret" "db_connection" {
  name         = "SqlConnectionString"
  key_vault_id = azurerm_key_vault.main.id
  value        = "Driver={ODBC Driver 18 for SQL Server};Server=tcp:sql-inventory-${var.yourname}.database.windows.net,1433;Database=InventoryDB;UID=${var.sql_admin_login};PWD={${var.sql_admin_password}};Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"

  depends_on = [azurerm_role_assignment.kv_admin_self]
}

# ---------------------------------------------------------------------------
# Service Bus - buffers sale events between the POS and the inventory system
# ---------------------------------------------------------------------------
resource "azurerm_servicebus_namespace" "main" {
  name                = "sbns-inventory-${var.yourname}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_servicebus_queue" "sale_events" {
  name         = "sale-events"
  namespace_id = azurerm_servicebus_namespace.main.id

  max_size_in_megabytes = 1024
  lock_duration         = "PT1M" # message is locked for 1 minute while the Function processes it
  max_delivery_count    = 3      # after 3 failed attempts, the message moves to the dead-letter queue
}

resource "azurerm_key_vault_secret" "servicebus_connection" {
  name         = "ServiceBusConnection"
  key_vault_id = azurerm_key_vault.main.id
  value        = azurerm_servicebus_namespace.main.default_primary_connection_string

  depends_on = [azurerm_role_assignment.kv_admin_self]
}

# ---------------------------------------------------------------------------
# Azure OpenAI - generates the daily restock recommendations
# ---------------------------------------------------------------------------
resource "azurerm_cognitive_account" "openai" {
  name                = "oai-inventory-${var.yourname}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  kind                = "OpenAI"
  sku_name            = "S0"

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

resource "azurerm_cognitive_deployment" "gpt4o_mini" {
  name                 = "gpt-5-mini"
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = "gpt-5-mini"
    version = "2025-08-07"
  }

  scale {
    type     = "GlobalStandard"
    capacity = 10
  }
}

resource "azurerm_key_vault_secret" "openai_key" {
  name         = "OpenAIApiKey"
  key_vault_id = azurerm_key_vault.main.id
  value        = azurerm_cognitive_account.openai.primary_access_key

  depends_on = [azurerm_role_assignment.kv_admin_self]
}

resource "azurerm_key_vault_secret" "openai_endpoint" {
  name         = "OpenAIEndpoint"
  key_vault_id = azurerm_key_vault.main.id
  value        = azurerm_cognitive_account.openai.endpoint

  depends_on = [azurerm_role_assignment.kv_admin_self]
}

# ---------------------------------------------------------------------------
# App Service plan (B1) - shared by the Web App and the Function App
# ---------------------------------------------------------------------------
resource "azurerm_service_plan" "main" {
  name                = "asp-inventory-${var.yourname}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "B1"
  tags                = var.tags
}

resource "azurerm_linux_web_app" "inventory_app" {
  name                = "app-inventory-${var.yourname}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  service_plan_id     = azurerm_service_plan.main.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.11"
    }
  }

  app_settings = {
    "KEY_VAULT_URI"        = azurerm_key_vault.main.vault_uri
    "SERVICEBUS_NAMESPACE" = azurerm_servicebus_namespace.main.name
    "SERVICEBUS_QUEUE"     = azurerm_servicebus_queue.sale_events.name
  }

  tags = var.tags
}

resource "azurerm_role_assignment" "app_kv_reader" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_web_app.inventory_app.identity[0].principal_id
}

# ---------------------------------------------------------------------------
# Function App - processes each sale event from the queue
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "functions" {
  name                     = "stfninventory${var.yourname}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = var.tags
}

resource "azurerm_linux_function_app" "sale_processor" {
  name                       = "func-inventory-${var.yourname}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = var.location
  storage_account_name       = azurerm_storage_account.functions.name
  storage_account_access_key = azurerm_storage_account.functions.primary_access_key
  service_plan_id            = azurerm_service_plan.main.id # shared B1 plan (Linux Consumption was unavailable)

  site_config {
    always_on                              = true # required on a dedicated plan so the queue trigger keeps listening
    application_insights_connection_string = azurerm_application_insights.main.connection_string

    application_stack {
      python_version = "3.11"
    }
  }

  app_settings = {
    # Key Vault reference, resolved at runtime with the Function's managed identity.
    "SqlConnectionString"  = "@Microsoft.KeyVault(VaultName=kv-inventory-${var.yourname};SecretName=SqlConnectionString)"
    "ServiceBusConnection" = azurerm_servicebus_namespace.main.default_primary_connection_string
  }

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

resource "azurerm_role_assignment" "func_kv_reader" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_function_app.sale_processor.identity[0].principal_id
}

# ---------------------------------------------------------------------------
# Logic App - daily AI restock analysis and email
# The workflow itself was built in the designer; its definition is in logic_app/workflow.json.
# ---------------------------------------------------------------------------
resource "azurerm_logic_app_workflow" "daily_recommendations" {
  name                = "la-restock-daily-${var.yourname}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-inventory-${var.yourname}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_application_insights" "main" {
  name                = "appi-inventory-${var.yourname}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"
  tags                = var.tags
}
