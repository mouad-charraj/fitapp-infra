variable "project" {
  description = "Short project name, used in resource names."
  type        = string
  default     = "fitapp"
}

variable "location" {
  description = "Azure region. Azure for Students allows: swedencentral, francecentral, germanywestcentral, polandcentral, norwayeast."
  type        = string
  default     = "swedencentral"
}

variable "budget_amount" {
  description = "Monthly budget in USD for the alert e-mails."
  type        = number
  default     = 30
}

variable "alert_email" {
  description = "E-mail address that receives the budget alerts. Empty = no budget alert is created."
  type        = string
  default     = ""
}
