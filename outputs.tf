output "web_app_url" {
  value = "https://${azurerm_linux_web_app.inventory_app.default_hostname}"
}

output "function_app_name" {
  value = azurerm_linux_function_app.sale_processor.name
}

output "sql_server_fqdn" {
  value = azurerm_mssql_server.main.fully_qualified_domain_name
}

output "servicebus_namespace" {
  value = azurerm_servicebus_namespace.main.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.main.vault_uri
}
