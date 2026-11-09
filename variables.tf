variable "yourname" {
  description = "Short, lowercase, letters/numbers only. Used in globally unique resource names (storage account max 24 chars)."
  type        = string
}

variable "location" {
  description = "Azure region. East US was blocked for SQL and lacked App Service quota on this subscription; West US 3 worked."
  type        = string
  default     = "West US 3"
}

variable "sql_admin_login" {
  description = "SQL Server administrator login."
  type        = string
  default     = "sqladmin"
}

variable "sql_admin_password" {
  description = "SQL Server administrator password. Set in terraform.tfvars (git-ignored)."
  type        = string
  sensitive   = true
}

variable "alert_email" {
  description = "Email address to receive daily restock recommendations."
  type        = string
}

variable "my_ip" {
  description = "Your public IPv4 address, allowed through the SQL firewall for the portal Query editor."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    project    = "inventory-tracker"
    managed_by = "terraform"
  }
}
